// The checks for Mac 3.8.4's last package: what real users reported on the
// Mac, and Windows 3.8.0 and 3.8.3's microphone, send and program source work.
//
//   The camera could never be granted (Raymond, in-app reports 38 and 43).
//   Remove in source control did not remove (in-app reports 36 and 37).
//   Every running order row said "Ticked to play" (Siena).
//   No track title ever reached a station (analysis N1), and the title format
//   Tyler asked for.
//   The microphone key must never do nothing (W383), the send is intent
//   (W380-06), Test the cable (W380-01), program sources closing and coming
//   back (W383-27), and a failed sound recording is said (N3).
//
// Each decision is a pure function where it can be, so the check holds it to
// its sentence with no device opened. Nothing here opens a microphone, a
// camera, the screen or a sound card, and nothing touches the real board.

import AppKit
import Carbon.HIToolbox
import CoreAudio
import AudioToolbox

extension SelfTest {

    func runReportsChecks() {
        testCameraEntitlement()
        testSourceControlRemove()
        testRunningOrderTicks()
        testTrackTitles()
        testMicrophoneKey()
        testMicrophoneWords()
        testErrorLog()
        testQueuedSpeech()
        testHotkeyClashes()
        testSendIsIntent()
        testCableVerdicts()
        testCableButton()
        testProgramSources()
        testRecordingFailure()
        testAuditTwo()
    }

    // ------------------------------------------------------------ the camera ---

    private func testCameraEntitlement() {
        out.append("")
        out.append("The camera can be granted at all (in-app reports 38 and 43)")
        let granted = Permissions.signedEntitlements()
        check("this bundle is signed with entitlements", !granted.isEmpty,
              "no entitlements read from the signature")
        check("it carries the camera entitlement, without which macOS never lists "
              + "the app under Camera",
              granted["com.apple.security.device.camera"] as? Bool == true,
              "\(granted.keys.sorted())")
        check("and still the microphone's",
              granted["com.apple.security.device.audio-input"] as? Bool == true)

        check("a camera picture asks for the camera at launch, whatever Command B "
              + "points at",
              Permissions.wantedAtLaunch(picture: C.pictureCamera, camera: .neverAsked,
                                         screen: .allowed, screenAskedBefore: false,
                                         screenUsed: true) == [.camera])
        check("so does the screen with the camera in a corner",
              Permissions.wantedAtLaunch(picture: C.pictureSplit, camera: .neverAsked,
                                         screen: .allowed, screenAskedBefore: false,
                                         screenUsed: true) == [.camera])
        check("a card asks for nothing",
              Permissions.wantedAtLaunch(picture: C.pictureCard, camera: .neverAsked,
                                         screen: .neverAsked, screenAskedBefore: false,
                                         screenUsed: true).isEmpty)
        check("and nothing already answered is asked again",
              Permissions.wantedAtLaunch(picture: C.pictureCamera, camera: .refused,
                                         screen: .neverAsked, screenAskedBefore: false,
                                         screenUsed: true).isEmpty)

        // Audit 2, finding 1: the screen, which macOS cannot say it has asked.
        check("a video board's screen is asked for the first time",
              Permissions.wantedAtLaunch(picture: C.pictureScreen, camera: .allowed,
                                         screen: .neverAsked, screenAskedBefore: false,
                                         screenUsed: true) == [.screen])
        check("and never again once this signed copy has asked, whatever macOS says",
              Permissions.wantedAtLaunch(picture: C.pictureScreen, camera: .allowed,
                                         screen: .neverAsked, screenAskedBefore: true,
                                         screenUsed: true).isEmpty)
        check("a screen shown to be refused is not asked for",
              Permissions.wantedAtLaunch(picture: C.pictureSplit, camera: .allowed,
                                         screen: .refused, screenAskedBefore: false,
                                         screenUsed: true).isEmpty)
        check("a radio board with a screen chosen and nothing to send it to is not asked",
              Permissions.wantedAtLaunch(picture: C.pictureScreen, camera: .allowed,
                                         screen: .neverAsked, screenAskedBefore: false,
                                         screenUsed: false).isEmpty)
        check("the split still asks for its camera when the screen is not wanted",
              Permissions.wantedAtLaunch(picture: C.pictureSplit, camera: .neverAsked,
                                         screen: .neverAsked, screenAskedBefore: true,
                                         screenUsed: true) == [.camera])
        let suite = "app.tgstudios.dropdeck.selftest.screenasked"
        if let scratch = UserDefaults(suiteName: suite) {
            scratch.removePersistentDomain(forName: suite)
            let me = "team:SELFTEST"
            let before = ScreenAsked.asked(defaults: scratch, identity: me)
            ScreenAsked.remember(defaults: scratch, identity: me)
            check("asking is remembered for this signing identity",
                  !before && ScreenAsked.asked(defaults: scratch, identity: me))
            check("and not for another, which macOS treats as a different app",
                  !ScreenAsked.asked(defaults: scratch, identity: "cdhash:00"))
            scratch.removePersistentDomain(forName: suite)
        }
        check("this copy knows who it is", !ScreenAsked.identity().isEmpty
              && !ScreenAsked.identity().hasPrefix("version:"), ScreenAsked.identity())
    }

    // ------------------------------------------------------- source control ---

    private func testSourceControlRemove() {
        out.append("")
        out.append("Remove in source control really removes (in-app reports 36 and 37)")
        let board = Board()
        let group = SourceGroup()
        let facetime = StandInSource(name: "FaceTime", level: 0.1)
        let teamtalk = StandInSource(name: "TeamTalk", level: 0.2)
        group.useForTesting([facetime, teamtalk])
        board.sources = [facetime.config, teamtalk.config]
        group.soloed = facetime.config.id

        check("removing one says it did", group.forget(id: facetime.config.id, on: board))
        check("it is out of the show", group.all.count == 1 && group.all.first === teamtalk)
        check("it is off the board, so it does not come back at the next start",
              board.sources.map(\.name) == ["TeamTalk"], "\(board.sources.map(\.name))")
        check("and a solo on it is dropped, rather than silencing everything for a "
              + "source that is gone", group.soloed == nil)
        let saved = Board.from(dict: board.toDict(), relativeTo: nil)
        check("the board file written afterwards has one source", saved.sources.count == 1)
        check("an id that is not there removes nothing",
              !group.forget(id: "not a source", on: board) && board.sources.count == 1)
    }

    // ------------------------------------------------------- the running order ---

    private func testRunningOrderTicks() {
        out.append("")
        out.append("Every running order row says its own tick (Siena)")
        let playlist = Playlist()
        let one = Track(filepath: "/nowhere/one.mp3"); one.title = "One"
        let two = Track(filepath: "/nowhere/two.mp3"); two.title = "Two"
        two.enabled = false
        playlist.tracks = [one, two]
        let view = PlaylistView(playlist: playlist)
        let ticked = view.tickCell(row: 0), unticked = view.tickCell(row: 1)
        check("a ticked row's tick has the value 1",
              (ticked?.accessibilityValue() as? NSNumber)?.intValue == 1)
        check("an unticked row's tick has the value 0",
              (unticked?.accessibilityValue() as? NSNumber)?.intValue == 0)
        check("and they say ticked and not ticked in words",
              ticked?.accessibilityValueDescription() == "ticked"
              && unticked?.accessibilityValueDescription() == "not ticked")
        check("the label is the same on both and never states the tick",
              ticked?.accessibilityLabel() == TickBox.label
              && unticked?.accessibilityLabel() == TickBox.label
              && !TickBox.label.lowercased().contains("tick"),
              TickBox.label)

        two.enabled = true
        check("after the tick moves, the row says the new value",
              (view.tickCell(row: 1)?.accessibilityValue() as? NSNumber)?.intValue == 1)
        let box = TickBox(target: nil, action: nil)
        box.show(true)
        check("a tick shown from the model changes its value and not its label",
              (box.accessibilityValue() as? NSNumber)?.intValue == 1
              && box.accessibilityLabel() == TickBox.label)
        check("Space says what it did, ticked",
              PlaylistView.tickSentence(name: "One", ticked: true) == "Ticked, One will play")
        check("and unticked",
              PlaylistView.tickSentence(name: "One", ticked: false)
              == "Unticked, One will be skipped")
    }

    // ------------------------------------------------------------- the titles ---

    private func testTrackTitles() {
        out.append("")
        out.append("Track titles reach the station, in the format the board asks for")
        let dance = Track(filepath: "/nowhere/dance.mp3")
        dance.title = "The Dance"
        dance.artist = "Garth Brooks"
        check("Title by Artist is Windows' display_name wording",
              dance.named(TitleFormat.titleByArtist) == "The Dance by Garth Brooks")
        check("Artist - Title is Tyler's order",
              dance.named(TitleFormat.artistTitle) == "Garth Brooks - The Dance")
        let bare = Track(filepath: "/nowhere/station ident.wav")
        check("no tags is the file name, in either format",
              bare.named(TitleFormat.artistTitle) == "station ident"
              && bare.named(TitleFormat.titleByArtist) == "station ident")
        let noArtist = Track(filepath: "/nowhere/x.wav")
        noArtist.title = "Just a Title"
        noArtist.artist = "  "
        check("a blank artist is no artist",
              noArtist.named(TitleFormat.artistTitle) == "Just a Title")
        check("the default is Windows' wording", TitleFormat.defaultFormat == "title_by_artist")

        check("Send what is playing off sends nothing, card included",
              MainWindow.titleToSend(dance, format: TitleFormat.artistTitle, send: false) == "")
        check("nothing playing sends nothing",
              MainWindow.titleToSend(nil, format: TitleFormat.artistTitle, send: true) == "")
        check("otherwise the formatted title",
              MainWindow.titleToSend(dance, format: TitleFormat.artistTitle, send: true)
              == "Garth Brooks - The Dance")

        let board = Board()
        board.titleFormat = TitleFormat.artistTitle
        let dict = board.toDict()
        check("the board writes stream_title_format",
              dict["stream_title_format"] as? String == "artist_title")
        check("and reads it back",
              Board.from(dict: dict, relativeTo: nil).titleFormat == "artist_title")
        var junk = dict
        junk["stream_title_format"] = "shouting"
        check("anything else is the default",
              Board.from(dict: junk, relativeTo: nil).titleFormat == "title_by_artist")
        let copy = Board()
        copy.replaceContents(with: board)
        check("File, Open carries it across", copy.titleFormat == "artist_title")

        var ice = StreamSettings()
        ice.host = "radio.example"
        ice.port = 8000
        ice.mount = "live"
        check("Icecast takes it at /admin/metadata, in Windows' order, UTF-8",
              Streamer.metadataURL(ice, title: "The Dance by Garth Brooks")?.absoluteString
              == "http://radio.example:8000/admin/metadata?mount=%2Flive&mode=updinfo"
                 + "&song=The%20Dance%20by%20Garth%20Brooks&charset=UTF-8",
              Streamer.metadataURL(ice, title: "The Dance by Garth Brooks")?.absoluteString ?? "nil")
        check("an ampersand and a plus in a title are escaped, not cut",
              Streamer.metadataURL(ice, title: "Tom & Jerry + 1")?.absoluteString
                .contains("song=Tom%20%26%20Jerry%20%2B%201&") == true)
        var shout = ice
        shout.server = C.streamServerShoutcast
        shout.password = "pa ss"
        check("SHOUTcast takes it at admin.cgi with the password, as Windows sends it",
              Streamer.metadataURL(shout, title: "X")?.absoluteString
              == "http://radio.example:8000/admin.cgi?pass=pa%20ss&mode=updinfo&song=X")
        check("an empty title goes nowhere", Streamer.metadataURL(ice, title: "") == nil)
    }

    // ------------------------------------------------------ the microphone ---

    private func testMicrophoneKey() {
        out.append("")
        out.append("The microphone key can never do nothing (W383-03, W383-16)")
        let spare = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                     modifierFlags: [.option, .shift], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: "\u{C2}",
                                     charactersIgnoringModifiers: "M", isARepeat: false,
                                     keyCode: UInt16(kVK_ANSI_M))
        check("Option Shift M reaches the microphone",
              spare.flatMap(KeyMap.aliasCommand(for:)) == .micToggle)
        check("Command M is still the menu's key",
              KeyMap.menuKey(.micToggle).map { $0.0 == "m" && $0.1 == [.command] } == true)
        check("the keyboard check asks for Option Shift M",
              KeyboardCheckPanel.wanted.contains { $0.0 == "Option Shift M" })
        let help = KeyboardHelp.chapters()
        check("F1 names Option Shift M", help.contains("Option Shift M"))
        check("and says what to do when Command M does nothing",
              help.contains("IF COMMAND M DOES NOTHING AT ALL")
              && help.contains("Help, Check the keyboard"))
        check("Option Shift M is in the dump the manual is checked against",
              KeyMap.dump().contains("Option+Shift+M"))
    }

    private func testMicrophoneWords() {
        out.append("")
        out.append("Why the microphone is not working, in words (W383-06, 07, 09, 10, 13)")
        check("allowed opens", MicDiag.privacy(.allowed) == .open)
        check("never asked asks first", MicDiag.privacy(.neverAsked) == .ask)
        check("refused opens nothing and says where to go",
              MicDiag.privacy(.refused) == .refuse(MicDiag.privacyBlocked)
              && MicDiag.privacyBlocked.contains("Privacy and Security, Microphone"))
        check("managed says only they can change it",
              MicDiag.privacy(.notYours) == .refuse(MicDiag.policyBlocked))

        check("a device that is gone says so",
              MicDiag.explain(kAudioHardwareBadDeviceError) == MicDiag.gone)
        check("held or refused",
              MicDiag.explain(kAudioDevicePermissionsError) == MicDiag.held
              && MicDiag.explain(kAudioHardwareIllegalOperationError) == MicDiag.held)
        check("the audio system not running",
              MicDiag.explain(kAudioHardwareNotRunningError) == MicDiag.noService)
        check("a format it will not take",
              MicDiag.explain(kAudioUnitErr_FormatNotSupported) == MicDiag.badFormat)
        check("anything else is refused, in words", MicDiag.explain(-50) == MicDiag.refused)
        check("no device at all", MicDiag.explain(nil) == MicDiag.nothingThere)
        check("a code is readable for support",
              MicDiag.code(kAudioHardwareNotRunningError) == "1937010544 'stop'",
              MicDiag.code(kAudioHardwareNotRunningError))

        let present: (String) -> Bool = { $0 == "here" }
        check("a chosen microphone that is unplugged is named",
              MicDiag.missing(chosenUID: "gone", chosenName: "Desk mic",
                              isPresent: present) == "Desk mic")
        check("one that is plugged in is not",
              MicDiag.missing(chosenUID: "here", chosenName: "Desk mic",
                              isPresent: present) == nil)
        check("nothing chosen is the default, which is never missing",
              MicDiag.missing(chosenUID: nil, chosenName: nil, isPresent: present) == nil)
        check("the default standing in is said, in Windows' words",
              "Microphone on, MacBook Microphone. Music ducked" + MicDiag.fellBack("Desk mic")
              == "Microphone on, MacBook Microphone. Music ducked. Your chosen microphone, "
                 + "Desk mic, is not plugged in, so this is the system default")
        check("and when even that fails",
              MicDiag.failureLine(reason: MicDiag.gone, missing: "Desk mic")
              == "Your chosen microphone, Desk mic, is not plugged in, and the system "
                 + "default would not open either. " + MicDiag.gone)

        check("sound arriving says nothing",
              MicDiag.silenceLine(signal: true, blocks: 40, privacy: .allowed) == nil)
        check("nothing sent at all is told apart",
              MicDiag.silenceLine(signal: false, blocks: 0, privacy: .allowed)?
                .hasPrefix("The microphone is on, but macOS has not sent Drop Deck any "
                           + "sound from it. If you are talking into it") == true)
        check("from exact silence",
              MicDiag.silenceLine(signal: false, blocks: 12, privacy: .allowed)?
                .hasPrefix("The microphone is on, but nothing is coming from it, not even "
                           + "background noise.") == true)
        check("and a refusal is named when that is the cause",
              MicDiag.silenceLine(signal: false, blocks: 12, privacy: .refused)?
                .hasSuffix(MicDiag.privacyBlocked) == true)
        var zeros = [Float](repeating: 0, count: 64)
        check("exact zeros are no signal", !MicDiag.hasSignal(zeros, count: 64))
        zeros[63] = 1e-9
        check("the faintest noise is", MicDiag.hasSignal(zeros, count: 64))

        let info = MainWindow.micDiagnostics(
            chosenUID: "gone", present: present, open: true,
            lastStatus: kAudioHardwareBadDeviceError, lastError: "That input would not open",
            signal: false, failedReads: 3, privacy: .refused)
        check("feedback says whether a microphone was chosen and found",
              info["mic_chosen"] as? Bool == true && info["mic_found"] as? Bool == false)
        check("the problem in words and the raw code",
              info["mic_problem"] as? String == MicDiag.gone
              && (info["mic_error_codes"] as? String)?.contains("!dev") == true)
        check("whether sound is arriving, and the privacy state",
              info["mic_sound_arriving"] as? Bool == false
              && info["mic_privacy"] as? String == "refused")
        check("and never a device's name",
              !info.values.contains { "\($0)".contains("Desk mic") })
    }

    // -------------------------------------------------------- the error log ---

    private func testErrorLog() {
        out.append("")
        out.append("Faults are written down, never lost (W383-05)")
        check("Info.plist names our own application",
              Bundle.main.infoDictionary?["NSPrincipalClass"] as? String == "DropDeckApplication")
        let named: AnyClass? = NSClassFromString("DropDeckApplication")
        check("and it is an NSApplication", named.map { $0 is NSApplication.Type } == true)
        let ours = class_getInstanceMethod(DropDeckApplication.self,
                                           #selector(NSApplication.reportException(_:)))
        let theirs = class_getInstanceMethod(NSApplication.self,
                                             #selector(NSApplication.reportException(_:)))
        check("which writes down what AppKit catches",
              ours != nil && theirs != nil
              && method_getImplementation(ours!) != method_getImplementation(theirs!))

        let folder = NSTemporaryDirectory() + "dropdeck-selftest/errorlog"
        try? FileManager.default.removeItem(atPath: folder)
        let saved = ErrorLog.pathOverride
        ErrorLog.pathOverride = folder + "/" + ErrorLog.fileName
        defer { ErrorLog.pathOverride = saved }

        let binary = (Bundle.main.executablePath as NSString?)?.lastPathComponent ?? "TGDropDeck"
        let frames = ["0   CoreFoundation  0x0000000180a1 __exceptionPreprocess + 164",
                      "1   \(binary)  0x0000000100a1 $s10TGDropDeck10MainWindowC9toggleMicyyF + 45",
                      "2   AppKit  0x0000000180b2 -[NSApplication sendAction:to:from:] + 12"]
        let line = ErrorLog.record(kind: "NSRangeException", symbols: frames,
                                   detail: "index 9 beyond /Users/somebody/secret show.wav")
        check("the summary is where and what kind, in our own code",
              line == "MainWindow.toggleMic: NSRangeException", line)
        check("the recent list has it, for feedback",
              ErrorLog.recent().contains(line))
        check("and never the reason, which can carry a path",
              !ErrorLog.recent().joined().contains("secret"))
        let written = (try? String(contentsOfFile: ErrorLog.path, encoding: .utf8)) ?? ""
        check("the log has the whole thing, for support",
              written.contains("secret show.wav") && written.contains("toggleMicyyF"))
        check("a frame from this very check is found as ours",
              ErrorLog.whereIn(Thread.callStackSymbols).contains("SelfTest"),
              ErrorLog.whereIn(Thread.callStackSymbols))

        let big = Data(repeating: 0x41, count: ErrorLog.maxBytes + 1000)
        try? big.write(to: URL(fileURLWithPath: ErrorLog.path))
        ErrorLog.record(kind: "Second", symbols: frames)
        let size = ((try? FileManager.default.attributesOfItem(atPath: ErrorLog.path))?[.size]
                    as? NSNumber)?.intValue ?? 0
        check("a log past its limit starts again from its newer half",
              size > 0 && size < ErrorLog.maxBytes, "\(size)")
        ErrorLog.install()
        ErrorLog.install()
        check("installing twice is harmless", true)
    }

    private func testQueuedSpeech() {
        out.append("")
        out.append("A line nobody asked for waits its turn (W383-15)")
        check("a keypress interrupts", Speaker.priority(interrupt: true) == .high)
        check("a timer's line is queued", Speaker.priority(interrupt: false) == .medium)
    }

    private func testHotkeyClashes() {
        out.append("")
        out.append("Our own global hotkey on one of our own keys is said at startup (W383-02)")
        func combo(_ key: Int, _ mods: Int) -> HotkeyCombination {
            HotkeyCombination(keyCode: UInt32(key), modifiers: UInt32(mods))
        }
        let saved = KeyMap.scheme
        KeyMap.scheme = .command
        defer { KeyMap.scheme = saved }
        let lines = HotkeyClash.lines(hotkeys: [
            (combo(kVK_ANSI_M, cmdKey), "Applause"),
            (combo(kVK_F9, controlKey | optionKey), "Laugh"),
            (combo(kVK_ANSI_1, shiftKey), "Boing"),
            (combo(kVK_ANSI_M, cmdKey), "Applause again"),
        ])
        check("Command M taken by a pad is said, in Windows' words",
              lines.first == "Command M is also the global hotkey for Applause, so while "
                + "global hotkeys are on it plays that sound instead. Command G turns "
                + "global hotkeys off", lines.first ?? "none")
        check("a key the app does not use is not a clash",
              !lines.contains { $0.contains("Laugh") })
        check("the digit map counts too", lines.contains { $0.hasPrefix("Shift 1 ") })
        check("one key is said once", lines.count == 2, "\(lines.count)")
    }

    // --------------------------------------------------------------- the send ---

    private func testSendIsIntent() {
        out.append("")
        out.append("A send that would not start is still wanted (W380-06, W380-03)")
        let missing = MainWindow.sendMissingLine("Drop Deck Audio")
        check("the missing card is Windows' sentence",
              missing == "Drop Deck Audio is not here at the moment, so the show is not "
                + "going to another program. It will start again by itself when the card "
                + "is back.")
        check("the startup line says the reason",
              MainWindow.startupSendLine(wanted: true, running: nil, failed: missing) == missing)
        check("and Windows' fallback when there is none",
              MainWindow.startupSendLine(wanted: true, running: nil, failed: "")
              == "The send could not start, so nothing is going to another program. "
                 + "Option+Shift+O to set it up again")
        check("a running send is said",
              MainWindow.startupSendLine(wanted: true, running: "Drop Deck Audio",
                                         failed: "")
              == "Sending your whole show to Drop Deck Audio for another program to pick up")
        check("no send wanted says nothing",
              MainWindow.startupSendLine(wanted: false, running: nil, failed: missing) == nil)
        check("the card coming back starts it again, which makes by itself true",
              MainWindow.sendShouldRetry(wanted: true, running: false, failed: missing,
                                         cardPresent: true))
        check("but not while the card is still away",
              !MainWindow.sendShouldRetry(wanted: true, running: false, failed: missing,
                                          cardPresent: false))
        check("nor a send that failed for another reason, every three seconds",
              !MainWindow.sendShouldRetry(wanted: true, running: false,
                                          failed: "The send could not be opened. x",
                                          cardPresent: true))
        check("nor one nobody wants",
              !MainWindow.sendShouldRetry(wanted: false, running: false, failed: missing,
                                          cardPresent: true))
        check("the far end is named for a device with an input side",
              MainWindow.farEndLine(name: "Drop Deck Audio", inputChannels: 2)
              == "In the other program, choose Drop Deck Audio as its input device.")
        check("and not for a loudspeaker",
              MainWindow.farEndLine(name: "Speakers", inputChannels: 0) == nil)
    }

    private func cableTone(_ count: Int, rate: Double, level: Double = 0.3) -> [Float] {
        (0..<count).map { Float(level * sin(2.0 * Double.pi * 1000.0 * Double($0) / rate)) }
    }

    private func testCableVerdicts() {
        out.append("")
        out.append("Test the cable, the verdicts (W380-01)")
        let rate = 48000.0
        let tone = cableTone(48000, rate: rate)
        let level = CableTest.levelAt(tone, rate: rate)
        check("a 0.3 tone reads within half a decibel of its arithmetic",
              abs(level - 20.0 * log10(0.3)) < 0.5, "\(level)")
        check("and to Windows' reference number",
              abs(level - (-10.457574835038535)) < 1e-6, "\(level)")
        let clean = CableTest.judge(tone, rate: rate, heard: "Drop Deck Audio")
        check("clean is working, in Windows' words",
              clean.ok && clean.said == "The cable is working. The tone came back at -10 "
                + "decibels with nothing missing, at 48000 hertz. Listening on Drop Deck Audio.",
              clean.said)
        let silence = CableTest.judge([Float](repeating: 0, count: 48000), rate: rate)
        check("silence is nothing came back, and names Audio MIDI Setup",
              !silence.ok && silence.said.hasPrefix("Nothing came back.")
              && silence.said.contains("Audio MIDI Setup"), silence.said)
        var holed = tone
        for start in stride(from: 0, to: holed.count, by: 4800) {
            for i in start..<min(start + 240, holed.count) { holed[i] = 0 }
        }
        let (share, runs) = CableTest.silenceIn(holed)
        check("a tone with holes in it is measured as Windows measures it",
              abs(share - 4.0) < 1e-9 && runs == 10, "\(share) \(runs)")
        let broken = CableTest.judge(holed, rate: rate)
        check("and judged as audio being lost",
              !broken.ok && broken.said.hasPrefix("The tone came back, but 4.0 per cent of "
                + "it was missing, in 10 separate gaps."), broken.said)
        check("a recording too short to measure is silent in full",
              CableTest.silenceIn([0.5, 0.5]) == (100.0, 1))
    }

    private func testCableButton() {
        out.append("")
        out.append("Test the cable, the real button (W380-01, W384-32)")
        let board = Board()
        let fake = AudioDeviceInfo(id: 0, uid: "self-test-cable", name: "Pretend Cable",
                                   outputChannels: 2, inputChannels: 2)
        var live = false
        var asked: [String] = []
        let panel = SendPanel(board: board, sources: [], speaker: nil,
                              refusal: { live ? CableTest.notWhileLive : nil },
                              outputs: [fake], privacy: { .allowed }, tester: { uid, name in
                                  asked.append(uid)
                                  Thread.sleep(forTimeInterval: 0.3)
                                  return CableTest.Result(ok: true, said: "Verdict for \(name)")
                              })
        _ = panel.makeAccessory()

        panel.chooseOutput(at: 0)
        panel.testButton.performClick(nil)
        check("with no output chosen it asks for one", panel.verdict.stringValue == CableTest.choose)

        live = true
        panel.chooseOutput(at: 1)
        panel.testButton.performClick(nil)
        check("on air or recording it refuses, and puts no tone anywhere",
              panel.verdict.stringValue == CableTest.notWhileLive && asked.isEmpty)

        live = false
        panel.testButton.performClick(nil)
        check("pressed, it says it is testing", panel.verdict.stringValue
              == "Testing Pretend Cable. Two seconds.")
        check("and the button stays enabled, so the focus stays on it",
              panel.testButton.isEnabled && panel.testFlag.running)
        panel.testButton.performClick(nil)
        check("a second press says it is still testing, and starts nothing",
              panel.verdict.stringValue.hasPrefix("Still testing"))
        let until = Date().addingTimeInterval(3)
        while panel.testFlag.running && Date() < until {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        check("the verdict comes back to the page", panel.verdict.stringValue
              == "Verdict for Pretend Cable", panel.verdict.stringValue)
        check("and the measurement ran once, on the cable chosen", asked == ["self-test-cable"])
    }

    // -------------------------------------------------------- program sources ---

    private func testProgramSources() {
        out.append("")
        out.append("A captured program closing and coming back is said (W383-27, N5)")
        check("closed, when the source is named after its program",
              ProgramWords.closed(program: "Logic Pro", sourceName: "logic pro")
              == "Logic Pro closed, so it is silent until it opens again")
        check("closed, when it is not",
              ProgramWords.closed(program: "TeamTalk", sourceName: "Callers")
              == "TeamTalk closed, so Callers is silent until it opens again")
        check("back",
              ProgramWords.back(program: "TeamTalk", sourceName: "TeamTalk") == "TeamTalk is back"
              && ProgramWords.back(program: "TeamTalk", sourceName: "Callers")
                 == "TeamTalk is back, so Callers is on again")
        check("on the air only for what is on the air",
              ProgramWords.cameOn(onAir: ["Logic"], monitored: ["Guide track"])
              == ["Logic is on the air now", "Guide track is running now, in your ears only"])
        check("below macOS 26 a dead capture is stopped so it can be found again",
              ProgramWords.stopWhenProgramQuits(macOS26: false))
        check("from 26 the tap follows the program and is left alone",
              !ProgramWords.stopWhenProgramQuits(macOS26: true))

        let group = SourceGroup()
        let logic = StandInSource(name: "Logic", level: 0.1)
        logic.config.kind = "process"
        logic.config.bundleID = "com.apple.logic10"
        logic.isRunning = false
        let desk = StandInSource(name: "Desk", level: 0.1)
        desk.isRunning = false
        group.useForTesting([logic, desk])
        check("sources are found by the program they capture",
              group.sources(forBundle: "com.apple.logic10").map(\.config.name) == ["Logic"])
        let skipped = group.retryFailed(outputRate: 48000, skip: ["com.apple.logic10"])
        check("a program settling after it opened again is left to the settle",
              skipped.map(\.config.name) == ["Desk"], "\(skipped.map(\.config.name))")
        let all = group.retryFailed(outputRate: 48000)
        check("and retried like anything else otherwise",
              all.map(\.config.name).contains("Logic"))
    }

    // ---------------------------------------------------------------- N3 ---

    private func testRecordingFailure() {
        out.append("")
        out.append("A sound recording that fails mid write is said, and lets go (N3)")
        let recorder = Recorder()
        let taps = Taps()
        var said: String?
        recorder.onFailed = { said = $0 }
        recorder.pretendRecording(taps: taps, rate: 48000,
                                  path: NSTemporaryDirectory() + "Drop Deck Stream 001.wav")
        check("recording, its bus is in the taps", !taps.isEmpty && recorder.holdsBus)
        recorder.failForTesting("The recording stopped. The disk is full")
        check("the failure is said", said == "The recording to Drop Deck Stream 001.wav has "
              + "stopped by itself. The disk is full. What was recorded before that is "
              + "still in the file.", said ?? "nothing")
        check("its bus is out of the taps", taps.isEmpty && !recorder.holdsBus)
        check("and it is not recording", !recorder.isRecording)
        check("stop afterwards has nothing to finish", recorder.stop(taps: taps) == nil)
    }

    // ------------------------------------------------------------ audit 2 ---

    private func testAuditTwo() {
        out.append("")
        out.append("After the second audit of 3.8.4")
        let board = Board()
        let fake = AudioDeviceInfo(id: 0, uid: "self-test-cable", name: "Pretend Cable",
                                   outputChannels: 2, inputChannels: 2)

        // Finding 3, on the REAL refusal over the real streamers, recorders
        // and a send.
        let radio = Streamer(), video = VideoStreamer()
        let recorder = Recorder(), pictures = VideoRecorder()
        var sending = false
        let refusal = {
            MainWindow.cableTestRefusal(streamer: radio, videoStreamer: video,
                                        recorder: recorder, videoRecorder: pictures,
                                        sending: sending)
        }
        check("nothing going anywhere, the cable may be tested", refusal() == nil)
        sending = true
        check("a send feeding a call refuses, in Windows' style",
              refusal() == CableTest.notWhileSending, refusal() ?? "nil")
        var tested: [String] = []
        let panel = SendPanel(board: board, sources: [], speaker: nil, refusal: refusal,
                              outputs: [fake], privacy: { .allowed },
                              tester: { uid, _ in tested.append(uid)
                                  return CableTest.Result(ok: true, said: "fine") })
        _ = panel.makeAccessory()
        panel.chooseOutput(at: 1)
        panel.testButton.performClick(nil)
        check("and the button says so and puts no tone down the cable",
              panel.verdict.stringValue == CableTest.notWhileSending && tested.isEmpty)
        sending = false
        radio.applyState(.live, "x")
        check("on air, it is Windows' own sentence", refusal() == CableTest.notWhileLive)
        radio.applyState(.off, "")

        // Finding 2: the microphone's privacy, before anything opens.
        var state: PermissionState = .refused
        var answer: ((PermissionState) -> Void)?
        let guarded = SendPanel(board: board, sources: [], speaker: nil, refusal: { nil },
                                outputs: [fake], privacy: { state },
                                askPrivacy: { answer = $0 },
                                tester: { uid, _ in tested.append(uid)
                                    return CableTest.Result(ok: true, said: "tested") })
        _ = guarded.makeAccessory()
        guarded.chooseOutput(at: 1)
        guarded.testButton.performClick(nil)
        check("refused, it says the privacy sentence and captures nothing",
              guarded.verdict.stringValue == CableTest.privacyFirst + MicDiag.privacyBlocked
                && tested.isEmpty, guarded.verdict.stringValue)
        state = .neverAsked
        guarded.testButton.performClick(nil)
        check("never asked, it asks first and tests nothing yet",
              answer != nil && tested.isEmpty
                && guarded.verdict.stringValue == CableTest.askingFirst)
        guarded.testButton.performClick(nil)
        check("a second press while macOS asks is still busy, and asks once",
              guarded.verdict.stringValue.hasPrefix("Still testing"))
        answer?(.allowed)
        let by = Date().addingTimeInterval(3)
        while tested.isEmpty && Date() < by { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        while guarded.testFlag.running && Date() < by {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        check("allowed, the test runs in the answer", tested == ["self-test-cable"]
              && guarded.verdict.stringValue == "tested", guarded.verdict.stringValue)

        // Finding 4: an MP3 file that stops taking writes, through the REAL
        // writer: a handle opened for reading refuses every write, which the
        // old `write(_:)` turned into an exception that ended the app.
        let folder = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("dropdeck-selftest-recfail-\(getpid())")
        try? FileManager.default.removeItem(atPath: folder)
        let failing = Recorder()
        failing.openForWriting = { FileHandle(forReadingAtPath: $0) }
        var said: String?
        failing.onFailed = { said = $0 }
        let taps = Taps()
        let started = failing.start(taps: taps, rate: 48000, format: "mp3", bitrate: 128,
                                    folder: folder)
        var tone = [Float](repeating: 0, count: 48000 * 2)
        for i in 0..<48000 {
            let v = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.3
            tone[i * 2] = v; tone[i * 2 + 1] = v
        }
        tone.withUnsafeBufferPointer { raw in
            taps.write(key: "self-test", samples: raw.baseAddress!, frames: 48000, rate: 48000)
        }
        let byFail = Date().addingTimeInterval(4)
        while said == nil && Date() < byFail {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        check("a file that refuses a write stops the recording and says so, and the app lives",
              started != nil && said?.contains("has stopped by itself. "
                                                + Recorder.cannotWrite) == true,
              said ?? "nothing said")
        check("and it lets go of the bus and is not recording",
              taps.isEmpty && !failing.isRecording && !failing.holdsBus)
        try? FileManager.default.removeItem(atPath: folder)

        // Findings 5, 7 and 8, on the real ProgramWatch with stand in sources.
        var heard: [(String, Bool)] = []
        let speaker = Speaker()
        speaker.level = C.speechAll
        speaker.spoken = { heard.append(($0, $1)) }
        let group = SourceGroup()
        let logic = StandInSource(name: "Logic", level: 0.1)
        logic.config.kind = "process"
        logic.config.bundleID = "com.apple.logic10"
        logic.startSetsRunning = true
        group.useForTesting([logic])
        let work = DispatchQueue(label: "self-test-source-work")
        let watch = ProgramWatch(sources: group, work: work, speaker: speaker,
                                 outputRate: { 48000 }, goingAnywhere: { true },
                                 changed: {})
        watch.stopWhenQuits = true
        func spin(_ seconds: Double) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        watch.stillRunning = { _ in true }
        watch.quit(bundle: "com.apple.logic10", name: "Logic Pro")
        spin(0.1)
        check("one copy of a program quitting while another runs says nothing and stops nothing",
              heard.isEmpty && logic.isRunning && logic.stops == 0)
        watch.stillRunning = { _ in false }
        watch.quit(bundle: "com.apple.logic10", name: "Logic Pro")
        spin(0.2)
        check("the last copy quitting is said, queued, and the capture stopped",
              heard.count == 1 && heard[0].0.hasPrefix("Logic Pro closed") && !heard[0].1
                && !logic.isRunning, "\(heard)")

        heard = []
        watch.settleSeconds = 0.1
        watch.launched(bundle: "com.apple.logic10", name: "Logic Pro")
        // A retry queued before the settle began starts it meanwhile, and has
        // said "on the air now" for it.
        logic.start(outputRate: 48000)
        let startsBefore = logic.starts
        spin(0.5)
        check("a source a retry already started is not started again, nor said to be back",
              logic.starts == startsBefore && !heard.contains { $0.0.contains("is back") },
              "\(heard.map(\.0))")

        logic.stop()
        heard = []
        work.async { Thread.sleep(forTimeInterval: 0.4) }
        watch.launched(bundle: "com.apple.logic10", name: "Logic Pro")
        spin(0.2)
        // Removed while it settles: the start is already queued behind the
        // busy work queue with the old list.
        _ = group.remove(id: logic.config.id)
        let stopsAtRemove = logic.stops
        spin(0.8)
        check("a source removed while its program settles is stopped again once started",
              logic.starts > startsBefore && logic.stops > stopsAtRemove && !logic.isRunning,
              "\(logic.starts) starts, \(logic.stops) stops, running \(logic.isRunning)")
        check("and is never said to be back", !heard.contains { $0.0.contains("is back") },
              "\(heard.map(\.0))")

        // Back, for real, is queued too.
        let again = StandInSource(name: "Logic", level: 0.1)
        again.config.kind = "process"
        again.config.bundleID = "com.apple.logic10"
        again.startSetsRunning = true
        again.isRunning = false
        group.useForTesting([again])
        heard = []
        watch.launched(bundle: "com.apple.logic10", name: "Logic Pro")
        spin(0.6)
        check("a program coming back is said, queued behind what VoiceOver is reading",
              heard.count == 1 && heard[0].0 == "Logic Pro is back, so Logic is on again"
                && !heard[0].1, "\(heard)")
        heard = []
        watch.sayCameOn([again])
        check("and so is a source the retry brought on",
              heard.count == 1 && !heard[0].1, "\(heard)")

        // Finding 6: Remove is never disabled, and refuses the microphone in
        // words.
        let control = SourceGroup()
        let desk = StandInSource(name: "Desk", level: 0.1)
        control.useForTesting([desk])
        let owned = Board()
        owned.sources = [desk.config]
        var answered: [String] = []
        let voice = Speaker()
        voice.status = { answered.append($0) }
        let sourcePanel = SourceControlPanel(group: control, mic: MicInput(duckBus: DuckBus()),
                                             speaker: voice) { id in
            control.forget(id: id, on: owned)
        }
        sourcePanel.confirmRemove = { _ in true }
        sourcePanel.makeControls()
        sourcePanel.select(row: 1)
        sourcePanel.removePressed()
        check("removing the last source leaves Remove enabled, so the focus stays on it",
              control.all.isEmpty && sourcePanel.removeButton.isEnabled)
        sourcePanel.removePressed()
        check("and pressed on the microphone it says why not",
              answered.last == "The microphone cannot be removed. Command M turns it off.",
              answered.last ?? "nothing")
    }
}
