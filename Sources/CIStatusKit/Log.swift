import Foundation

/// File logging for a menu bar app.
///
/// There is no stdout to print to: launched from Finder the process has nowhere
/// useful to write, and a crash report says nothing about why a source is
/// reporting grey. So everything that explains what the app is doing goes to a
/// file the user can open from the menu.
///
/// ## Never logs a secret
///
/// Every line passes through `redact`, which masks anything registered as a
/// secret as well as the token formats the supported services issue. A token
/// that reaches an API is out of our hands, but one that reaches the log file is
/// ours, and this is the last place that can catch it.
///
/// ## Failure is never fatal
///
/// Logging is best effort. If the file cannot be written, messages are dropped
/// rather than thrown, because a broken log must not stop the poll loop.
public enum Log {
    public enum Level: String, Comparable, Sendable, CaseIterable {
        case debug, info, warning, error

        private var rank: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warning: return 2
            case .error: return 3
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
    }

    /// Where lines are written. Tests replace this to keep output in memory.
    public protocol Sink: AnyObject, Sendable {
        func write(_ line: String)
    }

    // MARK: - Configuration

    private static let lock = NSLock()
    private static var _level: Level = .info
    private static var _sink: Sink?

    /// Redirects output, for tests. Nil restores file logging.
    public static func useSink(_ sink: Sink?) {
        lock.withLock { _sink = sink }
    }

    /// Values registered as secret and masked out of every line.
    private static var secrets: Set<String> = []

    public static var level: Level {
        get { lock.withLock { _level } }
        set { lock.withLock { _level = newValue } }
    }

    /// `~/Library/Logs/CIStatus/ciStatus.log`, the conventional macOS location.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/CIStatus", isDirectory: true)
            .appendingPathComponent("ciStatus.log")
    }

    /// Starts writing to `url`, rotating it once it grows past 1 MB.
    ///
    /// `CISTATUS_LOG_FILE` and `CISTATUS_LOG_LEVEL` override the defaults, which
    /// is how you get a log without changing anything in the UI.
    public static func configure(url: URL? = nil, level: Level? = nil) {
        let environment = ProcessInfo.processInfo.environment
        let resolvedLevel = level
            ?? environment["CISTATUS_LOG_LEVEL"].flatMap(Level.init(rawValue:))
            ?? .info
        let resolvedURL: URL? = {
            if let override = environment["CISTATUS_LOG_FILE"], !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return url ?? defaultURL
        }()

        lock.withLock {
            _level = resolvedLevel
            _sink = resolvedURL.map { FileSink(url: $0) }
            secrets.removeAll()
        }
        info("logging to \(resolvedURL?.path ?? "nowhere") at level \(resolvedLevel.rawValue)")
    }

    /// Where the log file is, for the menu item that reveals it.
    public static func currentURL() -> URL? {
        let sink = lock.withLock { _sink }
        return (sink as? FileSink)?.url
    }

    /// Registers values to be masked from every subsequent line.
    ///
    /// Called with the stored tokens once they are known, so a token that turns
    /// up inside an error body from a provider is still masked.
    public static func registerSecret(_ value: String?) {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return }
        lock.withLock { _ = secrets.insert(trimmed) }
    }

    public static func forgetSecrets() {
        lock.withLock { secrets.removeAll() }
    }

    // MARK: - Writing

    public static func debug(_ message: @autoclosure () -> String) {
        write(.debug, message())
    }

    public static func info(_ message: @autoclosure () -> String) {
        write(.info, message())
    }

    public static func warning(_ message: @autoclosure () -> String) {
        write(.warning, message())
    }

    public static func error(_ message: @autoclosure () -> String) {
        write(.error, message())
    }

    private static func write(_ level: Level, _ message: String) {
        // Snapshotted under the lock so a level change or a new sink cannot tear
        // a line in half from another thread.
        let (sink, threshold, known) = lock.withLock { (_sink, _level, secrets) }
        guard level >= threshold, let sink else { return }

        let line = format(level: level, message: message, secrets: known)
        sink.write(line)
    }

    static func format(level: Level, message: String, secrets: Set<String>) -> String {
        let timestamp = ISO8601DateFormatter.logging.string(from: Date())
        return "\(timestamp) \(level.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)) "
            + "\(redact(message, secrets: secrets))\n"
    }

    /// Masks secrets and anything shaped like a token.
    ///
    /// `secrets` catches the exact stored value. The patterns catch a token from
    /// a service we have no stored copy of, and a partially quoted one.
    static func redact(_ message: String, secrets: Set<String>) -> String {
        var result = message
        for secret in secrets {
            guard secret.count >= 8 else { continue }
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }
        let patterns = [
            "gh[pousr]_[A-Za-z0-9]{16,}",
            "github_pat_[A-Za-z0-9_]{20,}",
            "vercel_[A-Za-z0-9]{16,}",
            "sk-[A-Za-z0-9_-]{16,}",
            "sntrs_[A-Za-z0-9_-]{16,}",
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern, with: "<redacted>", options: .regularExpression)
        }
        return result
    }
}

/// A sink that appends to a file, rotating at 1 MB and keeping three copies.
///
/// Truncates a too-long line rather than letting it grow, because an API error
/// body can be megabytes and one of those would bury everything after it.
final class FileSink: Log.Sink, @unchecked Sendable {
    private static let maxBytes = 1_048_576
    private static let keptRotations = 3
    private static let maxLineBytes = 4_096

    let url: URL
    /// Reopened after a rotation, so this is a var rather than a let.
    private var handle: FileHandle?
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
        rotateIfNeeded()
        // Append, so restarting the app keeps the history that explains why the
        // previous run misbehaved.
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        guard let data = truncated(line).data(using: .utf8) else { return }
        handle.write(data)
        rotateIfNeeded()
    }

    /// A single line longer than the cap is cut, so one huge error body cannot
    /// evict the entire log.
    private func truncated(_ line: String) -> String {
        guard line.utf8.count > Self.maxLineBytes else { return line }
        let prefix = String(line.prefix(Self.maxLineBytes))
        return prefix + "\n… [line truncated at \(Self.maxLineBytes) bytes]\n"
    }

    private func rotateIfNeeded() {
        let manager = FileManager.default
        guard let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int,
              size >= Self.maxBytes else { return }

        // Oldest goes first, so the numbering always ends at .1 being newest.
        let oldest = url.appendingPathExtension("\(Self.keptRotations)")
        try? manager.removeItem(at: oldest)
        for index in stride(from: Self.keptRotations - 1, through: 1, by: -1) {
            let from = url.appendingPathExtension("\(index)")
            let to = url.appendingPathExtension("\(index + 1)")
            try? manager.moveItem(at: from, to: to)
        }
        try? manager.moveItem(at: url, to: url.appendingPathExtension("1"))
        manager.createFile(atPath: url.path, contents: nil)
        try? handle?.close()
        handle = try? FileHandle(forWritingTo: url)
    }
}

/// Collects lines in memory, for tests.
final class MemorySink: Log.Sink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    var text: String { lines.joined() }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }

    func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(line)
    }
}

extension ISO8601DateFormatter {
    /// Second precision, which is enough to order events and short enough not to
    /// dominate the file.
    static let logging: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
