import Foundation

/// Where API tokens are kept: one JSON file, readable only by you.
///
/// This replaced the login Keychain, which prompted on every rebuild. On the
/// legacy login keychain an item's ACL trusts the creating app by code signature,
/// and this app is re-signed by `build-app.sh` on every build, so each new build
/// was a new signature and therefore a new "ciStatus wants to use your
/// confidential information" dialog. `kSecAttrAccessibleWhenUnlocked` does not
/// avoid that on the login keychain; it is the data protection keychain that
/// isolates per app, and that needs a signing entitlement an ad-hoc build does
/// not have.
///
/// ## What this costs, plainly
///
/// The file is plaintext on disk, so anything running as you can read it, and an
/// unencrypted Time Machine backup will contain it. It is mode 600, so other
/// accounts cannot, and it is gitignored.
///
/// That is the same exposure as a `.env` file, which is the arrangement most
/// tools use, and it is the simplest thing that does not ask you to click Allow.
/// If a token must be unreadable to other local processes, put it in the login
/// Keychain and accept the prompt on each rebuild.
public enum TokenStore {
    /// `~/Library/Application Support/CIStatus/tokens.json`, next to the config.
    /// `CISTATUS_TOKENS` overrides it, which is how tests and side-by-side runs
    /// avoid touching the real file.
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["CISTATUS_TOKENS"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CIStatus", isDirectory: true)
            .appendingPathComponent("tokens.json")
    }

    public enum StoreError: Error, LocalizedError, Equatable {
        case unwritable(String)

        public var errorDescription: String? {
            switch self {
            case let .unwritable(path):
                return "Could not write \(path)."
            }
        }
    }

    private static let lock = NSLock()

    /// Cached for the life of the process, so a poll of ten sources reads the
    /// file once rather than ten times.
    private static var cache: [Source.Kind: String]?
    /// Overridden by the tests so they never touch the real file.
    static var overrideURL: URL?
    /// Answered instead of reading the file, for tests.
    static var readerOverride: (() -> [Source.Kind: String])?

    /// The file in use, so a caller can tell the user where it is.
    public static var fileURL: URL { overrideURL ?? defaultURL }

    private static var url: URL { fileURL }

    // MARK: - Reading

    /// Every stored token, trimmed, with blanks dropped.
    ///
    /// A missing file is not an error and yields nothing: a fresh install has no
    /// tokens, and that is an ordinary state rather than a failure to report.
    public static func all() -> [Source.Kind: String] {
        lock.lock(); defer { lock.unlock() }
        if let readerOverride { return readerOverride() }
        if let cache { return cache }

        var result: [Source.Kind: String] = [:]
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8),
           let parsed = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) {
            for (key, value) in parsed {
                guard let kind = Source.Kind(rawValue: key) else {
                    // An unknown service is ignored rather than fatal: the file
                    // may have been written by a newer build, and losing one
                    // token should not lose the others.
                    Log.warning("token file has an unknown service \"\(key)\"; ignoring it")
                    continue
                }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result[kind] = trimmed }
            }
        }
        cache = result
        return result
    }

    /// The token for one service, or nil when there is none.
    public static func token(for kind: Source.Kind) -> String? {
        all()[kind]
    }

    public static func hasToken(for kind: Source.Kind) -> Bool {
        all()[kind] != nil
    }

    // MARK: - Writing

    /// Stores a token, replacing any existing one for that service.
    ///
    /// The file is written atomically and then chmod'd, so a crash mid-write
    /// cannot leave a half-written token file that reads as corrupt.
    public static func save(_ token: String, for kind: Source.Kind) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.unwritable("an empty token") }

        var tokens = all()
        tokens[kind] = trimmed

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Dictionary(uniqueKeysWithValues:
            tokens.map { ($0.key.rawValue, $0.value) }))
        try write(data)
        lock.lock(); cache = tokens; lock.unlock()
    }

    /// Removes a service's token. Reports whether there was one.
    @discardableResult
    public static func delete(for kind: Source.Kind) throws -> Bool {
        var tokens = all()
        let existed = tokens.removeValue(forKey: kind) != nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Dictionary(uniqueKeysWithValues:
            tokens.map { ($0.key.rawValue, $0.value) }))
        try write(data)
        lock.lock(); cache = tokens; lock.unlock()
        return existed
    }

    private static func write(_ data: Data) throws {
        let target = url
        let manager = FileManager.default
        let directory = target.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        } catch {
            throw StoreError.unwritable(directory.path)
        }
        do {
            try data.write(to: target, options: .atomic)
            // Applied after the write because `Data.write` creates the file with
            // the process umask, which is typically 644 — readable by other
            // accounts until this runs.
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch {
            throw StoreError.unwritable(target.path)
        }
    }

    // MARK: - Tests

    public enum TestSupport {
        /// Points the store at a temporary file. Nil restores the real one.
        public static func use(url: URL?) {
            lock.lock()
            overrideURL = url
            cache = nil
            readerOverride = nil
            lock.unlock()
        }

        /// Answers reads from a fixture, for tests that only need presence.
        public static func useReader(_ reader: @escaping () -> [Source.Kind: String]) {
            lock.lock()
            readerOverride = reader
            cache = nil
            lock.unlock()
        }

        /// Drops the cache so the next read hits the file again.
        public static func invalidate() {
            lock.lock(); cache = nil; lock.unlock()
        }
    }
}
