import Foundation

/// Reports GitHub Actions status for a branch.
///
/// There are two ways to ask GitHub what CI is doing, and they need different
/// token permissions:
///
/// - `.checks` reads the Checks API (`/commits/{ref}/check-runs`). This is the
///   richer source: it includes checks posted by third party apps such as
///   Vercel or CircleCI, not just GitHub's own workflows. It needs the
///   `Checks: read` permission on a fine grained token.
/// - `.actions` reads the Actions API (`/actions/runs`). This only sees
///   GitHub's own workflows, but it needs `Actions: read`, which is far more
///   commonly available. `Checks` is not offered for every account, so this is
///   the fallback that keeps the app working without it.
///
/// `.auto` tries `.checks` and falls back to `.actions` when GitHub refuses the
/// request for lack of permission, which is why the fallback has to be
/// automatic rather than something you configure by hand.
public struct GitHubProvider: Sendable {
    public enum Strategy: String, Decodable, Sendable {
        case auto
        case checks
        case actions
    }

    public struct CheckRunsResponse: Decodable {
        public struct CheckRun: Decodable {
            public let name: String
            public let status: String
            public let conclusion: String?
            public let html_url: String?
        }
        public let total_count: Int
        public let check_runs: [CheckRun]
    }

    public struct WorkflowRunsResponse: Decodable {
        public struct WorkflowRun: Decodable {
            public let id: Int
            public let name: String?
            public let path: String?
            public let display_title: String?
            public let head_branch: String?
            public let head_sha: String
            public let event: String?
            public let status: String?
            public let conclusion: String?
            public let html_url: String?
            public let created_at: String?

            /// Prefers the workflow name, falling back to the file so a run is
            /// never left nameless in the menu.
            var label: String {
                if let name, !name.isEmpty { return name }
                if let path, !path.isEmpty { return path }
                return "run \(id)"
            }
        }
        public let total_count: Int
        public let workflow_runs: [WorkflowRun]
    }

    public struct StatusResponse: Decodable {
        public struct State: Decodable {
            public let context: String
            public let state: String
            public let target_url: String?
        }
        public let state: String
        public let sha: String?
        public let statuses: [State]
    }

    /// One CI signal, normalised so both strategies can share the roll-up.
    struct Signal {
        let name: String
        let state: State
        let url: URL?

        enum State {
            case passing
            case pending
            case failing
        }
    }

    /// What one strategy found, plus how many items were cut off by pagination.
    struct Result {
        let signals: [Signal]
        let used: Strategy
        /// Items beyond the page cap. Never folded into `signals`, because a
        /// made up signal would distort both the counts and the roll-up.
        let omitted: Int

        init(_ signals: [Signal], _ used: Strategy, omitted: Int = 0) {
            self.signals = signals
            self.used = used
            self.omitted = omitted
        }
    }

    let http: HTTP
    let source: Config.Source
    let strategy: Strategy

    /// Set to a non-`.auto` strategy to bypass the Checks API entirely, which
    /// is what the tests use to exercise the Actions path without a network.
    static var forcedStrategy: Strategy?

    public init(http: HTTP, source: Config.Source) {
        self.http = http
        self.source = source
        self.strategy = Self.forcedStrategy ?? source.strategy ?? .auto
    }

    public func poll() async -> SourceStatus {
        let name = source.name
        let owner = source.owner
        let repo = source.repo
        let branch = source.branch
        do {
            guard let owner, let repo, let branch else {
                return .init(id: name, name: name, health: .unknown,
                             summary: "owner, repo and branch are required",
                             detail: nil, url: nil, failingItems: [])
            }
            guard let token = source.token(), !token.isEmpty else {
                throw ConfigError.missingToken(source: name, env: source.tokenEnv ?? "<unset>")
            }
            guard let base = URL(string: "https://api.github.com/repos/\(owner)/\(repo)") else {
                throw HTTPError.badURL("https://api.github.com/repos/\(owner)/\(repo)")
            }

            let result: Result
            switch strategy {
            case .checks:
                // Pinned: a permission problem is reported rather than quietly
                // falling back to a source that sees less.
                result = try await checkRuns(base: base, branch: branch, token: token)
            case .actions:
                result = try await workflowRuns(base: base, branch: branch, token: token)
            case .auto:
                do {
                    result = try await checkRuns(base: base, branch: branch, token: token)
                } catch is PermissionError {
                    result = try await workflowRuns(base: base, branch: branch, token: token)
                }
            }

            let signals = result.signals
            let detail = "\(owner)/\(repo) @ \(branch)"
                + (result.used == .actions ? " · actions only" : "")

            if signals.isEmpty {
                return .init(id: name, name: name, health: .ok,
                             summary: "no checks on \(branch)", detail: detail,
                             url: source.resolvedDashboardURL, failingItems: [])
            }

            let failing = signals.filter { $0.state == .failing }
            let pending = signals.filter { $0.state == .pending }
            let passed = signals.count - failing.count - pending.count

            let health: Health = !failing.isEmpty ? .failing : (!pending.isEmpty ? .pending : .ok)
            var summary = "\(passed) passed"
                + (failing.isEmpty ? "" : ", \(failing.count) failed")
                + (pending.isEmpty ? "" : ", \(pending.count) running")
            // GitHub caps the page at 100. A partial page must not be presented
            // as the whole picture, or a failure beyond the cap reads as green.
            if result.omitted > 0 {
                summary += " (\(result.omitted) more not shown)"
                // Treat an incomplete view as pending, never as all clear.
                return .init(id: name, name: name, health: .pending, summary: summary,
                             detail: detail, url: source.resolvedDashboardURL,
                             failingItems: failing.map { "\($0.name)" })
            }

            return .init(id: name, name: name, health: health, summary: summary,
                         detail: detail, url: source.resolvedDashboardURL,
                         failingItems: failing.map { "\($0.name)" })
        } catch HTTPError.status(404, _) {
            return .init(id: name, name: name, health: .unknown, summary: "not found",
                         detail: "check owner, repo and that the token can see this repository",
                         url: source.resolvedDashboardURL, failingItems: [])
        } catch HTTPError.status(422, _) {
            // GitHub could not resolve the ref, which is a configuration mistake
            // rather than a transient failure.
            let where_ = "\(owner ?? "?")/\(repo ?? "?")"
            return .init(id: name, name: name, health: .unknown, summary: "branch not found",
                         detail: "\(where_) has no branch \"\(branch ?? "?")\"",
                         url: source.resolvedDashboardURL, failingItems: [])
        } catch is PermissionError where strategy != .auto {
            // Auto already retried, so reaching here means the user pinned
            // "checks" and the token cannot use it. Say so, with the fix.
            return .init(id: name, name: name, health: .unknown,
                         summary: "checks not permitted",
                         detail: checksPermissionAdvice,
                         url: source.resolvedDashboardURL, failingItems: [])
        } catch {
            return .init(id: name, name: name, health: .unknown, summary: "unreachable",
                         detail: error.localizedDescription,
                         url: source.resolvedDashboardURL, failingItems: [])
        }
    }

    // MARK: - Strategies

    /// The Checks API. Fails with `PermissionError` when the token cannot read
    /// check runs, which is the signal to fall back to Actions.
    private func checkRuns(base: URL, branch: String, token: String) async throws -> Result {
        let url = base.appendingPathComponent("commits/\(branch)/check-runs")
            .appending(queryItems: [URLQueryItem(name: "per_page", value: "100")])!
        let response: CheckRunsResponse
        do {
            response = try await http.get(CheckRunsResponse.self, url: url, token: token)
        } catch HTTPError.status(let code, _) where code == 403 || code == 401 {
            throw PermissionError(underlying: HTTPError.status(code, "token cannot read check runs"))
        }

        // Legacy commit statuses are not returned as check runs, so merge them in.
        let legacy = try? await http.get(
            StatusResponse.self,
            url: base.appendingPathComponent("commits/\(branch)/status"),
            token: token
        )

        var signals: [Signal] = response.check_runs.map { run in
            Signal(name: run.name,
                   state: Self.state(status: run.status, conclusion: run.conclusion),
                   url: run.html_url.flatMap(URL.init(string:)))
        }
        signals.append(contentsOf: legacy?.statuses.map {
            Signal(name: $0.context, state: Self.state(status: "completed", conclusion: $0.state),
                   url: $0.target_url.flatMap(URL.init(string:)))
        } ?? [])

        return Result(signals, .checks, omitted: max(0, response.total_count - response.check_runs.count))
    }

    /// The Actions API, restricted to the branch's head commit.
    ///
    /// Filtering by `branch` alone would include runs from every commit ever
    /// pushed to that branch, so a failure from last month would keep the dot
    /// red forever. Resolving the head SHA first and filtering on it is what
    /// makes this equivalent to the Checks API.
    private func workflowRuns(base: URL, branch: String, token: String) async throws -> Result {
        let headSHA = try await resolveHeadSHA(base: base, branch: branch, token: token)

        let url = base.appendingPathComponent("actions/runs")
            .appending(queryItems: [
                URLQueryItem(name: "head_sha", value: headSHA),
                URLQueryItem(name: "per_page", value: "100")
            ])!
        let response: WorkflowRunsResponse
        do {
            response = try await http.get(WorkflowRunsResponse.self, url: url, token: token)
        } catch HTTPError.status(let code, _) where code == 403 || code == 401 {
            throw PermissionError(underlying: HTTPError.status(code, "token cannot read workflow runs"))
        }

        let signals = response.workflow_runs.map { run in
            Signal(name: run.label,
                   state: Self.state(status: run.status, conclusion: run.conclusion),
                   url: run.html_url.flatMap(URL.init(string:)))
        }
        return Result(signals, .actions, omitted: max(0, response.total_count - response.workflow_runs.count))
    }

    /// Resolves a branch name to its head commit SHA.
    ///
    /// The combined status endpoint is used because it needs only the
    /// `Commit statuses: read` permission, which the Actions API does not.
    private func resolveHeadSHA(base: URL, branch: String, token: String) async throws -> String {
        let status: StatusResponse = try await http.get(
            StatusResponse.self,
            url: base.appendingPathComponent("commits/\(branch)/status"),
            token: token
        )
        guard let sha = status.sha, !sha.isEmpty else {
            throw HTTPError.decoding("head SHA", "the commit status response had no sha")
        }
        return sha
    }

    // MARK: - Mapping

    static func state(status: String?, conclusion: String?) -> Signal.State {
        let status = (status ?? "").lowercased()
        let conclusion = (conclusion ?? "").lowercased()

        // Anything that has not finished is still going, whatever it is called.
        let inProgress = ["queued", "in_progress", "waiting", "pending", "requested"]
        if inProgress.contains(status) { return .pending }
        if inProgress.contains(conclusion) { return .pending }

        switch conclusion {
        case "success", "skipped", "":
            return .passing
        case "failure", "timed_out", "action_required", "stale", "cancelled",
             "canceled", "neutral", "startup_failure":
            return .failing
        default:
            // An unrecognised conclusion is treated as a pass rather than a
            // failure, because a new GitHub state should not turn the dot red.
            return .passing
        }
    }
}

/// Thrown when GitHub refuses a request for lack of permission, so the caller
/// can try a different API rather than reporting the source as unreachable.
struct PermissionError: LocalizedError {
    let underlying: Error

    var errorDescription: String? {
        // Unwrap, so pinning a strategy reports the actual reason rather than
        // "PermissionError error 1".
        (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
    }
}

/// Advice shown when the Checks API is refused, since the usual cause is a
/// token that was never offered the `Checks` permission.
let checksPermissionAdvice = """
The Checks API was refused. Set "strategy": "actions" on this source to use the \
Actions API instead, which needs only Actions: read.
"""

private extension URL {
    func appending(queryItems items: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []) + items
        return components.url
    }
}
