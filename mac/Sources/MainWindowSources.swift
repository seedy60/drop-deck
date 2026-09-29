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
        let skip = programsSettling
        let sources = sourceGroup
        sourceWork.async { [weak self] in
            let cameOn = sources.retryFailed(outputRate: rate, skip: skip)
            DispatchQueue.main.async {
                guard let self else { return }
                self.sourcesRetrying = false
                guard !cameOn.isEmpty else { return }
                let lines = ProgramWords.cameOn(
                    onAir: cameOn.filter { $0.config.onAir }.map(\.config.name),
                    monitored: cameOn.filter { !$0.config.onAir }.map(\.config.name))
                // A timer's line, so it waits for whatever is being read.
                for line in lines { self.speaker.announceHelp(line, interrupt: false) }
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

    /// The program's name as a person knows it.
    private func programName(_ bundle: String, _ name: String?) -> String {
        let named = (name ?? "").trimmingCharacters(in: .whitespaces)
        return named.isEmpty ? (bundle.components(separatedBy: ".").last ?? bundle) : named
    }

    /// A captured program has quit.
    func programQuit(bundle: String, name: String?) {
        let affected = sourceGroup.sources(forBundle: bundle).filter(\.isRunning)
        guard !affected.isEmpty else { return }
        programsSettling.remove(bundle)
        let program = programName(bundle, name)
        var stop: Bool = true
        if #available(macOS 26.0, *) { stop = ProgramWords.stopWhenProgramQuits(macOS26: true) }
        else { stop = ProgramWords.stopWhenProgramQuits(macOS26: false) }
        if stop {
            sourceWork.async { for source in affected { source.stop() } }
        }
        // Said first, so nothing below can cost the sentence. Queued rather
        // than interrupting, because a program closing is nobody's keypress;
        // on the essential channel when that source was going out live.
        for source in affected {
            let line = ProgramWords.closed(program: program, sourceName: source.config.name)
            if source.config.onAir && goingAnywhere {
                speaker.announce(line, interrupt: false)
            } else {
                speaker.announceHelp(line, interrupt: false)
            }
        }
        updateStatusLine()
    }

    /// A program some source captures has launched. Give it time to settle,
    /// capture it if it needs capturing, and say it is back.
    func programLaunched(bundle: String, name: String?) {
        guard !sourceGroup.sources(forBundle: bundle).isEmpty else { return }
        programsSettling.insert(bundle)
        let program = programName(bundle, name)
        DispatchQueue.main.asyncAfter(deadline: .now() + C.sourceSettleSeconds) {
            [weak self] in
            guard let self, self.programsSettling.contains(bundle) else { return }
            let wanted = self.sourceGroup.sources(forBundle: bundle)
            let rate = self.group.sampleRate
            self.sourceWork.async {
                var back: [RunningSource] = []
                for source in wanted {
                    if source.isRunning || source.start(outputRate: rate) {
                        (source as? BaseSource)?.syncDelay()
                        back.append(source)
                    }
                }
                DispatchQueue.main.async {
                    self.programsSettling.remove(bundle)
                    for source in back {
                        self.speaker.announceHelp(
                            ProgramWords.back(program: program,
                                              sourceName: source.config.name),
                            interrupt: false)
                    }
                    self.updateStatusLine()
                }
            }
        }
    }
}
