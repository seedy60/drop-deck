// Why the microphone is not working, in words somebody can act on.
//
// The Mac half of Windows 3.8.3's `micdiag.py`. Mashal, 19 September 2026, on
// Windows: Command M's counterpart did nothing at all. Three different things
// stop the microphone key, and each needs its own answer:
//
//   1. The key never arrives. A second key, Option Shift M, and Help, Check the
//      keyboard, which reports every key that really reaches the app.
//   2. The microphone will not open. Core Audio's words for that are a four
//      character code, which is accurate and no use to anybody on air.
//      `explain` turns the codes into a sentence that says what to do next.
//   3. It opens and macOS hands over silence, which is what a privacy refusal
//      and a muted input both look like from here. `privacy` asks first, and
//      `silenceLine` says so a moment after opening when nothing has arrived.
//
// No AppKit here, so every answer can be checked against made up input.

import Foundation
import CoreAudio
import AudioToolbox

enum MicDiag {

    // ------------------------------------------------------------ privacy ---

    /// Where to go, in System Settings' own words.
    static let privacyFix = "Open System Settings, Privacy and Security, Microphone, "
        + "and turn on TG Drop Deck"

    static let privacyBlocked = "macOS privacy settings are stopping Drop Deck from "
        + "using the microphone. " + privacyFix

    static let policyBlocked = "A policy set by whoever manages this Mac stops Drop "
        + "Deck from using the microphone, and only they can change it"

    /// What the privacy state means for a press of the microphone key.
    enum Privacy: Equatable {
        /// Allowed: open it.
        case open
        /// Never asked: ask, and open in the answer.
        case ask
        /// Refused or managed: do not open, say this.
        case refuse(String)
    }

    /// **Asked BEFORE anything is opened.** A refused microphone opens
    /// perfectly well on a Mac and delivers silence, so opening first would
    /// say "Microphone on", duck the beds and send nothing: the exact dead key
    /// this exists to prevent, in its quietest form.
    static func privacy(_ state: PermissionState) -> Privacy {
        switch state {
        case .allowed: return .open
        case .neverAsked: return .ask
        case .refused: return .refuse(privacyBlocked)
        case .notYours: return .refuse(policyBlocked)
        }
    }

    /// The privacy sentence for a state, or nothing when it is not in the way.
    static func privacySentence(_ state: PermissionState) -> String? {
        if case .refuse(let said) = privacy(state) { return said }
        return nil
    }

    // ------------------------------------------------------------- errors ---

    static let held = "macOS would not let Drop Deck have it. Another program may be "
        + "holding it for itself, or the privacy settings are refusing it"
    static let gone = "macOS no longer has it. It may have been unplugged"
    static let noService = "The audio system is not running. Restarting the Mac usually "
        + "brings it back"
    static let badFormat = "It would not take any of the formats Drop Deck asked for"
    static let refused = "macOS would not open it and did not say why. Privacy settings "
        + "are the usual cause, then another program holding it"
    static let nothingThere = "macOS has no microphone to give Drop Deck"

    /// The failure a microphone reported, as one plain sentence (W383-07).
    ///
    /// `status` is the last OSStatus the opening got back, nil when there was
    /// no device at all to open.
    static func explain(_ status: OSStatus?) -> String {
        guard let status else { return nothingThere }
        switch status {
        case kAudioHardwareBadDeviceError, kAudioHardwareBadObjectError,
             kAudioHardwareBadStreamError:
            return gone
        case kAudioDevicePermissionsError, kAudioHardwareIllegalOperationError:
            return held
        case kAudioHardwareNotRunningError:
            return noService
        case kAudioDeviceUnsupportedFormatError, kAudioUnitErr_FormatNotSupported:
            return badFormat
        default:
            return refused
        }
    }

    /// An OSStatus as support can read it: the number, and its four
    /// characters when it is one of Core Audio's.
    static func code(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
           let text = String(bytes: bytes, encoding: .ascii) {
            return "\(status) '\(text)'"
        }
        return "\(status)"
    }

    // ------------------------------------------------------------ opening ---

    /// What Command M says when it would not open.
    ///
    /// `missing` is the name of the chosen microphone when it is not plugged
    /// in and the system default was tried in its place (W383-09).
    static func failureLine(reason: String, missing: String?) -> String {
        if let missing {
            return "Your chosen microphone, \(missing), is not plugged in, and the "
                + "system default would not open either. \(reason)"
        }
        return "The microphone would not open. \(reason)"
    }

    /// The chosen microphone's name when it is not plugged in today, and
    /// nil when it is, or when nothing was chosen and the system default is
    /// what is wanted anyway.
    ///
    /// **The choice itself is never touched.** Until 3.8.4 one press of
    /// Command M with the chosen microphone unplugged opened the default and
    /// then SAVED the default as the choice, so plugging the real one back in
    /// did nothing and the setting was gone for good (N4).
    static func missing(chosenUID: String?, chosenName: String?,
                        isPresent: (String) -> Bool) -> String? {
        guard let uid = chosenUID, !uid.isEmpty, !isPresent(uid) else { return nil }
        let name = (chosenName ?? "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "the one you chose" : name
    }

    /// Added to "Microphone on" when the chosen microphone was not there and
    /// the system default is the one that is live. Said, because somebody
    /// talking into the microphone on the desk needs to know it is the one in
    /// the laptop lid that is on.
    static func fellBack(_ missing: String) -> String {
        ". Your chosen microphone, \(missing), is not plugged in, so this is the "
            + "system default"
    }

    // ------------------------------------------------------------ silence ---

    /// A moment after opening: is macOS sending anything at all (W383-10)?
    ///
    /// nil when it is. **Exact zeros**, measured before the gain, because a
    /// real microphone is never digitally silent: background noise is enough
    /// to move the last bit. `blocks` is how many capture callbacks arrived,
    /// so "nothing sent at all" and "sent, and every sample of it zero" are
    /// told apart, because they are different faults.
    static func silenceLine(signal: Bool, blocks: Int, privacy: PermissionState) -> String? {
        guard !signal else { return nil }
        var line = blocks == 0
            ? "The microphone is on, but macOS has not sent Drop Deck any sound from it. "
            : "The microphone is on, but nothing is coming from it, not even background noise. "
        line += privacySentence(privacy)
            ?? ("If you are talking into it, check its input volume in System Settings, "
                + "Sound, Input, and that Drop Deck is allowed under Privacy and "
                + "Security, Microphone")
        return line
    }

    /// Whether a captured block holds anything but exact zeros.
    static func hasSignal(_ raw: UnsafePointer<Float>, count: Int) -> Bool {
        for i in 0..<count where raw[i] != 0 { return true }
        return false
    }
}
