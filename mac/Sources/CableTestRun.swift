// Test the cable, the half that opens sound cards. See CableTest.swift for
// the half that judges, which opens nothing and is what cross_check.py holds
// to Windows' `cabletest.py`; this file is kept apart so that half compiles
// on its own.

import Foundation

extension CableTest {

    /// What came back, gathered on the capture thread.
    private final class Heard {
        var samples: [Float] = []
        let lock = NSLock()
        func take(_ p: UnsafePointer<Float>, frames: Int, channels: UInt32) {
            lock.lock()
            for i in 0..<frames { samples.append(p[i * Int(channels)]) }
            lock.unlock()
        }
    }

    private final class Stopper { var wanted = false }

    /// Play a tone out of a device and record its own input side. Blocking,
    /// for `seconds`, so it belongs on a thread. Never throws; every failure
    /// is a Result with a sentence.
    static func run(uid: String, name: String, seconds: Double = seconds) -> Result {
        guard let device = AudioDevices.deviceID(forUID: uid),
              let info = AudioDevices.info(for: device) else {
            return Result(said: "macOS knows about \(name) but the audio system cannot open "
                + "it. Try unplugging and replugging it, or restarting Drop Deck.")
        }
        guard info.inputChannels >= 1 else { return Result(said: noFarEnd(name)) }

        // The far end first, so the leading silence is the cable's own
        // latency and not this function's.
        let heard = Heard()
        let input = InputUnit()
        input.onCapture = { p, frames, channels in heard.take(p, frames: frames, channels: channels) }
        guard input.open(deviceUID: uid) else {
            return Result(said: "The cable could not be opened. "
                + "\(input.lastError ?? "No reason was given.") "
                + "Something else may have exclusive use of it.")
        }
        let rate = input.captureRate

        // Its own output, not the show's send. Opened but not started, so a
        // cushion of tone is in its ring before anything drains it: see
        // SendCheck for why a harness writing on a wall clock needs one.
        let out = Send(deviceUID: uid, gainDB: 0, openStream: false)
        let block = 512
        var phase = 0.0
        let step = 2.0 * Double.pi * toneHz / out.sampleRate
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: block * 2)
        defer { buffer.deallocate() }
        func fill() {
            for i in 0..<block {
                let v = toneLevel * Float(sin(phase))
                buffer[i * 2] = v
                buffer[i * 2 + 1] = v
                phase += step
                if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
            }
            out.bus.write(key: "cable-test", samples: buffer, frames: block, rate: out.sampleRate)
        }
        var cushion = 0
        while cushion < Int(out.sampleRate * SendCheck.cushionSeconds) { fill(); cushion += block }
        guard out.start(), out.isRunning else {
            input.close()
            return Result(said: "The cable could not be opened. "
                + "\(out.lastError ?? "No reason was given.") "
                + "Something else may have exclusive use of it.")
        }

        let stopping = Stopper()
        let feeding = DispatchSemaphore(value: 0)
        let feeder = Thread {
            let started = Date()
            var sent = 0
            while !stopping.wanted {
                let due = Int(Date().timeIntervalSince(started) * out.sampleRate)
                if sent > due {
                    Thread.sleep(forTimeInterval: Double(block) / out.sampleRate / 2)
                    continue
                }
                fill()
                sent += block
            }
            feeding.signal()
        }
        feeder.name = "dropdeck-cable-test"
        feeder.qualityOfService = .userInitiated
        feeder.start()

        Thread.sleep(forTimeInterval: seconds)
        input.close()
        stopping.wanted = true
        _ = feeding.wait(timeout: .now() + 1.0)
        out.close()

        heard.lock.lock()
        let signal = heard.samples
        heard.lock.unlock()
        guard !signal.isEmpty else {
            return Result(said: "Nothing was recorded from \(name) at all, so the cable "
                + "could not be measured.")
        }
        // The first moments are the two sides starting at slightly different
        // times, which is not a gap in anybody's audio.
        let skip = min(signal.count / 4, Int(rate * 0.25))
        return judge(Array(signal[skip...]), rate: rate, heard: name)
    }
}
