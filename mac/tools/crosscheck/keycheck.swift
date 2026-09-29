import Foundation

func py(_ b: Bool) -> String { b ? "True" : "False" }
func flat(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: "\\n") }

var out: [String] = []
for url in ["rtmps://a.rtmps.youtube.com/live2",
            "rtmps://live-api-s.facebook.com:443/rtmp",
            "rtmp://live.restream.io/live", "rtmp://live.restream.io/live/",
            "RTMP://Example.COM/App", "rtmp://example.com",
            "rtmp://example.com:1936/a/b", "  rtmp://padded.example/live  ",
            "https://example.com/live", "not a url", "", "C:/Users/Public",
            "rtmp:///nohost", "udp://239.0.0.1:1234"] {
    if let parts = StreamKeyCheck.split(url) {
        out.append("split|\(url)|\(parts.secure ? "rtmps" : "rtmp")|\(parts.host)|\(parts.port)|\(parts.app)")
    } else {
        out.append("split|\(url)|None")
    }
}

for text in ["", "   ", "Start publishing", "  Publish \n Rejected:\tInvalid  URL ",
             String(repeating: "x", count: 199), String(repeating: "x", count: 200),
             String(repeating: "x", count: 201), String(repeating: "word ", count: 100)] {
    out.append("said|\(text.count)|\(StreamKeyCheck.said(text))")
}
out.append("said|none|\(StreamKeyCheck.said(nil))")

for stage in [StreamKeyCheck.Stage.handshake, .connect, .createStream, .publish] {
    out.append("gaveup|\(stage.rawValue)|\(StreamKeyCheck.gaveUp(stage, detail: "x").outcome.rawValue)")
}

let outcomes: [StreamKeyCheck.Outcome] = [.accepted, .refused, .noServer, .noRoute, .noTLS,
                                           .noAnswer, .badAddress, .noKey]
for platform in ["youtube", "facebook", "restream", "rtmp"] {
    out.append("label|\(platform)|\(StreamKeyCheck.label(platform))")
    out.append("asks|\(platform)|\(py(StreamKeyCheck.needsAsking(platform)))")
    if let question = StreamKeyCheck.question(server: platform) {
        out.append("question|\(platform)|\(flat(question))")
        out.append("question-title|\(platform)|\(StreamKeyCheck.questionTitle)")
    } else {
        out.append("question|\(platform)|None")
    }
    for outcome in outcomes {
        for said in ["", "Publish Rejected: Invalid URL"] {
            let text = StreamKeyCheck.verdict(StreamKeyCheck.Result(outcome, said: said),
                                              server: platform, key: "abcd-efgh-1234")
            out.append("verdict|\(platform)|\(outcome.rawValue)|\(said)|\(text)")
        }
    }
}

out.append("fixed|stillChecking|\(StreamKeyCheck.stillChecking)")
out.append("fixed|declined|\(StreamKeyCheck.declined)")
out.append("fixed|buttonHelp|\(StreamKeyCheck.buttonHelp)")
out.append("fixed|nothingTriedYet|\(StreamKeyCheck.nothingTriedYet)")
out.append("fixed|checkingWith|\(StreamKeyCheck.checkingWith(server: "youtube"))")
print(out.joined(separator: "\n"))
