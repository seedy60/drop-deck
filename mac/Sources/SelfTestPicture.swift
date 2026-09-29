// The checks for the picture belonging to the APP (Windows 3.8.1, W381).
//
// Every one of these is a fault that was silent: the app said nothing wrong
// because it said nothing at all. Nothing here opens a real camera or a real
// screen capture. Those raise system prompts, to a blind user, and the answer
// is filed against the build's signature; a picture source that opens nothing
// stands in, and the one pipeline is proved by COUNTING what it opens.

import Foundation
import AppKit
import CoreVideo
import CoreGraphics

/// A picture source that opens nothing, and counts what is asked of it.
final class FakePicture: PictureSource {
    let kind: String
    let camera: String
    var errorText = ""
    var count: Int?
    var answer: CVPixelBuffer?
    private(set) var starts = 0
    private(set) var closes = 0
    private(set) var titleSet = ""
    init(kind: String, camera: String = "", answer: CVPixelBuffer? = nil) {
        self.kind = kind
        self.camera = camera
        self.answer = answer
    }
    var error: String { errorText }
    var framesRead: Int? { count }
    var moving: Bool { true }
    func frame(width: Int, height: Int) -> CVPixelBuffer? { answer }
    func describe() -> String { "a stand in \(kind)" }
    func start() { starts += 1 }
    func close() { closes += 1 }
    func setTitle(_ title: String) { titleSet = title }
}

/// A picture whose `start()` does not return until it is let go: the way a
/// camera's first start waits on the permission prompt. Opens nothing.
final class SlowPicture: PictureSource {
    let kind = C.pictureCamera
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var starting = false
    private var closeCount = 0
    /// When set, the start is let go by a block on the MAIN queue, which is
    /// how a permission answer arrives.
    let answeredOnMain: Bool
    let limit: Double
    init(answeredOnMain: Bool = false, limit: Double = 4) {
        self.answeredOnMain = answeredOnMain
        self.limit = limit
    }
    var inStart: Bool { lock.lock(); defer { lock.unlock() }; return starting }
    var closes: Int { lock.lock(); defer { lock.unlock() }; return closeCount }
    var framesRead: Int? { 0 }
    func frame(width: Int, height: Int) -> CVPixelBuffer? { nil }
    func describe() -> String { "a slow stand in camera" }
    func start() {
        lock.lock(); starting = true; lock.unlock()
        if answeredOnMain {
            let gate = self.gate
            DispatchQueue.main.async { gate.signal() }
        }
        _ = gate.wait(timeout: .now() + limit)
        lock.lock(); starting = false; lock.unlock()
    }
    func letGo() { gate.signal() }
    func close() { lock.lock(); closeCount += 1; lock.unlock() }
}

/// A split that moves its corner and opens nothing.
final class FakeSplit: PictureSource, CornerMovable {
    let kind = C.pictureSplit
    var corner: String
    init(corner: String) { self.corner = corner }
    func frame(width: Int, height: Int) -> CVPixelBuffer? { nil }
    func describe() -> String { "a stand in split" }
}

extension SelfTest {

    func runPictureChecks() {
        testAuditOnePicture()
        testPictureFeedHolds()
        testPictureFeedRebuild()
        testOneCameraOwner()
        testPictureNotGatedOnLiveTo()
        testPictureWords()
        testPictureWindow()
        testStartingGrace()
        testReaderRecovery()
        testFrameTapQueue()
        testRecordingReport()
        testRecordPump()
        testPictureNotes()
        testLetterboxFastPath()
        testPictureHelpText()
    }

    /// A feed whose sources are stand ins, and the list of what it built.
    private func fakeFeed(_ settings: @escaping () -> PictureSettings)
        -> (PictureFeed, () -> [FakePicture]) {
        let lock = NSLock()
        var made: [FakePicture] = []
        let feed = PictureFeed(settings: settings, build: { s, _ in
            let one = FakePicture(kind: s.picture, camera: s.camera)
            lock.lock(); made.append(one); lock.unlock()
            return one
        })
        return (feed, { lock.lock(); defer { lock.unlock() }; return made })
    }

    // ------------------------------------------------------ one pipeline ---

    private func testPictureFeedHolds() {
        out.append("")
        out.append("One picture pipeline, reference counted (W381-03)")

        var wanted = PictureSettings()
        wanted.picture = C.pictureCamera
        wanted.camera = "Test Camera"
        let (feed, made) = fakeFeed({ wanted })
        feed.settle()
        check("nothing is open until somebody takes hold",
              !feed.running && made().isEmpty)

        feed.acquire(PictureFeed.forStream)
        feed.settle()
        check("the first holder opens it", feed.running && made().count == 1)
        check("and what it opens is STARTED, which is the whole fault Windows had",
              made().first?.starts == 1)

        feed.acquire(PictureFeed.forRecording)
        feed.settle()
        check("a second holder gets the SAME source, so one camera serves both",
              made().count == 1 && feed.builds == 1, "\(made().count) built")
        check("and both are named, in the order they took hold",
              feed.describeHolders() == "the stream and the recording",
              feed.describeHolders())

        // Coming off air: the stream lets go, the recording keeps the camera.
        // This is W381-37, which closed the recording's camera with the stream.
        feed.release(PictureFeed.forStream)
        feed.settle()
        check("the stream letting go leaves the recording's picture open",
              feed.running && made().first?.closes == 0)
        check("and the recording still holds it",
              feed.heldBy(PictureFeed.forRecording) && !feed.heldBy(PictureFeed.forStream))
        feed.release(PictureFeed.forRecording)
        feed.settle()
        check("the last one letting go closes it",
              !feed.running && made().first?.closes == 1)

        // Two previews both call themselves "a preview", and a set of names
        // let the first release close the camera under the second.
        feed.acquire(PictureFeed.forPreview)
        feed.acquire(PictureFeed.forPreview)
        feed.release(PictureFeed.forPreview)
        feed.settle()
        check("two previews are two holds, not one", feed.running)
        feed.release(PictureFeed.forPreview)
        feed.settle()
        check("and the second release closes it", !feed.running)

        check("nothing is asked of a feed that holds nothing",
              feed.frame(width: 64, height: 36) == nil)
        check("three names are said as a list",
              PictureFeed.join(["the stream", "the recording", "a preview"])
              == "the stream, the recording and a preview")

        // Released while it was still opening: nothing left open.
        feed.acquire(PictureFeed.forPreview)
        feed.release(PictureFeed.forPreview)
        feed.settle()
        check("a hold taken and let go before it opened leaves nothing open",
              !feed.running && feed.openNow == 0, "\(feed.openNow) open")

        check("acquire, release and rebuild never wait on a camera",
              { () -> Bool in
                  let slow = PictureFeed(settings: { wanted }, build: { s, _ in
                      Thread.sleep(forTimeInterval: 0.4)
                      return FakePicture(kind: s.picture)
                  })
                  let began = Date()
                  slow.acquire(PictureFeed.forRecording)
                  slow.rebuild()
                  slow.release(PictureFeed.forRecording)
                  let took = Date().timeIntervalSince(began)
                  slow.settle()
                  return took < 0.1
              }())
    }

    private func testPictureFeedRebuild() {
        out.append("")
        out.append("A new picture goes in before the old one comes out")

        var wanted = PictureSettings()
        wanted.picture = C.pictureCard
        wanted.name = "First"
        let (feed, made) = fakeFeed({ wanted })
        feed.acquire(PictureFeed.forPreview)
        feed.setTitle("A song")
        feed.settle()
        let first = made().first
        wanted.name = "Second"
        feed.acquire(PictureFeed.forRecording)
        feed.settle()
        check("a later hold rebuilds when the settings have moved on",
              made().count == 2 && first?.closes == 1)
        check("and the title survives the rebuild", made().last?.titleSet == "A song")

        wanted.title = "Only the title changed"
        feed.acquire(PictureFeed.forStream)
        feed.settle()
        check("a new track does not rebuild the camera once a song",
              made().count == 2, "\(made().count) built")

        wanted.picture = C.pictureScreen
        check("a rebuild with somebody holding it swaps the source", feed.rebuild())
        feed.settle()
        check("under everybody at once", made().count == 3 && feed.kind == C.pictureScreen,
              feed.kind)
        feed.close()
        feed.settle()
        check("close lets go of everything at once", !feed.running)
        check("a rebuild with nobody holding it opens nothing",
              !feed.rebuild() && { feed.settle(); return !feed.running }())

        // A source that has been replaced must not report on the live one.
        var told: [String] = []
        var builders: [(String) -> Void] = []
        var sources: [FakePicture] = []
        let teller = PictureFeed(settings: { wanted }, build: { s, fell in
            let one = FakePicture(kind: s.picture)
            builders.append(fell)
            sources.append(one)
            return one
        })
        teller.onFallback = { told.append($0) }
        teller.acquire(PictureFeed.forStream)
        teller.settle()
        wanted.picture = C.pictureCard
        teller.rebuild()
        teller.settle()
        builders.first?("the camera stopped")
        check("a dying source cannot write a reason over the live one",
              teller.reason.isEmpty && told.isEmpty, told.joined(separator: "; "))
        builders.last?("the camera stopped")
        check("and the live one still can",
              teller.reason == "the camera stopped" && told.count == 1)
        builders.last?("The camera is back")
        check("and coming back clears it", teller.reason.isEmpty && told.count == 2)
        teller.close()
        teller.settle()
    }

    /// W381-05. Two capture sessions on one camera are impossible by
    /// construction, not by care: every holder there is takes the picture
    /// through the ONE feed, and the feed counts what it opens per camera.
    private func testOneCameraOwner() {
        out.append("")
        out.append("A camera has one owner, whoever wants the picture")

        var wanted = PictureSettings()
        wanted.picture = C.pictureCamera
        wanted.camera = "Test Camera"
        let (feed, made) = fakeFeed({ wanted })
        // Record off air, go live, look with the shot check and with
        // Command+Shift+F, change the colours, move to the split, come off
        // air, stop the recording: every consumer and every rebuild.
        // Settled after each step, the way a show spreads them out: the
        // worker runs them in order either way, but a step taken before the
        // camera has even opened would prove nothing.
        let steps: [() -> Void] = [
            { feed.acquire(PictureFeed.forRecording) },
            { feed.acquire(PictureFeed.forStream) },
            { feed.acquire(PictureFeed.forPreview) },
            { feed.acquire(PictureFeed.forPreview) },
            { feed.release(PictureFeed.forPreview) },
            { feed.release(PictureFeed.forPreview) },
            { wanted.colourBackground = "navy"; feed.rebuild() },
            { wanted.picture = C.pictureSplit; feed.rebuild() },
            { feed.release(PictureFeed.forStream) },
        ]
        var runningThroughout = true
        for step in steps {
            step()
            feed.settle()
            if !feed.running { runningThroughout = false }
        }
        check("the picture stays open through all of it", runningThroughout)
        feed.release(PictureFeed.forRecording)
        feed.settle()
        let cameras = made().filter { C.pictureNeedsCamera.contains($0.kind) }
        check("never two sources on one camera at once",
              feed.mostOnOneCamera == 1, "\(feed.mostOnOneCamera) at once")
        check("every one opened was closed", cameras.count == 3 && cameras.allSatisfy { $0.closes == 1 }
              && !feed.running)
        check("and a picture change between different things still goes new in first",
              { () -> Bool in
                  var s = PictureSettings()
                  s.picture = C.pictureCard
                  let (f, m) = fakeFeed({ s })
                  f.acquire(PictureFeed.forStream)
                  f.settle()
                  s.picture = C.pictureScreen
                  f.rebuild()
                  f.settle()
                  let ok = f.mostOpenAtOnce == 2 && m().first?.closes == 1
                  f.close(); f.settle()
                  return ok
              }())
    }

    // ------------------------------------------------ not gated on live_to ---

    private func testPictureNotGatedOnLiveTo() {
        out.append("")
        out.append("The picture is not gated on where Command+B is pointed (W381-06)")

        let chosen = "what is on my screen"
        let head = MainWindow.screenHead(live: false, showing: false, recording: false,
                                         described: "", chosen: chosen)
        check("Command+Shift+V does not answer Nothing on a radio board",
              !head.hasPrefix("Nothing")
              && head == "what is on my screen, once you go live or start recording "
                 + "the picture", head)
        check("during a recording it says the picture is being recorded",
              MainWindow.screenHead(live: true, showing: false, recording: true,
                                    described: "a camera at 720p", chosen: chosen)
              == "a camera at 720p, being recorded")
        check("on air and recording, both",
              MainWindow.screenHead(live: true, showing: true, recording: true,
                                    described: "", chosen: chosen)
              == "a picture, going out and being recorded")
        check("a recording still opening says so",
              MainWindow.screenHead(live: false, showing: false, recording: true,
                                    described: "", chosen: chosen)
              == "what is on my screen, once the picture starts")

        check("a radio stream opens no picture",
              !PictureFeed.wantedFor(server: "icecast")
              && !PictureFeed.wantedFor(server: "shoutcast"))
        check("a video platform does", PictureFeed.wantedFor(server: "youtube"))

        check("a change with nothing live is for a stream AND a recording",
              MainWindow.nextTimeSentence("a camera")
              == "Next time you go live or record the picture: a camera")
    }

    // ------------------------------------------------------- what is said ---

    private func testPictureWords() {
        out.append("")
        out.append("What a blind presenter is told about the picture")

        // W381-43: the card is blamed on whoever is really showing it.
        check("a card is blamed on the recording, not on a stream that is off",
              MainWindow.fallbackSentence("the camera stopped", holders: "the recording")
              == "the camera stopped. The recording is showing a card instead.")
        check("and on both when both hold it",
              MainWindow.fallbackSentence("the camera stopped",
                                          holders: "the stream and the recording")
              == "the camera stopped. The stream and the recording is showing a card "
                 + "instead.")
        check("coming back says who has the picture again",
              MainWindow.fallbackSentence("The camera is back", holders: "the stream")
              == "The camera is back. The stream has the picture again.")
        check("with nobody named, the stream, as Windows says",
              MainWindow.fallbackSentence("x", holders: "")
              == "x. The stream is showing a card instead.")

        // N6: what came back is named.
        check("a camera coming back is the camera",
              FallbackSource.backLine(C.pictureCamera) == "The camera is back")
        check("a screen coming back is the screen, not a camera",
              FallbackSource.backLine(C.pictureScreen) == "The screen is back"
              && FallbackSource.backLine(C.pictureSplit) == "The screen is back")
        check("and anything else is the picture",
              FallbackSource.backLine(C.pictureImage) == "The picture is back")
        check("each of those counts as coming back",
              [C.pictureCamera, C.pictureScreen, C.pictureImage].allSatisfy {
                  PictureFeed.isRecovery(FallbackSource.backLine($0))
              })

        // W381-08: the verb says where it is going.
        check("a change on air says Now showing",
              MainWindow.pictureVerb(showing: true, recording: false) == "Now showing")
        check("during a recording, Now recording",
              MainWindow.pictureVerb(showing: false, recording: true) == "Now recording:")
        check("both, On air and recording",
              MainWindow.pictureVerb(showing: true, recording: true)
              == "On air and recording:")

        // W381-14: Command+Shift+R names its picture.
        check("a recording that has not been looked through names what is chosen",
              MainWindow.pictureInTheRecording(chosen: "a camera", running: true, asked: 0,
                                               fallenBack: false, reason: "",
                                               described: "x") == " Picture: a camera.")
        check("one that has fallen back says so, and why",
              MainWindow.pictureInTheRecording(chosen: "a camera", running: true, asked: 9,
                                               fallenBack: true,
                                               reason: "the camera stopped", described: "")
              == " Picture: a card instead of a camera, because the camera stopped.")
        check("one that is working says what it really is",
              MainWindow.pictureInTheRecording(chosen: "a camera", running: true, asked: 9,
                                               fallenBack: false, reason: "",
                                               described: "Studio Cam at 720p")
              == " Picture: Studio Cam at 720p.")

        // W381-11: Command+Shift+W.
        let radio = MainWindow.pictureReport(
            chosen: "a camera", width: 1280, height: 720, using: "", liveToVideo: false,
            fallenBack: false, reason: "", marks: "")
        check("on a radio board it says what the picture is for",
              radio == "Your picture is a camera, 1280 by 720. Nothing is using it yet. "
                     + "Your radio station sends no picture, so Option+Shift+B does not "
                     + "use it. It goes out when you press Command+B, which goes live on "
                     + "your video platform, and into the file when you press "
                     + "Command+Shift+R.", radio)
        // The key split made the old sentence false (P3 hand-off): Command+B
        // never goes to the radio station now, and nothing is "switched over".
        check("and never says Command+B goes to the radio station",
              !radio.contains("Command+B goes to your radio station")
              && !radio.contains("switch Command+B over"), radio)
        let busy = MainWindow.pictureReport(
            chosen: "a camera", width: 1280, height: 720,
            using: "the stream and the recording", liveToVideo: true, fallenBack: true,
            reason: "the camera stopped", marks: "your station name at the top")
        check("and names what is using it, the card and what is on top",
              busy == "Your picture is a camera, 1280 by 720. The stream and the recording "
                    + "are using it. A card is standing in, because the camera stopped. "
                    + "On top of it: your station name at the top.", busy)
        check("one holder is using it, not are",
              MainWindow.pictureReport(chosen: "a card", width: 640, height: 360,
                                       using: "a preview", liveToVideo: true,
                                       fallenBack: false, reason: "", marks: "")
              .contains("A preview is using it."))

        // W381-12 and W381-13.
        check("the status line says a picture recording is running",
              MainWindow.recordingStatus(audio: false, picture: true) == ["RECORDING PICTURE"])
        check("and both when both are",
              MainWindow.recordingStatus(audio: true, picture: true)
              == ["RECORDING", "RECORDING PICTURE"])
        check("a recording line goes on the end of a stream answer with a full stop",
              MainWindow.withSentence("On air to YouTube", "Recording picture and sound.")
              == "On air to YouTube. Recording picture and sound."
              && MainWindow.withSentence("Off air.", "More.") == "Off air. More."
              && MainWindow.withSentence("Off air", "") == "Off air")

        // W381-39.
        check("the shot check says where the picture is going: out",
              MainWindow.shotWhere(showing: true, recording: true) == "going out")
        check("into a recording",
              MainWindow.shotWhere(showing: false, recording: true)
              == "going into your recording")
        check("or nowhere yet",
              MainWindow.shotWhere(showing: false, recording: false) == "that would go out")
        check("and the line reads as Windows' does",
              ShotCheckPanel.whatLine(kind: "screen", who: "Claude",
                                      where: "going into your recording")
              == "This describes the picture going into your recording, which includes "
                 + "your screen. Claude is asked."
              && ShotCheckPanel.whatLine(kind: "camera", who: "Gemini",
                                         where: "that would go out")
              == "This describes the picture that would go out, camera and anything on "
                 + "top of it. Gemini is asked.")
    }

    private func testPictureWindow() {
        out.append("")
        out.append("The picture window: Picture, Using, and the chosen one always there")

        check("the Using column is empty on every row but the chosen one",
              VideoSourcePanel.useLabel(C.pictureCard, chosen: C.pictureCamera,
                                        showing: true, recording: true) == "")
        check("the chosen one says chosen when nothing is using it",
              VideoSourcePanel.useLabel(C.pictureCamera, chosen: C.pictureCamera,
                                        showing: false, recording: false) == "chosen")
        check("on air",
              VideoSourcePanel.useLabel(C.pictureCamera, chosen: C.pictureCamera,
                                        showing: true, recording: false) == "on air")
        check("recording",
              VideoSourcePanel.useLabel(C.pictureCamera, chosen: C.pictureCamera,
                                        showing: false, recording: true) == "recording")
        check("on air and recording",
              VideoSourcePanel.useLabel(C.pictureCamera, chosen: C.pictureCamera,
                                        showing: true, recording: true)
              == "on air and recording")

        let noCamera = VideoSourcePanel.offered(chosen: C.pictureCamera, hasCamera: false,
                                                hasScreen: false)
        check("the chosen source is always offered, even if it cannot work here",
              noCamera.contains(C.pictureCamera), noCamera.joined(separator: ", "))
        check("and the others that cannot work are not",
              !noCamera.contains(C.pictureSplit) && !noCamera.contains(C.pictureScreen)
              && noCamera.contains(C.pictureCard))
        check("everything is offered when everything can work",
              VideoSourcePanel.offered(chosen: C.pictureCard, hasCamera: true,
                                       hasScreen: true) == C.pictureSources)
        check("a missing camera is said, not left out",
              VideoSourcePanel.missingNote(hasCamera: false, hasScreen: true,
                                           screenReason: "")
              == "A camera is not offered: macOS can see none")
        check("and a screen that cannot be captured gives its reason",
              VideoSourcePanel.missingNote(hasCamera: true, hasScreen: false,
                                           screenReason: "")
              == "Your screen cannot be captured on this machine"
              && VideoSourcePanel.missingNote(hasCamera: true, hasScreen: false,
                                              screenReason: "Because.") == "Because.")
        check("and nothing when nothing is missing",
              VideoSourcePanel.missingNote(hasCamera: true, hasScreen: true,
                                           screenReason: "x").isEmpty)
    }

    // ------------------------------------------------- starting and dying ---

    private func testStartingGrace() {
        out.append("")
        out.append("Starting up is not the same as broken (W381-31)")

        let backup = CardSource(name: "Test")
        var told: [String] = []
        var clock = 100.0

        let opening = FakePicture(kind: C.pictureCamera)
        opening.count = 0
        let starting = FallbackSource(primary: opening, backup: backup,
                                      onFallback: { told.append($0) })
        starting.now = { clock }
        starting.restart = { $0.start() }
        check("a source that is still opening gets the card and is not called broken",
              starting.frame(width: 64, height: 36) != nil && !starting.fallenBack
              && starting.starting && told.isEmpty, told.joined(separator: "; "))
        check("and it says it is starting up, not showing a card instead",
              starting.describe() == "a stand in camera, starting up", starting.describe())
        clock += C.pictureStartSeconds + 0.1
        _ = starting.frame(width: 64, height: 36)
        check("but not for ever: past the ceiling it has fallen back and said so",
              starting.fallenBack && told.count == 1)

        told = []
        let stopped = FakePicture(kind: C.pictureCamera)
        stopped.count = 42
        let dead = FallbackSource(primary: stopped, backup: backup,
                                  onFallback: { told.append($0) })
        _ = dead.frame(width: 64, height: 36)
        check("a source that HAS produced frames and stopped is reported at once",
              dead.fallenBack && told.count == 1)

        told = []
        let refused = FakePicture(kind: C.pictureCamera)
        refused.count = 0
        refused.errorText = "macOS would not allow access to the camera"
        let blocked = FallbackSource(primary: refused, backup: backup,
                                     onFallback: { told.append($0) })
        _ = blocked.frame(width: 64, height: 36)
        check("one that has said what is wrong is broken, not starting",
              blocked.fallenBack && told == [refused.errorText])

        let mute = FakePicture(kind: C.pictureCamera)
        let blind = FallbackSource(primary: mute, backup: backup)
        _ = blind.frame(width: 64, height: 36)
        check("one that cannot say whether it has started gets no grace",
              blind.fallenBack)

        check("the split asks its SCREEN whether it has started",
              { () -> Bool in
                  let split = SplitSource(screen: ScreenSource(), camera: CameraSource(device: "x"))
                  return split.framesRead == 0
              }())
    }

    private func testReaderRecovery() {
        out.append("")
        out.append("A camera or a screen that goes away can come back (W381-32)")

        var clock = 0.0
        var told: [String] = []
        let gone = FakePicture(kind: C.pictureScreen)
        gone.count = 5
        let fallback = FallbackSource(primary: gone, backup: CardSource(name: "T"),
                                      onFallback: { told.append($0) })
        fallback.now = { clock }
        fallback.restart = { $0.start() }
        _ = fallback.frame(width: 64, height: 36)
        let before = gone.starts
        clock += C.pictureRetrySeconds + 0.1
        gone.answer = CardSource(name: "Back").frame(width: 64, height: 36)
        _ = fallback.frame(width: 64, height: 36)
        check("the retry STARTS the source again, so a dead reader can come back",
              gone.starts == before + 1)
        check("and says which thing came back",
              !fallback.fallenBack && told.last == "The screen is back",
              told.joined(separator: "; "))

        // Never opened, so nothing real is touched: what matters is that a
        // lost capture lets go of its session, because start() refuses while
        // one is held and the retry would otherwise ask a corpse.
        let camera = CameraSource(device: "No Such Camera For The Self Test")
        camera.lost("the camera is not there any more")
        check("a camera that goes away lets go of its session",
              !camera.holdsSession && camera.error == "the camera is not there any more")
        let asked = Date()
        let answered = camera.waitReady(timeout: 2.0)
        check("and a waiter on a camera that has gone is answered at once, not at the timeout",
              !answered && Date().timeIntervalSince(asked) < 0.2)
        let screen = ScreenSource()
        screen.lost("")
        check("and so does a screen, with a reason",
              !screen.holdsCapture && screen.error == "the screen stopped being captured")

        // W381-30: the screen is captured at the size it will be sent at.
        let wide = ScreenSource.captureSize(displayWidth: 1920, displayHeight: 1080,
                                            wantWidth: 1280, wantHeight: 720)
        check("a 16 by 9 screen is captured at exactly the frame size",
              wide == (1280, 720), "\(wide)")
        let tall = ScreenSource.captureSize(displayWidth: 2560, displayHeight: 1600,
                                            wantWidth: 1280, wantHeight: 720)
        check("a 16 by 10 screen keeps its shape inside the frame, in even numbers",
              tall == (1152, 720), "\(tall)")

        // W381-09: the split's corner moves on the live source.
        let split = SplitSource(screen: ScreenSource(), camera: CameraSource(device: "x"),
                                corner: "bottom right")
        split.corner = "top left"
        let moved = split.corner
        split.corner = "nowhere"
        check("the split's corner moves without a rebuild",
              moved == "top left" && split.corner == "top left")
        let (feed, _) = fakeFeed({ PictureSettings() })
        feed.acquire(PictureFeed.forStream)
        feed.settle()
        check("and asking a feed that is not a split to move it says it cannot",
              !feed.setCorner("top left"))
        feed.close()
        feed.settle()
    }

    // ------------------------------------------------------------ the file ---

    private func testFrameTapQueue() {
        out.append("")
        out.append("The file: every picture, once, in order (W381-26)")

        let tap = FrameTap()
        guard let a = CardSource(name: "A").frame(width: 32, height: 18),
              let b = CardSource(name: "B").frame(width: 32, height: 18) else {
            check("two test frames could be drawn", false)
            return
        }
        tap.put(a)
        tap.put(b)
        let first = tap.take()
        let second = tap.take()
        check("the tap hands over BOTH frames, oldest first",
              first.buffer === a && second.buffer === b && second.seq == first.seq + 1)
        check("and an empty tap answers nothing rather than the last one",
              tap.take().buffer == nil && tap.take().seq == 0)
        check("it holds more than one, which is what stops pictures being lost",
              FrameTap.depth >= 2)
        for _ in 0..<10 { tap.put(a) }
        check("but it is bounded, so a slow encoder cannot play stale pictures late",
              tap.waiting == FrameTap.depth && tap.dropped == 10 - FrameTap.depth,
              "\(tap.waiting) waiting, \(tap.dropped) dropped")
        check("every picture put in is counted", tap.puts == 12)
        check("latest looks without taking", tap.latest() === a && tap.waiting == FrameTap.depth)
        let one = FrameTap(depth: 1)
        one.put(a); one.put(b)
        check("a one slot tap keeps only the newest, which is what lost frames",
              one.take().buffer === b && one.dropped == 1)
        check("the stamp lead is the one measured on this Mac, not Windows' -1",
              C.recordTapLeadFrames == 0, "\(C.recordTapLeadFrames)")
    }

    private func testRecordingReport() {
        out.append("")
        out.append("What a finished picture recording says about itself")

        // W381-44.
        check("a 321 KB file is not 0 megabytes",
              VideoRecorder.sizePhrase(321 * 1024) == "0.3 megabytes",
              VideoRecorder.sizePhrase(321 * 1024))
        check("a tiny one is said in kilobytes",
              VideoRecorder.sizePhrase(50 * 1024) == "50 kilobytes")
        check("one decimal from a tenth of a megabyte",
              VideoRecorder.sizePhrase(110_000) == "0.1 megabytes"
              && VideoRecorder.sizePhrase(Int64(9.5 * 1_048_576)) == "9.5 megabytes")
        check("whole megabytes from ten",
              VideoRecorder.sizePhrase(Int64(12.4 * 1_048_576)) == "12 megabytes"
              && VideoRecorder.sizePhrase(10 * 1_048_576) == "10 megabytes")

        // W381-45.
        check("a file that never got a picture says it is black",
              VideoRecorder.pictureReport(puts: 0, framesSent: 300, repeated: 300)
              == ["NO PICTURE ever arrived, so the file is black. Check your picture "
                  + "with Option+Shift+V"])
        check("one that is almost all repeats says it is close to a still",
              VideoRecorder.pictureReport(puts: 3, framesSent: 1000, repeated: 990)
              == ["The picture repeated for 99 per cent of it, so it is close to a still"])
        check("and a healthy one says nothing about its picture",
              VideoRecorder.pictureReport(puts: 900, framesSent: 900, repeated: 20).isEmpty)

        // N4: a failed recording is not saved.
        let failed = VideoRecorder()
        failed.failure = "The disk is full"
        let said = failed.report()
        check("a picture recording whose writer failed is not reported as saved",
              said == "The picture recording stopped. The disk is full."
              && !said.contains("saved"), said)
    }

    private func testRecordPump() {
        out.append("")
        out.append("A recording made off air pulls from the one feed")

        var s = PictureSettings()
        s.picture = C.pictureCard
        s.name = "Pump"
        let feed = PictureFeed(settings: { s })
        feed.acquire(PictureFeed.forRecording)
        feed.settle()
        let tap = FrameTap()
        var words = OverlaySettings()
        words.places = ["lower": ["kind": C.textWords, "words": "", "file": ""]]
        let overlay = Overlay(settings: words)
        let pump = RecordPicturePump(feed: feed, tap: tap, width: 320, height: 180,
                                     fps: 30, overlay: overlay,
                                     framingLevel: C.framingProblems, say: { _ in })
        pump.start()
        Thread.sleep(forTimeInterval: 0.3)
        let bare = tap.latest().map { SelfTest.inspect($0).mean } ?? -1
        // W381-20: the words on top reach a recording that is already running.
        words.places = ["lower": ["kind": C.textWords, "words": "LIVE WORDS HERE",
                                  "file": ""]]
        overlay.apply(words)
        Thread.sleep(forTimeInterval: 0.3)
        let lettered = tap.latest().map { SelfTest.inspect($0).mean } ?? -1
        pump.stop()
        check("it fills the recording's tap", tap.puts > 3, "\(tap.puts) frames")
        check("from the feed, opening nothing of its own", feed.builds == 1)
        check("and new words reach the file while it records",
              bare >= 0 && lettered >= 0 && bare != lettered,
              "bare \(bare), with words \(lettered)")
        let after = tap.puts
        Thread.sleep(forTimeInterval: 0.15)
        check("and it stops when told, leaving the tap for the stream", tap.puts == after)
        feed.close()
        feed.settle()
    }

    // --------------------------------------------------------- pre-flight ---

    private func testPictureNotes() {
        out.append("")
        out.append("A picture pre-flight for a recording (W381-15, W381-16)")

        var s = PreflightSettings()
        s.picture = C.pictureCamera
        s.camera = ""
        var b = PreflightBoard()
        b.liveTo = C.liveToAudio
        let recording = Preflighter.pictureNotes(settings: s, board: b,
                                                 consumer: Preflighter.forRecording)
        check("a recording is warned about a camera it has not chosen",
              recording.map { $0.text }
              == ["No camera has been chosen, so the recording would fall back to a card"],
              recording.map { $0.text }.joined(separator: "; "))
        check("and nothing in it says the stream",
              recording.allSatisfy { !$0.text.contains("the stream") })
        let stream = Preflighter.pictureNotes(settings: s, board: b)
        check("the stream's own warning still says the stream",
              stream.first?.text
              == "No camera has been chosen, so the stream would fall back to a card")
        s.picture = C.pictureImage
        s.pictureFile = "/tmp/dropdeck-no-such-art.png"
        check("a moved picture file names the recording too",
              Preflighter.pictureNotes(settings: s, board: b,
                                       consumer: Preflighter.forRecording).first?.text
              == "That picture file is not there any more, so the recording would show "
                 + "an empty screen")
        s.picture = C.pictureCard
        b.streamTitles = false
        check("and the card is warned about when titles are off",
              Preflighter.pictureNotes(settings: s, board: b).map { $0.text }
              == ["Track titles are turned off, so the card will not say what is playing"])

        // The order: the picture's notes, THEN the bitrate advice.
        var v = PreflightSettings()
        v.server = "youtube"
        v.host = "rtmps://a.rtmps.youtube.com/live2/key"
        v.password = "secret"
        v.picture = C.pictureCard
        v.bitrate = 128
        v.videoWidth = 1280; v.videoHeight = 720; v.videoFPS = 30; v.videoBitrate = 400
        var vb = PreflightBoard()
        vb.liveTo = C.liveToVideo
        vb.videoServer = "youtube"
        vb.streamTitles = false
        let notes = Preflighter.check(settings: v, board: vb).notes.map { $0.text }
        let titles = notes.firstIndex { $0.hasPrefix("Track titles are turned off") }
        let advice = StreamServers.bitrateAdvice(server: "youtube", width: 1280, height: 720,
                                                 fps: 30, videoKbps: 400, audioKbps: 128)
        let adviceAt = notes.firstIndex(of: advice)
        check("the titles note comes before the bitrate advice, Windows' order",
              !advice.isEmpty && titles != nil && adviceAt != nil && titles! < adviceAt!,
              notes.joined(separator: " | "))
        check("spoken warnings are one sentence each, ending in a full stop",
              MainWindow.spokenNotes([PreflightNote(.warn, "One"),
                                      PreflightNote(.warn, "Two")]) == " One. Two."
              && MainWindow.spokenNotes([]).isEmpty)
    }

    // --------------------------------------------------------- cheap paths ---

    private func testLetterboxFastPath() {
        out.append("")
        out.append("A picture already the right size is not resized (W381-30)")

        guard let source = CardSource(name: "Same size", title: "Fast path")
                .frame(width: 640, height: 360),
              let image = CameraSource.image(from: source) else {
            check("a test picture could be drawn", false)
            return
        }
        let began = Date()
        var last: CVPixelBuffer?
        for _ in 0..<20 {
            last = Pixels.draw(width: 640, height: 360) { ctx in
                Pixels.letterbox(image, into: ctx, width: 640, height: 360)
            }
        }
        let each = Date().timeIntervalSince(began) / 20 * 1000
        let same = last.map { SelfTest.samePixels($0, source) } ?? false
        check("the same size is copied exactly, not resampled", same)
        check("and it is cheap", each < 10, String(format: "%.2f ms", each))
    }

    static func samePixels(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        guard w == CVPixelBufferGetWidth(b), h == CVPixelBufferGetHeight(b),
              let pa = CVPixelBufferGetBaseAddress(a)?.assumingMemoryBound(to: UInt8.self),
              let pb = CVPixelBufferGetBaseAddress(b)?.assumingMemoryBound(to: UInt8.self)
        else { return false }
        let sa = CVPixelBufferGetBytesPerRow(a), sb = CVPixelBufferGetBytesPerRow(b)
        for y in 0..<h {
            for x in 0..<(w * 4) where pa[y * sa + x] != pb[y * sb + x] { return false }
        }
        return true
    }

    private func testPictureHelpText() {
        out.append("")
        out.append("F1 and the Recording page talk about the picture (W381-48, W381-49)")

        // Whitespace run together, because the chapters are wrapped text.
        let help = KeyboardHelp.chapters().split(whereSeparator: { $0 == " " || $0 == "\n" })
            .joined(separator: " ")
        check("the chapter is for a stream OR a recording",
              help.contains("THE PICTURE, FOR A STREAM OR A RECORDING")
              && !help.contains("WHEN YOU ARE STREAMING VIDEO"))
        check("Option Shift V is the same picture for both",
              help.contains("It is the same picture for a stream and for a recording"))
        check("Command Shift R takes whatever Option Shift V is set to",
              help.contains("it takes whatever Option Shift V is set to"))
        check("Command Shift W includes the picture",
              help.contains("your picture and what is using it"))
        check("the Recording page names the picture key",
              VideoPrefs.recordingNote.contains("Command+Shift+R records the picture as "
                                                + "well, to one MP4")
              && VideoPrefs.recordingNote.contains("Option+Shift+V changes it from "
                                                   + "anywhere"))
    }

    // ------------------------------------------------------ audit 1 ---

    private func testAuditOnePicture() {
        out.append("")
        out.append("The picture, after the first audit of 3.8.4")

        var s = PictureSettings()
        s.picture = C.pictureCamera
        s.camera = "Test Camera"
        let card = Pixels.make(width: 64, height: 36)

        // Finding 3: while the real picture opens, the card goes out, not
        // nothing.
        let slow = SlowPicture()
        let stand = FakePicture(kind: C.pictureCard, answer: card)
        let feed = PictureFeed(settings: { s }, build: { _, fell in
            FallbackSource(primary: slow, backup: stand, onFallback: fell)
        })
        feed.acquire(PictureFeed.forStream, settings: s)
        let by = Date().addingTimeInterval(2)
        while Date() < by && !(slow.inStart && feed.running) { Thread.sleep(forTimeInterval: 0.01) }
        check("while a camera is still opening the stream gets the card, not nothing",
              slow.inStart && feed.running && feed.frame(width: 64, height: 36) != nil,
              "starting \(slow.inStart), published \(feed.running)")
        check("and nothing is announced about it",
              !feed.fallenBack && feed.reason.isEmpty)
        slow.letGo()
        feed.settle()
        check("it is the one source, counted once", feed.builds == 1 && feed.openNow == 1,
              "\(feed.builds) built, \(feed.openNow) open")
        feed.close()
        feed.settle()
        check("and it closes as ever", !feed.running && feed.openNow == 0 && slow.closes >= 1)

        // Finding 2: closing the app never waits long on a picture whose start
        // waits for the main thread, and what was opening is shut at once.
        let waiting = SlowPicture(answeredOnMain: true)
        let shutFeed = PictureFeed(settings: { s }, build: { _, fell in
            FallbackSource(primary: waiting, backup: FakePicture(kind: C.pictureCard,
                                                                 answer: card),
                           onFallback: fell)
        })
        shutFeed.acquire(PictureFeed.forStream, settings: s)
        let by2 = Date().addingTimeInterval(2)
        while Date() < by2 && !waiting.inStart { Thread.sleep(forTimeInterval: 0.01) }
        let began = Date()
        let finished = shutFeed.shutDown(within: 0.3)
        let took = Date().timeIntervalSince(began)
        check("closing the app with a start waiting on the main thread returns at once",
              !finished && took < 1.0, String(format: "%.2f s", took))
        check("and what was opening is closed straight away, not when the start returns",
              waiting.closes >= 1)
        let by3 = Date().addingTimeInterval(3)
        while Date() < by3 && (shutFeed.running || shutFeed.openNow > 0) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        check("and once the start comes back, nothing is left open",
              !shutFeed.running && shutFeed.openNow == 0, "\(shutFeed.openNow) open")

        // Finding 4: a corner moved on the live split is what it was built
        // from, so a newcomer does not close and reopen the camera.
        var split = PictureSettings()
        split.picture = C.pictureSplit
        split.camera = "Test Camera"
        split.splitCorner = "bottom right"
        var splits: [FakeSplit] = []
        let cornerFeed = PictureFeed(settings: { split }, build: { made, _ in
            let one = FakeSplit(corner: made.splitCorner)
            splits.append(one)
            return one
        })
        cornerFeed.acquire(PictureFeed.forStream, settings: split)
        cornerFeed.settle()
        check("the corner moves on the live source", cornerFeed.setCorner("top left")
              && splits.first?.corner == "top left")
        split.splitCorner = "top left"
        cornerFeed.acquire(PictureFeed.forRecording, settings: split)
        cornerFeed.settle()
        check("and Command+Shift+R after it does not rebuild the camera under the air",
              cornerFeed.builds == 1, "\(cornerFeed.builds) built")
        split.colourAccent = "red"
        cornerFeed.acquire(PictureFeed.forPreview, settings: split)
        cornerFeed.settle()
        check("a picture that really is different still is rebuilt", cornerFeed.builds == 2)
        cornerFeed.close()
        cornerFeed.settle()

        var before = PictureSettings()
        before.picture = C.pictureCamera
        var after = before
        after.colourBackground = "navy"
        check("Preferences OK rebuilds a held picture whose settings changed, and says so on the air",
              { let c = MainWindow.picturePrefsChange(before: before, after: after,
                                                      held: true, live: true)
                return c.rebuild && c.say == MainWindow.picturePrefsSentence }())
        check("for a preview alone it rebuilds and says nothing",
              { let c = MainWindow.picturePrefsChange(before: before, after: after,
                                                      held: true, live: false)
                return c.rebuild && c.say == nil }())
        check("with nothing holding it there is nothing to rebuild",
              { let c = MainWindow.picturePrefsChange(before: before, after: after,
                                                      held: false, live: false)
                return !c.rebuild && c.say == nil }())
        var retitled = before
        retitled.title = "Another song"
        check("and a title is not a picture change",
              { let c = MainWindow.picturePrefsChange(before: before, after: retitled,
                                                      held: true, live: true)
                return !c.rebuild && c.say == nil }())

        // Finding 6: a look from another thread takes the settings it was
        // handed, and never asks the board.
        let asked = NSLock()
        var boardReads = 0
        var builtWith = ""
        let offMain = PictureFeed(settings: {
            asked.lock(); boardReads += 1; asked.unlock()
            return PictureSettings()
        }, build: { made, _ in
            asked.lock(); builtWith = made.name; asked.unlock()
            return FakePicture(kind: made.picture, answer: card)
        })
        var handed = PictureSettings()
        handed.picture = C.pictureCard
        handed.name = "Taken on main"
        let preview = PicturePreview(feed: offMain, settings: handed, width: 64, height: 36,
                                     overlay: Overlay())
        let looked = DispatchSemaphore(value: 0)
        var grabbed = false
        DispatchQueue.global().async {
            grabbed = preview.grab() != nil
            looked.signal()
        }
        _ = looked.wait(timeout: .now() + 6)
        offMain.settle()
        asked.lock(); let reads = boardReads, name = builtWith; asked.unlock()
        check("a preview from another thread never reads the board",
              grabbed && reads == 0 && name == "Taken on main",
              "grabbed \(grabbed), \(reads) board reads, built from \(name)")

        // Finding 6: the words on top are written and drawn from different
        // threads at once. Under the lock this is simply busy; without it, a
        // string torn in half is a crash.
        var words = OverlaySettings()
        words.places = ["lower": ["kind": C.textPlaying, "words": "", "file": ""]]
        let marks = Overlay(settings: words)
        let writers = DispatchGroup()
        DispatchQueue.global().async(group: writers) {
            for i in 0..<4000 { marks.setTitle(i % 2 == 0 ? "A song with a long name \(i)" : "") }
        }
        DispatchQueue.global().async(group: writers) {
            for i in 0..<400 { marks.apply(words); if i % 50 == 0 { _ = marks.describe() } }
        }
        var drawn = 0
        let paint = Pixels.make(width: 160, height: 90)
        for _ in 0..<300 {
            guard let paint else { break }
            CVPixelBufferLockBaseAddress(paint, [])
            if let ctx = Pixels.context(for: paint) { marks.draw(into: ctx, width: 160, height: 90) }
            CVPixelBufferUnlockBaseAddress(paint, [])
            drawn += 1
        }
        _ = writers.wait(timeout: .now() + 20)
        check("the words on top can be changed while they are being drawn", drawn == 300)

        // Finding 8: a recording's picture thread stops at once, even inside
        // its wait for the picture, and puts nothing after.
        let stuck = SlowPicture()
        let pumpFeed = PictureFeed(settings: { s }, build: { _, fell in
            FallbackSource(primary: stuck, backup: FakePicture(kind: C.pictureCard, answer: card),
                           onFallback: fell)
        })
        pumpFeed.acquire(PictureFeed.forRecording, settings: s)
        let tap = FrameTap()
        let pump = RecordPicturePump(feed: pumpFeed, tap: tap, width: 64, height: 36, fps: 30,
                                     overlay: Overlay(), framingLevel: C.framingProblems,
                                     say: { _ in })
        pump.start()
        Thread.sleep(forTimeInterval: 0.2)
        let stopBegan = Date()
        pump.stop()
        let stopTook = Date().timeIntervalSince(stopBegan)
        check("stopping a recording's picture thread never waits on it",
              stopTook < 0.05 && !pump.isRunning, String(format: "%.3f s", stopTook))
        stuck.letGo()
        pumpFeed.settle()
        Thread.sleep(forTimeInterval: 0.3)
        check("and nothing reaches the tap after it was told", tap.puts == 0, "\(tap.puts) put")
        pumpFeed.close()
        pumpFeed.settle()

        // Finding 9: a retry that lands after the source was closed opens
        // nothing.
        var clock = 0.0
        var restarts = 0
        let dead = FakePicture(kind: C.pictureCamera)
        dead.count = 5
        let closing = FallbackSource(primary: dead, backup: FakePicture(kind: C.pictureCard,
                                                                        answer: card))
        closing.now = { clock }
        closing.restart = { _ in restarts += 1 }
        _ = closing.frame(width: 64, height: 36)
        clock += C.pictureRetrySeconds + 0.1
        _ = closing.frame(width: 64, height: 36)
        let before9 = restarts
        closing.close()
        clock += C.pictureRetrySeconds + 0.1
        _ = closing.frame(width: 64, height: 36)
        check("a fallback that has been closed asks for no more retries",
              before9 == 1 && restarts == 1, "\(before9) before, \(restarts) after")
        let camera = CameraSource(device: "Test Camera")
        camera.close()
        let screen = ScreenSource()
        screen.close()
        check("and a closed camera and a closed screen know it, so a late start opens nothing",
              camera.isClosed && screen.isClosed && !camera.holdsSession && !screen.holdsCapture)
    }
}
