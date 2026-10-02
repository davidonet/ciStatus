import Foundation

/// Reports the latest Vercel deployment state for a project and branch.
public struct VercelProvider: Sendable {
    public struct DeploymentsResponse: Decodable {
        public struct Deployment: Decodable {
            public struct Meta: Decodable {
                public let githubCommitRef: String?
                public let githubCommitSha: String?
                public let githubCommitMessage: String?
            }
            public let uid: String
            public let name: String
            public let url: String?
            public let inspectorUrl: String?
            public let target: String?
            public let created: Double
            public let readyState: String
            public let state: String?
            public let errorCode: String?
            public let errorMessage: String?
            public let meta: Meta?
        }
        public let deployments: [Deployment]
    }

    let http: HTTP
    let source: Source

    public init(http: HTTP, source: Source) {
        self.http = http
        self.source = source
    }

    public func poll() async -> SourceStatus {
        let name = source.name
        do {
            guard let projectId = source.projectId else {
                return .init(id: name, name: name, health: .unknown,
                             summary: "projectId is required", detail: nil, url: nil, failingItems: [])
            }
            guard let token = source.token(), !token.isEmpty else {
throw ConfigError.missingToken(source: name, kind: .vercel,
                                              enabled: source.usesToken)
            }
            guard let url = URL.build("https://api.vercel.com/v7/deployments", [
                ("projectId", projectId),
                ("limit", "5"),
                ("branch", source.branch),
                ("teamId", source.teamId)
            ]) else {
                throw HTTPError.badURL("https://api.vercel.com/v7/deployments")
            }

            let response = try await http.get(DeploymentsResponse.self, url: url, token: token)
            // Deployments arrive newest first, so the branch filter is belt and braces.
            let deployment = response.deployments.first {
                guard let branch = source.branch else { return true }
                guard let ref = $0.meta?.githubCommitRef else { return true }
                return ref == branch
            }

            guard let deployment else {
                return .init(id: name, name: name, health: .ok,
                             summary: "no deployment for \(source.branch ?? "any branch")",
                             detail: nil, url: source.resolvedDashboardURL, failingItems: [])
            }

            let state = (deployment.readyState.isEmpty ? (deployment.state ?? "") : deployment.readyState).uppercased()
            let health = Self.health(for: state)
            let shortSha = deployment.meta?.githubCommitSha.map { String($0.prefix(7)) }
            let detail = [
                deployment.target.map { "target: \($0)" },
                shortSha.map { "sha: \($0)" }
            ].compactMap { $0 }.joined(separator: " · ")

            let failing = health == .failing
                ? ["\(state): \(deployment.errorMessage ?? deployment.errorCode ?? "deployment failed")"]
                : []
            // Link to the deployment itself rather than the project list.
            let link = deployment.inspectorUrl.flatMap(URL.init(string:)) ?? source.resolvedDashboardURL

            return .init(id: name, name: name, health: health,
                         summary: state.isEmpty ? "unknown" : state,
                         detail: detail.isEmpty ? nil : detail,
                         url: link, failingItems: failing)
        } catch {
            return .init(id: name, name: name, health: .unknown, summary: "unreachable",
                         detail: error.localizedDescription,
                         url: source.resolvedDashboardURL, failingItems: [])
        }
    }

    public static func health(for state: String) -> Health {
        switch state {
        case "READY":                              return .ok
        case "BUILDING", "QUEUED", "INITIALIZING", "BLOCKED", "PENDING": return .pending
        case "ERROR", "CANCELED", "DELETED":       return .failing
        default:                                   return .unknown
        }
    }
}
