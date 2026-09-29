// Proving the cable works, by sending a tone down it and listening (W380-01).
//
// A name for name port of Windows' `dropdeck/cabletest.py`. Everything else
// about a send is inferred: a sound card opens, reports a healthy stream, and
// says nothing whatever about whether a sample reached the other program. So
// this plays a tone out of the device the show goes to, records the other end
// of the same cable at the same time, and says what came back.
//
// Three things it can tell you, and only one of them is "it works": nothing
// came back; it came back with holes in it, which sounds like a change in
// pitch rather than dropouts; or it came back clean, with a level.
//
// **On a Mac the far end of a cable is the same device.** A Core Audio cable is
// one device with an output side and an input side and one name, so where
// Windows has to find the recording endpoint that partners a playback one
// (`capture_for`), this only asks whether the device has an input side at all.
//
// It opens its OWN output on the device, not the send: a test through the live
// path measures the show as well as the tone, and somebody may want to prove a
// cable before ever turning a send on. And it never runs itself. The send page
// refuses it while the show is on air or recording, because it puts a tone
// into a cable somebody may be in a call on.
//
// `judge`, `levelAt` and `silenceIn` know nothing about sound cards, so every
// verdict is checked against audio made by hand, and `mac/tools/cross_check.py`
// holds them to the Windows module sample for sample.

import Foundation

enum CableTest {

    /// The tone: 1000 Hz, in the middle of everything a call codec keeps, at
    /// 0.3, because a test that clips tells you nothing about a show that does
    /// not, and full scale in somebody's headphones is unkind.
    static let toneHz = 1000.0
    static let toneLevel: Float = 0.3
    /// How long it listens.
    static let seconds = 2.0
    /// A block counts as a gap when its loudest sample is under this: more
    /// than twenty decibels under the tone.
    static let gapBelow: Float = 0.05
    static let gapBlock = 64
    /// Below this much of the tone arriving, nothing is getting through.
    static let arrivedDB = -60.0
    /// More than this share of the recording silent is a fault worth naming.
    static let gapShareOK = 0.5

    struct Result: Equatable {
        var ok = false
        var said = ""
        var levelDB = -999.0
        var gapShare = 0.0
        var gaps = 0
        var rate = 0
        /// The device it listened on, for the report.
        var heard = ""
    }

    // -------------------------------------------------------- measurement ---

    /// How loud one frequency is in a recording, in dBFS: numpy's symmetric
    /// Hann window, the real DFT bins inside `hz` plus or minus `width`, the
    /// biggest of them, doubled and divided by the window's sum.
    ///
    /// An ABSOLUTE level, never a ratio against the noise floor, for the
    /// reason Windows gives: a pure tone has a median of essentially zero, so
    /// a ratio came back as three hundred decibels. Only the bins in the band
    /// are computed, exactly, rather than a whole FFT: the answer is the same
    /// number and it needs no FFT of an awkward length.
    static func levelAt(_ signal: [Float], rate: Double, hz: Double = toneHz,
                        width: Double = 40.0) -> Double {
        let n = signal.count
        guard n >= 16 else { return -999.0 }
        // np.hanning(M): 0.5 + 0.5 * cos(pi * k / (M - 1)), k from 1 - M to
        // M - 1 in steps of two. Symmetric, with M - 1 underneath, and NOT
        // vDSP's periodic Hann.
        var windowed = [Double](repeating: 0, count: n)
        var windowSum = 0.0
        let span = Double(n - 1)
        for i in 0..<n {
            let w = 0.5 + 0.5 * cos(Double.pi * Double(1 - n + 2 * i) / span)
            windowSum += w
            windowed[i] = Double(signal[i]) * w
        }
        // np.fft.rfftfreq(n, 1 / rate): bin k is k * (1 / (n * (1 / rate))).
        let step = 1.0 / (Double(n) * (1.0 / rate))
        var bins: [Int] = []
        for k in 0...(n / 2) {
            let f = Double(k) * step
            if f > hz - width && f < hz + width { bins.append(k) }
        }
        guard !bins.isEmpty else { return -999.0 }
        // One table of the unit circle, indexed by k * i mod n, so no angle is
        // ever computed from a product large enough to lose precision.
        var cosines = [Double](repeating: 0, count: n)
        var sines = [Double](repeating: 0, count: n)
        for m in 0..<n {
            let angle = 2.0 * Double.pi * Double(m) / Double(n)
            cosines[m] = cos(angle)
            sines[m] = sin(angle)
        }
        var peak = 0.0
        for k in bins {
            var re = 0.0, im = 0.0, m = 0
            for i in 0..<n {
                re += windowed[i] * cosines[m]
                im -= windowed[i] * sines[m]
                m += k
                if m >= n { m -= n }
            }
            peak = max(peak, (re * re + im * im).squareRoot())
        }
        let amplitude = 2.0 * peak / windowSum
        return 20.0 * log10(max(amplitude, 1e-12))
    }

    /// How much of a recording is silent: the share as a percentage, and in
    /// how many separate runs. One long gap at the start is the far end
    /// opening late; sixty short ones through it is the fault.
    static func silenceIn(_ signal: [Float]) -> (share: Double, runs: Int) {
        let usable = signal.count / gapBlock * gapBlock
        guard usable >= gapBlock else { return (100.0, 1) }
        let blocks = usable / gapBlock
        var quiet = [Bool](repeating: false, count: blocks)
        for b in 0..<blocks {
            var loudest: Float = 0
            for i in (b * gapBlock)..<((b + 1) * gapBlock) { loudest = max(loudest, abs(signal[i])) }
            quiet[b] = loudest < gapBelow
        }
        var runs = quiet[0] ? 1 : 0
        for b in 1..<max(1, blocks) where quiet[b] && !quiet[b - 1] { runs += 1 }
        let count = quiet.filter { $0 }.count
        return (Double(count) / Double(blocks) * 100.0, runs)
    }

    /// The whole verdict on a recording of the far end. Windows' sentences,
    /// with the Mac's place to look where Windows names its volume mixer.
    static func judge(_ signal: [Float], rate: Double, heard: String = "") -> Result {
        let db = levelAt(signal, rate: rate)
        let (share, runs) = silenceIn(signal)
        let whole = Int(rate)
        if db < arrivedDB {
            return Result(ok: false, said: "Nothing came back. The other end of the cable "
                + "heard silence, so the show is not reaching it. Check that the send is "
                + "pointed at the cable's playback end and that nothing has it muted in "
                + "Audio MIDI Setup.",
                levelDB: db, gapShare: share, gaps: runs, rate: whole, heard: heard)
        }
        // One run of any length is the tone starting or stopping, not a fault.
        if share > gapShareOK && runs > 1 {
            return Result(ok: false, said: String(format: "The tone came back, but %.1f per "
                + "cent of it was missing, in %d separate gaps. That is audio being lost on "
                + "the way into the cable, and it sounds like a change in pitch rather than "
                + "like dropouts, so it is easy to mistake for something else. Tell Tony, "
                + "because the output buffer is supposed to make this impossible.",
                share, runs),
                levelDB: db, gapShare: share, gaps: runs, rate: whole, heard: heard)
        }
        let where_ = heard.isEmpty ? "" : " Listening on \(heard)."
        // Python's round is banker's rounding, and `.rounded()` is not.
        let said = "The cable is working. The tone came back at "
            + "\(Int(db.rounded(.toNearestOrEven))) decibels with nothing missing, at "
            + "\(whole) hertz.\(where_)"
        return Result(ok: true, said: said, levelDB: db, gapShare: share, gaps: runs,
                      rate: whole, heard: heard)
    }

    // ------------------------------------------------------------- the run ---

    static let choose = "Choose an output first, and then I can test it."
    static let notWhileLive = "Not while you are on air or recording. This puts a tone "
        + "down the cable, which everybody listening would hear."

    static func testing(_ name: String) -> String { "Testing \(name). Two seconds." }

    /// A device with no input side has no far end to listen on.
    static func noFarEnd(_ name: String) -> String {
        "There is no recording device that is the other end of \(name), so there is "
            + "nothing to listen on. A virtual audio cable has two ends and this looks "
            + "like a sound card rather than a cable."
    }
}
