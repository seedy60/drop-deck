// Two destinations, two keys (Windows 3.8.2, W382-07 to W382-13).
//
// Command B goes live on the VIDEO platform and Option Shift B on the RADIO
// station, each a toggle for its own destination. Tony asked for it on
// 12 September 2026, and the reason is what the summary used to say: one key
// plus a remembered setting meant the page in front of you before going live
// was for whichever destination you last chose, not the one you meant.
//
// Every decision the keys and the On air menu make is a pure function here,
// so the self test can hold each one to its sentence with nothing running.
//
// **Option Shift B, not Option Command B.** The Windows key is Alt+Shift+B and
// Option is what Alt is called here, so it carries across unchanged, in the
// Option Shift family the app already uses for the things you go and do.
// Control plus Option is VoiceOver's own modifier and the frozen digit map
// owns Option Command.

import Foundation

enum OnAir {

    /// The key for one destination, the way a spoken sentence says it.
    static func key(_ liveTo: String) -> String {
        liveTo == C.liveToVideo ? "Command B" : "Option Shift B"
    }

    /// "your video platform" or "your radio station", for a sentence.
    static func words(_ liveTo: String) -> String {
        liveTo == C.liveToVideo ? "your video platform" : "your radio station"
    }

    /// Which command goes live on a destination.
    static func command(_ liveTo: String) -> Command {
        liveTo == C.liveToVideo ? .streamToggle : .streamToggleRadio
    }

    /// Which destination a command goes live on, or nil for any other command.
    static func destination(_ command: Command) -> String? {
        switch command {
        case .streamToggle: return C.liveToVideo
        case .streamToggleRadio: return C.liveToAudio
        default: return nil
        }
    }

    /// What one press of a go live key does.
    enum Press: Equatable {
        /// This key's own destination is on air: come off it.
        case comeOff
        /// The OTHER destination is on air. Say this and do nothing else.
        case elsewhere(String)
        /// Off air: go live here. `pointAt` is true when Streaming location
        /// has to move first, which happens BEFORE the pre-flight reads it.
        case goLive(pointAt: Bool)
    }

    /// **Each key is a toggle for ITS OWN destination.** Pressing the key for
    /// the place you are not broadcasting to names where you actually are and
    /// does nothing else. Switching would mean dropping one connection and
    /// opening another, which is not something to do to somebody mid show on
    /// a keypress that looks like a toggle.
    static func press(_ to: String, liveTo: String, videoOn: Bool, radioOn: Bool) -> Press {
        let video = to == C.liveToVideo
        if video ? videoOn : radioOn { return .comeOff }
        if video ? radioOn : videoOn {
            return .elsewhere(wrongKey(liveOn: video ? C.liveToAudio : C.liveToVideo))
        }
        return .goLive(pointAt: to != liveTo)
    }

    /// Windows' sentence, keys translated.
    static func wrongKey(liveOn: String) -> String {
        "You are on air to \(words(liveOn)). \(key(liveOn)) comes off air."
    }

    /// Which destination is on air right now, or nil.
    static func liveOn(videoOn: Bool, radioOn: Bool) -> String? {
        if videoOn { return C.liveToVideo }
        if radioOn { return C.liveToAudio }
        return nil
    }

    /// The two On air menu items. Each says "Come off air" only while ITS OWN
    /// streamer is on, so the menu never offers to take you off air from a
    /// place you are not. Read from the streamers rather than from Streaming
    /// location, because the streamers are the truth (N1: the menu used to
    /// read the radio streamer alone and said Go live all through a YouTube
    /// broadcast).
    static func menuTitles(videoOn: Bool, radioOn: Bool) -> (video: String, radio: String) {
        (videoOn ? "Come off air" : "Go live on video",
         radioOn ? "Come off air" : "Go live on radio")
    }

    /// Changing where the show goes while it is going somewhere. Names the key
    /// that comes off air from where it really is (W382-11).
    static func comeOffFirst(videoOn: Bool, radioOn: Bool) -> String {
        let live = liveOn(videoOn: videoOn, radioOn: radioOn) ?? C.liveToVideo
        return "Come off air first, \(key(live)), then change where it goes"
    }

    /// Said when Streaming location is moved by hand.
    ///
    /// **Not Windows' "Ctrl+B now goes to", which the key split made false**:
    /// Command B always goes to the video platform now, whatever this is set
    /// to. What moved is which of the two Command Shift B describes off air
    /// and which one the dot is beside, so the sentence says where that is and
    /// which key goes live there.
    static func locationMoved(to liveTo: String, summary: String, stops: [String]) -> String {
        let name = C.liveToLabels[liveTo] ?? liveTo
        var said = "Streaming location is now \(name), \(summary). "
                 + "\(key(liveTo)) goes live there"
        if !stops.isEmpty { said += ". " + stops.joined(separator: ". ") }
        return said
    }

    /// Said when a saved setup is loaded, which carries its own destination.
    static func setupLoaded(label: String, liveTo: String, summary: String,
                            otherKind: Bool) -> String {
        var said = "\(label). \(key(liveTo)) goes to \(summary)"
        if otherKind {
            said += ", which is a different kind of destination from the last one"
        }
        return said
    }

    /// Command Shift B while off air. The key named is the one that would
    /// really go there: "Command B would go to" a radio station was a sentence
    /// the key split made false.
    static func offAirStatus(liveTo: String, summary: String) -> String {
        "Off air. \(key(liveTo)) would go to \(summary)"
    }

    /// Whether the show is on the air at all, for the feedback report (N2:
    /// it said false all through a video broadcast).
    static func streaming(audio: Bool, video: Bool) -> Bool { audio || video }
}

/// Work in flight behind a button that must never be disabled (W384-32).
///
/// **Disabling a focused button does not strand focus, it MOVES it, silently.**
/// Windows measured it with a real Space press: the focus went to the next
/// control, which then became the dialog's default, so Space then Return did
/// something else entirely. A flag and a spoken line refuse a second press
/// without touching focus at all. A class, so the button's closure and the
/// answer's closure share one.
final class WorkFlag {
    private(set) var running = false

    /// True when the work may start, and marks it running. False when it is
    /// already running, and the caller says so instead.
    func begin() -> Bool {
        if running { return false }
        running = true
        return true
    }

    func end() { running = false }
}
