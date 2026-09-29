import Foundation

var out: [String] = []
func py(_ value: Double) -> String {
    // Python's str() of these constants.
    value == value.rounded() && abs(value) < 1e15 ? String(format: "%.1f", value) : "\(value)"
}
out.append("const|\(py(CableTest.toneHz))|\(CableTest.toneLevel)|"
    + "\(py(CableTest.seconds))|\(CableTest.gapBelow)|\(CableTest.gapBlock)|"
    + "\(py(CableTest.arrivedDB))|\(py(CableTest.gapShareOK))")

func tone(_ count: Int, _ rate: Double, hz: Double = 1000.0, level: Double = 0.3) -> [Float] {
    let step = 2.0 * Double.pi * hz / rate
    return (0..<count).map { Float(level * sin(step * Double($0))) }
}

func holes(_ signal: [Float], every: Int, length: Int, start: Int = 0) -> [Float] {
    var s = signal
    for at in stride(from: start, to: s.count, by: every) {
        for i in at..<min(at + length, s.count) { s[i] = 0 }
    }
    return s
}

let cases: [(String, [Float], Double, String)] = [
    ("clean48", tone(48000, 48000), 48000, "Drop Deck Audio"),
    ("clean44", tone(77175, 44100), 44100, ""),
    ("clean96", tone(96000, 96000), 96000, "Loopback Audio"),
    ("silence", [Float](repeating: 0, count: 48000), 48000, "x"),
    ("quiet", tone(48000, 48000, level: 0.0005), 48000, ""),
    ("faint", tone(48000, 48000, level: 0.002), 48000, ""),
    ("holed", holes(tone(48000, 48000), every: 4800, length: 240), 48000, ""),
    ("many", holes(tone(48000, 48000), every: 640, length: 64), 48000, ""),
    ("late", holes(tone(48000, 48000), every: 480000, length: 4800), 48000, "late"),
    ("tiny", [Float](repeating: 0.5, count: 10), 48000, ""),
    ("short", tone(100, 48000), 48000, ""),
    ("low", tone(48000, 48000, hz: 961.0), 48000, ""),
    ("high", tone(48000, 48000, hz: 1039.5), 48000, ""),
    ("off", tone(48000, 48000, hz: 1200.0), 48000, ""),
    ("loud", tone(47999, 48000, level: 0.99), 48000, ""),
]

for (name, signal, rate, heard) in cases {
    out.append("level|\(name)|" + String(format: "%.6f", CableTest.levelAt(signal, rate: rate)))
    let (share, runs) = CableTest.silenceIn(signal)
    out.append("silence|\(name)|" + String(format: "%.6f", share) + "|\(runs)")
    let result = CableTest.judge(signal, rate: rate, heard: heard)
    out.append("judge|\(name)|\(result.ok ? "True" : "False")|\(result.rate)|\(result.said)")
}

print(out.joined(separator: "\n"))
