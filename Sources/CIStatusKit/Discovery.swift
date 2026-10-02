import Foundation

/// Lists what the configured tokens can actually see, so the settings window can
/// offer real repositories, projects and branches instead of asking a human to
/// type `owner/repo` from memory.
///
/// Every list is best effort. A page of results is fetched rather than
/// paginated, so a very large account may see a truncated list; the truncation
/// is reported by `DiscoveryResult.wasTruncated` rather than hidden.
public struct Discovery: Sendable {
    /// A GitHub repository.
    public struct Repo: Identifiable, Hashable, Sendable, Codable {
        public let owner: String
        public let name: String
        public var id: String { "\(owner)/\(name)" }

        public init(owner: String, name: String) {
            self.owner = owner
            self.name = name
        }
    }

    /// A Vercel or Sentry project. `id` is the identifier the API expects in a
    /// config; `name` is what a human recognises.
    public struct Project: Identifiable, Hashable, Sendable, Codable {
        public let id: String
        public let name: String
        /// Slug for Sentry, absent for Vercel.
        public let slug: String?

        public init(id: String, name: String, slug: String? = nil) {
            self.id = id
            self.name = name
            self.slug = slug
        }
    }

    /// A GitHub owner (a user or an organisation).
    public struct Org: Identifiable, Hashable, Sendable, Codable {
        public let slug: String
        public let name: String
        public var id: String { slug }

        public init(slug: String, name: String) {
            self.slug = slug
            self.name = name
        }
    }

    /// One list plus whether the API page cap hid more.
    public struct List<T: Sendable>: Sequence, Sendable {
        public var items: [T]
        public var wasTruncated: Bool

        public init(items: [T], wasTruncated: Bool = false) {
            self.items = items
            self.wasTruncated = wasTruncated
        }

        public func makeIterator() -> Array<T>.Iterator { items.makeIterator() }

        public var count: Int { items.count }
        public var isEmpty: Bool { items.isEmpty }
    }

    /// GitHub returns at most 100 items per page. Asking for 100 and treating
    /// "exactly 100" as possibly incomplete avoids inventing a second page.
    static let pageSize = 100

    let http: HTTP

    public init(http: HTTP = HTTP()) {
        self.http = http
    }

    // MARK: - GitHub

    struct GitHubRepoPayload: Decodable {
        struct Owner: Decodable { let login: String }
        let name: String
        let full_name: String?
        let owner: Owner?
        let archived: Bool?
        let fork: Bool?
    }

    struct GitHubBranchPayload: Decodable {
        struct Commit: Decodable { let sha: String }
        let name: String
        let commit: Commit?
        let protected: Bool?
    }

    /// Repositories the token can see.
    ///
    /// With an `owner` given, that owner's repositories are listed, which works
    /// for both organisations and users. Without one, everything the token can
    /// reach is listed, since that is what someone picking a first repo needs.
    public func githubRepos(token: String, owner: String? = nil) async throws -> List<Repo> {
        let base = owner.map { "https://api.github.com/users/\($0)/repos" }
            ?? "https://api.github.com/user/repos"
        guard let url = URL.build(base, [
            ("per_page", String(Self.pageSize)),
            ("type", "all"),
            // Without this, a fine grained token sees only repositories it owns,
            // not the ones it was granted access to.
            ("affiliation", "owner,collaborator,organization_member")
        ]) else {
            throw HTTPError.badURL(base)
        }

        let payload: [GitHubRepoPayload] = try await http.get([GitHubRepoPayload].self,
                                                              url: url, token: token)
        let repos = payload
            .filter { ($0.archived ?? false) == false && ($0.fork ?? false) == false }
            .map { payload -> Repo in
                let ownerName = payload.owner?.login
                    ?? payload.full_name.flatMap { $0.split(separator: "/").first.map(String.init) }
                    ?? owner
                    ?? ""
                return Repo(owner: ownerName, name: payload.name)
            }
            // The same repo can arrive twice across affiliations; the id would
            // collide and break the selection list's identity.
            .reduce(into: [Repo]()) { acc, repo in
                if !acc.contains(where: { $0.id == repo.id }) { acc.append(repo) }
            }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }

        return List(items: repos, wasTruncated: payload.count >= Self.pageSize)
    }

    /// Branches of one repository.
    public func githubBranches(token: String, owner: String, repo: String) async throws -> List<String> {
        let base = "https://api.github.com/repos/\(owner)/\(repo)/branches"
        guard let url = URL.build(base, [("per_page", String(Self.pageSize))]) else {
            throw HTTPError.badURL(base)
        }
        let payload: [GitHubBranchPayload] = try await http.get([GitHubBranchPayload].self,
                                                                 url: url, token: token)
        // The default branch is what most people mean, so it leads the list.
        // `protected` is preferred over `name == "main"` because the default
        // branch is not always called main.
        let branches = payload.sorted { lhs, rhs in
            if lhs.protected != rhs.protected { return (lhs.protected ?? false) && !(rhs.protected ?? false) }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }.map(\.name)
        return List(items: branches, wasTruncated: payload.count >= Self.pageSize)
    }

    // MARK: - Vercel

    struct VercelProjectPayload: Decodable {
        let id: String
        let name: String
    }

    /// Projects visible to the token, optionally scoped to a team.
    public func vercelProjects(token: String, teamId: String? = nil) async throws -> List<Project> {
        guard let url = URL.build("https://api.vercel.com/v9/projects", [
            ("limit", String(Self.pageSize)),
            ("teamId", teamId)
        ]) else {
            throw HTTPError.badURL("https://api.vercel.com/v9/projects")
        }
        let payload: [VercelProjectPayload] = try await http.get([VercelProjectPayload].self,
                                                                 url: url, token: token)
        let projects = payload
            .map { Project(id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return List(items: projects, wasTruncated: payload.count >= Self.pageSize)
    }

    /// Branches a Vercel project has actually deployed.
    ///
    /// Vercel has no "list branches" endpoint, so this is derived from recent
    /// deployments: the branches you can usefully watch are the ones you deploy.
    public func vercelBranches(token: String, projectId: String) async throws -> List<String> {
        guard let url = URL.build("https://api.vercel.com/v7/deployments", [
            ("projectId", projectId),
            ("limit", String(Self.pageSize))
        ]) else {
            throw HTTPError.badURL("https://api.vercel.com/v7/deployments")
        }
        let response: VercelProvider.DeploymentsResponse =
            try await http.get(VercelProvider.DeploymentsResponse.self, url: url, token: token)

        var seen: Set<String> = []
        var branches: [String] = []
        for deployment in response.deployments {
            guard let ref = deployment.meta?.githubCommitRef, !ref.isEmpty else { continue }
            guard seen.insert(ref).inserted else { continue }
            branches.append(ref)
        }
        branches.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return List(items: branches, wasTruncated: response.deployments.count >= Self.pageSize)
    }

    // MARK: - Sentry

    struct SentryProjectPayload: Decodable {
        let id: String
        let slug: String
        let name: String
    }

    struct SentryOrgPayload: Decodable {
        let id: String
        let slug: String
        let name: String
    }

    /// Organisations the token can see.
    public func sentryOrgs(token: String) async throws -> List<Org> {
        let base = "https://sentry.io/api/0/organizations/"
        guard let url = URL.build(base, [("per_page", String(Self.pageSize))]) else {
            throw HTTPError.badURL(base)
        }
        let payload: [SentryOrgPayload] = try await http.get([SentryOrgPayload].self,
                                                              url: url, token: token)
        let orgs = payload
            .map { Org(slug: $0.slug, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return List(items: orgs, wasTruncated: payload.count >= Self.pageSize)
    }

    /// Projects in one Sentry organisation.
    public func sentryProjects(token: String, org: String) async throws -> List<Project> {
        let base = "https://sentry.io/api/0/organizations/\(org)/projects/"
        guard let url = URL.build(base, [("per_page", String(Self.pageSize))]) else {
            throw HTTPError.badURL(base)
        }
        let payload: [SentryProjectPayload] = try await http.get([SentryProjectPayload].self,
                                                                url: url, token: token)
        let projects = payload
            .map { Project(id: $0.id, name: $0.name, slug: $0.slug) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return List(items: projects, wasTruncated: payload.count >= Self.pageSize)
    }
}