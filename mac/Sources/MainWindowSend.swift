// Giving another program on this machine the whole show.
//
// Option+Shift+O sets a send up and turns it on, Command+Shift+H puts it in the
// presenter's own headphones, Command+Shift+O says whether it is arriving, and
// Command+Shift+W reads out where every single thing is going.
//
// The reports live here rather than in `Send.swift` because most of what is
// worth saying is the window's and not the send's: which source is being left
// out, whether the name on the board still matches one, whether the microphone
// is switched off on the streaming page, and whether any output is late.

import AppKit

extension MainWindow {

    // ------------------------------------------------------------ the wire ---

    /// Is the show going out of a sound card to another program.
    var sending: Bool { send?.isRunning == true }

    /// Why Test the cable must not put a tone out now, or nil. Over the real
    /// streamers, recorders and send.
    var cableTestRefusal: String? {
        MainWindow.cableTestRefusal(streamer: streamer, videoStreamer: videoStreamer,
                                    recorder: recorder, videoRecorder: videoRecorder,
                                    sending: sending)
    }

    /// Windows asks on air or recording. **Sending is a third** (audit 2,
    /// finding 3): a call taking Drop Deck Audio with nothing on air heard two
    /// seconds of a 1 kHz tone at minus ten.
    static func cableTestRefusal(streamer: Streamer, videoStreamer: VideoStreamer,
                                 recorder: Recorder, videoRecorder: VideoRecorder,
                                 sending: Bool) -> String? {
        if streamer.isOn || videoStreamer.isOn || recorder.isRecording
            || videoRecorder.isRecording { return CableTest.notWhileLive }
        if sending { return CableTest.notWhileSending }
        return nil
    }

    /// Point the mixers at the send, or at nothing.
    ///
    /// Every start and stop goes through here rather than setting the tap
    /// itself. Setting a tap in two places is how the air tap got lost on a
    /// device change on Windows, and that was one caller, not two.
    func syncSend() {
        let live = sending
        group.sendTap = live ? send?.bus : nil
        // A blank name means everything goes out, and `sendReport` says so.
        let minus = board.sendMinus.trimmingCharacters(in: .whitespaces)
        group.sendMinus = (live && !minus.isEmpty) ? minus : nil
    }

    /// Open the send. True if audio is really going out of it.
    @discardableResult
    func startSend(quiet: Bool = false) -> Bool {
        stopSend(quiet: true)
        // A card named on the board that is not here any more is a refusal and
        // never a silent fall back to the speakers. On Windows, with no virtual
        // cable on the machine, the send used to pick a loudspeaker and call
        // that success.
        //
        // **A failure never touches `board.sendOn`** (W380-06). That is what
        // the user ASKED for, and it is saved with the board: switching it off
        // here meant one launch without the cable wrote "no send" to disk, and
        // the send never came back when the cable did. `sendFailed` says why
        // instead, in Windows' words, and the startup line reads it.
        if let uid = board.sendDeviceUID, AudioDevices.deviceID(forUID: uid) == nil {
            sendFailed = MainWindow.sendMissingLine(board.sendDeviceName)
            if !quiet { speaker.announce(sendFailed) }
            return false
        }
        let opened = Send(deviceUID: board.sendDeviceUID, gainDB: board.sendGainDB)
        guard opened.isRunning else {
            opened.close()
            sendFailed = "The send could not be opened. "
                + (opened.lastError ?? "No reason was given.")
            if !quiet { speaker.announce(sendFailed) }
            return false
        }
        sendFailed = ""
        send = opened
        board.sendOn = true
        // The confidence feed is an EXTRA on the source group, which is what
        // makes it impossible for it to loop: the group sums extras into what
        // the presenter hears and leaves them out of what goes out.
        if !sourceGroup.extras.contains(where: { $0 === opened.confidence }) {
            sourceGroup.extras.append(opened.confidence)
        }
        if board.sendMonitor { opened.confidence.start() }
        syncSend()
        updateStatusLine()
        return true
    }

    /// The card the send goes out of is not plugged in. Windows' sentence;
    /// "by itself" is made true here by `retrySend`, which Windows has not got.
    static func sendMissingLine(_ name: String?) -> String {
        "\(name ?? "That sound card") is not here at the moment, so the show is not "
            + "going to another program. It will start again by itself when the card "
            + "is back."
    }

    /// The card a wanted send goes out of has come back: start the send again,
    /// and say so. Asked on the slow retry tick, and only while a send the
    /// board wants is not running because its card was missing.
    func retrySend() {
        guard MainWindow.sendShouldRetry(wanted: board.sendOn, running: sending,
                                         failed: sendFailed,
                                         cardPresent: board.sendDeviceUID.map {
                                             AudioDevices.deviceID(forUID: $0) != nil } ?? true)
        else { return }
        if startSend(quiet: true) {
            speaker.announce("\(board.sendDeviceName ?? "The sound card") is back, so the "
                + "show is going to another program again.", interrupt: false)
        }
    }

    /// Whether to try a wanted send again: only when it is wanted, is not
    /// running, failed for want of its card, and the card is here now. A send
    /// that failed for any other reason is not retried every three seconds.
    static func sendShouldRetry(wanted: Bool, running: Bool, failed: String,
                                cardPresent: Bool) -> Bool {
        wanted && !running && !failed.isEmpty
            && failed.hasSuffix("It will start again by itself when the card is back.")
            && cardPresent
    }

    func stopSend(quiet: Bool = false) {
        guard let going = send else { syncSend(); return }
        send = nil
        sourceGroup.extras.removeAll { $0 === going.confidence }
        going.close()
        syncSend()
        if !quiet { speaker.announceState("The send has stopped.") }
        updateStatusLine()
    }

    // --------------------------------------------------------------- keys ---

    /// Option+Shift+O. Where the show goes, and what it leaves out.
    ///
    /// **One deliberate difference from Windows.** There the key opens the
    /// dialog whether or not a send is running, while the menu item reads "Stop
    /// sending this show", so the one thing the menu says it does is the one
    /// thing it does not do. A menu item that says Stop stops here, and the
    /// panel is one press away again afterwards.
    func toggleSend() {
        if sending {
            board.sendOn = false
            sendFailed = ""
            touch()
            stopSend()
            return
        }
        showSendSetup()
    }

    func showSendSetup() {
        let panel = SendPanel(board: board, sources: sourceGroup.all.map(\.config),
                              speaker: speaker,
                              refusal: { [weak self] in self?.cableTestRefusal })
        guard panel.run(over: window) else { return }
        panel.apply(to: board)
        touch()
        guard board.sendOn else { stopSend(); return }
        guard startSend() else { return }
        let trouble = routingConflicts()
        speaker.announce(trouble.isEmpty ? sendReport() : trouble.joined(separator: " "))
    }

    /// Command+Shift+H. Hear what the other program is being handed.
    func toggleSendMonitor() {
        guard let send else {
            speaker.announce("Nothing is being sent. Option+Shift+O sets a send up.")
            return
        }
        if send.confidence.on {
            send.confidence.stop()
            board.sendMonitor = false
            speaker.announceState("You are no longer hearing the send.")
        } else {
            send.confidence.start()
            board.sendMonitor = true
            let where_ = group.monitor != nil
                ? "your monitor output"
                : "your main output, because you have no separate monitor output set"
            speaker.announceState("You are hearing the send, through \(where_). It "
                + "arrives about a quarter of a second late, so it is for checking "
                + "rather than for talking over.")
        }
        updateAirMenu()
        updateStatusLine()
    }

    /// Command+Shift+O. Is the send arriving clean.
    ///
    /// On `announceAnswer`, not `announce`. This key has no other effect
    /// whatsoever, so at speech level "none" on the ordinary channel it would
    /// be a dead key. Same rule as Command+L.
    func saySendStatus() { speaker.announceAnswer(sendReport()) }

    /// Command+Shift+W. Where every single thing is going, in one go.
    ///
    /// The one command somebody who cannot see a routing page actually needs.
    /// Everything in it is derived from the board and the mixers at the moment
    /// it is asked, so it can never drift from what is really happening.
    func sayRouting() { speaker.announceAnswer(routingReport()) }

    // ------------------------------------------------- the cable of our own ---

    /// Install, update or remove Drop Deck Audio, and say what happened.
    ///
    /// One window that answers the whole question rather than a switch: where
    /// things stand, what installing will do to the machine, and a way out
    /// again. The account of the Core Audio restart is the important part, and
    /// it is given BEFORE the password box rather than after.
    func showVirtualDevice() {
        let alert = NSAlert()
        alert.messageText = VirtualDevice.name
        alert.informativeText = VirtualDevice.describe() + "\n\n" + VirtualDevice.warning
        let installing = !VirtualDevice.isPresent || VirtualDevice.needsUpdating
        if installing {
            alert.addButton(withTitle: "Install it and restart Core Audio")
            alert.addButton(withTitle: "Install it, and restart later")
        } else {
            alert.addButton(withTitle: "Remove it and restart Core Audio")
            alert.addButton(withTitle: "Leave it alone")
        }
        alert.addButton(withTitle: "Cancel")
        let answer = alert.runModal()
        guard answer != .alertThirdButtonReturn else { return }
        if !installing && answer == .alertSecondButtonReturn { return }

        let restart = (answer == .alertFirstButtonReturn)
        let outcome = installing
            ? VirtualDevice.install(restartAudio: restart)
            : VirtualDevice.uninstall(restartAudio: restart)
        switch outcome {
        case .cancelled:
            speaker.announce("Nothing was changed.")
        case .failed(let why):
            speaker.announce("\(VirtualDevice.name) could not be changed. \(why)")
        case .done where !installing:
            speaker.announceState("\(VirtualDevice.name) has been removed."
                + (restart ? "" : " It will go from the list when you next log in."))
        case .done:
            guard restart else {
                speaker.announceState("\(VirtualDevice.name) is in place. It will "
                    + "appear in the device lists when you next log in.")
                return
            }
            // Core Audio has just been restarted, so every card this app had
            // open went with it. Poll for the device rather than sleeping,
            // then put the outputs back before anything asks for a sound.
            let appeared = VirtualDevice.waitToAppear()
            group.stopAll(fadeOut: 0.0)
            group.rebuild(mainDeviceUID: board.deviceUID,
                          bankDevices: board.bankDevices,
                          monitorDeviceUID: board.micOutputUID)
            group.apply(board)
            group.start()
            group.primary.airSource = sourceGroup
            group.monitorMixer.monitorSource = sourceMonitor
            if sending { startSend(quiet: true) }
            speaker.announceState(appeared
                ? "\(VirtualDevice.name) is installed and ready. Option+Shift+O "
                    + "points the send at it, and the other program takes "
                    + "\(VirtualDevice.name) as its microphone."
                : "\(VirtualDevice.name) is in place, and Core Audio has not "
                    + "listed it yet. Log out and back in, and it will be there.")
        }
        updateAirMenu()
        updateStatusLine()
    }

    // ------------------------------------------------------------ reports ---

    /// The bank routing as device UIDs, which is what `Routing` wants.
    private func liveBankDevices() -> [Int: String?] {
        var out: [Int: String?] = [:]
        for bank in 1...C.bankCount { out[bank] = group.bankMixer[bank]?.deviceUID }
        return out
    }

    private func describeDevice(_ uid: String?) -> String {
        guard let uid else { return "the system default output" }
        return AudioDevices.name(forUID: uid) ?? uid
    }

    /// Anything wrong with where things are pointed. Sentences, or none.
    func routingConflicts() -> [String] {
        Routing.conflicts(
            bankDevices: liveBankDevices(),
            monitorDevice: group.monitor?.deviceUID ?? group.primary?.deviceUID,
            programDevice: send?.deviceUID ?? board.sendDeviceUID,
            programOn: board.sendOn,
            describe: describeDevice)
    }

    /// Main output, banks, monitor, programme output, and anything wrong.
    func routingReport() -> String {
        var parts = [Routing.describeRouting(
            bankDevices: liveBankDevices(),
            monitorDevice: group.monitor?.deviceUID ?? group.primary?.deviceUID,
            programDevice: send?.deviceUID,
            programOn: sending,
            monitorEverything: group.monitorEverything,
            describe: describeDevice,
            bankNames: board.bankNames)]
        if sending { parts.append(sendReport()) }
        let (ok, why) = group.keepingUp()
        if !ok { parts.append("One of your outputs is not keeping up: \(why).") }
        parts.append(contentsOf: routingConflicts())
        // And the picture, and what is using it (W381-11). Nowhere else
        // answered "what picture have I got, and what does it apply to".
        parts.append(pictureReport())
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The whole answer to "how is the send doing", as one spoken line.
    func sendReport() -> String {
        guard let send else {
            return "Nothing is being sent. Option+Shift+O sets up a send to "
                + "another program on this machine."
        }
        var parts = [send.report()]
        // The one sentence everybody setting up a call needs and nobody is
        // told (W380-03). On a Mac a cable is one device with one name, so the
        // far end is the same name, and a card with no input side has no far
        // end to name at all.
        if let uid = send.deviceUID, let id = AudioDevices.deviceID(forUID: uid),
           let info = AudioDevices.info(for: id),
           let line = MainWindow.farEndLine(name: info.name, inputChannels: info.inputChannels) {
            parts.append(line)
        }
        if !board.stream.sendMic {
            // The same rule as the mix minus sentence below: something that is
            // NOT in the send must never be described as though it were.
            parts.append("Your microphone is switched off on the Streaming page, "
                + "so your voice is not in it.")
        }
        let wanted = board.sendMinus.trimmingCharacters(in: .whitespaces)
        if wanted.isEmpty {
            parts.append("Everything is in it.")
        } else if !sendMinusExists(wanted) {
            // **A mix minus that is not happening must never look like one that
            // is.** This is the sentence that stops a call full of echo being a
            // mystery when a source was renamed on a Tuesday.
            parts.append("It is set to leave out \(wanted), and there is nothing "
                + "by that name any more, so everything is going out.")
        } else {
            parts.append("It leaves out \(wanted).")
        }
        let (ok, why) = group.keepingUp()
        if !ok { parts.append("Your output is not keeping up: \(why).") }
        return parts.joined(separator: " ")
    }

    /// Windows' `SendDialog._describe` sentence, for a device that is its
    /// own far end. nil for one with no input side.
    static func farEndLine(name: String, inputChannels: Int) -> String? {
        inputChannels >= 1 ? "In the other program, choose \(name) as its input device." : nil
    }

    /// Is there really something by that name to leave out.
    private func sendMinusExists(_ wanted: String) -> Bool {
        let want = wanted.lowercased()
        if sourceGroup.all.contains(where: {
            $0.config.name.trimmingCharacters(in: .whitespaces).lowercased() == want
        }) { return true }
        return want == SourceGroup.micLabel.lowercased()
    }
}
