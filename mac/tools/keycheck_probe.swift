// The app's own RTMP code, driven from the command line, for
// mac/tools/check_keycheck.py. Built the way check_rtmp.py builds
// rtmp_publish.swift: every file in mac/Sources except main.swift, plus this
// as main.swift. Prints one line starting RESULT with JSON after it.
//
//   keycheck_probe keycheck <base> <key> [timeout]
//       StreamKeyCheck.verify, exactly as the Preferences button will call it.
//   keycheck_probe video <base> <key> <server> <seconds>
//       A headless VideoStreamer with no sound going into it, for the
//       refusal, hang up and silence proofs.
//   keycheck_probe radio <host> <port> <seconds>
//       A headless Streamer, for the refused password proof.

import Foundation
import Darwin

func maxResident() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)          // bytes, on macOS
}

func emit(_ fields: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    print("RESULT " + String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

/// Spin the main run loop, because the streamers tell the window on main.
func spin(_ seconds: Double, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end && !done() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else { print("need a mode"); exit(2) }

switch mode {
case "keycheck":
    guard args.count >= 3 else { print("keycheck <base> <key> [timeout]"); exit(2) }
    let timeout = args.count > 3 ? (Double(args[3]) ?? C.streamKeyCheckTimeout)
                                 : C.streamKeyCheckTimeout
    let before = maxResident()
    let result = StreamKeyCheck.verify(base: args[1], key: args[2], timeout: timeout)
    let after = maxResident()
    emit([
        "outcome": result.outcome.rawValue,
        "said": result.serverSaid,
        "detail": result.detail,
        "stage": result.stage?.rawValue ?? "",
        "sent": result.sent,
        "tags_sent": result.tagsSent,
        "seconds": result.seconds,
        "timeout": timeout,
        "rss_before": before,
        "rss_after": after,
        "verdict": StreamKeyCheck.verdict(result, server: "rtmp", key: args[2]),
    ])

case "video":
    guard args.count >= 5 else { print("video <base> <key> <server> <seconds>"); exit(2) }
    let group = MixerGroup(mainDeviceUID: nil, bankDevices: [:])
    let streamer = VideoStreamer()
    var states: [String] = []
    streamer.onState = { state, detail in
        states.append(detail.isEmpty ? state.rawValue : "\(state.rawValue): \(detail)")
    }
    var settings = VideoStreamSettings()
    settings.host = args[1]
    settings.key = args[2]
    settings.server = args[3]
    settings.width = 320
    settings.height = 180
    let started = streamer.start(group: group, settings: settings)
    let seconds = Double(args[4]) ?? 8
    // Stops early once it has given up, but spins on a moment after, so a
    // retry that should not happen has the chance to show itself.
    spin(seconds, until: { streamer.state == .failed })
    spin(1.5)
    let line = streamer.statusLine()
    emit([
        "started": started,
        "states": states,
        "final": streamer.state.rawValue,
        "detail": streamer.detail,
        "attempts": streamer.attempts,
        "media_bytes": streamer.bytesSent,
        "status": line,
    ])
    streamer.stop(group: group)
    group.stop()

case "radio":
    guard args.count >= 4 else { print("radio <host> <port> <seconds>"); exit(2) }
    let group = MixerGroup(mainDeviceUID: nil, bankDevices: [:])
    let streamer = Streamer()
    var states: [String] = []
    streamer.onState = { state, detail in
        states.append(detail.isEmpty ? state.rawValue : "\(state.rawValue): \(detail)")
    }
    var settings = StreamSettings()
    settings.host = args[1]
    settings.port = Int(args[2]) ?? 8000
    settings.mount = "/live"
    settings.password = "wrong"
    let started = streamer.start(group: group, settings: settings)
    spin(Double(args[3]) ?? 6, until: { streamer.state == .failed })
    spin(1.5)
    emit([
        "started": started,
        "states": states,
        "final": streamer.state.rawValue,
        "detail": streamer.detail,
        "attempts": streamer.attempts,
    ])
    streamer.stop(group: group)
    group.stop()

default:
    print("unknown mode \(mode)")
    exit(2)
}
