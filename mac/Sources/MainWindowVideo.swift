// The frame's half of the video work: what the keys and the menu actually do.
//
// The panels are in VideoPanels.swift and know nothing about the show. This is
// where they are handed the board, the speaker and a way to change what is
// going out, and where Command B learns that there are two places a show can
// go.

import AppKit
import CoreVideo

extension MainWindow {

    /// What is playing, the way a listener would be told it.
    ///
    /// The card and the lower third both want this and they must agree, so it
    /// is asked for in one place rather than assembled twice.
    var nowPlayingTitle: String {
        guard let track = player?.currentTrack else { return "" }
        let artist = (track.artist ?? "").trimmingCharacters(in: .whitespaces)
        let title = (track.title ?? "").trimmingCharacters(in: .whitespaces)
        if !artist.isEmpty && !title.isEmpty { return "\(artist) - \(title)" }
        return title.isEmpty ? track.displayName : title
    }

    // ------------------------------------------------------ the settings ---

    /// What the picture needs, out of the board.
    ///
    /// **Deliberately separate from the destination's settings.** Windows
    /// keeps three dictionaries here and the reason is a bug that shipped in
    /// 3.5.0: reading the picture out of the destination's settings gives a
    /// board pointed at the radio station no picture key at all, so the shot
    /// check confidently described a card the user never chose.
    func pictureSettings() -> PictureSettings {
        var s = PictureSettings()
        s.picture = board.picture
        s.pictureFile = board.pictureFile
        s.pictureClock = board.pictureClock
        s.camera = board.camera
        s.screen = board.screen
        s.splitCorner = board.splitCorner
        s.name = board.stream.name
        s.streamName = board.stream.name
        s.title = nowPlayingTitle
        s.colourBackground = board.colourBackground
        s.colourText = board.colourText
        s.colourAccent = board.colourAccent
        s.videoWidth = board.videoWidth
        s.videoHeight = board.videoHeight
        s.videoFPS = board.videoFPS
        return s
    }

    func overlaySettings() -> OverlaySettings {
        var s = OverlaySettings()
        s.places = board.textPlaces
        s.name = board.stream.name
        s.streamName = board.stream.name
        s.colourBackground = board.colourBackground
        s.colourText = board.colourText
        return s
    }

    func videoStreamSettings() -> VideoStreamSettings {
        var s = VideoStreamSettings()
        s.server = board.videoServer
        s.host = board.videoHost
        // The keychain's key, or the board file's when the keychain would not
        // keep it: the same two things in the same order as the Preferences
        // box, so the box always shows the key that is really in force.
        s.key = board.videoKeyInForce()
        s.width = board.videoWidth
        s.height = board.videoHeight
        s.fps = board.videoFPS
        s.videoBitrate = board.videoBitrate
        s.audioBitrate = board.stream.bitrate
        s.framingLevel = board.framingLevel
        s.overlay = overlaySettings()
        return s
    }

    /// The settings the pre-flight reads, which is what the streamer will see.
    func preflightSettings() -> PreflightSettings {
        var s = PreflightSettings()
        let video = board.liveTo == C.liveToVideo
        s.server = video ? board.videoServer : board.stream.server
        s.host = video ? board.videoHost : board.stream.host
        s.mount = video ? "" : board.stream.mount
        // The radio station's name, which the card says either way, and the
        // video channel's name, which is the only name said about a video
        // platform (W382-06). Two destinations, two names.
        s.name = board.stream.name
        s.videoName = video ? board.videoName : ""
        s.password = video ? videoStreamSettings().key : board.stream.password
        s.format = board.stream.format
        s.bitrate = board.stream.bitrate
        s.picture = board.picture
        s.pictureFile = board.pictureFile
        s.camera = board.camera
        s.streamName = board.stream.name
        s.videoWidth = board.videoWidth
        s.videoHeight = board.videoHeight
        s.videoFPS = board.videoFPS
        s.videoBitrate = board.videoBitrate
        return s
    }

    func preflightBoard() -> PreflightBoard {
        var b = PreflightBoard()
        b.liveTo = board.liveTo
        b.videoServer = board.videoServer
        b.streamMic = board.stream.sendMic
        b.streamTitles = board.stream.sendTitles
        b.textPlaces = board.textPlaces
        return b
    }

    /// Everything Command B is about to do, worked out before it does it.
    func preflight() -> Preflight {
        let report = Preflighter.check(
            settings: preflightSettings(), board: preflightBoard(),
            audioRunning: group.isRunning, micOpen: mic.isOpen,
            screenReady: Screens.available(),
            screenReason: Screens.whyUnavailable(),
            text: Preflighter.TextFitting(
                placeLabel: { Overlays.placeLabel($0) },
                fits: { Overlays.fits($0, key: $1, width: $2, height: $3) }))
        // One last go at anything that is not running, then the ones still
        // wrong go in the list with everything else. A source marked on air
        // that is not actually running is a voice missing from the whole show,
        // and this is the last moment anybody can put it right.
        //
        // Added out here rather than inside Preflighter, which is checked line
        // for line against the Windows copy and must stay identical.
        _ = sourceGroup.retryFailed(outputRate: group.sampleRate)
        let notes = sourceGroup.trouble.map {
            PreflightNote(.warn, "A source is not on the air. \($0)")
        } + sourceGroup.waitingForAProgram.map {
            PreflightNote(.warn, "A source will be silent. \($0)")
        }
        guard !notes.isEmpty else { return report }
        return Preflight(target: report.target, lines: report.lines,
                         notes: report.notes + notes)
    }

    // ---------------------------------------------------------- the keys ---

    // Nothing on the picture side is gated on where Command+B is pointed
    // (W381-06). Since 3.7.0 a recording carries a picture, and a presenter set
    // up for a radio station could not choose the picture going into their own
    // file: Option+Shift+V and Option+Shift+T refused, and Command+Shift+V
    // answered "Nothing" while a picture was being written to disk.

    /// Option+Shift+V. What the picture is, whatever Command+B is pointed at.
    func showVideoSource() {
        let panel = VideoSourcePanel(
            board: board, speaker: speaker, live: pictureLive(),
            using: { [weak self] in
                (self?.showingPicture ?? false, self?.videoRecorder.isRecording ?? false)
            },
            apply: { [weak self] kind in self?.setPicture(kind) ?? "" },
            applyCorner: { [weak self] corner in
                guard let self, self.board.picture == C.pictureSplit,
                      self.pictureFeed.held else { return }
                // MOVED ON THE LIVE SOURCE, no rebuild (W381-09). It used to
                // rebuild the whole picture and wait up to five seconds for the
                // camera on the main thread, for every arrow in the popup.
                if !self.pictureFeed.setCorner(corner) { self.pictureFeed.rebuild() }
            })
        panel.run(over: window)
    }

    /// Change the picture, for the stream and a recording at once (W381-04).
    ///
    /// Returns the sentence to say now, or "" when the answer is said once the
    /// new picture has opened: said OFF THE RESULT, because a camera that will
    /// not open comes back as the card, and "Now showing a camera" to somebody
    /// looking at a card is the class of fault this release is about.
    ///
    /// **The choice is kept either way.** The Mac used to put the board back
    /// to the old picture when the new one did not open; Windows keeps what
    /// was asked for and says a card is standing in, which is right: the
    /// camera being unplugged for a moment is not a reason to forget it was
    /// chosen, and the fallback's retry brings it back by itself.
    func setPicture(_ kind: String) -> String {
        board.picture = kind
        board.dirty = true
        let label = (C.pictureLabels[kind] ?? kind).lowercased()
        let feed = pictureFeed
        if feed.held { feed.rebuild() }
        guard pictureLive() else { return MainWindow.nextTimeSentence(label) }
        let showing = showingPicture, recording = videoRecorder.isRecording
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = feed.waitReady(timeout: C.cameraOpenTimeout)
            DispatchQueue.main.async {
                guard let self else { return }
                feed.setTitle(self.nowPlayingTitle)
                let fell = feed.fallenBack || !feed.reason.isEmpty
                    || (!feed.kind.isEmpty && feed.kind != kind)
                let said = fell
                    ? "Asked for \(label), and a card is showing instead"
                      + (feed.reason.isEmpty ? "" : ": \(feed.reason)")
                    : "\(MainWindow.pictureVerb(showing: showing, recording: recording)) \(label)"
                self.speaker.announceState(said)
                self.updateStatusLine()
            }
        }
        return ""
    }

    /// Option+Shift+T. Words on the picture, wherever the picture is going.
    func showScreenText() {
        let panel = ScreenTextPanel(
            board: board, speaker: speaker, live: pictureLive(), window: window,
            ask: { [weak self] title, message, value, fieldLabel in
                self?.ask(title: title, message: message, value: value,
                          okTitle: "OK", fieldLabel: fieldLabel)
            },
            nowPlaying: { [weak self] in self?.nowPlayingTitle ?? "" },
            apply: { [weak self] in self?.refreshPictureWords() })
        panel.run(over: window)
    }

    func showColours() {
        let panel = ColoursPanel(
            board: board, speaker: speaker, window: window,
            sample: { [weak self] in self?.brandSample() },
            apply: { [weak self] in
                guard let self else { return }
                self.refreshPictureWords()
                // Whatever is holding the picture, the stream or a recording
                // or both, gets the new colours (W381-21). It used to reach
                // the stream alone, and only while it was on.
                if self.pictureFeed.held { self.pictureFeed.rebuild() }
            })
        panel.run(over: window)
    }

    /// A real frame of the brand, with the overlay on it.
    ///
    /// Not a list of colour names: a model cannot judge what three names look
    /// like together any better than the person asking can. A card only, so
    /// it opens nothing.
    func brandSample() -> CVPixelBuffer? {
        var settings = pictureSettings()
        settings.picture = C.pictureCard
        settings.title = "What is playing right now"
        let card = Picture.build(settings)
        guard let frame = card.frame(width: board.videoWidth,
                                     height: board.videoHeight) else { return nil }
        let overlay = Overlay(settings: overlaySettings())
        overlay.setTitle(settings.title)
        return Pixels.composite(frame, overlay, width: board.videoWidth,
                                height: board.videoHeight)
    }

    /// The picture going out or being recorded, or the one that would be.
    ///
    /// **Through the one shared feed** (W381-40). Whatever already holds the
    /// picture is looked through rather than a second one opened; when nothing
    /// does, a hold is taken for the look and let go again, and it is a
    /// RELEASE rather than a close, so a stream or a recording that took hold
    /// meanwhile keeps the device. Never on the main queue: it waits for the
    /// picture.
    func previewPicture() -> CVPixelBuffer? {
        let feed = pictureFeed
        let width = board.videoWidth, height = board.videoHeight
        let overlay = Overlay(settings: overlaySettings())
        overlay.setTitle(nowPlayingTitle)
        var taken = false
        if !feed.running {
            feed.acquire(PictureFeed.forPreview)
            taken = true
            _ = feed.waitReady(timeout: C.cameraOpenTimeout)
        }
        defer { if taken { feed.release(PictureFeed.forPreview) } }
        return feed.frame(width: width, height: height).map {
            Pixels.composite($0, overlay, width: width, height: height)
        }
    }

    func showShotCheck() {
        // Made here, on the main thread, before the panel looks through it
        // from another.
        _ = pictureFeed
        // The kind decides whether consent is asked for, so it is read from
        // what the picture really is rather than passed around.
        let kind = C.pictureNeedsScreen.contains(board.picture) ? "screen" : "camera"
        let panel = ShotCheckPanel(board: board, speaker: speaker, window: window,
                                   kind: kind,
                                   where: MainWindow.shotWhere(
                                       showing: showingPicture,
                                       recording: videoRecorder.isRecording),
                                   grab: { [weak self] in self?.previewPicture() })
        panel.run(over: window)
    }

    /// What the camera can see. Answers at every talkativeness setting,
    /// including off: a switch that silences the announcements must not
    /// silence the answer to a direct question.
    ///
    /// **Through the shared feed** (W381-41), never a camera of its own. A
    /// second capture of a device the stream or a recording holds is the two
    /// owner case this whole change exists to remove.
    func sayWhatTheCameraSees() {
        guard C.pictureNeedsCamera.contains(board.picture) else {
            speaker.announceAnswer("Your picture is not set to a camera. Picture settings "
                                 + "are in Preferences, or press Option+Shift+V")
            return
        }
        if videoStreamer.isOn {
            speaker.announceAnswer(videoStreamer.framer.describe())
            return
        }
        if let pump = recordPump, pump.isRunning {
            speaker.announceAnswer(pump.framer.describe())
            return
        }
        guard !board.camera.isEmpty else {
            speaker.announceAnswer("No camera has been chosen. Option Shift V picks one.")
            return
        }
        speaker.announce("Looking through the camera.")
        let feed = pictureFeed
        let level = board.framingLevel
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let held = feed.held
            if !held { feed.acquire(PictureFeed.forPreview) }
            defer { if !held { feed.release(PictureFeed.forPreview) } }
            _ = feed.waitReady(timeout: C.cameraOpenTimeout)
            guard let frame = feed.latest() else {
                let why = feed.reason.isEmpty ? "The camera did not answer" : feed.reason
                DispatchQueue.main.async { self?.speaker.announceAnswer(why) }
                return
            }
            let framer = Framer(level: level)
            let reading = framer.measure(frame)
            DispatchQueue.main.async { self?.speaker.announceAnswer(reading.sentence()) }
        }
    }

    /// The picture, and everything on top of it, in words.
    ///
    /// **Nothing else in broadcasting does this.** A preview window is a
    /// graphics surface with no accessibility information at all, on any
    /// platform, so there is nothing anywhere that will tell the person making
    /// a stream what is currently in it.
    func sayWhatIsOnScreen() {
        var parts: [String] = []
        parts.append(MainWindow.screenHead(
            live: pictureLive(), showing: showingPicture,
            recording: videoRecorder.isRecording, described: pictureFeed.describe(),
            chosen: chosenPictureLabel))
        let overlay = Overlay(settings: overlaySettings())
        overlay.setTitle(nowPlayingTitle)
        parts.append("On top of it: \(overlay.describe())")
        parts.append(Colours.describePair(front: board.colourText,
                                          back: board.colourBackground))
        speaker.announceAnswer(parts.joined(separator: ". "))
    }

    func showPermissions() {
        PermissionsPanel(speaker: speaker).run(over: window)
    }

    func showStreamHelp() {
        StreamHelpPanel(speaker: speaker).run(over: window)
    }

    /// On air, Streaming location: which destination the dot is beside and
    /// Command Shift B describes while off air. Since the key split the keys
    /// themselves choose where the show goes, and each one moves this too.
    func setLiveTo(_ which: String) {
        guard C.liveTo.contains(which) else { return }
        if streamer.isOn || videoStreamer.isOn {
            speaker.announce(OnAir.comeOffFirst(videoOn: videoStreamer.isOn,
                                                radioOn: streamer.isOn))
            return
        }
        board.liveTo = which
        board.dirty = true
        // The pre-flight summary, so the answer is where it is going rather
        // than which of two words was picked.
        let report = preflight()
        speaker.announceState(OnAir.locationMoved(
            to: which, summary: report.summary(),
            stops: report.blocked ? report.stops.map { $0.text } : []))
        updateAirMenu()
    }
}
