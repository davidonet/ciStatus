import Foundation

/// The user's `config.json`.
///
/// The file has two sections: `tokens` says which services are enabled, and
/// `services` lists what to watch, grouped by provider. A target may name
/// several branches, and each one becomes its own row in the menu.
///
/// Tokens live in `TokenStore` and are never written here, so this file stays
/// safe to commit. Everything can also be typed by hand: the settings window's
/// pickers are a convenience over fields the config already accepts.
public struct Config: Codable, Sendable, Equatable {
    /// Which services read a token from `TokenStore`.
    ///
    /// Listed explicitly rather than inferred from whether an entry happens to
    /// exist, so a leftover token for a service you stopped watching cannot
    /// silently keep it polled.
    public struct Tokens: Codable, Sendable, Equatable {
        public var github: Bool?
        public var vercel: Bool?
        public var sentry: Bool?

        public init(github: Bool? = nil, vercel: Bool? = nil, sentry: Bool? = nil) {
            self.github = github
            self.vercel = vercel
            self.sentry = sentry
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case github, vercel, sentry
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try rejectUnknownKeys(in: decoder, section: "tokens",
                                  known: Set(CodingKeys.allCases.map(\.rawValue)))
            github = try Self.decodeFlag(container, forKey: .github)
            vercel = try Self.decodeFlag(container, forKey: .vercel)
            sentry = try Self.decodeFlag(container, forKey: .sentry)
        }

        /// A service is on or off, so `true` is the only shape that means
        /// anything. An absent or null key means off. A string is the old form,
        /// where a service named an environment variable, and gets its own
        /// message because it is the likeliest thing to be in a config written
        /// against an earlier version.
        private static func decodeFlag(_ container: KeyedDecodingContainer<CodingKeys>,
                                       forKey key: CodingKeys) throws -> Bool? {
            // `decodeNil` throws when the key is absent rather than reporting
            // it, and every section here is optional, so absence is checked
            // first.
            guard container.contains(key) else { return nil }
            if try container.decodeNil(forKey: key) { return nil }
            if let flag = try? container.decode(Bool.self, forKey: key) { return flag }
            if let name = try? container.decode(String.self, forKey: key) {
                throw ConfigError.legacyEnvToken(service: key.rawValue, variable: name)
            }
            throw ConfigError.unknownServiceKey(section: "tokens", key: "\(key.rawValue) (expected true)")
        }

        public var isEmpty: Bool {
            enabledServices.isEmpty
        }

        public func isEnabled(_ kind: Source.Kind) -> Bool {
            switch kind {
            case .github: return github == true
            case .vercel: return vercel == true
            case .sentry: return sentry == true
            }
        }

        public subscript(kind: Source.Kind) -> Bool? {
            get {
                switch kind {
                case .github: return github
                case .vercel: return vercel
                case .sentry: return sentry
                }
            }
            set {
                switch kind {
                case .github: github = newValue
                case .vercel: vercel = newValue
                case .sentry: sentry = newValue
                }
            }
        }

        public var enabledServices: [Source.Kind] {
            Source.Kind.allCases.filter { isEnabled($0) }
        }
    }

    /// One GitHub repository, watched on one or more branches.
    public struct GitHubTarget: Codable, Identifiable, Sendable, Equatable {
        public var owner: String
        public var repo: String
        /// Branches to watch. Empty means `main`.
        public var branches: [String]
        /// Label shown in the menu. Defaults to the repository name.
        public var name: String?
        /// "auto" (default), "checks" or "actions". See `GitHubProvider`.
        public var strategy: GitHubProvider.Strategy?
        /// Overrides the dashboard link derived from the other fields.
        public var dashboardURL: String?

        public var id: String { "\(owner)/\(repo)" }

        public init(owner: String, repo: String, branches: [String] = [], name: String? = nil,
                    strategy: GitHubProvider.Strategy? = nil, dashboardURL: String? = nil) {
            self.owner = owner
            self.repo = repo
            self.branches = branches
            self.name = name
            self.strategy = strategy
            self.dashboardURL = dashboardURL
        }

        public var labelBase: String { name ?? repo }

        private enum CodingKeys: String, CodingKey {
            case owner, repo, branches, name, strategy, dashboardURL
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Only owner and repo are required. `branches` defaults to main, so
            // the shortest useful entry is {"owner":…,"repo":…}.
            owner = try container.decode(String.self, forKey: .owner)
            repo = try container.decode(String.self, forKey: .repo)
            branches = try container.decodeIfPresent([String].self, forKey: .branches) ?? []
            name = try container.decodeIfPresent(String.self, forKey: .name)
            strategy = try container.decodeIfPresent(GitHubProvider.Strategy.self, forKey: .strategy)
            dashboardURL = try container.decodeIfPresent(String.self, forKey: .dashboardURL)
        }
    }

    /// One Vercel project, watched on one or more branches.
    public struct VercelTarget: Codable, Identifiable, Sendable, Equatable {
        public var projectId: String
        /// Scope the token to a team when the account has more than one.
        public var teamId: String?
        /// Branches to watch. Empty means `main`.
        public var branches: [String]
        /// Human project name from the API, used as the menu label.
        public var name: String?
        /// Overrides the dashboard link derived from the other fields.
        public var dashboardURL: String?

        public var id: String { projectId }

        public init(projectId: String, teamId: String? = nil, branches: [String] = [],
                    name: String? = nil, dashboardURL: String? = nil) {
            self.projectId = projectId
            self.teamId = teamId
            self.branches = branches
            self.name = name
            self.dashboardURL = dashboardURL
        }

        public var labelBase: String { name ?? projectId }

        private enum CodingKeys: String, CodingKey {
            case projectId, teamId, branches, name, dashboardURL
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            projectId = try container.decode(String.self, forKey: .projectId)
            teamId = try container.decodeIfPresent(String.self, forKey: .teamId)
            branches = try container.decodeIfPresent([String].self, forKey: .branches) ?? []
            name = try container.decodeIfPresent(String.self, forKey: .name)
            dashboardURL = try container.decodeIfPresent(String.self, forKey: .dashboardURL)
        }
    }

    /// One Sentry project. Sentry has no branch notion, so this watches the
    /// whole project over a rolling window.
    public struct SentryTarget: Codable, Identifiable, Sendable, Equatable {
        public var org: String
        public var project: String
        /// Sentry counts an issue as new when first seen within this many hours.
        public var newWithinHours: Int?
        /// Label shown in the menu. Defaults to the project slug.
        public var name: String?
        /// Overrides the dashboard link derived from the other fields.
        public var dashboardURL: String?

        public var id: String { "\(org)/\(project)" }

        public init(org: String, project: String, newWithinHours: Int? = nil,
                    name: String? = nil, dashboardURL: String? = nil) {
            self.org = org
            self.project = project
            self.newWithinHours = newWithinHours
            self.name = name
            self.dashboardURL = dashboardURL
        }

        private enum CodingKeys: String, CodingKey {
            case org, project, newWithinHours, name, dashboardURL
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            org = try container.decode(String.self, forKey: .org)
            project = try container.decode(String.self, forKey: .project)
            newWithinHours = try container.decodeIfPresent(Int.self, forKey: .newWithinHours)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            dashboardURL = try container.decodeIfPresent(String.self, forKey: .dashboardURL)
        }
    }

    /// What to watch, grouped by provider. Every list is optional, so a config
    /// that only uses GitHub needs no empty Vercel or Sentry section.
    public struct Services: Codable, Sendable, Equatable {
        public var github: [GitHubTarget]
        public var vercel: [VercelTarget]
        public var sentry: [SentryTarget]

        public init(github: [GitHubTarget] = [], vercel: [VercelTarget] = [],
                    sentry: [SentryTarget] = []) {
            self.github = github
            self.vercel = vercel
            self.sentry = sentry
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case github, vercel, sentry
        }

        /// Each provider section is genuinely optional, so a GitHub-only config
        /// is two lines rather than three empty lists.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try rejectUnknownKeys(in: decoder, section: "services",
                                  known: Set(CodingKeys.allCases.map(\.rawValue)))
            github = try container.decodeIfPresent([GitHubTarget].self, forKey: .github) ?? []
            vercel = try container.decodeIfPresent([VercelTarget].self, forKey: .vercel) ?? []
            sentry = try container.decodeIfPresent([SentryTarget].self, forKey: .sentry) ?? []
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if !github.isEmpty { try container.encode(github, forKey: .github) }
            if !vercel.isEmpty { try container.encode(vercel, forKey: .vercel) }
            if !sentry.isEmpty { try container.encode(sentry, forKey: .sentry) }
        }

        public func targets(for kind: Source.Kind) -> [String] {
            switch kind {
            case .github: return github.map(\.id)
            case .vercel: return vercel.map(\.id)
            case .sentry: return sentry.map(\.id)
            }
        }

        /// A human summary for the log, e.g. "2 GitHub, 1 Vercel".
        public var enabledTargetsDescription: String {
            let parts: [String] = []
                + (github.isEmpty ? [] : ["\(github.count) GitHub"])
                + (vercel.isEmpty ? [] : ["\(vercel.count) Vercel"])
                + (sentry.isEmpty ? [] : ["\(sentry.count) Sentry"])
            return parts.isEmpty ? "no services" : parts.joined(separator: ", ")
        }

        public var isEmpty: Bool {
            github.isEmpty && vercel.isEmpty && sentry.isEmpty
        }

        // MARK: - Editing
        //
        // Mutations live here rather than in the settings window so they can be
        // tested: the window is an executable target, and these are the rules
        // that keep a hand-edited list sane.
        //
        // Every field is authoritative rather than "change this one", because the
        // editor is prefilled with the whole target and sends all of it. A
        // partial update would have to distinguish "leave alone" from "clear
        // this", and the blank-means-unset convention already covers that.

        public func indexOfGitHub(_ id: String) -> Int? {
            github.firstIndex { $0.id == id }
        }

        public func indexOfVercel(_ id: String) -> Int? {
            vercel.firstIndex { $0.id == id }
        }

        public func indexOfSentry(_ id: String) -> Int? {
            sentry.firstIndex { $0.id == id }
        }

        /// Replaces the GitHub target at `index`, keeping its position in the menu.
        ///
        /// Refuses rather than merging when the new owner/repo is already
        /// configured elsewhere: editing one row into another would leave the same
        /// repository polled twice.
        @discardableResult
        public mutating func updateGitHub(at index: Int, owner: String, repo: String,
                                          branches: [String], name: String?,
                                          strategy: GitHubProvider.Strategy?,
                                          dashboardURL: String?) -> Bool {
            guard github.indices.contains(index) else { return false }
            let owner = owner.trimmed, repo = repo.trimmed
            guard !owner.isEmpty, !repo.isEmpty else { return false }
            let id = "\(owner)/\(repo)"
            guard !github.enumerated().contains(where: { $0.offset != index && $0.element.id == id })
            else { return false }

            github[index] = .init(owner: owner, repo: repo, branches: branches,
                                  name: name?.trimmed.nilIfEmpty, strategy: strategy,
                                  dashboardURL: dashboardURL?.trimmed.nilIfEmpty)
            return true
        }

        @discardableResult
        public mutating func updateVercel(at index: Int, projectId: String, teamId: String?,
                                          branches: [String], name: String?,
                                          dashboardURL: String?) -> Bool {
            guard vercel.indices.contains(index) else { return false }
            let projectId = projectId.trimmed
            guard !projectId.isEmpty else { return false }
            guard !vercel.enumerated().contains(where: { $0.offset != index && $0.element.id == projectId })
            else { return false }

            vercel[index] = .init(projectId: projectId,
                                  teamId: teamId?.trimmed.nilIfEmpty,
                                  branches: branches,
                                  name: name?.trimmed.nilIfEmpty,
                                  dashboardURL: dashboardURL?.trimmed.nilIfEmpty)
            return true
        }

        @discardableResult
        public mutating func updateSentry(at index: Int, org: String, project: String,
                                          newWithinHours: Int?, name: String?,
                                          dashboardURL: String?) -> Bool {
            guard sentry.indices.contains(index) else { return false }
            let org = org.trimmed, project = project.trimmed
            guard !org.isEmpty, !project.isEmpty else { return false }
            let id = "\(org)/\(project)"
            guard !sentry.enumerated().contains(where: { $0.offset != index && $0.element.id == id })
            else { return false }

            sentry[index] = .init(org: org, project: project,
                                  newWithinHours: newWithinHours,
                                  name: name?.trimmed.nilIfEmpty,
                                  dashboardURL: dashboardURL?.trimmed.nilIfEmpty)
            return true
        }

        /// Adds a branch, or removes it when it is already watched.
        public mutating func toggleBranch(_ branch: String, forGitHub index: Int) {
            guard github.indices.contains(index) else { return }
            github[index].branches.toggle(branch)
        }

        public mutating func toggleBranch(_ branch: String, forVercel index: Int) {
            guard vercel.indices.contains(index) else { return }
            vercel[index].branches.toggle(branch)
        }
    }

    public var pollIntervalSeconds: Int?
    public var tokens: Tokens
    public var services: Services

    public init(pollIntervalSeconds: Int? = 60, tokens: Tokens = Tokens(),
                services: Services = Services()) {
        self.pollIntervalSeconds = pollIntervalSeconds
        self.tokens = tokens
        self.services = services
    }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case pollIntervalSeconds, tokens, services, sources
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A pre-`services` config is rejected with an actionable message rather
        // than silently loading as "no sources configured", which would look
        // like the app had simply lost its setup.
        if container.contains(.sources) {
            throw ConfigError.legacySourcesFormat
        }
        // A typo in a service name would otherwise be ignored, leaving the user
        // with a config that looks right and watches nothing.
        let raw = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        for key in raw where !known.contains(key) {
            throw ConfigError.unknownKey(key)
        }
        pollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds)
        tokens = try container.decodeIfPresent(Tokens.self, forKey: .tokens) ?? Tokens()
        services = try container.decodeIfPresent(Services.self, forKey: .services) ?? Services()
    }

    /// Written by hand so the file the app saves stays pleasant to hand edit:
    /// sections that are empty or unset are left out entirely rather than
    /// serialised as `"sentry": []` and `"sentry": null`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(pollIntervalSeconds, forKey: .pollIntervalSeconds)

        if !tokens.isEmpty {
            try container.encode(tokens, forKey: .tokens)
        }
        if !services.isEmpty {
            var servicesContainer = container.nestedContainer(keyedBy: ServicesKeys.self,
                                                            forKey: .services)
            if !services.github.isEmpty {
                try servicesContainer.encode(services.github, forKey: .github)
            }
            if !services.vercel.isEmpty {
                try servicesContainer.encode(services.vercel, forKey: .vercel)
            }
            if !services.sentry.isEmpty {
                try servicesContainer.encode(services.sentry, forKey: .sentry)
            }
        }
    }

    private enum ServicesKeys: String, CodingKey {
        case github, vercel, sentry
    }

    // MARK: - Expansion

    /// The branches to watch for a target, defaulting to `main` when the list
    /// is empty so an omitted `branches` still produces a working row.
    static func branchesOrDefault(_ branches: [String]) -> [String] {
        var seen: Set<String> = []
        var cleaned: [String] = []
        for branch in branches {
            let trimmed = branch.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            cleaned.append(trimmed)
        }
        return cleaned.isEmpty ? ["main"] : cleaned
    }

    /// The same list, exposed so the settings UI can show which branches a
    /// target already watches without duplicating the defaulting rule.
    public static func branchesOrDefaultForDisplay(_ branches: [String]) -> [String] {
        branchesOrDefault(branches)
    }

    /// Flattens the grouped config into one unit of polling per branch.
    ///
    /// The providers work on flat sources because that is what a single API
    /// query needs; the config stays grouped because that is what a human wants
    /// to edit. This is the only place the two meet.
    public var expandedSources: [Source] {
        var result: [Source] = []

        for target in services.github {
            for branch in Self.branchesOrDefault(target.branches) {
                result.append(.init(
                    kind: .github,
                    name: "\(target.labelBase) · \(branch)",
                    owner: target.owner,
                    repo: target.repo,
                    branch: branch,
                    strategy: target.strategy,
                    usesToken: tokens.isEnabled(.github),
                    dashboardURL: target.dashboardURL
                ))
            }
        }

        for target in services.vercel {
            for branch in Self.branchesOrDefault(target.branches) {
                result.append(.init(
                    kind: .vercel,
                    name: "\(target.labelBase) · \(branch)",
                    branch: branch,
                    projectId: target.projectId,
                    teamId: target.teamId,
                    usesToken: tokens.isEnabled(.vercel),
                    dashboardURL: target.dashboardURL
                ))
            }
        }

        for target in services.sentry {
            result.append(.init(
                kind: .sentry,
                name: target.name ?? target.project,
                org: target.org,
                project: target.project,
                newWithinHours: target.newWithinHours,
                usesToken: tokens.isEnabled(.sentry),
                dashboardURL: target.dashboardURL
            ))
        }

        return result
    }

    public static func load(from url: URL) throws -> Config {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    /// Reads the config, changes one thing, writes it back.
    ///
    /// A missing file becomes an empty config rather than an error, because the
    /// caller is usually enabling a service that was just given a token, and
    /// refusing to create the file would leave the token stored but unused — which
    /// is exactly the state that looks like nothing working.
    public static func update(at url: URL, _ body: (inout Config) -> Void) throws {
        var config: Config
        if FileManager.default.fileExists(atPath: url.path) {
            config = try load(from: url)
        } else {
            config = Config(pollIntervalSeconds: 60)
        }
        body(&config)
        try config.save(to: url)
    }

    /// Writes the config with stable key order and readable indentation, so a
    /// file the app writes stays pleasant to hand edit afterwards.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// One unit of polling: a single provider, a single branch, already resolved
/// against the token section. Derived from `Config`, never decoded directly.
public struct Source: Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case github
        case vercel
        case sentry

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .github: return "GitHub"
            case .vercel: return "Vercel"
            case .sentry: return "Sentry"
            }
        }

        /// Whether a source has branches, which is what the editor asks about.
        public var usesBranches: Bool { self != .sentry }
    }

    public var kind: Kind
    public var name: String

    // GitHub
    public var owner: String?
    public var repo: String?
    public var branch: String?
    public var strategy: GitHubProvider.Strategy?

    // Vercel
    public var projectId: String?
    public var teamId: String?

    // Sentry
    public var org: String?
    public var project: String?
    public var newWithinHours: Int?

    /// Whether this source reads a token from `TokenStore`. Copied in from the
    /// `tokens` section during expansion.
    public var usesToken: Bool

    /// Human facing link opened when the row is clicked. Overrides the link
    /// that would otherwise be derived from the other fields.
    public var dashboardURL: String?

    public var id: String { name }

    public init(kind: Kind, name: String, owner: String? = nil, repo: String? = nil,
                branch: String? = nil, strategy: GitHubProvider.Strategy? = nil,
                projectId: String? = nil, teamId: String? = nil, org: String? = nil,
                project: String? = nil, newWithinHours: Int? = nil,
                usesToken: Bool = false,
                dashboardURL: String? = nil) {
        self.kind = kind
        self.name = name
        self.owner = owner
        self.repo = repo
        self.branch = branch
        self.strategy = strategy
        self.projectId = projectId
        self.teamId = teamId
        self.org = org
        self.project = project
        self.newWithinHours = newWithinHours
        self.usesToken = usesToken
        self.dashboardURL = dashboardURL
    }

    /// The token from `TokenStore`. The config never holds the value.
    public func token() -> String? {
        guard usesToken else { return nil }
        return TokenStore.token(for: kind)
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

/// A key that matches any string, so the unknown-key check can see the names
/// the JSON actually contains.
///
/// `KeyedDecodingContainer.allKeys` returns keys already coerced into the
/// container's key type, so an unrecognised name is dropped before a loop over
/// them can look at it. Reading through this type instead is what makes a typo
/// visible at all.
private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Throws on the first key a section does not define.
///
/// A misspelled provider or token name would otherwise be ignored, leaving a
/// config that looks right and watches nothing, which is the hardest kind of
/// mistake to notice.
private func rejectUnknownKeys(in decoder: any Decoder,
                               section: String,
                               known: Set<String>) throws {
    let present = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
    for key in present where !known.contains(key) {
        throw ConfigError.unknownServiceKey(section: section, key: key)
    }
}

public enum ConfigError: Error, LocalizedError, Equatable {
    case missingToken(source: String, kind: Source.Kind, enabled: Bool)
    case legacySourcesFormat
    case unknownKey(String)
    /// A key inside a `services` or `tokens` section that is not recognised.
    case unknownServiceKey(section: String, key: String)
    /// The form where a service named an environment variable.
    case legacyEnvToken(service: String, variable: String)

    public var errorDescription: String? {
        switch self {
        case let .missingToken(source, kind, enabled):
            if enabled {
                return "\(source): no \(kind.displayName) token stored. Open Settings, paste one and press Save, or run \"probe --store-token \(kind.rawValue) <token>\"."
            }
            return "\(source): \(kind.displayName) is not enabled. Set \"tokens\": { \"\(kind.rawValue)\": true } in the config, or add the token in Settings."
        case let .unknownKey(key):
            return """
            Unknown config key "\(key)". Valid keys are pollIntervalSeconds, tokens and services. \
            A misspelled key is ignored otherwise, which looks like the app lost your setup.
            """
        case let .legacyEnvToken(service, variable):
            return """
            "\(service)": "\(variable)" is the old form, where a service named an environment \
            variable. Tokens now come from TokenStore and the environment is not read, \
            so replace "\(variable)" with true, then store the token in Settings or with \
            "probe --store-token \(service) <token>".
            """
        case let .unknownServiceKey(section, key):
            return """
            Unknown key "\(key)" in the "\(section)" section. Valid keys there are \
            github, vercel and sentry. A misspelled key is ignored otherwise, \
            which looks like the app lost your setup.
            """
        case .legacySourcesFormat:
            return """
            This config still uses the old "sources" array, which has been replaced by \
            "tokens" and "services". Open Settings to rebuild it, or migrate by hand: \
            group each source under services.github, services.vercel or services.sentry by \
            its "kind", and set that service to true in the tokens section.
            """
        }
    }
}
private extension Array where Element == String {
    /// Adds the branch, or removes it when it is already there. A blank name is
    /// ignored, since an empty entry would become a row labelled " · ".
    mutating func toggle(_ branch: String) {
        let trimmed = branch.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let offset = firstIndex(of: trimmed) {
            remove(at: offset)
        } else {
            append(trimmed)
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
