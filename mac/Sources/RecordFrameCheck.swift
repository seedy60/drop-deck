// Every picture into the file, once, in order: measured rather than assumed.
//
//     TGDropDeck --check-record-frames [seconds] [width] [height] [depth] [lead]
//
// The Mac's counterpart to the measurement Windows made on 12 September 2026
// before it changed `FrameTap` (W381-26): **a one slot handover between two
// independent clocks loses frames**, and nothing in the recorder can see it,
// because every count is right and the file plays. Windows burned a decodable
// index into every produced frame, recorded, decoded the file back and found
// 455 of 1800 pictures (25.3 per cent) never arrived, with the same share of
// the file being duplicates.
//
// This does the same here, with nothing real opened. No camera and no screen
// capture: a synthetic source on its OWN thread and its OWN clock, the way a
// camera is, draws its frame number as sixteen black and white blocks across
// the top of the picture. Silence is written into the recorder's bus in real
// time on a second thread, the way the mixers do, so the recorder is clocked
// by audio exactly as it is in a show. The REAL `VideoRecorder` writes the
// MP4, and `AVAssetReader` reads it back and reads the numbers off the pixels.
//
// What it reports: how many pictures were produced, how many different ones
// reached the file, how many in the middle never arrived, and how many file
// frames repeat the one before. The last two are the fault.
//
// **And where the picture sits against the sound.** Once a second the silence
// carries a 10 ms tone burst at exactly the moment the synthetic camera puts
// down a frame, so the file says how far the picture landed from its sound,
// read off the decoded pixels and the decoded audio rather than off the
// container's headers. `depth` and `lead` override `FrameTap.depth` and
// `C.recordTapLeadFrames` for one run, which is how both were chosen: swept,
// one variable at a time, never reasoned about.

import Foundation
import AVFoundation
import CoreVideo
import CoreMedia

enum RecordFrameCheck {

    /// Sixteen bits, one block each, across the top eighth of the picture.
    static let bits = 16

    /// A frame with `index` burned into it, plus a moving bar so the encoder
    /// has a real picture to encode rather than a still.
    static func frame(index: Int, width: Int, height: Int) -> CVPixelBuffer? {
        Pixels.draw(width: width, height: height) { ctx in
            ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let blockW = width / bits
            let blockH = max(8, height / 8)
            for bit in 0..<bits {
                let on = (index >> (bits - 1 - bit)) & 1 == 1
                let v: CGFloat = on ? 1 : 0
                ctx.setFillColor(red: v, green: v, blue: v, alpha: 1)
                // Core Graphics counts from the bottom, so the top band is
                // height minus the block.
                ctx.fill(CGRect(x: bit * blockW, y: height - blockH,
                                width: blockW, height: blockH))
            }
            let bar = (index * 7) % max(1, width - 40)
            ctx.setFillColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)
            ctx.fill(CGRect(x: bar, y: height / 3, width: 40, height: height / 3))
        }
    }

    /// The number read back off a decoded frame. Zero for a frame with no
    /// number on it, which is what black looks like.
    static func read(_ buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?
                .assumingMemoryBound(to: UInt8.self) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let blockW = width / bits
        let blockH = max(8, height / 8)
        var value = 0
        for bit in 0..<bits {
            let x = bit * blockW + blockW / 2
            let y = blockH / 2
            let p = base + y * stride + x * 4
            let lum = (Int(p[0]) + Int(p[1]) + Int(p[2])) / 3
            value = (value << 1) | (lum > 128 ? 1 : 0)
        }
        return value
    }

    /// What the file turned out to hold.
    struct Tally {
        var produced = 0
        var fileFrames = 0
        var distinct = 0
        var missing = 0
        var repeats = 0
        var black = 0
        var first = 0
        var last = 0
        var puts = 0
        var repeatedByRecorder = 0
        var droppedByRecorder = 0

        var missingShare: Double {
            let span = max(1, last - first + 1)
            return Double(missing) / Double(span)
        }
        var repeatShare: Double {
            Double(repeats) / Double(max(1, fileFrames))
        }
    }

    /// Count the fault out of a list of indices in file order.
    static func tally(_ seen: [Int], produced: Int) -> Tally {
        var t = Tally()
        t.produced = produced
        t.fileFrames = seen.count
        let real = seen.filter { $0 > 0 }
        t.black = seen.count - real.count
        let unique = Set(real)
        t.distinct = unique.count
        t.first = real.min() ?? 0
        t.last = real.max() ?? 0
        if t.last >= t.first, t.first > 0 {
            t.missing = (t.first...t.last).filter { !unique.contains($0) }.count
        }
        var previous = -1
        for v in seen where v > 0 {
            if v == previous { t.repeats += 1 }
            previous = v
        }
        return t
    }

    private final class Flag { var stop = false; let lock = NSLock()
        func set() { lock.lock(); stop = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return stop }
    }

    static func run(seconds: Double, width: Int, height: Int,
                    depth: Int = FrameTap.depth,
                    lead: Int = C.recordTapLeadFrames) -> Int32 {
        let rate = 48000.0
        let fps = 30
        let folder = NSTemporaryDirectory() + "dropdeck-frame-check"
        try? FileManager.default.removeItem(atPath: folder)
        try? FileManager.default.createDirectory(atPath: folder,
                                                 withIntermediateDirectories: true)
        let taps = Taps()
        let tap = FrameTap(depth: depth)
        let recorder = VideoRecorder()
        recorder.tapLead = lead
        guard let path = recorder.start(taps: taps, rate: rate, width: width,
                                        height: height, fps: fps, folder: folder,
                                        tap: tap) else {
            print("FAILED: the recorder would not start: \(recorder.lastError ?? "")")
            return 2
        }
        let stop = Flag()
        // One moment both clocks count from, a little in the future so both
        // threads are waiting for it rather than one starting late.
        let began = ProcessInfo.processInfo.systemUptime + 0.2

        // The mixers' stand in: silence, in real time, 10 ms at a time, paced
        // against the monotonic clock rather than slept, so it does not drift.
        // Sample n belongs to the moment began + n / rate, and on every whole
        // second there is a 10 ms burst of 1 kHz, which is where the camera
        // below puts down frame 30 j + 1.
        let audio = Thread {
            let block = 480
            var samples = [Float](repeating: 0, count: block * 2)
            let wait = began - ProcessInfo.processInfo.systemUptime
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            var written = 0
            let burst = Int(rate / 100)
            while !stop.isSet {
                let due = Int((ProcessInfo.processInfo.systemUptime - began) * rate)
                while written + block <= due {
                    for i in 0..<block {
                        let n = written + i
                        let into = n % Int(rate)
                        let v: Float = into < burst
                            ? Float(0.5 * sin(2.0 * Double.pi * 1000.0 * Double(into) / rate))
                            : 0
                        samples[i * 2] = v
                        samples[i * 2 + 1] = v
                    }
                    samples.withUnsafeBufferPointer {
                        taps.write(key: "check", samples: $0.baseAddress!,
                                   frames: block, rate: rate)
                    }
                    written += block
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        audio.name = "dropdeck-check-audio"
        audio.qualityOfService = .userInteractive

        // The camera's stand in, on its own clock. Frames are drawn ahead of
        // time so drawing costs nothing on the schedule.
        var produced = 0
        let total = Int(seconds * Double(fps))
        var made: [CVPixelBuffer] = []
        for i in 1...total {
            if let f = frame(index: i, width: width, height: height) { made.append(f) }
        }
        let producer = Thread {
            for (i, f) in made.enumerated() {
                if stop.isSet { break }
                let due = began + Double(i) / Double(fps)
                let wait = due - ProcessInfo.processInfo.systemUptime
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                tap.put(f)
                produced = i + 1
            }
        }
        producer.name = "dropdeck-check-camera"
        producer.qualityOfService = .userInitiated

        audio.start()
        producer.start()
        Thread.sleep(forTimeInterval: seconds + 0.3)
        stop.set()
        Thread.sleep(forTimeInterval: 0.1)
        recorder.stop(taps: taps)

        let pictures = decode(path)
        var t = tally(pictures.map { $0.index }, produced: produced)
        let offsets = syncOffsets(pictures: pictures, sounds: decodeBursts(path, rate: rate),
                                  fps: fps)
        t.puts = tap.puts
        t.repeatedByRecorder = recorder.repeated
        t.droppedByRecorder = recorder.droppedPictures
        print("file            : \(path)")
        print("size            : \(width) by \(height) at \(fps), \(seconds) seconds")
        print("tap depth       : \(tap.depth)")
        print("produced        : \(t.produced)")
        print("put in the tap  : \(t.puts)")
        print("frames in file  : \(t.fileFrames)")
        print("black frames    : \(t.black)")
        print("distinct shown  : \(t.distinct)")
        print("span            : \(t.first) to \(t.last)")
        print(String(format: "never arrived   : %d (%.1f per cent)", t.missing,
                     t.missingShare * 100))
        print(String(format: "repeated frames : %d (%.1f per cent of the file)",
                     t.repeats, t.repeatShare * 100))
        print("recorder repeats: \(t.repeatedByRecorder)")
        print("recorder skips  : \(t.droppedByRecorder)")
        print("tap lead        : \(lead)")
        if offsets.isEmpty {
            print("sync            : no burst could be matched to a picture")
        } else {
            let sorted = offsets.sorted()
            let median = sorted[sorted.count / 2]
            let mean = offsets.reduce(0, +) / Double(offsets.count)
            print(String(format: "sync            : picture %+.1f ms against its sound, "
                         + "median of %d, mean %+.1f (from %+.1f to %+.1f)",
                         median, sorted.count, mean, sorted.first!, sorted.last!))
        }
        return 0
    }

    /// Where each second's picture landed against its sound, in milliseconds.
    /// Positive is the picture LATER than the sound.
    static func syncOffsets(pictures: [(index: Int, seconds: Double)],
                            sounds: [Double], fps: Int) -> [Double] {
        var firstShown: [Int: Double] = [:]
        for p in pictures where p.index > 0 && firstShown[p.index] == nil {
            firstShown[p.index] = p.seconds
        }
        var out: [Double] = []
        for sound in sounds {
            let second = Int(sound.rounded())
            guard second >= 1, abs(sound - Double(second)) < 0.4,
                  let shown = firstShown[second * fps + 1] else { continue }
            out.append((shown - sound) * 1000.0)
        }
        return out
    }

    /// When each tone burst starts, in seconds of the file.
    static func decodeBursts(_ path: String, rate: Double) -> [Double] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let semaphore = DispatchSemaphore(value: 0)
        var track: AVAssetTrack?
        Task {
            track = try? await asset.loadTracks(withMediaType: .audio).first
            semaphore.signal()
        }
        semaphore.wait()
        guard let track else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var mono: [Float] = []
        var origin: Double?
        while let sample = output.copyNextSampleBuffer() {
            if origin == nil {
                origin = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { f in
                var i = 0
                while i < count { mono.append(f[i]); i += 2 }
            }
        }
        let start = origin ?? 0
        var out: [Double] = []
        var quiet = 0
        let needQuiet = Int(rate * 0.5)
        for (i, v) in mono.enumerated() {
            if abs(v) > 0.1 {
                if quiet >= needQuiet { out.append(start + Double(i) / rate) }
                quiet = 0
            } else {
                quiet += 1
            }
        }
        return out
    }

    /// Every video frame of the file, in order, as the number drawn on it and
    /// the moment it is shown.
    static func decode(_ path: String) -> [(index: Int, seconds: Double)] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let semaphore = DispatchSemaphore(value: 0)
        var track: AVAssetTrack?
        Task {
            track = try? await asset.loadTracks(withMediaType: .video).first
            semaphore.signal()
        }
        semaphore.wait()
        guard let track else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var seen: [(index: Int, seconds: Double)] = []
        while let sample = output.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                seen.append((read(buffer),
                             CMSampleBufferGetPresentationTimeStamp(sample).seconds))
            }
        }
        return seen
    }
}
