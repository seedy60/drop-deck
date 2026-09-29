// Whether a broadcast is really a broadcast: the decisions both streamers
// make about a failure and about silence, kept apart from either streamer so
// they can be asserted with nothing running.
//
// Windows 3.8.4, W384-15 to 17. Joshua, 20 September 2026: Command B said it
// was going live to YouTube and nothing appeared. Two of the ways that
// sentence could be false were a refusal retried for ever, with the reason
// spoken once, and a stream that carried no sound announcing ON AIR anyway.

import Foundation

/// What went wrong on one attempt to be on air, sorted by what can be done
/// about it rather than by how it was worded.
///
/// Windows decides this by looking for words in the error message
/// (`streamout.REFUSED` and `ONLY_AT_FIRST`). The Mac decides it from the kind
/// of failure, which the sentence cannot drift away from.
enum StreamFault: Equatable {
    /// The far end said no: a password, a mount point, a stream key, an
    /// address that is not an RTMP one. Saying it again will not help.
    case refused(String)
    /// A name that will not resolve. A typo at Command B; the network on the
    /// way back from a dropped connection.
    case notFound(String)
    /// Nothing ever reached the stream, so there is nothing for another
    /// connection to carry.
    case noSound
    /// Anything else: a drop, a timeout, the audio that stopped arriving.
    case dropped(String)

    var said: String {
        switch self {
        case .refused(let why), .notFound(let why), .dropped(let why): return why
        case .noSound: return SilenceWatch.neverArrived
        }
    }
}

/// Whether a failure is worth another attempt (W384-15).
///
/// **Asked on EVERY attempt, not only the first.** On Windows the guard was
/// consulted once, so a key the platform refused on the way back from a
/// dropped connection was retried for ever. On the Mac it was never consulted
/// at all: the video streamer retried a refused key and a malformed address
/// for ever from the very first attempt, and the radio streamer set FAILED for
/// a wrong password and then overwrote it with RETRYING on the next line (M5).
enum Retry {
    /// Windows' `streamout.REFUSED`, word for word: a sentence containing any
    /// of these is the far end saying no, on ANY attempt.
    ///
    /// **Asked only of a refusal the Mac cannot sort by its kind**: a server's
    /// `_error` or error `onStatus` whose code says nothing about the key.
    /// Windows hears those as "<host> said: ..." and retries them unless the
    /// words name a password or a key, so a transient `_error` on the way
    /// back from a dropped connection does not end a working show. The Mac
    /// used to call every one of them fatal (audit 1, finding 1).
    static let refusedWords = [
        "password",
        "no mount point by that name",
        "stream key",
        "there is no stream key",
        "there is no server address",
        "not an rtmp one",
        "no sound ever reached",
    ]

    /// A refusal, sorted by what it says: fatal when it names something
    /// Windows' REFUSED names, otherwise a drop worth another attempt.
    static func sortRefusal(_ said: String) -> StreamFault {
        let low = said.lowercased()
        return refusedWords.contains { low.contains($0) } ? .refused(said) : .dropped(said)
    }

    static func isFatal(_ fault: StreamFault, attempts: Int) -> Bool {
        switch fault {
        case .refused, .noSound:
            return true
        case .notFound:
            // Only at Command B. Measured on Windows: Wi-Fi away for ten
            // seconds gave "could not find" on the reconnect, and treating it
            // as fatal ended a working show.
            return attempts <= 1
        case .dropped:
            return false
        }
    }
}

/// A connection that has carried no audio is not a broadcast (W384-16, W384-17).
///
/// Both streamers used to sleep and try again for ever when the bus delivered
/// nothing, staying ON AIR with nothing leaving the machine. The two sentences
/// are Windows' own, and the difference between them is the whole of what the
/// presenter needs: never anything is a setup fault, stopping part way is a
/// sound card that went away mid show.
enum SilenceWatch {
    static let stoppedArriving = "the audio stopped arriving"
    static let neverArrived = "no sound ever reached the stream, so nothing was "
        + "broadcast. Check your sound card is working and that something is playing"

    /// What to do after `idle` seconds with nothing off the bus, or nil while
    /// it is still within the limit. `mediaBytes` counts every connection of
    /// this broadcast, not only the current one.
    static func fault(idle: Double, mediaBytes: Int,
                      timeout: Double = C.streamSilenceTimeout) -> StreamFault? {
        guard idle > timeout else { return nil }
        return mediaBytes > 0 ? .dropped(stoppedArriving) : .noSound
    }

    /// The Command Shift B addition when nothing has gone out yet. Windows
    /// says "Preferences, Audio"; the Mac's sound card page is Output.
    static let nothingYet = "but nothing has left this machine yet. Give it a moment, "
        + "and if it does not change, check your sound card in Preferences, Output"

    static func nothingYetNote(liveFor: Double, mediaBytes: Int) -> String? {
        liveFor > C.streamNothingYetSeconds && mediaBytes == 0 ? nothingYet : nil
    }
}
