// Going out on YouTube, Facebook, Restream, or anything else that speaks RTMP.
//
// The counterpart of `Streamer` in StreamOut.swift, which sends audio to a
// radio server. Command+B goes to one or the other, never both: two
// destinations means two encoders and twice the upload, and it is not built.
//
// ## Audio is the master clock, and this is where that lives
//
// **Video timestamps count frames encoded against the audio sample counter,
// never a wall clock and never the camera's own timing.** Carried across from
// Windows unchanged, and it is the single most important thing in the video
// work. Three things fall out of it and none of them would survive a different
// choice:
//
//   * the picture can be swapped mid stream without the timeline moving,
//     because the clock does not belong to the picture;
//   * sound and picture cannot drift, because there is only one clock;
//   * a slow frame costs a frame rather than a second, because the pump asks
//     "how many frames should exist by now" rather than "how long since last
//     time".
//
// Measured against the mock server by `mac/tools/check_rtmp.py`: sound and
// picture finished 0 ms apart over a three second publish.
//
// ## The catch-up limit is not a knob
//
// Measured on Windows on 7 September 2026: with the pump running four times a
// second, video left in bursts of eight frames with a fifth of a second of
// nothing between them, which is what "choppy" looks like from the sending end
// even though the AVERAGE gap was a perfect 33 ms. So no more than
// `C.rtmpCatchupFrames` go out in one turn of the loop.

import Foundation
import AVFoundation
import CoreVideo

final class VideoStreamer {

    private(set) var state: StreamState = .off
    private(set) var detail = ""
    private(set) var startedAt: Date?
    private(set) var reconnects = 0
    private(set) var behindSeconds: Double = 0

    /// Told when the state changes, so the window can speak it and relabel a
    /// menu. Always called on the main queue.
    var onState: ((StreamState, String) -> Void)?
    /// Told when the picture falls back, or comes back, or dies. One sentence.
    var onSay: ((String) -> Void)?

    private let lock = NSLock()
    private var bus: AirBus?
    private weak var group: MixerGroup?
    private var thread: Thread?
    private var stopping = false
    /// The connection in use, or being made. Held under `lock` so Command B
    /// can hang it up from the main thread while the worker is inside
    /// `connect()`, which is where the stop race lived (M6).
    private var client: RTMPClient?
    /// Which run a worker belongs to. See `Streamer.generation`.
    private(set) var generation = 0
    /// Connection attempts in this run, the first being 1.
    private(set) var attempts = 0
    /// Audio and video that really went out, across every connection of this
    /// run: the frames, not the sequence headers and not the metadata.
    private(set) var mediaBytes = 0
    /// Video frames that really went out (M7). `videoFrames` is the CLOCK and
    /// counts frames that were due, including ones the picture never made.
    private(set) var framesSent = 0
    private(set) var liveSince: Date?
    private var encoder: VideoEncoder?
    private var source: PictureSource?
    private var wantedSource: PictureSource?
    private var overlay = Overlay()
    /// Watches what actually goes out, for a picture that has gone black.
    private let health = HealthWatcher()
    /// Watches the CAMERA on its own, for one that has stopped moving.
    ///
    /// Separate because the two questions have different subjects. Black is a
    /// fault in the whole picture and is asked of the whole picture. Frozen is
    /// a fault in a source that is supposed to be live, and on a shared screen
    /// the camera is a sixteenth of the frame, so asking the composite gets
    /// the answer "nothing moved" whatever the camera is doing.
    private let cameraHealth = HealthWatcher()
    private(set) var framer = Framer()

    private var settings = VideoStreamSettings()
    private var currentTitle = ""
    /// Samples read off the bus. The master clock.
    private var samplesSent = 0
    private var videoFrames = 0

    var isOn: Bool {
        lock.lock(); defer { lock.unlock() }
        return state != .off && state != .failed
    }

    var elapsed: Double { startedAt.map { -$0.timeIntervalSinceNow } ?? 0 }
    /// What has gone out that a viewer could receive (M8). It used to be
    /// every byte including the handshake, which is never nought.
    var bytesSent: Int { lock.lock(); defer { lock.unlock() }; return mediaBytes }

    // ------------------------------------------------------------ going on ---

    @discardableResult
    func start(group: MixerGroup, settings: VideoStreamSettings) -> Bool {
        guard !isOn else { return true }
        guard !settings.host.isEmpty else {
            set(.failed, "there is no video platform set up yet")
            return false
        }
        guard !settings.key.isEmpty else {
            set(.failed, "there is no stream key for this station")
            return false
        }
        self.settings = settings
        let rate = group.sampleRate
        let bus = AirBus(sampleRate: rate)
        self.bus = bus
        self.group = group
        group.addAirBus(bus)

        overlay.apply(settings.overlay)
        framer = Framer(level: settings.framingLevel,
                        onSay: { [weak self] text in self?.say(text) })
        health.reset()
        health.onSay = { [weak self] text in self?.say(text) }
        cameraHealth.reset()
        cameraHealth.onSay = { [weak self] text in
            // Named, because "the picture has frozen" is not true of the
            // picture when only the inset has stopped.
            self?.say(text.replacingOccurrences(of: "The picture", with: "The camera"))
        }

        lock.lock()
        stopping = false
        generation += 1
        let run = generation
        attempts = 0
        mediaBytes = 0
        framesSent = 0
        liveSince = nil
        lock.unlock()
        samplesSent = 0
        videoFrames = 0
        startedAt = Date()
        applyState(.connecting, "", generation: run)

        let worker = Thread { [weak self] in self?.run(rate: rate, generation: run) }
        worker.name = "dropdeck-rtmp"
        worker.qualityOfService = .userInitiated
        thread = worker
        worker.start()
        return true
    }

    func stop(group: MixerGroup) {
        lock.lock()
        stopping = true
        let open = client
        client = nil
        let picture = source
        let waiting = wantedSource
        source = nil
        wantedSource = nil
        lock.unlock()
        // Hung up first, so a worker inside connect() is woken by the close
        // rather than finishing the conversation and going live after it.
        open?.close()
        thread?.cancel()
        thread = nil
        if let bus { group.removeAirBus(bus) }
        bus = nil
        picture?.close()
        waiting?.close()
        encoder?.close()
        encoder = nil
        startedAt = nil
        liveSince = nil
        applyState(.off, "")
    }

    /// Change what is going out, without dropping the stream.
    ///
    /// The new source is built and STARTED here and picked up by the pump on
    /// its next turn, so nothing that blocks happens on the thread carrying
    /// the audio.
    /// Returns what went wrong, or "" when it did not. The caller says so:
    /// a switcher that reports success whatever happened is a switcher that
    /// leaves somebody broadcasting a card and believing otherwise.
    @discardableResult
    func setPicture(_ picture: PictureSettings) -> String {
        let made = Picture.build(picture, onFallback: { [weak self] text in
            self?.say(text)
        })
        made.start()
        let ready = made.waitReady(timeout: C.cameraOpenTimeout)
        made.setTitle(currentTitle)
        lock.lock()
        // Off air by the time it opened, a refusal having come back first:
        // closed rather than left holding the camera for nobody.
        let wanted = state != .off && state != .failed && !stopping
        if wanted { wantedSource = made }
        lock.unlock()
        if !wanted { made.close(); return "" }
        if ready { return "" }
        // A card cannot fail and never reports one, so an error here is the
        // real source saying it could not open.
        let trouble = made.error
        return trouble.isEmpty
            ? "\((C.pictureLabels[picture.picture] ?? picture.picture).lowercased()) "
              + "did not start" : trouble
    }

    func setOverlay(_ settings: OverlaySettings) {
        overlay.apply(settings)
    }

    func setTitle(_ title: String) {
        currentTitle = title
        overlay.setTitle(title)
        lock.lock()
        source?.setTitle(title)
        wantedSource?.setTitle(title)
        lock.unlock()
    }

    /// The frame going out right now, for the shot check.
    ///
    /// The picture that is really on the air, so "how does my shot look" is
    /// answered about what viewers can see rather than about a fresh grab
    /// taken while the presenter was moving.
    func currentFrame() -> CVPixelBuffer? {
        lock.lock(); let picture = source; lock.unlock()
        guard let picture else { return nil }
        guard let frame = picture.frame(width: settings.width,
                                        height: settings.height) else { return nil }
        return Pixels.composite(frame, overlay, width: settings.width,
                                height: settings.height)
    }

    /// What is on the screen, in words.
    func describePicture() -> String {
        lock.lock(); let picture = source; lock.unlock()
        return picture?.describe() ?? "nothing yet"
    }

    /// What the stream is doing, for Command+Shift+B.
    func statusLine() -> String {
        lock.lock()
        let now = state
        let said = detail
        let frames = framesSent
        let sent = mediaBytes
        let since = liveSince
        lock.unlock()
        switch now {
        case .off: return "Off air"
        case .connecting: return "Connecting"
        case .failed: return "Off air. \(said)"
        case .retrying: return "Reconnecting. \(said)"
        case .live:
            let seconds = Int(elapsed)
            let where_ = StreamServers.serverLabel(settings.server)
            var line = "On air to \(where_) for \(seconds / 60) minutes "
                     + "\(seconds % 60) seconds, \(frames) frames sent"
            // **Whether anything has actually left the machine** (W384-17).
            if let nothing = SilenceWatch.nothingYetNote(
                liveFor: since.map { -$0.timeIntervalSinceNow } ?? 0, mediaBytes: sent) {
                line += ", " + nothing
            }
            if let source { line += ", showing \(source.describe())" }
            let picture = health.describe()
            if picture != "the picture looks fine" { line += ". " + picture }
            return line
        }
    }

    // ------------------------------------------------------------ the pump ---

    private func run(rate: Double, generation run: Int) {
        guard let bus else { return }
        guard let aac = AACEncoder(rate: rate, bitrate: settings.audioBitrate) else {
            applyState(.failed, "the sound encoder would not start", generation: run)
            return
        }
        let chunk = AACEncoder.frameSize
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(chunk))
        else { return }
        var interleaved = [Float](repeating: 0, count: chunk * 2)

        let video = VideoEncoder(width: settings.width, height: settings.height,
                                 fps: settings.fps, bitrate: settings.videoBitrate)
        guard video.open() else {
            applyState(.failed, video.error, generation: run)
            return
        }
        encoder = video

        var sequenceSent = false
        var backoff = 1.0
        var live: RTMPClient?
        var lastAudio = ProcessInfo.processInfo.systemUptime
        var failed = false

        /// Hang up the connection in use, if any.
        func hangUp() {
            lock.lock()
            let open = client
            client = nil
            lock.unlock()
            open?.close()
            live = nil
        }

        /// One failure, decided: stop for good, or wait and go round again.
        /// Returns false when the run is over.
        func survive(_ fault: StreamFault) -> Bool {
            hangUp()
            lock.lock(); let tries = attempts; lock.unlock()
            if Retry.isFatal(fault, attempts: tries) {
                applyState(.failed, fault.said, generation: run)
                failed = true
                return false
            }
            reconnects += 1
            applyState(.retrying, fault.said, generation: run)
            var waited = 0.0
            while waited < backoff && current(run) {
                Thread.sleep(forTimeInterval: 0.1)
                waited += 0.1
            }
            backoff = min(15.0, backoff * 2)
            return true
        }

        while current(run) {
            if live == nil {
                let made = RTMPClient(url: settings.host, key: settings.key)
                lock.lock()
                attempts += 1
                // Held where stop() can reach it BEFORE the conversation
                // starts, so Command B during connect() hangs this up.
                self.client = made
                lock.unlock()
                do {
                    try made.connect()
                    guard current(run) else { hangUp(); break }
                    live = made
                    backoff = 1.0
                    sequenceSent = false
                    try made.send(metadata: FLV.metadata(
                        width: settings.width, height: settings.height,
                        fps: settings.fps, videoBitrate: settings.videoBitrate,
                        audioBitrate: settings.audioBitrate,
                        sampleRate: Int(rate), channels: 2))
                    try made.send(audio: FLV.audio(
                        FLV.audioSpecificConfig(sampleRate: Int(rate), channels: 2),
                        sequence: true), timestamp: 0)
                    applyState(.live, StreamServers.serverLabel(settings.server),
                               generation: run)
                    lock.lock(); liveSince = Date(); lock.unlock()
                    lastAudio = ProcessInfo.processInfo.systemUptime
                } catch {
                    if survive(fault(for: error)) { continue }
                    break
                }
            }
            guard let link = live else { continue }

            // A platform that is going to refuse may do it after the first
            // frames rather than at publish, so it is asked every turn.
            if let refused = link.refusal() {
                hangUp()
                applyState(.failed, refused, generation: run)
                failed = true
                break
            }

            // The picture is swapped here rather than under the caller, so the
            // old one is closed on this thread and never while it is being read.
            lock.lock()
            if let wanted = wantedSource {
                let old = source
                source = wanted
                wantedSource = nil
                lock.unlock()
                old?.close()
                health.reset()
                cameraHealth.reset()
                video.forceKeyframe()
            } else {
                lock.unlock()
            }

            let ready = bus.available()
            behindSeconds = Double(ready) / rate
            if ready < chunk {
                Thread.sleep(forTimeInterval: C.streamPollSeconds)
                // **Nothing off the bus is not a broadcast** (W384-16). This
                // used to sleep and go round for ever, ON AIR with nothing
                // leaving the machine.
                let idle = ProcessInfo.processInfo.systemUptime - lastAudio
                lock.lock(); let sent = mediaBytes; lock.unlock()
                if let fault = SilenceWatch.fault(idle: idle, mediaBytes: sent) {
                    lastAudio = ProcessInfo.processInfo.systemUptime
                    if survive(fault) { continue }
                    break
                }
                continue
            }
            lastAudio = ProcessInfo.processInfo.systemUptime

            interleaved.withUnsafeMutableBufferPointer { raw in
                bus.read(frames: chunk, into: raw.baseAddress!)
                pcm.frameLength = AVAudioFrameCount(chunk)
                guard let channels = pcm.floatChannelData else { return }
                for i in 0..<chunk {
                    channels[0][i] = raw[i * 2]
                    channels[1][i] = raw[i * 2 + 1]
                }
            }
            samplesSent += chunk
            let milliseconds = Int(Double(samplesSent) * 1000.0 / rate)

            var ok = true
            if let packet = aac.encode(pcm) {
                for frame in VideoStreamer.adtsFrames(packet) {
                    let raw = FLV.stripADTS(frame)
                    do {
                        try link.send(audio: FLV.audio(raw, sequence: false),
                                        timestamp: milliseconds)
                        lock.lock(); mediaBytes += raw.count; lock.unlock()
                    } catch { ok = false; break }
                }
            }

            if ok { ok = pumpVideo(client: link, video: video,
                                   milliseconds: milliseconds,
                                   sequenceSent: &sequenceSent) }
            if !ok {
                // A drop, not a refusal: straight back round to reconnect.
                hangUp()
                reconnects += 1
                applyState(.retrying, "the connection dropped", generation: run)
            }
        }
        video.close()
        hangUp()
        if failed { releaseAfterFailure(run, bus: bus) }
    }

    /// What a connect failure means for a retry, in words that name the
    /// platform rather than its address.
    private func fault(for error: Error) -> StreamFault {
        guard let rtmp = error as? RTMPError else { return .dropped("\(error)") }
        if case .keyRefused = rtmp {
            // Windows' sentence for the same refusal, with the platform's
            // name where Windows puts the host, because a host name is a run
            // of letter clusters to a screen reader.
            return .refused("\(StreamServers.serverLabel(settings.server)) would not take "
                          + "the stream key. Check it has been copied in full and has not "
                          + "expired")
        }
        return rtmp.fault
    }

    /// How many frames should exist by now, capped.
    private func pumpVideo(client: RTMPClient, video: VideoEncoder,
                           milliseconds: Int, sequenceSent: inout Bool) -> Bool {
        lock.lock(); let picture = source; lock.unlock()
        guard let picture else { return true }

        let wanted = milliseconds * settings.fps / 1000
        var behind = wanted - videoFrames
        if behind <= 0 { return true }
        // See the note at the top: a burst is what choppy looks like.
        behind = min(behind, C.rtmpCatchupFrames)

        for _ in 0..<behind {
            guard let frame = picture.frame(width: settings.width,
                                            height: settings.height) else {
                videoFrames += 1
                continue
            }
            // The overlay goes on here, once per frame, into a buffer of our
            // own. See Pixels.composite for why it must not go onto the one
            // the source handed back.
            let shown = Pixels.composite(frame, overlay, width: settings.width,
                                         height: settings.height)
            health.look(buffer: shown, moving: picture.moving)
            // And the camera on its own, when there is one. A camera that has
            // stopped delivering is caught by staleness in CameraSource; this
            // catches the other kind, where frames keep arriving and they are
            // all the same picture.
            if let camera = VideoStreamer.cameraFrame(picture) {
                cameraHealth.look(buffer: camera, moving: true)
            }
            if framer.due(), let camera = VideoStreamer.cameraFrame(picture) {
                framer.look(camera)
            }
            let at = videoFrames * 1000 / settings.fps
            video.encode(shown, milliseconds: at)
            videoFrames += 1
        }

        for out in video.drain() {
            do {
                if !sequenceSent, let config = video.config {
                    try client.send(video: FLV.video(config.record(), keyframe: true,
                                                     sequence: true),
                                    timestamp: out.timestamp)
                    sequenceSent = true
                }
                try client.send(video: FLV.video(out.data, keyframe: out.keyframe,
                                                 sequence: false),
                                timestamp: out.timestamp)
                lock.lock(); framesSent += 1; mediaBytes += out.data.count; lock.unlock()
            } catch {
                return false
            }
        }
        return true
    }

    /// The camera's own picture, for the framing checker.
    ///
    /// NOT the composite: on a shared screen that is mostly desktop with the
    /// presenter a quarter of the width in the corner, and a face detector
    /// given that would report a shot nobody is actually in.
    static func cameraFrame(_ source: PictureSource) -> CVPixelBuffer? {
        if let camera = source as? CameraSource { return camera.latestFrame() }
        if let split = source as? SplitSource { return split.latestFrame() }
        if let fallback = source as? FallbackSource {
            return cameraFrame(fallback.primary)
        }
        return nil
    }

    /// An AAC packet from the app's encoder is one or more ADTS frames, and
    /// each declares its own length. RTMP carries the raw frames.
    static func adtsFrames(_ packet: Data) -> [Data] {
        var out: [Data] = []
        var at = packet.startIndex
        while packet.distance(from: at, to: packet.endIndex) > 7 {
            let b3 = Int(packet[packet.index(at, offsetBy: 3)])
            let b4 = Int(packet[packet.index(at, offsetBy: 4)])
            let b5 = Int(packet[packet.index(at, offsetBy: 5)])
            let length = ((b3 & 0x03) << 11) | (b4 << 3) | ((b5 & 0xe0) >> 5)
            guard length > 7,
                  packet.distance(from: at, to: packet.endIndex) >= length else { break }
            let end = packet.index(at, offsetBy: length)
            out.append(packet.subdata(in: at..<end))
            at = end
        }
        // Not ADTS at all: hand it back whole rather than dropping the audio.
        return out.isEmpty ? [packet] : out
    }


    private func say(_ text: String) {
        guard !text.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onSay?(text) }
    }

    private func set(_ newState: StreamState, _ newDetail: String) {
        applyState(newState, newDetail)
    }

    /// Change the state, and tell the window, unless nothing changed. See
    /// `Streamer.applyState`: an unchanged state is not said again (M13), and
    /// a worker from a stopped or replaced run changes nothing (M6).
    @discardableResult
    func applyState(_ newState: StreamState, _ newDetail: String,
                    generation run: Int? = nil) -> Bool {
        lock.lock()
        if let run, run != generation || stopping {
            lock.unlock()
            return false
        }
        if state == newState && detail == newDetail {
            lock.unlock()
            return false
        }
        state = newState
        detail = newDetail
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onState?(newState, newDetail)
        }
        return true
    }

    private func current(_ run: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return run == generation && !stopping
    }

    /// A run that ended itself lets go of the programme bus and the picture,
    /// or the camera stays open, and the bus filled, for nobody.
    private func releaseAfterFailure(_ run: Int, bus used: AirBus) {
        lock.lock()
        let same = run == generation
        let picture = same ? source : nil
        let waiting = same ? wantedSource : nil
        if same { source = nil; wantedSource = nil }
        lock.unlock()
        picture?.close()
        waiting?.close()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // The bus THIS run used, whatever has happened since: a Command B
            // straight after the failure has already made a new one.
            self.group?.removeAirBus(used)
            if self.bus === used { self.bus = nil }
        }
    }
}

/// What a video broadcast needs. Built from the board, the same way
/// `StreamSettings` is, and deliberately SEPARATE from the picture's own
/// settings: Windows keeps three dictionaries here and the reason is a bug
/// that shipped. Reading the picture out of the destination's settings gives a
/// board pointed at a radio station no picture key at all, and the shot check
/// then confidently describes a card the user never chose.
struct VideoStreamSettings {
    var server = "youtube"
    var host = ""
    var key = ""
    var width = C.rtmpWidth
    var height = C.rtmpHeight
    var fps = C.rtmpFPS
    var videoBitrate = C.rtmpVideoBitrate
    var audioBitrate = C.defaultStreamBitrate
    var framingLevel = C.framingProblems
    var overlay = OverlaySettings()
}
