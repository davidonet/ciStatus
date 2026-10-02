import Foundation

/// Owns the polling loop and the last known state of every source.
@MainActor
public final class Monitor: ObservableObject {
    @Published public private(set) var statuses: [SourceStatus] = []
    @Published public private(set) var lastChecked: Date?
    @Published public private(set) var isLoading = false
    @Published public private(set) var configError: String?
    @Published public var intervalSeconds: Int = 60

    private let http = HTTP()
    private var task: Task<Void, Never>?

    public init() {}

    /// The health shown in the menu bar icon.
    public var overall: Health { statuses.overall }

    /// The config currently in force, exposed so the settings window edits the
    /// same object the poll loop uses.
    @Published public private(set) var config: Config?

    /// Where the config was read from, so edits go back to the same file.
    public private(set) var configURL: URL?

    /// Reads the config, then starts the loop. Safe to call repeatedly.
    public func start(configURL: URL) {
        stop()
        self.configURL = configURL
        Log.info("reading config from \(configURL.path)")

        do {
            // A missing file is not an error: it just means nothing has been
            // configured yet, which is the state right after installing.
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                config = Config()
                configError = nil
                statuses = []
                Log.info("no config file yet; nothing to poll. Use Settings… to add targets.")
                startLoop()
                return
            }
            let loaded = try Config.load(from: configURL)
            config = loaded
            configError = nil
            if let interval = loaded.pollIntervalSeconds, interval > 0 {
                intervalSeconds = interval
            }
            logSummary(of: loaded)
        } catch {
            config = nil
            configError = "Could not read config: \(error.localizedDescription)"
            statuses = []
            Log.error("could not read config: \(error.localizedDescription)")
            return
        }
        startLoop()
    }

    /// Records what the config asked for, and the thing most often wrong: a
    /// service with targets but no token switched on.
    ///
    /// That combination is the reason a configured app shows only grey, and it is
    /// invisible from the config alone, so it is worth a line of its own.
    private func logSummary(of config: Config) {
        let services = config.expandedSources
        Log.info("config loaded: \(services.count) row(s) across "
                 + "\(config.services.enabledTargetsDescription)")

        for kind in Source.Kind.allCases {
            let targets = config.tokens.isEnabled(kind)
                ? config.services.targets(for: kind).count : 0
            let token = TokenStore.token(for: kind)
            if targets > 0 && !config.tokens.isEnabled(kind) {
                Log.error("\(kind.displayName): \(targets) target(s) configured but "
                          + "\"tokens\": { \"\(kind.rawValue)\": true } is missing, so none "
                          + "of them will be polled. Store the token in Settings or run "
                          + "\"probe --store-token \(kind.rawValue) <token>\".")
            } else if config.tokens.isEnabled(kind) && token == nil && targets > 0 {
                Log.warning("\(kind.displayName): enabled but no token is stored; "
                            + "its rows will report as unreachable.")
            } else if config.tokens.isEnabled(kind) {
                Log.info("\(kind.displayName): enabled, token "
                         + (token == nil ? "not stored" : "present") + ", \(targets) target(s)")
            }
        }

        if services.isEmpty {
            Log.warning("no targets configured; the dot will be grey. Add one in Settings…")
        }
        // Registered so a token echoed back inside an error body is masked.
        Log.forgetSecrets()
        for (_, token) in TokenStore.all() { Log.registerSecret(token) }
    }

    /// The polling loop itself, separate from reading the config so an empty or
    /// missing config still refreshes rather than leaving a stale icon.
    private func startLoop() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let seconds = self?.intervalSeconds ?? 60
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 15)) * 1_000_000_000)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Polls all sources concurrently so a slow API does not serialise the rest.
    public func refresh() async {
        guard let config, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let sources = config.expandedSources

        let results = await withTaskGroup(of: SourceStatus.self) { group in
            for source in sources {
                group.addTask { [http] in
                    switch source.kind {
                    case .github: return await GitHubProvider(http: http, source: source).poll()
                    case .vercel: return await VercelProvider(http: http, source: source).poll()
                    case .sentry: return await SentryProvider(http: http, source: source).poll()
                    }
                }
            }
            var collected: [SourceStatus] = []
            for await status in group { collected.append(status) }
            return collected
        }

        // Keep the config order so the menu does not shuffle between refreshes.
        var order: [String: Int] = [:]
        for (offset, source) in sources.enumerated() {
            order[source.name] = offset
        }
        let position: (SourceStatus) -> Int = { order[$0.id] ?? Int.max }
        statuses = results.sorted { position($0) < position($1) }
        lastChecked = Date()

        // One line per row, so "configured but grey" can be read straight off the
        // log without reproducing it in the UI.
        for status in statuses {
            let line = "poll \(status.name): \(status.health) — \(status.summary)"
                + (status.detail.map { " (\($0))" } ?? "")
            switch status.health {
            case .ok: Log.info(line)
            case .pending: Log.info(line)
            case .unknown: Log.warning(line)
            case .failing: Log.error(line)
            }
        }
        Log.info("poll finished: overall \(overall) from \(results.count) row(s)")
    }

    /// Writes a new config and immediately starts polling it.
    ///
    /// The file is written before the poll restarts, so a save that fails on
    /// disk leaves the running app on the config it already had rather than
    /// showing an edit that was never persisted.
    @discardableResult
    public func apply(_ new: Config) -> Bool {
        guard let url = configURL else {
            configError = "No config path is known yet."
            Log.error("apply: no config path known yet")
            return false
        }
        do {
            try new.save(to: url)
            Log.info("saved config to \(url.path)")
            config = new
            configError = nil
            if let interval = new.pollIntervalSeconds, interval > 0 {
                intervalSeconds = interval
            }
            start(configURL: url)
            return true
        } catch {
            configError = "Could not save config: \(error.localizedDescription)"
            Log.error("could not save config: \(error.localizedDescription)")
            return false
        }
    }
}
