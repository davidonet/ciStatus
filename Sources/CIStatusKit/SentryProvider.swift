import Foundation

/// Reports new Sentry issues for a project within a rolling time window.
public struct SentryProvider: Sendable {
    public struct Issue: Decodable, Identifiable {
        public let id: String
        public let shortId: String?
        public let title: String
        public let level: String?
        public let status: String?
        public let firstSeen: String?
        public let lastSeen: String?
        public let permalink: String?
        public let count: String?
    }

    let http: HTTP
    let source: Config.Source

    public init(http: HTTP, source: Config.Source) {
        self.http = http
        self.source = source
    }

    public func poll() async -> SourceStatus {
        let name = source.name
        do {
            guard let org = source.org, let project = source.project else {
                return .init(id: name, name: name, health: .unknown,
                             summary: "org and project are required", detail: nil, url: nil, failingItems: [])
            }
            guard let token = source.token(), !token.isEmpty else {
                throw ConfigError.missingToken(source: name, env: source.tokenEnv ?? "<unset>")
            }

            let hours = source.newWithinHours ?? 24
            let query = "is:unresolved firstSeen:-\(hours)h"
            guard let url = URL.build("https://sentry.io/api/0/projects/\(org)/\(project)/issues/", [
                ("query", query),
                ("sort", "date"),
                ("limit", "100")
            ]) else {
                throw HTTPError.badURL("https://sentry.io/api/0/projects/\(org)/\(project)/issues/")
            }

            let issues: [Issue] = try await http.get([Issue].self, url: url, token: token)

            guard !issues.isEmpty else {
                return .init(id: name, name: name, health: .ok,
                             summary: "no new issue in \(hours)h",
                             detail: "\(org)/\(project)", url: source.resolvedDashboardURL, failingItems: [])
            }

            let worst = issues.first { $0.level?.lowercased() == "fatal" } ?? issues[0]
            let label = issues.count == 1 ? "1 new issue" : "\(issues.count) new issues"
            let items = issues.prefix(5).map { issue in
                "\(issue.shortId ?? issue.id) \(issue.title)"
            }

            return .init(id: name, name: name, health: .failing,
                         summary: label,
                         detail: "latest: \(worst.title)",
                         url: worst.permalink.flatMap(URL.init(string:)) ?? source.resolvedDashboardURL,
                         failingItems: items)
        } catch {
            return .init(id: name, name: name, health: .unknown, summary: "unreachable",
                         detail: error.localizedDescription,
                         url: source.resolvedDashboardURL, failingItems: [])
        }
    }
}
