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
    private var config: Config?
    private var task: Task<Void, Never>?

    public init() {}

    /// The health shown in the menu bar icon.
    public var overall: Health { statuses.overall }

    /// Reads the config, then starts the loop. Safe to call repeatedly.
    public func start(configURL: URL) {
        stop()
        do {
            let loaded = try Config.load(from: configURL)
            config = loaded
            configError = nil
            if let interval = loaded.pollIntervalSeconds, interval > 0 {
                intervalSeconds = interval
            }
        } catch {
            config = nil
            configError = "Could not read config: \(error.localizedDescription)"
            statuses = []
            return
        }
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

        let results = await withTaskGroup(of: SourceStatus.self) { group in
            for source in config.sources {
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
        for (offset, source) in config.sources.enumerated() {
            order[source.name] = offset
        }
        let position: (SourceStatus) -> Int = { order[$0.id] ?? Int.max }
        statuses = results.sorted { position($0) < position($1) }
        lastChecked = Date()
    }
}
