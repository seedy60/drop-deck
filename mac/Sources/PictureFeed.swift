// One picture pipeline, however many things want to look at it.
//
// Mirrors dropdeck/picturefeed.py (Windows 3.8.1, W381-03). Tony, 12 September
// 2026: "ice cast, shoucast, is not the same as facebook and youtube." The
// picture belongs to the APP, not to where Command+B is pointed.
//
// ## Why this exists
//
// Four things want the picture: the RTMP stream, the file recording, the
// preview behind the shot check and Command+Shift+F. Before this each of them
// built its own with `Picture.build`, so starting a recording off air and then
// going live opened the camera twice, and a preview during a recording opened
// it a third time. **A camera has ONE owner.** Windows measured a second
// capture on one device killing the first one's reader for good, and the app
// then blaming another program for a camera it was holding itself. So there is
// one source here, reference counted, and everybody reads the same frames.
// `Picture.build` has one caller in the app now, and it is `open` below.
//
// ## The rules, all learned somewhere else first
//
// - **Open on the first holder, close on the LAST.** A preview must never be
//   able to close the camera under a live show, and a recording that ends
//   must not take the stream's picture with it.
// - **The new source goes in BEFORE the old one comes out.** A camera is about
//   six tenths of a second to its first frame, and closing first puts a card on
//   the air for that long.
// - **`frame()` never waits on a camera opening.** It is called on the thread
//   carrying the audio.
// - **The title survives a rebuild.**
// - **A source that has been replaced cannot report on the live one.**
//
// ## One deliberate difference from Windows
//
// Windows reads `_source` with no lock at all and argues it is safe because the
// attribute is a single reference. In Swift that is a data race, so there are
// two locks here and neither is EVER held while a source opens or closes:
// `lock` guards the bookkeeping and the published source, and every open and
// close runs on `worker`, a serial queue, in the order it was asked for. So
// acquire, release and rebuild return at once on any thread, the main one
// included, and nothing on the main thread ever waits for a camera (N8,
// W381-09). Opening off the main thread is not only tidiness: the first ever
// camera open asks for permission and that answer arrives ON the main queue,
// so a camera opened there waited two minutes for an answer it was blocking.

import Foundation
import CoreVideo

final class PictureFeed {

    /// What a holder is called, for `describeHolders` and for saying which of
    /// them a card is standing in for. Plain words, because they are spoken.
    static let forStream = "the stream"
    static let forRecording = "the recording"
    static let forPreview = "a preview"

    /// How to make a source. The app's is `Picture.build`; a check hands in
    /// one that opens nothing real.
    typealias Builder = (PictureSettings, @escaping (String) -> Void) -> PictureSource

    private let settingsFor: () -> PictureSettings
    private let build: Builder
    /// Told when the source falls back to the card, or comes back off it. On
    /// whichever thread noticed.
    var onFallback: ((String) -> Void)?
    /// Told after a rebuild has put a new source in. On the worker queue.
    var onChange: (() -> Void)?

    private let lock = NSLock()
    private let worker = DispatchQueue(label: "app.tgstudios.dropdeck.picturefeed")

    private var source: PictureSource?
    /// {name: how many hold it}. A COUNT, because two previews both call
    /// themselves "a preview", and a set of names let the first release close
    /// the camera under the second.
    private var holders: [String: Int] = [:]
    /// The names in the order they first took hold, so a sentence naming them
    /// comes out the same way every time.
    private var order: [String] = []
    /// What the open source was built from, so a later holder can tell
    /// whether it is still the picture that was asked for.
    private var builtFrom: PictureSettings?
    /// The settings the next open or rebuild will use. Read on the caller's
    /// thread when asked, never on the worker, because the board is the
    /// window's.
    private var wanted = PictureSettings()
    /// A rebuild has been asked for and not yet done.
    private var rebuildWanted = false
    /// The source the worker is starting right now, if any. `close` shuts it
    /// at once rather than waiting for a start that may be waiting on a
    /// permission prompt the user has not answered.
    private var opening: PictureSource?
    private var title = ""
    private var reasonNow = ""
    private var asked = 0
    private(set) var builds = 0
    /// How many sources are open right now. Two only for the moment a new
    /// picture goes in before the old one comes out.
    private(set) var openNow = 0
    private(set) var mostOpenAtOnce = 0
    /// Sources open per camera, and the most there have ever been on one
    /// camera at once. NEVER above one: that is the whole point, and a check
    /// asserts it by driving every holder there is.
    private var onCamera: [String: Int] = [:]
    private var cameraOf: [ObjectIdentifier: String] = [:]
    private(set) var mostOnOneCamera = 0

    init(settings: @escaping () -> PictureSettings,
         build: @escaping Builder = { Picture.build($0, onFallback: $1) }) {
        self.settingsFor = settings
        self.build = build
    }

    // --------------------------------------------------------- who wants it --

    /// Somebody wants the picture. Opens it if nobody had it, or if what is
    /// open was built for settings that have since changed. Returns at once;
    /// `waitReady` is for a caller that can afford to wait, never the main
    /// thread.
    ///
    /// **Main thread only**: this reads the settings out of the board. A
    /// caller on any other thread uses `acquire(_:settings:)` with settings it
    /// took on the main thread before it left (audit 1, finding 6).
    @discardableResult
    func acquire(_ who: String) -> PictureFeed {
        acquire(who, settings: settingsFor())
    }

    /// The same, with the settings handed in. Safe on any thread.
    ///
    /// What an open source is compared with is what it was built from, kept
    /// up to date by everything that changes a live source in place (the
    /// split's corner), so a newcomer only rebuilds a picture that really is
    /// a different picture (audit 1, finding 4).
    @discardableResult
    func acquire(_ who: String, settings asked: PictureSettings) -> PictureFeed {
        let settings = PictureFeed.comparable(asked)
        lock.lock()
        if holders[who] == nil { order.append(who) }
        holders[who, default: 0] += 1
        wanted = settings
        let needed = source == nil || builtFrom != settings
        lock.unlock()
        if needed { schedule() }
        return self
    }

    /// One holder lets go. The source closes when the last one does, on the
    /// worker, never under a lock.
    @discardableResult
    func release(_ who: String) -> PictureFeed {
        lock.lock()
        let left = (holders[who] ?? 0) - 1
        if left > 0 {
            holders[who] = left
        } else {
            holders[who] = nil
            order.removeAll { $0 == who }
        }
        let empty = holders.isEmpty
        lock.unlock()
        if empty { schedule() }
        return self
    }

    /// Everybody lets go. For closing the app, where politeness is not the
    /// point.
    func close() {
        lock.lock()
        holders = [:]
        order = []
        lock.unlock()
        schedule()
    }

    /// The settings changed. Swap the source under everybody holding it, new
    /// one in first. False when nothing holds it, which is not a failure:
    /// the next holder gets the new settings anyway.
    @discardableResult
    func rebuild() -> Bool {
        let settings = PictureFeed.comparable(settingsFor())
        lock.lock()
        let held = !holders.isEmpty
        wanted = settings
        if held { rebuildWanted = true }
        lock.unlock()
        if held { schedule() }
        return held
    }

    /// Wait for everything asked of the worker so far to be done. For the
    /// checks, and for a caller off the main thread that needs the answer.
    /// **Never on the main thread**: the worker may be inside a camera start
    /// that waits for a permission answer delivered on the main queue.
    func settle() {
        worker.sync {}
    }

    /// The same, for at most `timeout` seconds. True when the worker finished.
    @discardableResult
    func settle(timeout: Double) -> Bool {
        let done = DispatchSemaphore(value: 0)
        worker.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// How long closing the app waits for the picture to be shut properly.
    static let shutdownWait = 1.0

    /// Closing the app: everybody lets go, anything still opening is shut at
    /// once, and the wait for the worker is SHORT (audit 1, finding 2). It
    /// was `settle()`, a wait with no end, on the main thread, while the
    /// worker could be inside `CameraSource.start()` waiting up to two
    /// minutes for a permission answer that is delivered on the main queue.
    /// Command+Q with the camera prompt up made the app stop responding.
    /// Whatever is still opening is closed here, so it cannot open a session
    /// when its start finally returns, and the worker shuts the rest when it
    /// gets there. True when everything was shut within the wait.
    @discardableResult
    func shutDown(within timeout: Double = PictureFeed.shutdownWait) -> Bool {
        close()
        lock.lock(); let starting = opening; lock.unlock()
        starting?.close()
        return settle(timeout: timeout)
    }

    /// Wait for the REAL picture, not the card standing in for it. Never call
    /// this on the main thread.
    ///
    /// Worth it on any other: a capture's first frame takes a moment and
    /// whoever asks first gets the card.
    @discardableResult
    func waitReady(timeout: Double) -> Bool {
        let began = ProcessInfo.processInfo.systemUptime
        let done = DispatchSemaphore(value: 0)
        worker.async { done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut { return false }
        lock.lock(); let open = source; lock.unlock()
        guard let open else { return false }
        let left = max(0, timeout - (ProcessInfo.processInfo.systemUptime - began))
        return open.waitReady(timeout: left)
    }

    var running: Bool { lock.lock(); defer { lock.unlock() }; return source != nil }

    /// Whether anybody at all holds it, opened yet or not.
    var held: Bool { lock.lock(); defer { lock.unlock() }; return !holders.isEmpty }

    func heldBy(_ who: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (holders[who] ?? 0) > 0
    }

    /// The names holding it, once each however many times over.
    func holderNames() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return order
    }

    /// "the stream and the recording", for a sentence about a fault.
    func describeHolders() -> String {
        PictureFeed.join(holderNames())
    }

    static func join(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        if names.count == 1 { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    // ------------------------------------------------------------ pictures --

    /// The picture at the size asked for. Nil only when nothing is open.
    /// Called on the thread carrying the audio, so it waits on nothing but a
    /// pointer read.
    func frame(width: Int, height: Int) -> CVPixelBuffer? {
        lock.lock()
        let open = source
        if open != nil { asked += 1 }
        lock.unlock()
        return open?.frame(width: width, height: height)
    }

    /// How many frames have been asked of the open source. Nought means
    /// nothing has looked yet, which is not a fallback and must not be
    /// reported as one.
    var framesAsked: Int { lock.lock(); defer { lock.unlock() }; return asked }

    /// The raw camera frame at its own size, for a face detector: through the
    /// fallback and through a split's composite, because what it wants is the
    /// camera and not the card or the desktop.
    func latest() -> CVPixelBuffer? {
        lock.lock(); let open = source; lock.unlock()
        guard let open else { return nil }
        return PictureFeed.cameraFrame(open)
    }

    static func cameraFrame(_ source: PictureSource) -> CVPixelBuffer? {
        if let camera = source as? CameraSource { return camera.latestFrame() }
        if let split = source as? SplitSource { return split.latestFrame() }
        if let fallback = source as? FallbackSource { return cameraFrame(fallback.primary) }
        return nil
    }

    /// What is really being shown. A card IS frozen and must never be
    /// reported as stuck, so a fallback answers "card".
    var kind: String {
        lock.lock(); let open = source; lock.unlock()
        guard let open else { return "" }
        if (open as? FallbackSource)?.fallenBack == true { return C.pictureCard }
        return open.kind
    }

    var moving: Bool {
        lock.lock(); let open = source; lock.unlock()
        return open?.moving ?? false
    }

    var fallenBack: Bool {
        lock.lock(); let open = source; lock.unlock()
        return (open as? FallbackSource)?.fallenBack ?? false
    }

    /// Why the card is standing in, or "" when it is not.
    var reason: String { lock.lock(); defer { lock.unlock() }; return reasonNow }

    func describe() -> String {
        lock.lock(); let open = source; lock.unlock()
        return open?.describe() ?? ""
    }

    /// What is playing, for the card. Remembered for the next build.
    func setTitle(_ text: String) {
        lock.lock()
        title = text
        let open = source
        lock.unlock()
        open?.setTitle(text)
    }

    /// Move a split's camera with no rebuild at all. False when the open
    /// source is not a split, so the caller can rebuild rather than silently
    /// doing nothing.
    @discardableResult
    func setCorner(_ corner: String) -> Bool {
        lock.lock(); let open = source; lock.unlock()
        let target = (open as? FallbackSource)?.primary ?? open
        guard let split = target as? CornerMovable else { return false }
        split.corner = corner
        // The live source has it now, so it is part of what that source was
        // built from. Without this a newcomer (Command+Shift+R, a preview)
        // saw settings that differed from `builtFrom` and closed and reopened
        // the camera under the air to "apply" a corner already applied.
        lock.lock()
        if source === open {
            builtFrom?.splitCorner = split.corner
            wanted.splitCorner = split.corner
        }
        lock.unlock()
        return true
    }

    // ------------------------------------------------------------- the work --

    private func schedule() {
        worker.async { [weak self] in self?.reconcile() }
    }

    /// Make what is open match what is wanted. Only ever on `worker`, so opens
    /// and closes happen one at a time in the order they were asked for, and
    /// a burst of requests collapses into the one that matters.
    private func reconcile() {
        lock.lock()
        let wantOpen = !holders.isEmpty
        let current = source
        let settings = wanted
        let stale = builtFrom != settings
        let forced = rebuildWanted
        rebuildWanted = false
        let heading = title
        lock.unlock()

        if !wantOpen {
            guard let current else { return }
            lock.lock()
            // Somebody may have taken hold again while this was queued.
            if !holders.isEmpty { lock.unlock(); return }
            source = nil
            builtFrom = nil
            reasonNow = ""
            lock.unlock()
            shut(current)
            return
        }
        guard current == nil || stale || forced else { return }

        // Built and STARTED before it is published, and the old one closed
        // after, so a frame asked for in between gets the old picture rather
        // than nothing.
        //
        // **Except when both of them want the SAME camera.** New in before old
        // out would then be two capture sessions on one device, which is the
        // one thing this module exists to make impossible, so the old one is
        // taken out first and the picture holds still for the moment the
        // camera takes to reopen. A still frame for half a second beats a
        // camera fought over by two owners.
        var outgoing = current
        if let old = current,
           let device = PictureFeed.cameraDevice(builtFrom ?? PictureSettings()),
           device == PictureFeed.cameraDevice(settings) {
            lock.lock()
            source = nil
            builtFrom = nil
            lock.unlock()
            shut(old)
            outgoing = nil
        }
        let box = SourceBox()
        let made = build(settings) { [weak self, box] reason in
            self?.fellBack(reason, from: box.source)
        }
        box.source = made
        if !heading.isEmpty { made.setTitle(heading) }
        lock.lock(); opening = made; lock.unlock()
        defer { lock.lock(); if opening === made { opening = nil }; lock.unlock() }

        // **Nothing on the air to hold it, so the card goes out while the
        // real picture opens** (audit 1, finding 3). Published only after
        // `start()` returned, a first open, and every same camera rebuild,
        // sent no video at all: the stream's pump skips a frame the feed
        // cannot give, and a camera's first start can wait up to two minutes
        // on a permission prompt. The fallback's card stands in while its
        // primary starts (W381-31), which is what `startVideoStream` always
        // said happened. With an OLD picture still up, new in before old out
        // is kept: the old picture is better than a card.
        if outgoing == nil, let fallback = made as? FallbackSource {
            fallback.backup.start()
            guard publish(made, settings) else { shut(made); return }
            onChange?()
            fallback.primary.start()
            lock.lock()
            if source === made { reasonNow = made.error }
            lock.unlock()
            onChange?()
            return
        }

        made.start()
        guard publish(made, settings) else {
            // Everybody let go while it was opening.
            shut(made)
            return
        }
        if let outgoing { shut(outgoing) }
        onChange?()
    }

    /// Put a built source up as THE source. False when nobody holds the feed
    /// any more, in which case the caller shuts it. Counted as open either
    /// way, so `shut` can count it closed.
    private func publish(_ made: PictureSource, _ settings: PictureSettings) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        openNow += 1
        mostOpenAtOnce = max(mostOpenAtOnce, openNow)
        builds += 1
        if let device = PictureFeed.cameraDevice(settings) {
            onCamera[device, default: 0] += 1
            cameraOf[ObjectIdentifier(made)] = device
            mostOnOneCamera = max(mostOnOneCamera, onCamera[device] ?? 0)
        }
        guard !holders.isEmpty else { return false }
        source = made
        builtFrom = settings
        reasonNow = made.error
        asked = 0
        return true
    }

    /// Which camera a picture holds, or nil when it holds none. An empty name
    /// is still a camera: it means whichever one macOS offers first.
    static func cameraDevice(_ s: PictureSettings) -> String? {
        C.pictureNeedsCamera.contains(s.picture) ? s.camera : nil
    }

    private func shut(_ old: PictureSource) {
        old.close()
        lock.lock()
        openNow = max(0, openNow - 1)
        if let device = cameraOf.removeValue(forKey: ObjectIdentifier(old)) {
            onCamera[device] = max(0, (onCamera[device] ?? 1) - 1)
        }
        lock.unlock()
    }

    /// The fallback swapped to the card, or came back off it. A source that
    /// has already been replaced is IGNORED: its capture can fall back on the
    /// way out, and that used to write "the camera stopped" over a brand new
    /// healthy source and announce it.
    private func fellBack(_ why: String, from reporter: PictureSource?) {
        lock.lock()
        guard let reporter, let open = source, reporter === open else {
            lock.unlock()
            return
        }
        reasonNow = PictureFeed.isRecovery(why) ? "" : why
        lock.unlock()
        onFallback?(why)
    }

    /// The fallback reports coming back with the same callback it left by.
    static func isRecovery(_ reason: String) -> Bool {
        reason.lowercased().contains("is back")
    }

    /// The settings as far as the PICTURE is concerned. The title changes with
    /// every track and is handed to the source directly, so it must not make
    /// an open source look stale and rebuild the camera once a song.
    static func comparable(_ s: PictureSettings) -> PictureSettings {
        var out = s
        out.title = ""
        return out
    }

    /// Whether a STREAM wants a picture at all. A radio station has nowhere to
    /// put one, and opening a camera for it is a light on in the room for
    /// nothing. A recording always wants one, whatever Command+B is pointed
    /// at, and that distinction is the fault Tony reported. Asked in one
    /// place.
    static func wantedFor(server: String) -> Bool {
        StreamServers.isRTMP(server)
    }

    /// Filled in after the build returns, so the fallback callback knows which
    /// source it belongs to.
    private final class SourceBox {
        weak var source: PictureSource?
    }
}

// ------------------------------------------------- a recording's own pump ---

/// The recording's picture when the stream is not filling it: one frame every
/// 1/fps, out of the shared feed, words on top, into the tap.
///
/// It PULLS FROM THE FEED and never builds a source of its own, which is the
/// whole of W381-01 and W381-03. The pacing clock here is pacing and nothing
/// else: nothing in the file is stamped from it, because the recorder counts
/// frames against its own audio sample clock.
///
/// It also watches what it sends, the same two ways the stream does (W381-38):
/// a picture gone black or frozen, and, through a camera, whether the presenter
/// is in shot. A presenter recording themselves needs that at least as much as
/// one who is live.
final class RecordPicturePump {

    private let feed: PictureFeed
    private let tap: FrameTap
    private let width: Int
    private let height: Int
    private let fps: Int
    /// The words on top, read every frame so an edit or a new track reaches
    /// the file at once (W381-20).
    private let overlay: Overlay
    let health = HealthWatcher()
    let cameraHealth = HealthWatcher()
    private(set) var framer: Framer
    private var thread: Thread?
    private let lock = NSLock()
    private var stopping = false
    private(set) var puts = 0

    init(feed: PictureFeed, tap: FrameTap, width: Int, height: Int, fps: Int,
         overlay: Overlay, framingLevel: String, say: @escaping (String) -> Void) {
        self.feed = feed
        self.tap = tap
        self.width = width
        self.height = height
        self.fps = max(1, fps)
        self.overlay = overlay
        framer = Framer(level: framingLevel, onSay: say)
        health.onSay = say
        cameraHealth.onSay = { text in
            say(text.replacingOccurrences(of: "The picture", with: "The camera"))
        }
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return thread != nil }

    func start() {
        lock.lock()
        guard thread == nil else { lock.unlock(); return }
        stopping = false
        let worker = Thread { [weak self] in self?.run() }
        worker.name = "dropdeck-record-picture"
        worker.qualityOfService = .userInitiated
        thread = worker
        lock.unlock()
        worker.start()
    }

    /// Stop our own thread. The tap is left alone: the stream may be about to
    /// fill it.
    ///
    /// **Returns at once, and nothing reaches the tap after it has** (audit 1,
    /// finding 8). It used to spin on the calling thread, which is the main
    /// one, for up to two seconds until the thread finished, and the thread
    /// could be inside `waitReady` for five or in the framing check: VoiceOver
    /// stalled just as the stream reached ON AIR during a recording. Now the
    /// flag is set under the lock every put is made under, so once this
    /// returns the thread can put nothing more, and it ends by itself.
    func stop() {
        lock.lock()
        stopping = true
        thread = nil
        lock.unlock()
    }

    private var done: Bool { lock.lock(); defer { lock.unlock() }; return stopping }

    private func run() {
        // BEFORE the first question. Asking a capture that has not produced a
        // frame yet gets the card. This thread is not the window's, so waiting
        // here costs the user nothing.
        _ = feed.waitReady(timeout: C.cameraOpenTimeout)
        let step = 1.0 / Double(fps)
        var next = ProcessInfo.processInfo.systemUptime
        while !done {
            if let raw = feed.frame(width: width, height: height) {
                let shown = Pixels.composite(raw, overlay, width: width, height: height)
                // Put under the lock `stop` sets the flag under, and only if
                // it has not been set, so nothing lands after `stop` returns.
                lock.lock()
                if stopping { lock.unlock(); break }
                tap.put(shown)
                puts += 1
                lock.unlock()
                // LAST, and on the composite: what a watcher is asked is
                // whether anybody watching would see anything.
                health.look(buffer: shown, moving: feed.moving)
                if let camera = feed.latest() {
                    cameraHealth.look(buffer: camera, moving: true)
                    if framer.due() { _ = framer.look(camera) }
                }
            }
            next += step
            let wait = next - ProcessInfo.processInfo.systemUptime
            if wait > 0 {
                Thread.sleep(forTimeInterval: wait)
            } else if wait < -1.0 {
                // A long stall is not caught up in a burst.
                next = ProcessInfo.processInfo.systemUptime
            }
        }
    }
}
