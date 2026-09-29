// Asking a platform whether a stream key is right, without broadcasting.
//
// The Mac port of `dropdeck/rtmpcheck.py` and of the verdicts in
// `dialogs._key_verdict`, Windows 3.8.4. Joshua, 20 September 2026: Command B
// said it was going live to YouTube and nothing appeared on his channel. Until
// this existed the app could not tell him whether the one thing he had typed,
// the key, was right, short of going on the air and looking at a page he
// cannot see.
//
// ## Why this is safe, and the whole of why
//
// **Nothing is sent after the publish command. Not metadata, not a codec
// header, not a byte of sound or picture, and not even FCUnpublish or
// deleteStream.** YouTube's API reference defines a stream as active when it
// is "receiving data", and a broadcast cannot start while its stream is
// inactive, and auto start is that same transition. So a publish carrying no
// data starts nothing, notifies nobody and leaves nothing on a channel. What
// nobody publishes is whether YouTube counts a HEADER as data, which is why
// none is sent.
//
// Windows sends FCUnpublish and deleteStream after the answer, to be polite.
// The Mac does not, and that is deliberate: `tools/mock_rtmp.py` stops
// reading at FCUnpublish, so on Windows the zero tag proof only covers the gap
// between the answer and those two commands. Sending nothing at all makes the
// proof cover everything. `mac/tools/check_keycheck.py` runs this against that
// server and against Mac-owned ones that refuse, hang up and chatter, and
// asserts that not one audio, video or data message arrives.
//
// ## Nothing here throws
//
// Every failure is a `Result` naming what happened, in words a presenter can
// act on, because somebody who cannot see the screen cannot read a stack
// trace out of a status line.
//
// ## For whoever builds the button (package P4)
//
//     StreamKeyCheck.needsAsking(server)          ask first? then question(server:)
//     StreamKeyCheck.check(host:key:server:) { result in ... }   off main, answers on main
//     StreamKeyCheck.verdict(result, server:, key:)   the sentence to show and say
//
// and the fixed sentences below (`buttonHelp`, `nothingTriedYet`,
// `stillChecking`, `checkingWith(server:)`, `declined`).

import Foundation
import Darwin

enum StreamKeyCheck {

    /// What happened, as something to branch on rather than a string to read.
    /// The raw values are Windows' own, so a support question reads the same
    /// on both platforms.
    enum Outcome: String {
        case accepted = "accepted"
        case refused = "refused"
        case noServer = "no-server"
        case noRoute = "no-route"
        case noTLS = "no-tls"
        case noAnswer = "no-answer"
        case badAddress = "bad-address"
        case noKey = "no-key"
    }

    /// How far the conversation got. A dropped connection means a refusal
    /// ONLY after the publish has gone out.
    enum Stage: String {
        case open, handshake, connect, createStream, publish
    }

    /// How much of a server's own wording may end up in a spoken sentence.
    /// The far end chooses the length and VoiceOver has to read it.
    static let sayLimit = 200

    struct Result {
        var outcome: Outcome
        /// The platform's OWN words, when it gave any. "Publish Rejected:
        /// Invalid URL" is the one phrase somebody could search for, so it is
        /// repeated, never paraphrased.
        var serverSaid = ""
        /// For a support question: the status code or the reason it stopped.
        /// Never spoken.
        var detail = ""
        /// Where it got to. Nil when it never opened a socket.
        var stage: Stage?
        /// What this end wrote, by name, in order. The last entry is
        /// "publish" whenever the question was asked at all, and nothing
        /// follows it.
        var sent: [String] = []
        /// Audio, video and data messages written. Always nought.
        var tagsSent = 0
        var seconds = 0.0

        var ok: Bool { outcome == .accepted }

        init(_ outcome: Outcome, said: String = "", detail: String = "",
             stage: Stage? = nil) {
            self.outcome = outcome
            serverSaid = said
            self.detail = detail
            self.stage = stage
        }
    }

    // ---------------------------------------------------------- addresses ---

    /// The address a check should use for a platform, from what is typed.
    /// YouTube and Facebook have one ingest each and it is not the user's to
    /// get wrong; the others take what is typed, or the starting point.
    /// The same rule the Video streaming page's OK applies.
    static func address(server: String, typed: String) -> String {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if C.rtmpFixedAddress.contains(server) { return C.rtmpIngest[server] ?? typed }
        return typed.isEmpty ? (C.rtmpIngest[server] ?? "") : typed
    }

    /// The parts of a base address, or nil when it is not an RTMP one.
    static func split(_ base: String) -> RTMPClient.Parts? {
        RTMPClient.split(base)
    }

    // --------------------------------------------------------------- asking ---

    /// Does this server accept this stream key. Nothing is broadcast.
    ///
    /// For the Preferences button. `host` is the Address box as typed (or
    /// empty, for a platform with a fixed ingest); `key` is the key box, and
    /// every whitespace character is taken out of it, because a key never has
    /// one and a paste often brings a newline. Blocks for up to `timeout`
    /// seconds: never call it on the main thread. `check` does it for you.
    static func verify(host: String, key: String, server: String,
                       timeout: Double = C.streamKeyCheckTimeout) -> Result {
        let cleaned = String(key.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        })
        return verify(base: address(server: server, typed: host), key: cleaned,
                      timeout: timeout)
    }

    /// `verify`, on a background queue, answering on the main queue.
    static func check(host: String, key: String, server: String,
                      timeout: Double = C.streamKeyCheckTimeout,
                      then: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = verify(host: host, key: key, server: server, timeout: timeout)
            DispatchQueue.main.async { then(result) }
        }
    }

    /// The conversation itself, as far as the answer to publish and no
    /// further. Never throws.
    static func verify(base: String, key rawKey: String,
                       timeout: Double = C.streamKeyCheckTimeout) -> Result {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return Result(.noKey) }
        guard let parts = split(base) else { return Result(.badAddress) }

        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + timeout
        func finished(_ result: Result, _ client: RTMPClient?) -> Result {
            var out = result
            if let client {
                out.sent = client.sentDuringConversation
                out.tagsSent = client.tagsSent
            }
            out.seconds = ProcessInfo.processInfo.systemUptime - started
            return out
        }

        // The name first, separately, so a misspelt address is called what it
        // is rather than "did not answer" (M2).
        guard resolves(parts.host, port: parts.port, until: deadline) else {
            return finished(Result(.noServer, detail: "the name did not resolve"), nil)
        }

        let client = RTMPClient(parts: parts, key: key)
        // Hanging up is a cancel. Nothing is written on the way out.
        defer { client.close() }
        client.begin(until: deadline)
        do {
            try client.open()
        } catch let error as RTMPError {
            switch error {
            case .notFound: return finished(Result(.noServer, detail: "\(error)", stage: .open), client)
            case .insecure: return finished(Result(.noTLS, detail: "\(error)", stage: .open), client)
            default: return finished(Result(.noRoute, detail: "\(error)", stage: .open), client)
            }
        } catch {
            return finished(Result(.noRoute, detail: "\(error)", stage: .open), client)
        }

        // **How far it got decides what a silence means.** Measured by
        // Windows on 20 September 2026 with a made up key: Facebook answers
        // with an onStatus saying "Publish Rejected: Invalid URL", and YouTube
        // simply CLOSES THE CONNECTION. Both are a refusal, and a dropped
        // socket means a refusal only once the publish has gone out: the same
        // drop at the handshake is the network, and calling that a bad key
        // sends somebody hunting for a key that was fine.
        var stage = Stage.handshake
        do {
            try client.handshake()
            stage = .connect
            let connected = try client.sendConnect()
            if connected.command == "_error" {
                return finished(Result(.refused, said: said(connected.description),
                                       detail: connected.code, stage: stage), client)
            }
            stage = .createStream
            let created = try client.createStream()
            if created.command == "_error" {
                return finished(Result(.refused, said: said(created.description),
                                       detail: created.code, stage: stage), client)
            }
            // THE question, on chunk stream 4 with the stream id the server
            // just handed out.
            stage = .publish
            try client.publish(on: RTMPClient.publishChunk)
            switch client.waitPublishAnswer(until: deadline) {
            case .accepted(let answer):
                return finished(Result(.accepted, said: said(answer.description),
                                       detail: answer.code, stage: stage), client)
            case .refused(let answer):
                return finished(Result(.refused, said: said(answer.description),
                                       detail: answer.code, stage: stage), client)
            case .hungUp:
                return finished(gaveUp(stage, detail: "the server closed the connection"), client)
            case .tooLarge:
                return finished(gaveUp(stage, detail: "the server sent something too large"), client)
            case .silent:
                return finished(gaveUp(stage, detail: "it did not answer in time"), client)
            }
        } catch {
            return finished(gaveUp(stage, detail: "\(error)"), client)
        }
    }

    /// A conversation that stopped early, read according to where it stopped.
    ///
    /// Only after the publish command does a silence mean the key. Anywhere
    /// earlier, the same silence is the network and is reported as the
    /// network.
    static func gaveUp(_ stage: Stage, detail: String = "") -> Result {
        Result(stage == .publish ? .refused : .noAnswer, detail: detail, stage: stage)
    }

    /// The platform's own SENTENCE out of a status description, or nothing.
    ///
    /// The description only, never the code: the code is a machine's name
    /// for the thing and is read out dot by dot. Whitespace collapsed, and
    /// capped, because this goes into a spoken line and a server on the other
    /// side of the internet chooses its length.
    static func said(_ description: String?) -> String {
        guard let description else { return "" }
        let words = description.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let value = words.joined(separator: " ")
        if value.isEmpty { return "" }
        if value.count > sayLimit { return String(value.prefix(sayLimit - 1)) + "." }
        return value
    }

    /// Whether the name resolves, within the deadline. `getaddrinfo` has no
    /// timeout of its own, so it runs on a thread of its own and the answer
    /// is waited for only as long as the conversation may take.
    static func resolves(_ host: String, port: Int, until deadline: TimeInterval) -> Bool {
        final class Answer { let lock = NSLock(); var ok = false }
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP
            var found: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, String(port), &hints, &found)
            if status == 0 {
                answer.lock.lock(); answer.ok = true; answer.lock.unlock()
                freeaddrinfo(found)
            }
            done.signal()
        }
        let left = max(0.05, deadline - ProcessInfo.processInfo.systemUptime)
        if done.wait(timeout: .now() + left) == .timedOut { return false }
        answer.lock.lock(); defer { answer.lock.unlock() }
        return answer.ok
    }

    // -------------------------------------------------------------- saying ---

    /// Whether this platform is KNOWN to put you live the moment it is sent
    /// a stream. True for YouTube, false for Facebook, nil for anything
    /// nobody has established.
    static func goesLiveAtOnce(_ server: String) -> Bool? {
        C.rtmpGoesLiveAtOnce[server] ?? nil
    }

    /// Ask first, unless the platform is KNOWN to be safe.
    ///
    /// Not only when it is known to be dangerous: nil means nobody knows,
    /// which is the honest answer for a custom server, and proceeding silently
    /// there would be the app making a promise it cannot keep. Only Facebook,
    /// which posts nothing until somebody presses Go Live Now, is not asked.
    static func needsAsking(_ server: String) -> Bool {
        goesLiveAtOnce(server) != false
    }

    /// The name a sentence uses for a platform. Never an address.
    static func label(_ server: String) -> String {
        let named = StreamServers.serverLabel(server)
        return named.isEmpty ? "the server" : named
    }

    /// The box's title when asking first.
    static let questionTitle = "Check my stream key"

    /// What to ask before checking, or nil when there is nothing to ask.
    /// Verbatim from `dialogs._agree_to_check`.
    static func question(server: String) -> String? {
        guard needsAsking(server) else { return nil }
        let name = label(server)
        if goesLiveAtOnce(server) == true {
            return "Checking connects to \(name) for about a second and sends no sound "
                 + "and no picture, so it cannot put you on the air, tell your "
                 + "subscribers, or leave anything on your channel.\n\nCheck the key now?"
        }
        return "\(name) is not a service Drop Deck knows, so it cannot promise what "
             + "connecting does. Nothing is sent but the key itself: no sound and no "
             + "picture.\n\nCheck the key now?"
    }

    /// Said when the question is answered No.
    static let declined = "Nothing was checked and nothing was sent."

    /// The button's help text.
    static let buttonHelp = "Asks the platform whether your stream key is right. It "
        + "sends no sound and no picture, so nothing is broadcast and nothing is posted."

    /// What the result box holds before anything has been tried.
    static let nothingTriedYet = "Nothing tried yet. Check my stream key asks the "
        + "platform whether your key is right. It sends no sound and no picture."

    /// A second press while the first is still out. The button is never
    /// disabled: disabling a focused button MOVES focus, silently.
    static let stillChecking = "Still checking your stream key. The answer will be read out."

    /// Said as the check starts.
    static func checkingWith(server: String) -> String {
        "Checking your stream key with \(label(server)). Nothing is being broadcast."
    }

    /// One outcome, as a sentence to show and to speak.
    ///
    /// Verbatim from `dialogs._key_verdict`. No addresses, no error numbers,
    /// no status codes, and the platform's own words repeated when it gave
    /// any. The key itself only ever as its last four characters.
    static func verdict(_ result: Result, server: String, key: String) -> String {
        let name = label(server)
        let goesLive = goesLiveAtOnce(server)
        switch result.outcome {
        case .accepted:
            // "Broadcast" and "posted" are different promises, and Facebook's
            // whole reassurance is that nothing is POSTED.
            let said = "\(name) accepted your stream key, and nothing was "
                     + (server == "facebook" ? "posted" : "broadcast") + "."
            if goesLive == true {
                return said + " If you go live and nothing appears on your channel, the "
                     + "usual reason is that auto start is switched off for that stream, "
                     + "so \(name) is waiting for you to press Go live in your live "
                     + "control room."
            }
            if goesLive == false && server == "facebook" {
                return said + " Remember that Facebook only posts the video when you "
                     + "press Go Live Now on its own page."
            }
            return said
        case .refused:
            // A refusal says nothing was broadcast too: it is the answer most
            // likely to worry somebody, and the one thing they cannot check
            // for themselves.
            if !result.serverSaid.isEmpty {
                return "\(name) would not take that stream key, and nothing was "
                     + "broadcast. It said: \(result.serverSaid). Check the key is pasted "
                     + "in full, that you took it from the page Get my stream key opens, "
                     + "and that it has not expired."
            }
            return "\(name) would not take that stream key, and nothing was broadcast. "
                 + "It closed the connection without saying why, which is what it does "
                 + "when a key is wrong or has expired. Check the key is pasted in full "
                 + "and comes from the page Get my stream key opens. Yours is "
                 + "\(Secrets.redact(key))."
        case .noServer:
            return "Could not find \(name). Check that you are online, and that the "
                 + "address on this page is the one they gave you."
        case .noRoute:
            return "Could not reach \(name). Something on your network may be blocking "
                 + "it. On a work or school network, that is the usual reason."
        case .noTLS:
            return "Reached \(name) but the secure connection failed. Something on your "
                 + "network may be blocking it."
        case .noKey:
            return "There is no stream key. Get my stream key opens the page where "
                 + "yours is."
        case .badAddress:
            return "That does not look like a server address. It should start with "
                 + "rtmp or rtmps."
        case .noAnswer:
            return "\(name) took the connection but did not answer. Nothing was "
                 + "broadcast. Try again, and if it keeps happening something on your "
                 + "network may be blocking it."
        }
    }
}
