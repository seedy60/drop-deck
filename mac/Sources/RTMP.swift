// An RTMP client, written by hand over the Network framework.
//
// This is the one genuinely new thing in the Mac's video work. Everything else
// is either arithmetic retyped from the Windows copy or a system framework
// doing its job; nothing on a Mac speaks RTMP, so this is a protocol
// implementation rather than a port.
//
// It is small enough to read in one sitting because a PUBLISHER needs about a
// third of RTMP. There is no playback here, no seeking, no shared objects, no
// server side scripting: a handshake, a chunk layer, five AMF0 commands, and
// then audio and video tags until somebody presses the key again.
//
// ## What it speaks
//
//     handshake      C0/C1 out, S0/S1/S2 in, C2 out. The simple version, not
//                    the signed one, which is what every ingest accepts from
//                    a publisher.
//     connect        with the app name out of the URL
//     releaseStream  and FCPublish, which YouTube and Facebook both expect
//     createStream   answered with a stream id
//     publish        answered with NetStream.Publish.Start, after which the
//                    tags flow
//
// ## RTMPS is not a preference
//
// Facebook has refused unencrypted RTMP since 2018 and YouTube asks for RTMPS,
// so `rtmps` gets TLS from `Network` with nothing added to the app. Measured
// on this Mac: both ingests complete a TLS 1.3 handshake in about a quarter of
// a second.
//
// ## The stream key never appears in anything that can be read out
//
// It is the last path component of the URL and it is a credential: anybody
// holding a YouTube key can broadcast to that channel. `StreamServers.hostLabel`
// is what the status line and the pre-flight use, and nothing here logs a URL.

import Foundation
import Network

enum RTMPError: Error, CustomStringConvertible {
    case badURL
    /// The address is not an RTMP one at all. Windows' own sentence, from
    /// `RtmpDestination.url`.
    case notRTMP
    case refused(String)
    case handshake(String)
    case dropped(String)
    /// The name did not resolve. Kept apart from every other failure to
    /// connect because it is the one worth stopping for at Command B, where
    /// it is nearly always a misspelt address, and the one NOT worth stopping
    /// for on the way back from a dropped connection, where it is the network.
    case notFound(String)
    /// The socket could not be opened: refused, unreachable, no route.
    case unreachable(String)
    /// The TLS handshake failed.
    case insecure(String)
    /// The far end closed the connection.
    case hungUp
    /// The far end closed the connection AFTER the publish command went out,
    /// which is how YouTube answers a stream key it will not take: measured by
    /// Windows on 20 September 2026, it says nothing at all and hangs up.
    case keyRefused
    /// The whole conversation took longer than it was allowed to.
    case timedOut
    /// The far end declared a message bigger than anything a publisher is
    /// ever sent. See `RTMPChunkReader.maxMessage`.
    case tooLarge

    var description: String {
        switch self {
        case .badURL: return "that address is not one this can use"
        case .notRTMP:
            return "that server address is not an RTMP one, so nothing was sent. "
                 + "It has to start with rtmp or rtmps"
        case .refused(let why): return why
        case .handshake(let why): return why
        case .dropped(let why): return why
        case .notFound(let why): return why
        case .unreachable(let why): return why
        case .insecure(let why): return why
        case .hungUp: return "the server closed the connection"
        case .keyRefused:
            return "the server would not take the stream key. Check it has been "
                 + "copied in full and has not expired"
        case .timedOut: return "the server did not answer in time"
        case .tooLarge: return "the server sent something too large"
        }
    }

    /// What a streamer should do about it. A refusal is the far end saying
    /// no, and saying it again will not help; see `Retry.isFatal`.
    ///
    /// A server's own refusal is sorted by its words, as Windows sorts it
    /// (`Retry.sortRefusal`): one naming the stream key stops, and a generic
    /// `_error` is retried, because on a reconnect it is as often the server
    /// still tidying up the last connection as a real no.
    var fault: StreamFault {
        switch self {
        case .refused(let why): return Retry.sortRefusal(why)
        case .badURL, .notRTMP, .keyRefused: return .refused(description)
        case .notFound: return .notFound(description)
        default: return .dropped(description)
        }
    }
}

/// One command the server sent, with everything in it anything here acts on.
///
/// It used to be `(command, code)` and nothing else, which could not tell a
/// yes from a no (that is the `level`), could not repeat the platform's own
/// words (the `description`), and could not tell WHICH request a `_result`
/// answered (the `transaction`), so the createStream wait was satisfied by the
/// connect reply and the server's stream id was never read (M1).
struct RTMPHeard {
    /// Counts every command ever heard on this connection, so a wait can ask
    /// only about what arrived after the thing it is waiting on was sent.
    let seq: Int
    let command: String
    let transaction: Double
    let code: String
    let level: String
    let description: String
    /// The last plain number after the transaction id, which in the answer to
    /// createStream is the stream id the server handed out.
    let number: Double?

    /// The accept rule, from `dropdeck/rtmpcheck.py`: an onStatus that says
    /// `NetStream.Publish.Start`, or any onStatus at level `status`.
    var isAcceptance: Bool {
        command == "onStatus" && (code == "NetStream.Publish.Start" || level == "status")
    }

    init(seq: Int, values: [AMF0.Value]) {
        self.seq = seq
        command = AMF0.firstString(in: values) ?? ""
        if values.count > 1, case .number(let n) = values[1] { transaction = n } else { transaction = -1 }
        code = AMF0.field("code", in: values) ?? ""
        level = AMF0.field("level", in: values) ?? ""
        description = AMF0.field("description", in: values) ?? ""
        var last: Double?
        for value in values.dropFirst(2) {
            if case .number(let n) = value { last = n }
        }
        number = last
    }
}

/// One inbound message, put back together out of its chunks.
struct RTMPMessage {
    let type: UInt8
    let streamID: UInt32
    let payload: Data
}

/// The chunk layer, incoming.
///
/// **This is the half that was missing, and missing it cost a release.** RTMP
/// does not put a message on the wire in one piece: it cuts it into chunks and
/// puts a header byte in front of every piece after the first, and until the
/// server has been told otherwise those pieces are 128 bytes long. So
/// `NetConnection.Connect.Success`, which is what YouTube answers a connect
/// with, arrives as `NetConnection.Conne`, then a header byte, then
/// `ct.Success`.
///
/// The first version of this client looked for those names in the raw bytes.
/// That works against `tools/mock_rtmp.py`, whose replies are small enough to
/// fit in one chunk, and it does not work against YouTube. Measured against
/// the real ingest on 8 September 2026: the connect succeeded, the answer
/// arrived in 311 bytes, and searching for the name found nothing, so the app
/// waited fifteen seconds, gave up, and sat on "connecting" for ever.
///
/// A publisher needs to UNDERSTAND about six of these messages and can ignore
/// the rest, but it has to unwrap all of them to find the six.
struct RTMPChunkReader {

    /// The largest message this will hold for a server. The same 64 KB as
    /// `MAX_MESSAGE` in `dropdeck/rtmpcheck.py`, and for the same reason: a
    /// publisher is only ever sent commands and control messages of a few
    /// hundred bytes, but the length field is three bytes wide, so a server
    /// may DECLARE sixteen megabytes and then trickle it, and every byte of
    /// it would have been held (W384-04).
    static let maxMessage = 64 * 1024

    /// What the far end says its chunks are. 128 until it says otherwise, and
    /// it always says otherwise early.
    private(set) var chunkSize = 128

    /// Set once a server declares something over `maxMessage`. Nothing more
    /// is read after it: the connection is treated as closed.
    private(set) var tooLarge = false

    private struct Partial {
        var type: UInt8 = 0
        var streamID: UInt32 = 0
        var length: Int = 0
        var timestamp: Int = 0
        /// Whether the message on this chunk stream carries the four byte
        /// extended timestamp. A property of the MESSAGE, remembered here,
        /// because a type 3 chunk carries no timestamp field to look at.
        var extended = false
        var payload = Data()
    }
    private var streams: [UInt32: Partial] = [:]

    /// Take whatever has arrived and hand back every WHOLE message in it,
    /// leaving the leftovers in `buffer` for next time.
    mutating func read(from buffer: inout Data) -> [RTMPMessage] {
        var out: [RTMPMessage] = []
        while !tooLarge {
            guard let (message, used) = one(buffer) else { break }
            if tooLarge { break }
            buffer.removeFirst(used)
            if let message {
                // Set Chunk Size. Everything after it is cut differently, so
                // this one is acted on here rather than handed up.
                if message.type == 1, message.payload.count >= 4 {
                    let value = message.payload.prefix(4).reduce(0) { ($0 << 8) | Int($1) } & 0x7fff_ffff
                    if value > 0 { chunkSize = min(value, 0x00ff_ffff) }
                }
                out.append(message)
            }
        }
        // Nothing after a message too large to hold is worth reading: the
        // stream is out of step from here on whatever happens.
        if tooLarge { buffer.removeAll() }
        return out
    }

    /// One chunk off the front. Returns the message when that chunk finished
    /// one, and how many bytes were consumed, or nothing when there is not a
    /// whole chunk yet.
    private mutating func one(_ data: Data) -> (RTMPMessage?, Int)? {
        var at = 0
        func byte(_ i: Int) -> UInt8? {
            let index = data.index(data.startIndex, offsetBy: i, limitedBy: data.endIndex)
            guard let index, index < data.endIndex else { return nil }
            return data[index]
        }
        guard let first = byte(at) else { return nil }
        at += 1
        let fmt = (first >> 6) & 0x03

        // The chunk stream id, in one, two or three bytes.
        var csid = UInt32(first & 0x3f)
        if csid == 0 {
            guard let b = byte(at) else { return nil }
            csid = UInt32(b) + 64
            at += 1
        } else if csid == 1 {
            guard let lo = byte(at), let hi = byte(at + 1) else { return nil }
            csid = UInt32(hi) * 256 + UInt32(lo) + 64
            at += 2
        }

        var partial = streams[csid] ?? Partial()
        var timestampField = partial.timestamp

        func three(_ i: Int) -> Int? {
            guard let a = byte(i), let b = byte(i + 1), let c = byte(i + 2) else { return nil }
            return Int(a) << 16 | Int(b) << 8 | Int(c)
        }

        switch fmt {
        case 0:
            guard let ts = three(at), let len = three(at + 3), let type = byte(at + 6),
                  let s0 = byte(at + 7), let s1 = byte(at + 8),
                  let s2 = byte(at + 9), let s3 = byte(at + 10) else { return nil }
            timestampField = ts
            partial.length = len
            partial.type = type
            // The one little endian field in the whole protocol.
            partial.streamID = UInt32(s0) | UInt32(s1) << 8 | UInt32(s2) << 16 | UInt32(s3) << 24
            at += 11
        case 1:
            guard let ts = three(at), let len = three(at + 3),
                  let type = byte(at + 6) else { return nil }
            timestampField = ts
            partial.length = len
            partial.type = type
            at += 7
        case 2:
            guard let ts = three(at) else { return nil }
            timestampField = ts
            at += 3
        default:
            break
        }

        // **Whether the four extra bytes are there is a property of the
        // MESSAGE, not of this chunk** (W384-05). A type 3 chunk has no
        // timestamp field, so the 0xffffff marker cannot appear in it, and the
        // DECODED value remembered from the last header can never equal the
        // marker either. Comparing that value, as this used to, read the
        // continuation of an extended timestamp message four bytes short and
        // put everything after it out of step.
        let extended = fmt == 3 ? partial.extended : timestampField == 0xffffff
        if extended {
            guard let a = byte(at), let b = byte(at + 1),
                  let c = byte(at + 2), let d = byte(at + 3) else { return nil }
            timestampField = Int(a) << 24 | Int(b) << 16 | Int(c) << 8 | Int(d)
            at += 4
        }
        partial.timestamp = timestampField
        partial.extended = extended

        // A length is three bytes, so a server may declare 16 MB. Refused
        // here, before a byte of it is held.
        if partial.length > RTMPChunkReader.maxMessage {
            tooLarge = true
            return (nil, at)
        }

        // A message longer than one chunk arrives in chunkSize pieces.
        let remaining = max(0, partial.length - partial.payload.count)
        let take = min(chunkSize, remaining)
        guard data.count >= at + take else { return nil }
        if take > 0 {
            let from = data.index(data.startIndex, offsetBy: at)
            partial.payload.append(data[from..<data.index(from, offsetBy: take)])
        }
        at += take

        if partial.payload.count >= partial.length && partial.length > 0 {
            let message = RTMPMessage(type: partial.type, streamID: partial.streamID,
                                      payload: partial.payload)
            partial.payload = Data()
            streams[csid] = partial
            return (message, at)
        }
        streams[csid] = partial
        return (nil, at)
    }
}

/// One publishing connection.
final class RTMPClient {

    // Chunk stream ids. Two so audio and video interleave without either
    // having to rewrite the other's header every message.
    private let controlChunk: UInt32 = 3
    private let audioChunk: UInt32 = 4
    private let videoChunk: UInt32 = 6

    /// Where the key check says publish: chunk stream 4, which is what every
    /// encoder does and what `dropdeck/rtmpcheck.py` does. The broadcast
    /// itself still says it on the control stream, as it always has.
    static let publishChunk: UInt32 = 4

    /// The message stream the server handed back from createStream. One
    /// until it says otherwise, which is what every server this has met says.
    private var messageStreamID: UInt32 = 1

    /// How many of the server's commands are kept. A server may send them for
    /// as long as the connection is up, and nothing older than the publish
    /// answer is ever asked about.
    static let keepHeard = 256

    /// How much may arrive before the handshake is done. The handshake is
    /// 3073 bytes; a server sending more than this before it has finished is
    /// not an RTMP server worth holding memory for.
    static let preHandshakeLimit = 3073 + RTMPChunkReader.maxMessage

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "app.tgstudios.dropdeck.rtmp")
    private var outChunkSize = 4096
    private var transaction: Double = 1
    /// The last timestamp written on each chunk stream, for the type 1 header.
    private var lastStamp: [UInt32: Int] = [:]

    private let lock = NSLock()
    private var incoming = Data()
    private var reader = RTMPChunkReader()
    /// Commands the server has sent, in order. Filled by the reassembler
    /// rather than by looking for names in the raw bytes, which is what missed
    /// YouTube's answer entirely.
    private var heard: [RTMPHeard] = []
    private var heardCount = 0
    private var handshakeDone = false
    private var closedByPeer = false
    private var overflowed = false
    /// When the whole conversation has to be over, on the monotonic clock.
    ///
    /// **One deadline, not one per step** (W384-03). Each wait used to have
    /// its own fifteen seconds and each write its own twenty, so a server that
    /// answered each step just before its limit could hold a check for a
    /// minute. A deadline checked on every turn of every wait bounds the
    /// whole conversation however the far end paces it.
    private var deadline: TimeInterval = .infinity
    private var inConversation = false
    /// The seq the publish went out at: an answer to it is anything after.
    private var publishSeq = Int.max
    /// Transactions nobody waits for, whose `_error` must not be read as the
    /// answer to something else.
    private var unanswered: Set<Double> = []
    private var _bytesSent = 0
    private var _tagsSent = 0
    private var _mediaBytesSent = 0
    private var _sent: [String] = []
    private(set) var connected = false

    let url: String
    let key: String
    private var host = ""
    private var port: UInt16 = 1935
    private var app = ""
    private var secure = false
    private var tcURL: String

    init(url: String, key: String) {
        self.url = url
        self.key = key
        tcURL = url
    }

    /// A client for an address already taken apart by `split`, which is how
    /// the key check makes one: Windows' rules for what an address is, and
    /// Windows' tcUrl.
    init(parts: Parts, key: String) {
        let scheme = parts.secure ? "rtmps" : "rtmp"
        url = "\(scheme)://\(parts.host):\(parts.port)/\(parts.app)"
        tcURL = url
        self.key = key
        host = parts.host
        port = UInt16(clamping: parts.port)
        app = parts.app
        secure = parts.secure
    }

    /// Everything the server has said, for the diagnostics and the checks.
    /// A publisher acts on about six of these and this is all of them.
    var conversation: [(command: String, code: String)] {
        lock.lock(); defer { lock.unlock() }
        return heard.map { ($0.command, $0.code) }
    }

    /// Every command the server has sent, whole.
    var heardEntries: [RTMPHeard] {
        lock.lock(); defer { lock.unlock() }
        return heard
    }

    /// Every byte written, handshake and commands included.
    var bytesSent: Int { lock.lock(); defer { lock.unlock() }; return _bytesSent }
    /// Audio, video and data messages written. The key check asserts this is
    /// nought as a second guard, beside the mock server counting what arrived.
    var tagsSent: Int { lock.lock(); defer { lock.unlock() }; return _tagsSent }
    /// Audio and video payload bytes only (M8): what a viewer could receive.
    var mediaBytesSent: Int { lock.lock(); defer { lock.unlock() }; return _mediaBytesSent }
    /// What was written during the conversation, in order, by name: "chunk
    /// size", then each command. Nothing is recorded once the broadcast is
    /// under way, so it cannot grow over a show.
    var sentDuringConversation: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
    /// Whether the far end has closed the connection, or broken it.
    var peerClosed: Bool { lock.lock(); defer { lock.unlock() }; return closedByPeer }

    /// The full address, key included. Never shown, never logged.
    var publishTarget: String {
        key.isEmpty ? url : url + "/" + key
    }

    // ---------------------------------------------------------- addresses ---

    /// An RTMP address taken apart, the way `rtmpcheck.split_url` does it.
    struct Parts: Equatable {
        let secure: Bool
        let host: String
        let port: Int
        let app: String
    }

    /// A base RTMP address as its parts, or nil when it is not one.
    ///
    /// `base` is the address WITHOUT the key, "rtmps://a.rtmps.youtube.com/live2".
    /// The app is the path, less its slashes, and may be empty; the port is
    /// the scheme's own unless one is given. Mirrors `split_url` in
    /// `dropdeck/rtmpcheck.py`, and `mac/tools/crosscheck/keycheck` holds the
    /// two to the same answers.
    static func split(_ base: String) -> Parts? {
        let text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URLComponents(string: text),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "rtmp" || scheme == "rtmps",
              let host = parsed.host, !host.isEmpty else { return nil }
        let secure = scheme == "rtmps"
        let port = parsed.port ?? (secure ? 443 : 1935)
        guard port > 0, port <= 65535 else { return nil }
        let app = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Parts(secure: secure, host: host.lowercased(), port: port, app: app)
    }

    // ------------------------------------------------------------ opening ---

    /// Connect and publish, for a broadcast.
    ///
    /// Throws an `RTMPError`. `timeout` bounds the whole conversation, from
    /// the first packet to the answer to createStream; the grace after publish
    /// is `C.rtmpPublishGrace` on top of it.
    func connect(timeout: Double = 15) throws {
        try parse()
        begin(timeout: timeout)
        try open()
        try handshake()

        let connectAnswer = try sendConnect()
        if connectAnswer.command == "_error"
            || RTMPClient.refusals.contains(connectAnswer.code) {
            throw RTMPError.refused(Self.saying(connectAnswer))
        }
        let created = try createStream()
        if created.command == "_error" {
            throw RTMPError.refused(Self.saying(created))
        }
        try publish(on: controlChunk)

        // **Not a wait for permission.** The Mac waited only for a refusal
        // here, on the belief that YouTube never answers publish. That belief
        // came from a made up key, which YouTube answers by HANGING UP, and
        // the hang up was invisible, because a peer closing was never
        // recorded. Windows measured a real key accepted with
        // NetStream.Publish.Start in 0.60 s. So a yes ends the wait at once, a
        // no or a hang up is a refusal (W384-06), and silence for the whole
        // grace still goes on, exactly as before, for a platform that says
        // nothing either way.
        let grace = ProcessInfo.processInfo.systemUptime + C.rtmpPublishGrace
        switch waitPublishAnswer(until: grace) {
        case .accepted, .silent:
            break
        case .refused(let answer):
            throw RTMPError.refused(Self.saying(answer))
        case .hungUp:
            throw RTMPError.keyRefused
        case .tooLarge:
            throw RTMPError.tooLarge
        }
        lock.lock(); inConversation = false; lock.unlock()
        connected = true
    }

    private func parse() throws {
        // rtmp://host[:port]/app[/more]
        guard let parsed = URLComponents(string: url), let scheme = parsed.scheme,
              let host = parsed.host, !host.isEmpty else {
            // Neither a scheme nor a host: a folder, a file, a word.
            throw url.lowercased().hasPrefix("rtmp") ? RTMPError.badURL : RTMPError.notRTMP
        }
        switch scheme.lowercased() {
        case "rtmp": secure = false; port = 1935
        case "rtmps": secure = true; port = 443
        default: throw RTMPError.notRTMP
        }
        if let given = parsed.port {
            guard given > 0, given <= 65535 else { throw RTMPError.badURL }
            port = UInt16(given)
        }
        self.host = host
        // The app is everything after the host, less the leading slash. For
        // YouTube that is "live2", for Facebook "rtmp".
        app = parsed.path.hasPrefix("/") ? String(parsed.path.dropFirst()) : parsed.path
        if app.isEmpty { throw RTMPError.badURL }
    }

    /// Start the clock on the whole conversation.
    func begin(timeout: Double) {
        begin(until: ProcessInfo.processInfo.systemUptime + timeout)
    }

    func begin(until: TimeInterval) {
        lock.lock()
        deadline = until
        inConversation = true
        lock.unlock()
    }

    private var remaining: Double {
        lock.lock(); defer { lock.unlock() }
        return deadline - ProcessInfo.processInfo.systemUptime
    }

    /// Open the socket, and TLS when the address is rtmps.
    ///
    /// Throws `.notFound` for a name that will not resolve, `.insecure` for a
    /// TLS failure, `.unreachable` for anything else that stopped it, and
    /// `.timedOut` when the deadline passed first.
    func open() throws {
        guard let port = NWEndpoint.Port(rawValue: self.port), self.port > 0 else {
            throw RTMPError.badURL
        }
        let parameters: NWParameters = secure ? .tls : .tcp
        // Nagle would hold a small chunk back waiting for company, which on a
        // 30 fps stream is a frame of latency for nothing.
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let made = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        lock.lock(); connection = made; lock.unlock()

        let ready = DispatchSemaphore(value: 0)
        let settle = NSLock()
        var settled = false
        var failure: RTMPError?
        func finish(_ error: RTMPError?) {
            settle.lock()
            if !settled { settled = true; failure = error; ready.signal() }
            settle.unlock()
        }
        made.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                finish(nil)
            // **Waiting is an answer, not a pause** (M2). A name that does not
            // resolve, or a port nothing listens on, leaves the connection
            // WAITING for a better network, not failed, and this used to sit
            // the whole timeout out and then say the server "did not answer".
            case .waiting(let error):
                finish(Self.openError(error))
            case .failed(let error):
                finish(Self.openError(error))
                self?.markClosed()
            case .cancelled:
                finish(.hungUp)
                self?.markClosed()
            default:
                break
            }
        }
        made.start(queue: queue)
        receiveLoop(made)
        if ready.wait(timeout: .now() + max(0.05, remaining)) == .timedOut {
            throw RTMPError.timedOut
        }
        settle.lock(); let why = failure; settle.unlock()
        if let why { throw why }
    }

    /// What stopped a socket opening, sorted the way the key check needs it.
    static func openError(_ error: NWError) -> RTMPError {
        switch error {
        case .dns:
            return .notFound("that address could not be found. Check it, and check you are online")
        case .tls:
            return .insecure("the secure connection to the server could not be made")
        default:
            return .unreachable(explain(error))
        }
    }

    static func explain(_ error: Error) -> String {
        let text = "\(error)".lowercased()
        if text.contains("refused") {
            return "the server refused the connection"
        }
        if text.contains("hostname") || text.contains("notfound")
            || text.contains("cannot find") || text.contains("dnsresolution") {
            return "that address could not be found. Check it, and check you are online"
        }
        if text.contains("timeout") || text.contains("timed out") {
            return "the server did not answer"
        }
        if text.contains("tls") || text.contains("certificate") {
            return "the secure connection to the server could not be made"
        }
        return "the connection to the server failed"
    }

    // ---------------------------------------------------------- handshake ---

    func handshake() throws {
        // C0 is one byte of version. C1 is 1536 bytes: four of time, four of
        // zero, and 1528 the server echoes back. The signed handshake exists
        // for Flash player authentication and no ingest asks a publisher for
        // it.
        var c0c1 = Data([0x03])
        var c1 = Data(count: 1536)
        c1[0] = 0; c1[1] = 0; c1[2] = 0; c1[3] = 0
        for i in 8..<1536 { c1[i] = UInt8.random(in: 0...255) }
        c0c1.append(c1)
        try write(c0c1, name: "C0 C1")

        // S0 and S1 and S2 together, and then C2 is S1 echoed.
        let reply = try read(3073)
        guard reply.count >= 3073, reply[0] == 0x03 else {
            throw RTMPError.handshake("the server did not answer as an RTMP server")
        }
        let s1 = reply.subdata(in: 1..<1537)
        try write(s1, name: "C2")
        // Everything from here is chunked, so the reassembler takes over. Set
        // before anything else arrives, and anything already buffered is
        // handed to it now.
        lock.lock()
        handshakeDone = true
        drainMessages()
        lock.unlock()
    }

    // ------------------------------------------------------------ commands ---

    /// Say connect, and return the server's answer to it: the `_result` or
    /// `_error` carrying connect's own transaction id, and nothing earlier.
    @discardableResult
    func sendConnect() throws -> RTMPHeard {
        // Tell the server how big our chunks are before anything else, or
        // every message over 128 bytes has to be split into 128 byte pieces.
        try write(chunk(type: 0, chunkStream: 2, messageType: 1, streamID: 0,
                        timestamp: 0, payload: be32(UInt32(outChunkSize))),
                  name: "set chunk size")

        let txn = nextTransaction()
        var body = AMF0.encode(.string("connect"))
        body.append(AMF0.encode(.number(txn)))
        body.append(AMF0.encode(.object([
            ("app", .string(app)),
            ("type", .string("nonprivate")),
            ("flashVer", .string("FMLE/3.0 (compatible; \(C.appName))")),
            ("tcUrl", .string(tcURL)),
        ])))
        let since = heardSoFar()
        try write(chunk(type: 0, chunkStream: controlChunk, messageType: 20,
                        streamID: 0, timestamp: 0, payload: body), name: "connect")
        return try waitReply(transaction: txn, since: since)
    }

    /// releaseStream, FCPublish and createStream, and the answer to the last.
    ///
    /// The answer is read by TRANSACTION (M1). Some servers answer
    /// releaseStream and FCPublish with a `_result` of their own, and taking
    /// the first `_result` in sight read one of those as the stream id.
    @discardableResult
    func createStream() throws -> RTMPHeard {
        // YouTube and Facebook both expect these two and smaller servers
        // ignore them, so nothing waits on them.
        for name in ["releaseStream", "FCPublish"] {
            let txn = nextTransaction()
            lock.lock(); unanswered.insert(txn); lock.unlock()
            var body = AMF0.encode(.string(name))
            body.append(AMF0.encode(.number(txn)))
            body.append(AMF0.encode(.null))
            body.append(AMF0.encode(.string(key)))
            try write(chunk(type: 0, chunkStream: controlChunk, messageType: 20,
                            streamID: 0, timestamp: 0, payload: body), name: name)
        }

        let txn = nextTransaction()
        var create = AMF0.encode(.string("createStream"))
        create.append(AMF0.encode(.number(txn)))
        create.append(AMF0.encode(.null))
        let since = heardSoFar()
        try write(chunk(type: 0, chunkStream: controlChunk, messageType: 20,
                        streamID: 0, timestamp: 0, payload: create), name: "createStream")
        let answer = try waitReply(transaction: txn, since: since)
        if answer.command == "_result", let id = answer.number, id >= 0, id < 4_294_967_295 {
            messageStreamID = UInt32(id)
        }
        return answer
    }

    /// The stream id the server handed back, for the checks.
    var streamID: UInt32 { messageStreamID }

    /// Say publish. Nothing is waited for here; see `waitPublishAnswer`.
    func publish(on chunkStream: UInt32) throws {
        let txn = nextTransaction()
        var publish = AMF0.encode(.string("publish"))
        publish.append(AMF0.encode(.number(txn)))
        publish.append(AMF0.encode(.null))
        publish.append(AMF0.encode(.string(key)))
        publish.append(AMF0.encode(.string("live")))
        lock.lock(); publishSeq = heardCount; lock.unlock()
        try write(chunk(type: 0, chunkStream: chunkStream, messageType: 20,
                        streamID: messageStreamID, timestamp: 0, payload: publish),
                  name: "publish")
    }

    /// What the server made of the publish.
    enum PublishAnswer {
        case accepted(RTMPHeard)
        case refused(RTMPHeard)
        /// It closed the connection, which after publish is a refusal.
        case hungUp
        case tooLarge
        /// Nothing, by the time given.
        case silent
    }

    /// Wait for the answer to publish, until `until` on the monotonic clock.
    ///
    /// Reads only what arrived AFTER the publish went out. An onStatus is a
    /// yes or a no by the accept rule; an `_error` is a no; the peer closing
    /// is `hungUp`. Sends nothing, ever.
    func waitPublishAnswer(until: TimeInterval) -> PublishAnswer {
        while true {
            lock.lock()
            let from = publishSeq
            let answer = heard.first { entry in
                entry.seq >= from && (entry.command == "onStatus"
                    || (entry.command == "_error" && !unanswered.contains(entry.transaction)))
            }
            let closed = closedByPeer
            let big = reader.tooLarge || overflowed
            lock.unlock()
            if let answer {
                return answer.isAcceptance ? .accepted(answer) : .refused(answer)
            }
            if big { return .tooLarge }
            if closed { return .hungUp }
            if ProcessInfo.processInfo.systemUptime >= until { return .silent }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// A refusal the server has sent since publish, or nothing.
    ///
    /// The pump asks this every turn. `publish` is not answered by every
    /// platform, so the absence of an answer is not an error and cannot be
    /// treated as one; the presence of a refusal always is.
    func refusal() -> String? {
        lock.lock(); defer { lock.unlock() }
        for entry in heard where entry.seq >= publishSeq {
            if entry.command == "_error", !unanswered.contains(entry.transaction) {
                return Self.saying(entry)
            }
            if entry.command == "onStatus", entry.level == "error" { return Self.saying(entry) }
            if RTMPClient.refusals.contains(entry.code) { return Self.saying(entry) }
        }
        return nil
    }

    /// What one of the server's refusals means, in a sentence.
    ///
    /// **Never the status code** (W384-07, M9). "NetStream.Publish.BadName"
    /// is a machine's name for a thing and VoiceOver reads it dot by dot; the
    /// platform's own DESCRIPTION is repeated instead, when it gave one,
    /// because "Publish Rejected: Invalid URL" is the one phrase somebody
    /// could search for. And BadName is what YouTube and Facebook say about a
    /// wrong key: "something is already publishing" was nginx-rtmp's meaning
    /// of it, which is not the server anybody here is talking to.
    static func saying(_ answer: RTMPHeard) -> String {
        saying(code: answer.code, description: answer.description)
    }

    static func saying(code: String, description: String = "") -> String {
        let base: String
        switch code {
        case "NetConnection.Connect.Rejected", "NetStream.Publish.Denied",
             "NetStream.Publish.BadName":
            base = "the server refused the stream key"
        case "NetConnection.Connect.InvalidApp":
            base = "that address has the wrong application name in it"
        default:
            base = "the server refused the stream"
        }
        var said = StreamKeyCheck.said(description)
        while said.hasSuffix(".") { said.removeLast() }
        return said.isEmpty ? base : "\(base). It said: \(said)"
    }

    // ------------------------------------------------------------- sending ---

    /// One FLV tag out. `timestamp` is milliseconds against the audio clock.
    func send(audio payload: Data, timestamp: Int) throws {
        try sendTag(chunkStream: audioChunk, messageType: 8,
                    payload: payload, timestamp: timestamp)
    }

    func send(video payload: Data, timestamp: Int) throws {
        try sendTag(chunkStream: videoChunk, messageType: 9,
                    payload: payload, timestamp: timestamp)
    }

    func send(metadata payload: Data) throws {
        try sendTag(chunkStream: controlChunk, messageType: 18,
                    payload: payload, timestamp: 0)
    }

    private func sendTag(chunkStream: UInt32, messageType: UInt8,
                         payload: Data, timestamp: Int) throws {
        // A type 0 header every time is four bytes more than a type 1 and is
        // what makes this recoverable: no chunk depends on the one before it,
        // so a message never has to be rebuilt because an earlier one moved.
        try write(chunk(type: 0, chunkStream: chunkStream, messageType: messageType,
                        streamID: messageStreamID, timestamp: timestamp,
                        payload: payload), name: "tag \(messageType)")
        lock.lock()
        _tagsSent += 1
        if messageType == 8 || messageType == 9 { _mediaBytesSent += payload.count }
        lock.unlock()
        lastStamp[chunkStream] = timestamp
    }

    // -------------------------------------------------------------- chunks ---

    private func chunk(type: UInt8, chunkStream: UInt32, messageType: UInt8,
                       streamID: UInt32, timestamp: Int, payload: Data) -> Data {
        var out = Data()
        out.append(UInt8((type << 6) | UInt8(chunkStream & 0x3f)))

        // Past 0xffffff the timestamp moves to an extended field at the end of
        // the header and the three byte one is all ones. A show over four
        // hours and a half reaches this, so it is not theoretical.
        let extended = timestamp >= 0xffffff
        let shown = extended ? 0xffffff : timestamp
        out.append(UInt8((shown >> 16) & 0xff))
        out.append(UInt8((shown >> 8) & 0xff))
        out.append(UInt8(shown & 0xff))

        out.append(UInt8((payload.count >> 16) & 0xff))
        out.append(UInt8((payload.count >> 8) & 0xff))
        out.append(UInt8(payload.count & 0xff))
        out.append(messageType)
        // The message stream id is the one little endian field in the whole
        // protocol, which is a wart of the format and not a mistake here.
        out.append(contentsOf: withUnsafeBytes(of: streamID.littleEndian) { Array($0) })
        if extended {
            out.append(contentsOf: be32(UInt32(timestamp)))
        }

        // Split into chunks, each continuation carrying a one byte type 3
        // header.
        var at = payload.startIndex
        var first = true
        while at < payload.endIndex {
            if !first {
                out.append(UInt8(0xc0 | UInt8(chunkStream & 0x3f)))
                if extended { out.append(contentsOf: be32(UInt32(timestamp))) }
            }
            let take = min(outChunkSize, payload.distance(from: at, to: payload.endIndex))
            let end = payload.index(at, offsetBy: take)
            out.append(payload[at..<end])
            at = end
            first = false
        }
        return out
    }

    private func be32(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
              UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }

    private func nextTransaction() -> Double {
        transaction += 1
        return transaction - 1
    }

    // ---------------------------------------------------------- the socket ---

    private func write(_ data: Data, name: String) throws {
        lock.lock()
        let connection = self.connection
        let talking = inConversation
        let left = deadline - ProcessInfo.processInfo.systemUptime
        lock.unlock()
        guard let connection else { throw RTMPError.dropped("the connection is gone") }
        if talking && left <= 0 { throw RTMPError.timedOut }
        let done = DispatchSemaphore(value: 0)
        let box = NSLock()
        var failure: String?
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { box.lock(); failure = Self.explain(error); box.unlock() }
            done.signal()
        })
        // During the conversation a write is bounded by what is left of it;
        // once the broadcast is under way, by twenty seconds of a receiver
        // whose window has closed for far too long to be a pause.
        if done.wait(timeout: .now() + (talking ? max(0.05, left) : 20)) == .timedOut {
            if talking { throw RTMPError.timedOut }
            throw RTMPError.dropped("the connection stopped accepting anything")
        }
        box.lock(); let why = failure; box.unlock()
        if let why { throw RTMPError.dropped(why) }
        lock.lock()
        _bytesSent += data.count
        if talking { _sent.append(name) }
        lock.unlock()
    }

    private func markClosed() {
        lock.lock(); closedByPeer = true; lock.unlock()
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, complete, error in
            guard let self else { return }
            self.lock.lock()
            if let data, !data.isEmpty {
                self.incoming.append(data)
                if self.handshakeDone {
                    self.drainMessages()
                } else if self.incoming.count > RTMPClient.preHandshakeLimit {
                    self.overflowed = true
                }
                // **No trimming** (M4). This used to keep only the last 64 KB,
                // which could cut a chunk in half and put the reader out of
                // step for the rest of the show. It does not need it: the
                // reader consumes every whole chunk, so what is left is at most
                // one chunk's worth, and the reader refuses any message over
                // its ceiling.
                if self.reader.tooLarge || self.overflowed { self.incoming.removeAll() }
            }
            let stop = complete || error != nil || self.reader.tooLarge || self.overflowed
            // **A close is recorded, and it ends the loop** (M3). A server
            // hanging up used to look exactly like a server saying nothing,
            // which is how YouTube's answer to a wrong key went unseen; and a
            // read error re-armed the read at once, which on a dead connection
            // is a loop with nothing in it to slow it down.
            if stop { self.closedByPeer = true }
            self.lock.unlock()
            if stop { return }
            self.receiveLoop(connection)
        }
    }

    /// Take whole messages out of the buffer and remember what they said.
    /// Called with the lock held.
    private func drainMessages() {
        guard handshakeDone else { return }
        for message in reader.read(from: &incoming) where message.type == 20 {
            let values = AMF0.read(message.payload)
            guard AMF0.firstString(in: values) != nil else { continue }
            heard.append(RTMPHeard(seq: heardCount, values: values))
            heardCount += 1
            if heard.count > RTMPClient.keepHeard {
                heard.removeFirst(heard.count - RTMPClient.keepHeard)
            }
        }
    }

    private func heardSoFar() -> Int {
        lock.lock(); defer { lock.unlock() }
        return heardCount
    }

    private func read(_ count: Int) throws -> Data {
        while true {
            lock.lock()
            if incoming.count >= count {
                let out = incoming.prefix(count)
                incoming.removeFirst(count)
                lock.unlock()
                return Data(out)
            }
            let closed = closedByPeer
            let big = overflowed
            let left = deadline - ProcessInfo.processInfo.systemUptime
            lock.unlock()
            if big { throw RTMPError.tooLarge }
            if closed { throw RTMPError.hungUp }
            if left <= 0 { throw RTMPError.timedOut }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Wait for the `_result` or `_error` that answers one transaction.
    ///
    /// Asks the REASSEMBLER, not the raw bytes: a command name is split across
    /// chunk boundaries as a matter of course, so looking for one in what
    /// arrived finds it only when the reply happens to be short. YouTube's is
    /// not, and that is exactly how this shipped broken. Bounded by the one
    /// deadline, checked on every turn, so a server sending a ping every fifty
    /// milliseconds cannot keep it here.
    private func waitReply(transaction: Double, since: Int) throws -> RTMPHeard {
        while true {
            lock.lock()
            let answer = heard.first { entry in
                entry.seq >= since && entry.transaction == transaction
                    && (entry.command == "_result" || entry.command == "_error")
            }
            let closed = closedByPeer
            let big = reader.tooLarge || overflowed
            let left = deadline - ProcessInfo.processInfo.systemUptime
            lock.unlock()
            if let answer {
                lock.lock(); lastAnswer = answer; lock.unlock()
                return answer
            }
            if big { throw RTMPError.tooLarge }
            if closed { throw RTMPError.hungUp }
            if left <= 0 { throw RTMPError.timedOut }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// The last answer a wait returned, for a caller that wants the words.
    private(set) var lastAnswer: RTMPHeard?

    static let refusals: Set<String> = [
        "NetConnection.Connect.Rejected", "NetStream.Publish.Denied",
        "NetConnection.Connect.InvalidApp", "NetStream.Publish.BadName",
        "NetConnection.Connect.Failed",
    ]

    /// Hang up. **Sends nothing**: no FCUnpublish, no deleteStream. The key
    /// check depends on that, and a broadcast that is ending has nothing left
    /// worth saying to a server that is about to see the socket close.
    func close() {
        lock.lock()
        connected = false
        let made = connection
        connection = nil
        lock.unlock()
        made?.cancel()
    }
}
