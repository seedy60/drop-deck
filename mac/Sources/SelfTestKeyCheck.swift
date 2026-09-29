// The checks for Windows 3.8.4's RTMP half on the Mac: Check my stream key,
// and the streamers telling the truth about being on air.
//
// Everything here runs with no network at all. The conversation itself, with
// real servers that accept, refuse, hang up, chatter and lie about sizes, is
// proved by `mac/tools/check_keycheck.py`, which runs the real Swift against
// `tools/mock_rtmp.py` and against Mac-owned servers in `mac/tools/`. What is
// here is the part that has to hold in the SHIPPED bundle: the reader, the
// sentences, and the decisions.

import Foundation

extension SelfTest {

    func runKeyCheckChecks() {
        testReaderCeiling()
        testAMF0Answers()
        testKeyCheckDecisions()
        testKeyCheckVerdicts()
        testStreamerTruth()
    }

    // ---------------------------------------------------------- the reader ---

    /// A fmt 0 header for one message on one chunk stream.
    private func rtmpHeader(csid: UInt8 = 3, timestamp: Int = 0, length: Int,
                            type: UInt8 = 20) -> Data {
        var out = Data([csid & 0x3f])
        let shown = min(timestamp, 0xffffff)
        out.append(contentsOf: [UInt8((shown >> 16) & 0xff), UInt8((shown >> 8) & 0xff),
                                UInt8(shown & 0xff)])
        out.append(contentsOf: [UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff),
                                UInt8(length & 0xff)])
        out.append(type)
        out.append(contentsOf: [0, 0, 0, 0])
        return out
    }

    private func testReaderCeiling() {
        out.append("")
        out.append("A server cannot make the reader hold what it likes")

        // W384-04. The length field is three bytes, so a server may declare
        // sixteen megabytes and then trickle it, and every byte was held.
        for declared in [1 << 20, 0xffffff] {
            var reader = RTMPChunkReader()
            var wire = rtmpHeader(length: declared)
            wire.append(Data(repeating: 0x41, count: 4096))
            let got = reader.read(from: &wire)
            check("a declared \((declared + (1 << 19)) >> 20) MB message is refused before it is held",
                  reader.tooLarge && got.isEmpty && wire.isEmpty,
                  "tooLarge \(reader.tooLarge), \(got.count) messages, \(wire.count) bytes kept")
        }
        var reader = RTMPChunkReader()
        var fine = rtmpHeader(length: 3)
        fine.append(contentsOf: [0x05, 0x05, 0x05])
        let small = reader.read(from: &fine)
        check("and an ordinary one is not", !reader.tooLarge && small.count == 1)
        check("the ceiling is Windows' own 64 KB", RTMPChunkReader.maxMessage == 64 * 1024)

        // W384-05. A type 3 continuation of an extended timestamp message
        // carries the four extra bytes again, and the reader compared the
        // DECODED timestamp with the marker, so it read four bytes short.
        var body = AMF0.encode(.string("onStatus"))
        body.append(AMF0.encode(.number(0)))
        body.append(AMF0.encode(.null))
        body.append(AMF0.encode(.object([
            ("level", .string("status")),
            ("code", .string("NetStream.Publish.Start")),
            ("description", .string(String(repeating: "Long enough to be cut into pieces. ",
                                            count: 7))),
        ])))
        let extendedAt = 0x0123_4567
        let stamp: [UInt8] = [0x01, 0x23, 0x45, 0x67]
        var wire = rtmpHeader(timestamp: 0xffffff, length: body.count)
        wire.append(contentsOf: stamp)
        var at = body.startIndex
        var first = true
        while at < body.endIndex {
            if !first {
                wire.append(0xc3)
                wire.append(contentsOf: stamp)
            }
            let end = body.index(at, offsetBy: min(128, body.distance(from: at, to: body.endIndex)))
            wire.append(body[at..<end])
            at = end
            first = false
        }
        var after = AMF0.encode(.string("_result"))
        after.append(AMF0.encode(.number(4)))
        after.append(AMF0.encode(.null))
        after.append(AMF0.encode(.number(7)))
        wire.append(rtmpHeader(csid: 3, length: after.count))
        wire.append(after)
        reader = RTMPChunkReader()
        let messages = reader.read(from: &wire)
        check("an extended timestamp message cut into 128 byte chunks comes out whole",
              body.count > 256 && messages.first?.payload == body,
              "\(body.count) bytes, \(messages.count) messages, extended \(extendedAt)")
        check("and the message after it still parses",
              messages.count == 2 && AMF0.firstString(in: AMF0.read(messages[1].payload)) == "_result",
              "\(messages.count) messages")
    }

    // --------------------------------------------------------- the answers ---

    private func testAMF0Answers() {
        out.append("")
        out.append("Reading what a server answered")

        // M10. A strict array, a date or a long string ahead of the status
        // object stopped the reader, and everything after it was lost.
        var payload = AMF0.encode(.string("onStatus"))
        payload.append(AMF0.encode(.number(0)))
        payload.append(AMF0.encode(.strictArray([.number(1), .string("two")])))
        payload.append(Data([0x0b, 0x42, 0x78, 0, 0, 0, 0, 0, 0, 0, 0]))       // a date
        payload.append(Data([0x0c, 0, 0, 0, 3]) + Data("abc".utf8))          // a long string
        payload.append(AMF0.encode(.object([
            ("level", .string("error")),
            ("code", .string("NetStream.Publish.BadName")),
            ("description", .string("Publish Rejected: Invalid URL")),
        ])))
        let values = AMF0.read(payload)
        check("types 0x0A, 0x0B and 0x0C are read past, not stopped at",
              AMF0.code(in: values) == "NetStream.Publish.BadName",
              AMF0.code(in: values) ?? "nothing")
        check("and the platform's own words come out of the status object",
              AMF0.field("description", in: values) == "Publish Rejected: Invalid URL")

        let refused = RTMPHeard(seq: 0, values: values)
        check("an onStatus at level error is not an acceptance", !refused.isAcceptance)
        var yes = AMF0.encode(.string("onStatus"))
        yes.append(AMF0.encode(.number(0)))
        yes.append(AMF0.encode(.null))
        yes.append(AMF0.encode(.object([("level", .string("status")),
                                        ("code", .string("NetStream.Publish.Start"))])))
        check("an onStatus saying Publish.Start is",
              RTMPHeard(seq: 0, values: AMF0.read(yes)).isAcceptance)

        // M1. The answer to createStream carries the stream id, and the
        // transaction says WHICH request it answers.
        var created = AMF0.encode(.string("_result"))
        created.append(AMF0.encode(.number(4)))
        created.append(AMF0.encode(.null))
        created.append(AMF0.encode(.number(7)))
        let heard = RTMPHeard(seq: 3, values: AMF0.read(created))
        check("a _result knows which transaction it answers", heard.transaction == 4)
        check("and carries the server's stream id", heard.number == 7,
              "\(String(describing: heard.number))")

        // W384-07, M9. A status code is never spoken.
        let codeOnly = RTMPClient.saying(code: "NetStream.Publish.BadName")
        check("a refusal with only a code says no code",
              !codeOnly.contains("NetStream") && codeOnly.contains("stream key"), codeOnly)
        let unknown = RTMPClient.saying(code: "Some.Server.Thing")
        check("not even one it does not know", !unknown.contains("Some.Server"), unknown)
        let worded = RTMPClient.saying(refused)
        check("and the platform's own words are kept",
              worded.hasSuffix("It said: Publish Rejected: Invalid URL"), worded)
        check("BadName is a key refused, not something already publishing",
              !codeOnly.contains("already"), codeOnly)
    }

    // ------------------------------------------------------- the decisions ---

    private func testKeyCheckDecisions() {
        out.append("")
        out.append("Check my stream key, without the network")

        check("a status description comes back whole", StreamKeyCheck.said("Start publishing") == "Start publishing")
        check("with its whitespace collapsed",
              StreamKeyCheck.said("  Publish \n Rejected:\tInvalid  URL ") == "Publish Rejected: Invalid URL")
        check("and nothing for nothing", StreamKeyCheck.said(nil) == "" && StreamKeyCheck.said("   ") == "")
        let long = StreamKeyCheck.said(String(repeating: "word ", count: 100))
        check("a long one is capped where a screen reader can bear it",
              long.count == StreamKeyCheck.sayLimit && long.hasSuffix("."), "\(long.count)")

        let youtube = StreamKeyCheck.split("rtmps://a.rtmps.youtube.com/live2")
        check("YouTube's address is rtmps on 443, app live2",
              youtube == RTMPClient.Parts(secure: true, host: "a.rtmps.youtube.com", port: 443, app: "live2"),
              "\(String(describing: youtube))")
        let facebook = StreamKeyCheck.split("rtmps://live-api-s.facebook.com:443/rtmp")
        check("Facebook's names its port and the app is rtmp",
              facebook?.port == 443 && facebook?.app == "rtmp")
        let plain = StreamKeyCheck.split("rtmp://live.restream.io/live/")
        check("plain rtmp is 1935, and a trailing slash is not part of the app",
              plain?.port == 1935 && plain?.app == "live" && plain?.secure == false)
        check("anything but rtmp or rtmps is not an address",
              StreamKeyCheck.split("https://example.com/live") == nil
              && StreamKeyCheck.split("C:/Users/Public") == nil
              && StreamKeyCheck.split("not a url") == nil)

        var result = StreamKeyCheck.verify(base: "rtmps://a.rtmps.youtube.com/live2", key: "  \n ")
        check("an empty key is no key, before anything connects",
              result.outcome == .noKey && result.stage == nil && result.sent.isEmpty)
        result = StreamKeyCheck.verify(base: "https://example.com/live", key: "abcd")
        check("an https address is a bad address, before anything connects",
              result.outcome == .badAddress && result.stage == nil && result.sent.isEmpty)
        check("YouTube's address is the fixed one whatever is typed",
              StreamKeyCheck.address(server: "youtube", typed: "rtmp://elsewhere/x")
                  == C.rtmpIngest["youtube"])
        check("a custom server's is what is typed",
              StreamKeyCheck.address(server: "rtmp", typed: " rtmp://my.server/live ")
                  == "rtmp://my.server/live")

        // W384-06. A drop means the key only once publish has gone out.
        check("a hang up after publish is a refusal",
              StreamKeyCheck.gaveUp(.publish).outcome == .refused)
        check("and anywhere earlier is the network",
              [StreamKeyCheck.Stage.open, .handshake, .connect, .createStream]
                  .allSatisfy { StreamKeyCheck.gaveUp($0).outcome == .noAnswer })

        // W384-09. Asked unless it is KNOWN to be safe.
        check("only Facebook is checked without asking first",
              !StreamKeyCheck.needsAsking("facebook") && StreamKeyCheck.needsAsking("youtube")
              && StreamKeyCheck.needsAsking("restream") && StreamKeyCheck.needsAsking("rtmp"))
        check("a custom server is not known to be safe any more",
              C.rtmpGoesLiveAtOnce.keys.contains("rtmp") && StreamKeyCheck.goesLiveAtOnce("rtmp") == nil)
        let asking = StreamKeyCheck.question(server: "youtube") ?? ""
        check("the YouTube question says it cannot put you on the air",
              asking.contains("cannot put you on the air") && asking.hasSuffix("Check the key now?"),
              asking)
        let custom = StreamKeyCheck.question(server: "rtmp") ?? ""
        check("and a custom server's says nobody knows what connecting does",
              custom.contains("is not a service Drop Deck knows"), custom)
        check("Facebook is not asked", StreamKeyCheck.question(server: "facebook") == nil)
    }

    private func testKeyCheckVerdicts() {
        out.append("")
        out.append("What the check says, outcome by outcome")

        let key = "abcd-efgh-ijkl"
        func verdict(_ outcome: StreamKeyCheck.Outcome, _ server: String = "youtube",
                     said: String = "") -> String {
            StreamKeyCheck.verdict(StreamKeyCheck.Result(outcome, said: said),
                                   server: server, key: key)
        }
        let yes = verdict(.accepted)
        check("an accepted YouTube key says so, and says nothing was broadcast",
              yes.contains("accepted your stream key") && yes.contains("nothing was broadcast"), yes)
        check("and names the reason a good key still shows nothing",
              yes.contains("auto start") && yes.contains("Go live"), yes)
        let fb = verdict(.accepted, "facebook")
        check("an accepted Facebook key says nothing was posted",
              fb.contains("nothing was posted") && fb.contains("Go Live Now"), fb)
        let no = verdict(.refused, said: "Publish Rejected: Invalid URL")
        check("a refusal repeats the platform's own words",
              no.contains("It said: Publish Rejected: Invalid URL."), no)
        let quiet = verdict(.refused)
        check("a refusal with no words still explains itself",
              quiet.contains("closed the connection") && quiet.contains("expired"), quiet)
        check("and never puts the whole key on screen",
              !quiet.contains(key) && quiet.contains("ijkl"), quiet)
        let outcomes: [StreamKeyCheck.Outcome] = [.accepted, .refused, .noServer, .noRoute,
                                                   .noTLS, .noAnswer, .noKey, .badAddress]
        var bad: [String] = []
        for outcome in outcomes {
            for server in ["youtube", "facebook", "restream", "rtmp"] {
                let line = verdict(outcome, server)
                let plain = line.first?.isUppercase == true && line.hasSuffix(".")
                let leaks = ["rtmp://", "rtmps://", "youtube.com", "facebook.com",
                             "restream.io", "Errno", "NetStream", key]
                    .contains { line.contains($0) }
                if !plain || leaks { bad.append("\(server) \(outcome.rawValue): \(line)") }
            }
        }
        check("every verdict is a plain sentence with no address, code or key in it",
              bad.isEmpty, bad.joined(separator: " | "))
        check("a refusal says nothing was broadcast too",
              verdict(.refused, "facebook").contains("nothing was broadcast"))
    }

    // ------------------------------------------------- the streamers' truth ---

    private func testStreamerTruth() {
        out.append("")
        out.append("A streamer tells the truth about being on air")

        // W384-15, M5. Refusals stop on ANY attempt.
        let cases: [(String, StreamFault, Int, Bool)] = [
            ("a refused key", RTMPError.refused("the server refused the stream key").fault, 4, true),
            ("a hang up after publish", RTMPError.keyRefused.fault, 4, true),
            ("an address that is not RTMP", RTMPError.notRTMP.fault, 1, true),
            ("a malformed address", RTMPError.badURL.fault, 3, true),
            ("a refused password", .refused("the server refused the password"), 6, true),
            ("no sound ever", .noSound, 2, true),
            ("a name that will not resolve, at Command B", RTMPError.notFound("x").fault, 1, true),
            ("the same name on a reconnect", RTMPError.notFound("x").fault, 3, false),
            ("the audio that stopped arriving", SilenceWatch.fault(idle: 9, mediaBytes: 10)!, 3, false),
            ("a dropped connection", RTMPError.hungUp.fault, 3, false),
            ("a timeout", RTMPError.timedOut.fault, 1, false),
            ("a socket that would not open", RTMPError.unreachable("x").fault, 1, false),
        ]
        for (name, fault, attempts, fatal) in cases {
            check("\(name) \(fatal ? "stops" : "keeps trying") on attempt \(attempts)",
                  Retry.isFatal(fault, attempts: attempts) == fatal)
        }

        // W384-16. The two sentences, and when.
        check("no silence is said inside the limit",
              SilenceWatch.fault(idle: C.streamSilenceTimeout - 0.1, mediaBytes: 0) == nil)
        check("past it, with nothing ever sent, it is the setup",
              SilenceWatch.fault(idle: C.streamSilenceTimeout + 0.1, mediaBytes: 0) == .noSound)
        check("and that sentence is Windows' own",
              StreamFault.noSound.said.hasPrefix("no sound ever reached the stream, so nothing was broadcast"))
        check("past it, after something went out, the audio stopped arriving",
              SilenceWatch.fault(idle: C.streamSilenceTimeout + 0.1, mediaBytes: 1)
                  == .dropped("the audio stopped arriving"))

        // W384-17.
        check("Command Shift B says nothing has left the machine after two seconds",
              SilenceWatch.nothingYetNote(liveFor: 2.1, mediaBytes: 0)?
                  .hasPrefix("but nothing has left this machine yet") == true)
        check("but not straight after Command B, and not once something has gone",
              SilenceWatch.nothingYetNote(liveFor: 1.9, mediaBytes: 0) == nil
              && SilenceWatch.nothingYetNote(liveFor: 30, mediaBytes: 1) == nil)
        check("and it names the Mac's sound card page",
              SilenceWatch.nothingYet.hasSuffix("Preferences, Output"))

        // M13 and M6, on the real objects.
        let group = MixerGroup(mainDeviceUID: nil, bankDevices: [:])
        let radio = Streamer()
        check("a new state is said", radio.applyState(.retrying, "the server did not answer"))
        check("the same state and reason is not said again",
              !radio.applyState(.retrying, "the server did not answer"))
        check("a different reason is", radio.applyState(.retrying, "the connection dropped"))
        check("a worker from another run changes nothing",
              !radio.applyState(.live, "x", generation: radio.generation + 1) && radio.state == .retrying)
        radio.stop(group: group)
        check("and after Command B off, not even this run's worker can say on air",
              !radio.applyState(.live, "x", generation: radio.generation) && radio.state == .off)

        let video = VideoStreamer()
        check("the video streamer says a new state", video.applyState(.retrying, "a"))
        check("and not the same one twice", !video.applyState(.retrying, "a"))
        video.stop(group: group)
        check("and after Command B off its worker cannot say on air",
              !video.applyState(.live, "x", generation: video.generation) && video.state == .off)

        // W384-15 on the real video streamer, with no network at all: an
        // address that is not RTMP used to be retried for ever from the first
        // attempt, saying "Off air, trying again" each time.
        var settings = VideoStreamSettings()
        settings.server = "rtmp"
        settings.host = "ftp://example.com/live"
        settings.key = "not-a-real-key"
        settings.width = 320
        settings.height = 180
        let failing = VideoStreamer()
        _ = failing.start(group: group, settings: settings)
        let until = Date().addingTimeInterval(5)
        while Date() < until && failing.state != .failed { Thread.sleep(forTimeInterval: 0.05) }
        check("a video address that is not RTMP stops on the first attempt",
              failing.state == .failed && failing.attempts == 1 && !failing.isOn,
              "\(failing.state) after \(failing.attempts) attempts: \(failing.detail)")
        check("and says why in Windows' words",
              failing.detail.hasPrefix("that server address is not an RTMP one"), failing.detail)
        failing.stop(group: group)

        // M5 on the radio streamer, again with no network: a port that is not
        // valid set FAILED and was overwritten with RETRYING on the next line.
        var radioSettings = StreamSettings()
        radioSettings.host = "127.0.0.1"
        radioSettings.port = 0
        let refusing = Streamer()
        _ = refusing.start(group: group, settings: radioSettings)
        let by = Date().addingTimeInterval(5)
        while Date() < by && refusing.state != .failed { Thread.sleep(forTimeInterval: 0.05) }
        Thread.sleep(forTimeInterval: 0.3)
        check("a radio streamer told no stays told no",
              refusing.state == .failed && refusing.attempts == 1 && !refusing.isOn,
              "\(refusing.state) after \(refusing.attempts) attempts: \(refusing.detail)")
        refusing.stop(group: group)
        group.stop()
    }
}
