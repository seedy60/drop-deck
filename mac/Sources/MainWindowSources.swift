// Program sources that close and come back, and the retry that finds them.
//
// Windows 3.8.3 (Tony, 19 September 2026): Chrome opened again was a new
// process and nothing went looking for it. On a Mac the program is known by its
// bundle id, so NSWorkspace says when it quits and when it launches, and this
// is where the window hears it (W383-27):
//
//   * a program closing is SAID, once, "closed, so it is silent until it opens
//     again", because a source that goes quiet mid show looks exactly like one
//     that is working;
//   * below macOS 26 its capture is stopped, so the retry can pick up the new
//     process. It used to stay "running" on the dead one for good;
//   * a program opening again is given a few seconds to settle, captured if it
//     needs to be, and said to be back.
//
// **Nothing here holds the window's thread.** Opening a capture is a round trip
// to coreaudiod, so every start and stop is on `sourceWork`, and only what is
// said comes back to the main queue.

import AppKit

extension MainWindow {

    /// The on air mix is wanted by anybody: a stream, a recording or a send.
    /// Windows' `going_anywhere`.
    var goingAnywhere: Bool {
        streamer.isOn || videoStreamer.isOn || recorder.isRecording
            || videoRecorder.isRecording || sending
    }

    /// The slow tick: sources that were not ready get another go, off the
    /// main thread, and what came on is said in words that are true of it.
    func retrySources() {
        guard !sourcesRetrying else { return }
        sourcesRetrying = true
        let rate = group.sampleRate
        let skip = programWatch.settling
        let sources = sourceGroup
        sourceWork.async { [weak self] in
            let cameOn = sources.retryFailed(outputRate: rate, skip: skip)
            DispatchQueue.main.async {
                guard let self else { return }
                self.sourcesRetrying = false
                guard !cameOn.isEmpty else { return }
                self.programWatch.sayCameOn(cameOn)
                self.updateStatusLine()
            }
        }
    }

    /// Listen for programs quitting and launching. Once, from init.
    func watchPrograms() {
        let centre = NSWorkspace.shared.notificationCenter
        programObservers.append(centre.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
            queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                      let bundle = app.bundleIdentifier else { return }
                self?.programQuit(bundle: bundle, name: app.localizedName)
            })
        programObservers.append(centre.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil,
            queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                      let bundle = app.bundleIdentifier else { return }
                self?.programLaunched(bundle: bundle, name: app.localizedName)
            })
    }

    /// The watcher that decides what a program quitting or launching means,
    /// wired to this window's sources, queue and voice. Made once.
    func makeProgramWatch() -> ProgramWatch {
        ProgramWatch(sources: sourceGroup, work: sourceWork, speaker: speaker,
                     outputRate: { [weak self] in
                         self?.group.sampleRate ?? C.defaultSampleRate },
                     goingAnywhere: { [weak self] in self?.goingAnywhere ?? false },
                     changed: { [weak self] in self?.updateStatusLine() })
    }

    /// A captured program has quit.
    func programQuit(bundle: String, name: String?) {
        programWatch.quit(bundle: bundle, name: name)
    }

    /// A program some source captures has launched.
    func programLaunched(bundle: String, name: String?) {
        programWatch.launched(bundle: bundle, name: name)
    }
}

/// What a captured program quitting or launching means, apart from the window
/// so the checks can drive it with stand in sources (audit 2, findings 5 and 7).
///
/// Every start and stop is on `work`. What is said comes back on the main
/// queue.
final class ProgramWatch {
    let sources: SourceGroup
    let work: DispatchQueue
    let outputRate: () -> Double
    /// Programs just opened again, given `settleSeconds` before they are
    /// captured, so the retry leaves them alone meanwhile.
    private(set) var settling = Set<String>()
    var settleSeconds = C.sourceSettleSeconds
    /// Whether any copy of a program is still running. **One copy quitting is
    /// not the program closing** (audit 2, finding 7): a second copy opened
    /// with open -n quitting said "closed" and, below macOS 26, stopped the
    /// capture of the copy still playing.
    var stillRunning: (String) -> Bool = { bundle in
        // The one that quit can still be listed for a moment, marked ended.
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            .contains { !$0.isTerminated }
    }
    /// Below macOS 26 a dead capture is stopped so the retry can find the new
    /// process; from 26 the tap follows the program.
    var stopWhenQuits: Bool = {
        if #available(macOS 26.0, *) { return ProgramWords.stopWhenProgramQuits(macOS26: true) }
        return ProgramWords.stopWhenProgramQuits(macOS26: false)
    }()
    let speaker: Speaker
    let goingAnywhere: () -> Bool
    let changed: () -> Void

    init(sources: SourceGroup, work: DispatchQueue, speaker: Speaker,
         outputRate: @escaping () -> Double, goingAnywhere: @escaping () -> Bool,
         changed: @escaping () -> Void) {
        self.sources = sources
        self.work = work
        self.speaker = speaker
        self.outputRate = outputRate
        self.goingAnywhere = goingAnywhere
        self.changed = changed
    }

    // Every line here is one nobody asked for, so every one is QUEUED behind
    // whatever VoiceOver is reading (W383-15), never interrupting it.

    /// A program closing: on the essential channel when that source was going
    /// out live, otherwise a hint.
    private func sayClosed(_ line: String, onAir: Bool) {
        if onAir && goingAnywhere() {
            speaker.announce(line, interrupt: false)
        } else {
            speaker.announceHelp(line, interrupt: false)
        }
    }

    private func sayBack(_ line: String) {
        speaker.announceHelp(line, interrupt: false)
    }

    /// Sources the slow retry brought on, said in words true of them.
    func sayCameOn(_ cameOn: [RunningSource]) {
        let lines = ProgramWords.cameOn(
            onAir: cameOn.filter { $0.config.onAir }.map(\.config.name),
            monitored: cameOn.filter { !$0.config.onAir }.map(\.config.name))
        for line in lines { speaker.announceHelp(line, interrupt: false) }
    }

    /// The program's name as a person knows it.
    static func name(_ bundle: String, _ name: String?) -> String {
        let named = (name ?? "").trimmingCharacters(in: .whitespaces)
        return named.isEmpty ? (bundle.components(separatedBy: ".").last ?? bundle) : named
    }

    /// A captured program has quit. Main thread.
    func quit(bundle: String, name: String?) {
        let affected = sources.sources(forBundle: bundle).filter(\.isRunning)
        guard !affected.isEmpty else { return }
        guard !stillRunning(bundle) else { return }
        settling.remove(bundle)
        let program = ProgramWatch.name(bundle, name)
        if stopWhenQuits {
            work.async { for source in affected { source.stop() } }
        }
        // Said first, so nothing below can cost the sentence.
        for source in affected {
            sayClosed(ProgramWords.closed(program: program, sourceName: source.config.name),
                      onAir: source.config.onAir)
        }
        changed()
    }

    /// A program some source captures has launched. Give it time to settle,
    /// capture it if it needs capturing, and say it is back. Main thread.
    func launched(bundle: String, name: String?) {
        let affected = sources.sources(forBundle: bundle)
        guard !affected.isEmpty else { return }
        settling.insert(bundle)
        let program = ProgramWatch.name(bundle, name)
        // Which were stopped when it quit. One of those running by the time
        // the settle ends was started by a retry queued before this, which
        // has already said it is on the air, so it is not said twice.
        let stoppedNow = Set(affected.filter { !$0.isRunning }.map { ObjectIdentifier($0) })
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds) { [weak self] in
            guard let self, self.settling.contains(bundle) else { return }
            let wanted = self.sources.sources(forBundle: bundle)
            let rate = self.outputRate()
            let group = self.sources
            self.work.async {
                var back: [RunningSource] = []
                for source in wanted {
                    let wasStopped = stoppedNow.contains(ObjectIdentifier(source))
                    if source.isRunning {
                        // Kept running through the quit (macOS 26): back.
                        // Started by a retry meanwhile: already said.
                        if !wasStopped { back.append(source) }
                        continue
                    }
                    guard source.start(outputRate: rate) else { continue }
                    // **Removed while it settled** (audit 2, finding 5): a
                    // Remove, a Sources OK or a File, Open during the four
                    // seconds. It is stopped again, and never said to be back.
                    guard group.all.contains(where: { $0 === source }) else {
                        source.retire()
                        continue
                    }
                    (source as? BaseSource)?.syncDelay()
                    back.append(source)
                }
                DispatchQueue.main.async {
                    self.settling.remove(bundle)
                    for source in back where group.all.contains(where: { $0 === source }) {
                        self.sayBack(ProgramWords.back(program: program,
                                                       sourceName: source.config.name))
                    }
                    self.changed()
                }
            }
        }
    }
}
