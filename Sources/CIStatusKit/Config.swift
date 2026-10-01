import Foundation

/// The user's `config.json`. Kept deliberately flat and explicit so the file
/// can be edited by hand without reading any Swift.
public struct Config: Decodable, Sendable {
    public struct Source: Decodable, Sendable {
        public enum Kind: String, Decodable, Sendable {
            case github
            case vercel
            case sentry
        }

        public var kind: Kind
        public var name: String

        // GitHub
        public var owner: String?
        public var repo: String?
        public var branch: String?
        /// Which GitHub API to use: "auto" (default), "checks", or "actions".
        /// Auto uses the Checks API and falls back to Actions when the token
        /// lacks the Checks permission.
        public var strategy: GitHubProvider.Strategy?

        // Vercel
        public var projectId: String?
        public var teamId: String?

        // Sentry
        public var org: String?
        public var project: String?
        /// Sentry considers an issue "new" when first seen within this many hours.
        public var newWithinHours: Int?

        /// Name of the environment variable holding the API token.
        /// Tokens are never stored in the config file itself.
        public var tokenEnv: String?

        /// Human facing link opened when the row is clicked. Overrides the
        /// link that would otherwise be derived from the other fields.
        public var dashboardURL: String?

        public func token() -> String? {
            guard let tokenEnv else { return nil }
            return ProcessInfo.processInfo.environment[tokenEnv]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public var resolvedDashboardURL: URL? {
            if let dashboardURL, let url = URL(string: dashboardURL) { return url }
            switch kind {
            case .github:
                guard let owner, let repo else { return nil }
                var components = URLComponents(string: "https://github.com/\(owner)/\(repo)/actions")
                if let branch {
                    components?.queryItems = [URLQueryItem(name: "query", value: "branch:\(branch)")]
                }
                return components?.url
            case .vercel:
                guard let projectId else { return nil }
                var components = URLComponents(string: "https://vercel.com")
                components?.path = "/dashboard/deployments"
                components?.queryItems = [URLQueryItem(name: "projectId", value: projectId)]
                return components?.url
            case .sentry:
                guard let org, let project else { return nil }
                return URL(string: "https://\(org).sentry.io/issues/?project=\(project)")
            }
        }
    }

    public var pollIntervalSeconds: Int?
    public var sources: [Source]

    public static func load(from url: URL) throws -> Config {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }
}

public enum ConfigError: LocalizedError {
    case missingToken(source: String, env: String)

    public var errorDescription: String? {
        switch self {
        case let .missingToken(source, env):
            return "\(source): environment variable \(env) is empty. Launch with it set, e.g. \(env)=… open -a CIStatus"
        }
    }
}
