// The checks for Windows 3.8.2's two destinations with two keys and two
// names, and the Windows 3.8.4 interface half: Check my stream key on the
// Video streaming page, the reason a Go live will not go said first, the auto
// start wording, and the setting-up help.
//
// Every decision here is a pure function on purpose, so each one is held to
// its sentence with no window, no network and no streamer running.

import AppKit

extension SelfTest {

    func runTwoKeysChecks() {
        testTwoKeysBound()
        testWhatAKeyDoes()
        testAirMenuTitles()
        testKeySplitSentences()
        testWhereItGoesByChannel()
        testGoLiveSummary()
        testAutoStartWording()
        testCheckMyStreamKeyButton()
        testNoDisabledButtons()
        testTwoKeysHelp()
    }

    // ------------------------------------------------------------- the keys ---

    private func testTwoKeysBound() {
        out.append("")
        out.append("One key per destination (W382-07)")

        let video = KeyMap.menuKey(.streamToggle)
        let radio = KeyMap.menuKey(.streamToggleRadio)
        check("Command B is the video platform",
              video?.0 == "b" && video?.1 == [.command],
              video.map { KeyMap.spell(key: $0.0, mods: $0.1) } ?? "none")
        check("and the radio station has a key of its own, Option Shift B",
              radio?.0 == "b" && radio?.1 == [.option, .shift],
              radio.map { KeyMap.spell(key: $0.0, mods: $0.1) } ?? "none")
        check("which is spelled the way F1 and the manual say it",
              radio.map { KeyMap.spell(key: $0.0, mods: $0.1) } == "Option+Shift+B",
              radio.map { KeyMap.spell(key: $0.0, mods: $0.1) } ?? "none")
        // Control plus Option is VoiceOver's own modifier, and Option Command
        // plus a digit is the frozen beds bank. Neither may carry a go live key.
        check("no go live key is built on Control Option or Option Command",
              [radio?.1, video?.1].allSatisfy {
                  guard let mods = $0 else { return false }
                  return !mods.contains([.control, .option]) && !mods.contains([.option, .command])
              })
        check("the Windows Control B is still the VIDEO key, as Ctrl+B is on Windows",
              KeyMap.windowsAliases["b"] == .streamToggle)
        check("each destination knows its command, and each command its destination",
              OnAir.command(C.liveToVideo) == .streamToggle
              && OnAir.command(C.liveToAudio) == .streamToggleRadio
              && OnAir.destination(.streamToggle) == C.liveToVideo
              && OnAir.destination(.streamToggleRadio) == C.liveToAudio
              && OnAir.destination(.streamStatus) == nil)
        check("the keys are named the Mac way in a sentence",
              OnAir.key(C.liveToVideo) == "Command B"
              && OnAir.key(C.liveToAudio) == "Option Shift B")
        check("and each destination has words of its own",
              OnAir.words(C.liveToVideo) == "your video platform"
              && OnAir.words(C.liveToAudio) == "your radio station")
    }

    private func testWhatAKeyDoes() {
        out.append("")
        out.append("Each key toggles its own destination (W382-08, W382-09)")

        let v = C.liveToVideo, a = C.liveToAudio
        // The key IS the choice, written down before the pre-flight reads it.
        check("the video key on a radio board points it at video first",
              OnAir.press(v, liveTo: a, videoOn: false, radioOn: false) == .goLive(pointAt: true))
        check("the radio key on a video board points it at radio first",
              OnAir.press(a, liveTo: v, videoOn: false, radioOn: false) == .goLive(pointAt: true))
        check("and a key already pointed at its own place changes nothing",
              OnAir.press(v, liveTo: v, videoOn: false, radioOn: false) == .goLive(pointAt: false)
              && OnAir.press(a, liveTo: a, videoOn: false, radioOn: false)
                 == .goLive(pointAt: false))

        check("the video key comes off video",
              OnAir.press(v, liveTo: v, videoOn: true, radioOn: false) == .comeOff)
        check("the radio key comes off radio",
              OnAir.press(a, liveTo: a, videoOn: false, radioOn: true) == .comeOff)

        // The wrong key while live says where you are and does NOTHING else.
        let onVideo = OnAir.press(a, liveTo: v, videoOn: true, radioOn: false)
        check("the radio key during a video broadcast says where you are",
              onVideo == .elsewhere("You are on air to your video platform. "
                                    + "Command B comes off air."), "\(onVideo)")
        let onRadio = OnAir.press(v, liveTo: a, videoOn: false, radioOn: true)
        check("the video key during a radio broadcast says where you are",
              onRadio == .elsewhere("You are on air to your radio station. "
                                    + "Option Shift B comes off air."), "\(onRadio)")
        check("whatever Streaming location says, the streamers decide",
              OnAir.press(a, liveTo: a, videoOn: true, radioOn: false) == onVideo)
    }

    private func testAirMenuTitles() {
        out.append("")
        out.append("Two On air items, each Come off air only when its own streamer is on (N1)")

        let off = OnAir.menuTitles(videoOn: false, radioOn: false)
        check("off air they say where each one goes",
              off.video == "Go live on video" && off.radio == "Go live on radio")
        let video = OnAir.menuTitles(videoOn: true, radioOn: false)
        check("on video, only the video item offers to come off",
              video.video == "Come off air" && video.radio == "Go live on radio")
        let radio = OnAir.menuTitles(videoOn: false, radioOn: true)
        check("on radio, only the radio item offers to come off",
              radio.video == "Go live on video" && radio.radio == "Come off air")
        check("the feedback report knows a video broadcast is streaming (N2)",
              OnAir.streaming(audio: false, video: true)
              && OnAir.streaming(audio: true, video: false)
              && !OnAir.streaming(audio: false, video: false))
    }

    private func testKeySplitSentences() {
        out.append("")
        out.append("No sentence says Command B goes somewhere it no longer goes (W382-11, W382-13)")

        check("changing where it goes while on video names Command B",
              OnAir.comeOffFirst(videoOn: true, radioOn: false)
              == "Come off air first, Command B, then change where it goes")
        check("and while on radio names Option Shift B, not Command B",
              OnAir.comeOffFirst(videoOn: false, radioOn: true)
              == "Come off air first, Option Shift B, then change where it goes")

        let moved = OnAir.locationMoved(to: C.liveToAudio, summary: "Blindside Radio, x/live",
                                        stops: [])
        check("Streaming location moved to the radio station names the radio key",
              moved == "Streaming location is now my radio station, Blindside Radio, "
                     + "x/live. Option Shift B goes live there", moved)
        check("and never says Command B now goes there",
              !moved.contains("Command B now goes to"), moved)
        let blocked = OnAir.locationMoved(to: C.liveToVideo, summary: "YouTube Live",
                                          stops: ["There is no stream key for this station"])
        check("moved to video names Command B and says what is stopping it",
              blocked.hasSuffix("Command B goes live there. There is no stream key for "
                                + "this station"), blocked)

        let status = OnAir.offAirStatus(liveTo: C.liveToAudio, summary: "Blindside Radio")
        check("Command Shift B off air names the key that would really go there",
              status == "Off air. Option Shift B would go to Blindside Radio", status)
        check("and Command B for the video platform",
              OnAir.offAirStatus(liveTo: C.liveToVideo, summary: "YouTube Live")
              == "Off air. Command B would go to YouTube Live")

        let loaded = OnAir.setupLoaded(label: "Blindside", liveTo: C.liveToAudio,
                                       summary: "Blindside Radio, x/live", otherKind: true)
        check("a saved setup says which key goes to it",
              loaded == "Blindside. Option Shift B goes to Blindside Radio, x/live, which is "
                      + "a different kind of destination from the last one", loaded)

        check("the Video streaming box no longer promises Command B goes there",
              !VideoPrefs.locationLabel.contains("Command B")
              && VideoPrefs.locationNote.contains("Command B always goes live on this platform"))
        check("the ask first box is about both keys",
              !VideoPrefs.askLabel.contains("Command B")
              && VideoPrefs.askHelp.hasPrefix("Command B and Option Shift B"))
        check("Do not ask again names both keys", GoLivePanel.neverTip.hasPrefix(
            "Command B and Option Shift B go straight on the air"))
    }

    // ------------------------------------------------------ where it goes ---

    private func testWhereItGoesByChannel() {
        out.append("")
        out.append("Two destinations, two names (W382-04 to W382-06)")

        func goes(_ server: String, _ host: String, name: String = "Blindside Radio",
                  channel: String = "", video: Bool = true) -> String {
            var s = PreflightSettings()
            s.server = server; s.host = host; s.name = name; s.videoName = channel
            s.mount = "/live"
            return Preflighter.whereItGoes(s, video: video)
        }
        let youtube = C.rtmpIngest["youtube"] ?? ""
        let facebook = C.rtmpIngest["facebook"] ?? ""
        check("YouTube with no channel name is just the platform, never the radio station",
              goes("youtube", youtube) == StreamServers.serverLabel("youtube"),
              goes("youtube", youtube))
        check("Facebook too, and its single address is not read out",
              goes("facebook", facebook) == StreamServers.serverLabel("facebook"),
              goes("facebook", facebook))
        check("the channel's own name leads when there is one",
              goes("youtube", youtube, channel: "Tony Gebhard")
              == "Tony Gebhard, on \(StreamServers.serverLabel("youtube"))")
        check("a name of only spaces is no name",
              goes("youtube", youtube, channel: "   ") == StreamServers.serverLabel("youtube"))
        let custom = goes("rtmp", "rtmp://stream.example.com/app/SECRETKEY")
        check("a custom server keeps its address, because it is the useful fact",
              custom == "\(StreamServers.serverLabel("rtmp")), stream.example.com", custom)
        check("and never its key", !custom.contains("SECRETKEY"))
        check("Restream says its address",
              goes("restream", "rtmp://live.restream.io/live").hasSuffix("live.restream.io"))
        check("a server with no label says the host alone",
              goes("", "rtmp://h.example/app/k") == "h.example",
              goes("", "rtmp://h.example/app/k"))
        check("the channel name with no platform is the channel alone",
              goes("", "rtmp://h.example/app/k", channel: "My Show") == "My Show")
        check("the radio destination still says the radio station",
              goes("icecast", "radio.example.com", video: false)
              == "Blindside Radio, radio.example.com/live")
        check("and never the video channel's name",
              !goes("icecast", "radio.example.com", channel: "Tony Gebhard", video: false)
                  .contains("Tony Gebhard"))
        for server in C.videoServerOrder {
            let said = goes(server, C.rtmpIngest[server] ?? "rtmp://h.example/app/k")
            check("\(server) never borrows the radio station's name",
                  !said.contains("Blindside Radio"), said)
        }

        // The whole pre-flight's first line, the way Command B reads it.
        var s = PreflightSettings()
        s.server = "youtube"; s.host = youtube; s.password = "k"; s.bitrate = 128
        s.name = "Blindside Radio"; s.videoName = ""
        var b = PreflightBoard()
        b.liveTo = C.liveToVideo; b.videoServer = "youtube"
        let summary = Preflighter.check(settings: s, board: b).summary()
        check("Command B's summary for YouTube is the platform, not Blindside Radio",
              summary == StreamServers.serverLabel("youtube"), summary)

        // M15: an address typed without its scheme is not read out key and all.
        check("an address with no host found is said without its path (M15)",
              StreamServers.hostLabel("live.example.com/app/SECRETKEY") == "live.example.com",
              StreamServers.hostLabel("live.example.com/app/SECRETKEY"))
        check("and a plain host is said as it is",
              StreamServers.hostLabel("radio.example.com") == "radio.example.com"
              && StreamServers.hostLabel("") == "")
    }

    // ------------------------------------------------------------- go live ---

    private func testGoLiveSummary() {
        out.append("")
        out.append("The reason it will not go is the first thing read (W384-13, M16)")

        let lines: [(label: String, value: String)] = [
            ("Going to", "YouTube Live"), ("Sound", "128 kbps MP3")]
        let blocked = Preflight(target: C.liveToVideo, lines: lines, notes: [
            PreflightNote(.warn, "Your microphone is not on the air, so listeners will "
                          + "not hear you at all", C.fixAudio),
            PreflightNote(.stop, "There is no stream key for this station", C.fixVideo),
        ])
        let text = GoLivePanel.summaryText(blocked)
        check("a blocked summary starts Not going out, with the stop",
              text.hasPrefix("Not going out: there is no stream key for this station\n"), text)
        check("and still says where it was going",
              text.contains("Going to: YouTube Live") && text.contains("Sound: 128 kbps MP3"))
        let fine = Preflight(target: C.liveToVideo, lines: lines, notes: [
            PreflightNote(.warn, "A warning", C.fixAudio)])
        check("an unblocked summary is only the lines",
              GoLivePanel.summaryText(fine) == "Going to: YouTube Live\nSound: 128 kbps MP3")
        check("Put it right goes to the STOP's page, not the first warning's",
              GoLivePanel.fixPage(blocked) == C.fixVideo, GoLivePanel.fixPage(blocked) ?? "nil")
        check("and to a warning's page when nothing stops it",
              GoLivePanel.fixPage(fine) == C.fixAudio)
        check("Stay off air says why when there was a reason",
              GoLivePanel.stayOffSentence(blocked)
              == "Still off air. There is no stream key for this station")
        check("and just Still off air when there was not",
              GoLivePanel.stayOffSentence(fine) == "Still off air")
    }

    private func testAutoStartWording() {
        out.append("")
        out.append("Auto start, said honestly in three places (W384-11)")

        var b = PreflightBoard()
        b.liveTo = C.liveToVideo; b.videoServer = "youtube"
        let label = StreamServers.serverLabel("youtube")
        check("the going live warning says usually, and names auto start",
              Preflighter.goingLiveWarning(b)
              == "\(label) usually puts you live the moment you connect, and tells your "
               + "subscribers. If auto start is switched off for this stream, \(label) "
               + "waits for you to press Go live in your live control room instead",
              Preflighter.goingLiveWarning(b))
        check("the Video streaming page says both halves, with the Mac's key",
              GoingLive.note("youtube") == "Careful: with auto start on, pressing Command B "
               + "puts you live on YouTube straight away, with no preview, your subscribers "
               + "notified and the stream saved to your channel. With auto start off, "
               + "YouTube waits for you to press Go live in your live control room.",
              GoingLive.note("youtube"))
        check("and so does the answer when YouTube accepts a key",
              StreamKeyCheck.verdict(StreamKeyCheck.Result(.accepted), server: "youtube",
                                     key: "abcd").contains("auto start is switched off"))
    }

    // ------------------------------------------------- check my stream key ---

    private func testCheckMyStreamKeyButton() {
        out.append("")
        out.append("Check my stream key on the Video streaming page (W384-09, W384-10, M11)")

        check("every space and newline is taken out of a pasted key",
              VideoPrefs.cleanKey("  abcd efgh\n\tijkl \r\n") == "abcdefghijkl")

        let youtube = C.rtmpIngest["youtube"] ?? ""
        let noAddress = VideoPrefs.checkPress(running: false, server: "rtmp",
                                              host: "not an address", key: "k")
        check("an address that is not one is said at once, with nothing sent",
              noAddress == .refuse(StreamKeyCheck.verdict(
                  StreamKeyCheck.Result(.badAddress), server: "rtmp", key: ""), focusKey: false),
              "\(noAddress)")
        let noKey = VideoPrefs.checkPress(running: false, server: "youtube", host: "",
                                          key: " \n ")
        check("a key of only spaces is no key, and the focus goes to the key box",
              noKey == .refuse("There is no stream key. Get my stream key opens the page "
                               + "where yours is.", focusKey: true), "\(noKey)")
        check("a second press while checking says so rather than starting again",
              VideoPrefs.checkPress(running: true, server: "youtube", host: youtube, key: "k")
              == .stillChecking)
        check("the second press is refused BEFORE anything is asked",
              VideoPrefs.checkPress(running: true, server: "rtmp",
                                    host: "rtmp://h.example/app", key: "k") == .stillChecking)
        if case .ask(let question) = VideoPrefs.checkPress(running: false, server: "youtube",
                                                           host: "", key: "k") {
            check("YouTube is asked first, in Windows' words",
                  question == StreamKeyCheck.question(server: "youtube")
                  && question.hasSuffix("Check the key now?"))
        } else {
            check("YouTube is asked first, in Windows' words", false)
        }
        if case .ask(let question) = VideoPrefs.checkPress(
            running: false, server: "rtmp", host: "rtmp://h.example/app", key: "k") {
            check("a custom server is asked first too, because nobody knows what it does",
                  question.contains("is not a service Drop Deck knows"))
        } else {
            check("a custom server is asked first too, because nobody knows what it does",
                  false)
        }
        check("Facebook, which posts nothing, goes straight ahead",
              VideoPrefs.checkPress(running: false, server: "facebook", host: "", key: "k")
              == .start)

        let flag = WorkFlag()
        check("the re-entry flag lets the first press through", flag.begin() && flag.running)
        check("and refuses the second", !flag.begin() && flag.running)
        flag.end()
        check("and lets the next one through once the answer is back",
              flag.begin())

        check("the Channel name help is Windows' with the Mac's page name",
              VideoPrefs.channelHelp == "What this channel is called, if you want it said "
               + "on the way to air. Nothing to do with your radio station's name, which is "
               + "on the Streaming page. Leave it empty and Drop Deck just says the platform.")
    }

    /// W384-32. Each of the three used to set `isEnabled = false` on the button
    /// with the focus while it worked, and return in silence on a second press.
    private func testNoDisabledButtons() {
        out.append("")
        out.append("A button that is working stays focused and says so (W384-32)")

        var heard: [String] = []
        let speaker = Speaker()
        speaker.status = { heard.append($0) }
        let board = Board()

        let ask = AskPanel(speaker: speaker, board: board, kind: "camera", label: "Ask",
                           picture: { nil }, askConsent: { _ in false })
        _ = ask.build(width: 400)
        _ = ask.work.begin()
        ask.ask()
        check("Ask pressed again says it is still asking",
              heard.last == AskPanel.stillAsking, heard.last ?? "nothing")
        check("and the Ask button is never disabled", ask.send.isEnabled)
        check("and the first question is still the one in flight", ask.work.running)

        let shot = ShotCheckPanel(board: board, speaker: speaker, window: nil, kind: "camera",
                                  grab: { nil })
        _ = shot.work.begin()
        shot.check()
        check("Check the shot pressed again says it is still looking",
              heard.last == ShotCheckPanel.stillLooking, heard.last ?? "nothing")

        let colours = ColoursPanel(board: board, speaker: speaker, window: nil,
                                   sample: { nil }, apply: {})
        _ = colours.work.begin()
        colours.opinion()
        check("the colours opinion pressed again says it is still looking",
              heard.last == ColoursPanel.stillLooking, heard.last ?? "nothing")
    }

    // ---------------------------------------------------------------- help ---

    private func testTwoKeysHelp() {
        out.append("")
        out.append("F1, the keyboard check and the setting-up help know both keys (W382-12, W384-12)")

        let help = KeyboardHelp.chapters().split(whereSeparator: { $0 == " " || $0 == "\n" })
            .joined(separator: " ")
        check("F1 teaches Command B as the video platform",
              help.contains("Command B Go live on your VIDEO platform"))
        check("and Option Shift B as the radio station",
              help.contains("Option Shift B Go live on your RADIO station"))
        check("and that nothing goes out until one of them is pressed",
              help.contains("Nothing goes out until you press Command B or Option Shift B"))
        check("Help, Check the keyboard asks for the new key",
              KeyboardCheckPanel.wanted.contains { $0.0 == "Option Shift B" })

        let all = StreamHelp.everything()
        check("the help never sends anybody to a Test the connection button that is gone",
              !all.contains("Test the connection"))
        check("it sends them to Check my stream key instead",
              all.contains("Press Check my stream key. It asks the platform whether your "
                           + "key is right"))
        check("YouTube's safe way to try it starts with the check",
              StreamHelp.platforms["youtube"]?.testing.hasPrefix("Press Check my stream key")
              == true)
        check("a custom server's says Drop Deck asks first",
              StreamHelp.platforms["rtmp"]?.testing.hasSuffix("so Drop Deck asks you first.")
              == true)
        check("it no longer tells anybody to tick a box so Command B goes there",
              !all.contains("Tick Go live here when I press Command B"))
        let trouble = StreamHelp.trouble.map { $0.what }
        check("the three new trouble entries are there",
              trouble.contains("It says I am on air and nothing appears on my channel")
              && trouble.contains("Command B goes to the wrong place")
              && trouble.contains("It says I am on air and I am not sure anything is going out"))
        check("and the old one that blamed the tick box is gone",
              !trouble.contains("Nothing appears on the platform"))
        let wrong = StreamHelp.trouble.first { $0.what == "Command B goes to the wrong place" }?
            .fix ?? ""
        check("the wrong place entry names both keys and no dot for Command B",
              wrong.hasPrefix("Command B goes to your video platform and Option Shift B goes "
                              + "to your radio station")
              && !wrong.contains("the one Command B will use"), wrong)
    }
}
