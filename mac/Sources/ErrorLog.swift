// Faults that would otherwise vanish without a trace.
//
// The Mac half of Windows 3.8.3's `errorlog.py`. An Objective-C exception
// raised inside a menu action or a key handler is caught by AppKit, written to
// a console nobody is reading, and the app carries on: the key simply did
// nothing. That is exactly the shape of Mashal's report on Windows, a
// microphone key doing nothing at all with nothing anywhere to say why.
//
// So every such fault is written to `errors.log` beside the board, with its
// whole call stack, where support can ask for it; and a one line summary,
// WHERE and WHAT KIND, is kept for the feedback window. Never the reason: an
// exception's reason can carry a file path or a sound's name, and the feedback
// promise is that neither is ever sent.
//
// Nothing here speaks, because a fault in a timer can repeat four times a
// second and a fault that turns into an announcement at a random moment in a
// show is a new fault. And nothing here may raise, or the safety net becomes
// the fall.

import AppKit

/// The application, with one addition: an exception AppKit catches is written
/// down before AppKit carries on. **Named in Info.plist as NSPrincipalClass**,
/// which has to stay there and has to name a real NSApplication: without it the
/// app does not activate properly and nothing says why. The Objective-C name is
/// fixed so the plist does not depend on the Swift module name.
@objc(DropDeckApplication)
final class DropDeckApplication: NSApplication {
    override func reportException(_ exception: NSException) {
        ErrorLog.record(exception, thread: Thread.isMainThread ? "main" : nil)
        super.reportException(exception)
    }
}

enum ErrorLog {

    static let fileName = "errors.log"
    /// Past this the log starts again, keeping the most recent half. A log
    /// that grows for ever on somebody's disk is its own bug.
    static let maxBytes = 256 * 1024
    /// How many summaries the feedback window gets.
    static let keep = 8

    private static var recentLines: [String] = []
    private static let lock = NSLock()
    private static var installed = false

    /// Where the log goes. The self test points this somewhere of its own, so
    /// it never writes beside a real board.
    static var pathOverride: String?

    static var path: String {
        pathOverride ?? (Board.configDir() as NSString).appendingPathComponent(fileName)
    }

    // ----------------------------------------------------------- recording ---

    /// Write one exception down. Returns its one line summary. Never raises.
    @discardableResult
    static func record(_ exception: NSException, thread: String? = nil) -> String {
        record(kind: exception.name.rawValue, symbols: exception.callStackSymbols,
               detail: exception.reason ?? "", thread: thread)
    }

    /// The same, for anything that is not an NSException: a fault the app
    /// caught itself and wants on file. `detail` goes to the log only.
    @discardableResult
    static func record(kind: String, symbols: [String] = Thread.callStackSymbols,
                       detail: String = "", thread: String? = nil) -> String {
        let line = "\(whereIn(symbols)): \(kind)"
        lock.lock()
        if !recentLines.contains(line) {
            recentLines.append(line)
            if recentLines.count > keep { recentLines.removeFirst(recentLines.count - keep) }
        }
        lock.unlock()
        write(kind: kind, detail: detail, symbols: symbols, thread: thread)
        return line
    }

    /// What went wrong this session, as "where: Kind" lines.
    static func recent() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return recentLines
    }

    /// Catch what AppKit does not: an exception thrown on a thread of our own,
    /// or one that escapes altogether. Safe to call more than once. The one
    /// reported on the way down is on disk before the process ends.
    static func install() {
        lock.lock()
        let first = !installed
        installed = true
        lock.unlock()
        guard first else { return }
        NSSetUncaughtExceptionHandler { exception in
            ErrorLog.record(exception, thread: "uncaught")
        }
    }

    // ------------------------------------------------------------- where ---

    /// The innermost place in THIS app's code, as "Type.function".
    ///
    /// The innermost frame is usually inside AppKit or Foundation, which says
    /// nothing about which of our commands failed. The first frame that
    /// belongs to our own binary does.
    static func whereIn(_ symbols: [String]) -> String {
        let binary = (Bundle.main.executablePath as NSString?)?.lastPathComponent ?? "TGDropDeck"
        for frame in symbols {
            let fields = frame.split(separator: " ", omittingEmptySubsequences: true)
            // "3   TGDropDeck   0x0000000100abc123 symbol + 45"
            guard fields.count >= 4, fields[1] == binary || fields[1] == "TGDropDeck"
            else { continue }
            let symbol = fields[3...].prefix { $0 != "+" }.joined(separator: " ")
            return readable(symbol)
        }
        return "unknown"
    }

    /// A Swift symbol as "Type.function", or as it came when it is not one.
    static func readable(_ symbol: String) -> String {
        var name = demangle(symbol) ?? symbol
        // "TGDropDeck.MainWindow.toggleMic() -> ()" to "MainWindow.toggleMic".
        if let paren = name.firstIndex(of: "(") { name = String(name[..<paren]) }
        for prefix in ["TGDropDeck.", "@objc TGDropDeck."] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        return name.isEmpty ? symbol : name
    }

    private typealias Demangler = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
        UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    /// The Swift runtime's own demangler, asked for by name. nil when it is
    /// not there or the symbol is not a Swift one.
    private static func demangle(_ symbol: String) -> String? {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s"),
              let handle = dlopen(nil, RTLD_NOW),
              let found = dlsym(handle, "swift_demangle") else { return nil }
        let call = unsafeBitCast(found, to: Demangler.self)
        return symbol.withCString { raw -> String? in
            guard let out = call(raw, strlen(raw), nil, nil, 0) else { return nil }
            defer { free(out) }
            return String(cString: out)
        }
    }

    // ------------------------------------------------------------ writing ---

    private static func write(kind: String, detail: String, symbols: [String],
                              thread: String?) {
        let target = path
        let stamp: String = {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return format.string(from: Date())
        }()
        let who = thread ?? (Thread.isMainThread ? "main" : (Thread.current.name ?? "a worker"))
        var entry = "=== \(stamp)  version \(C.appVersion)  thread \(who)\n\(kind)"
        if !detail.isEmpty { entry += ": \(detail)" }
        entry += "\n" + symbols.joined(separator: "\n") + "\n\n"

        lock.lock(); defer { lock.unlock() }
        let files = FileManager.default
        try? files.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
        if let size = (try? files.attributesOfItem(atPath: target))?[.size] as? NSNumber,
           size.intValue > maxBytes,
           let data = files.contents(atPath: target) {
            let kept = data.suffix(maxBytes / 2)
            try? Data(kept).write(to: URL(fileURLWithPath: target))
        }
        guard let bytes = entry.data(using: .utf8) else { return }
        if !files.fileExists(atPath: target) {
            files.createFile(atPath: target, contents: bytes)
            return
        }
        guard let handle = FileHandle(forWritingAtPath: target) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: bytes)
    }

    // ----------------------------------------------------------- crashes ---

    /// How many crash reports macOS has kept for this app in the last week.
    ///
    /// A Swift fault stops the process outright and no handler here sees it;
    /// macOS writes it down instead, and a feedback report saying there is one
    /// is what tells support to ask for it. A count, never the report.
    static func recentCrashReports(now: Date = Date(),
                                   folder: String = NSHomeDirectory()
                                     + "/Library/Logs/DiagnosticReports") -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder)
        else { return 0 }
        let week = now.addingTimeInterval(-7 * 24 * 3600)
        return names.filter { name in
            guard name.hasPrefix("TGDropDeck") else { return false }
            let full = (folder as NSString).appendingPathComponent(name)
            let when = (try? FileManager.default.attributesOfItem(atPath: full))?[.modificationDate]
                as? Date
            return (when ?? .distantPast) > week
        }.count
    }
}
