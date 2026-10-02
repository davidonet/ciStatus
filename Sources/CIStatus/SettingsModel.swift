import Combine
import CIStatusKit
import Foundation

/// Backs the settings window.
///
/// It owns a working copy of the config rather than editing the loaded one in
/// place, so a half-finished change cannot alter what the menu bar shows
/// mid-edit. Nothing reaches the poll loop until Save calls `Monitor.apply`.
@MainActor
final class SettingsModel: ObservableObject {
    /// The config as it will be written. Edited freely, including unsaved.
    @Published var draft: Config
    /// The config currently in force, for revert.
    @Published private(set) var saved: Config
    /// Per service token, held only for this session's discovery calls.
    @Published var tokens: [Source.Kind: String] = [:]
    @Published private(set) var isSaving = false
    @Published var notice: String?

    private let monitor: Monitor
    private let discovery = Discovery()

    /// Per service discovery state, so one provider being slow or broken does
    /// not blank the others.
    let repos = ServiceState<Discovery.Repo>()
    let branches = ServiceState<String>()
    let projects = ServiceState<Discovery.Project>()
    let orgs = ServiceState<Discovery.Org>()

    /// A list that is loading, loaded, or failed, per service.
    final class ServiceState<Item>: ObservableObject {
        @Published var items: [Item] = []
        @Published var isLoading = false
        @Published var error: String?
        @Published var wasTruncated = false

        func reset() {
            items = []
            error = nil
            wasTruncated = false
            isLoading = false
        }

        /// Keeps whichever service state is being replaced, so two services do
        /// not overwrite each other's list.
        func set(_ result: Discovery.List<Item>) {
            items = result.items
            wasTruncated = result.wasTruncated
            error = nil
            isLoading = false
        }
    }

    init(monitor: Monitor) {
        self.monitor = monitor
        let current = monitor.config ?? Config()
        self.draft = current
        self.saved = current

        // The settings window is built by SwiftUI before
        // `applicationDidFinishLaunching` reads the config, so a draft taken at
        // init time is an empty one. That would show "no repositories yet" for a
        // fully configured app, and saving it would wipe the config.
        //
        // So the draft follows the monitor instead, but only while it is
        // untouched: adopting a new config mid-edit would discard whatever the
        // user was in the middle of typing.
        monitor.$config
            .sink { [weak self] loaded in
                guard let self, let loaded else { return }
                guard !self.hasChanges else {
                    Log.info("config changed on disk while settings had unsaved edits; "
                             + "the draft was left alone")
                    return
                }
                self.draft = loaded
                self.saved = loaded
            }
            .store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []

    var hasChanges: Bool { draft != saved }

    func revert() {
        draft = saved
        Log.info("settings reverted to the saved configuration")
        notice = "Reverted to the saved configuration."
    }

    // MARK: - Tokens

    /// The value discovery should use: what is typed into the window this
    /// session, else whatever is already stored.
    ///
    /// A typed value is never persisted, so a token can be checked or browsed
    /// with before committing to storing it.
    private func usableToken(for kind: Source.Kind) -> String? {
        if let typed = tokens[kind]?.trimmingCharacters(in: .whitespaces), !typed.isEmpty {
            return typed
        }
        return storedToken(for: kind)
    }

    /// The token the app itself will use, which is `TokenStore` and nothing else.
    func storedToken(for kind: Source.Kind) -> String? {
        TokenStore.token(for: kind)
    }

    /// Whether a service is switched on in the config.
    func isEnabled(_ kind: Source.Kind) -> Bool {
        draft.tokens.isEnabled(kind)
    }

    /// Stores a token and switches the config on for that service.
    ///
    /// The write happens before the config change so a failed write cannot leave
    /// the config asking for a token that was never stored.
    func storeToken(_ value: String, for kind: Source.Kind) {
        do {
            try TokenStore.save(value, for: kind)
            draft.tokens[kind] = true
            tokens[kind] = ""
            Log.registerSecret(value)
            Log.info("stored the \(kind.displayName) token and enabled it")
            notice = "\(kind.displayName) token saved."
        } catch {
            Log.error("could not store the \(kind.displayName) token: "
                      + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            notice = "Could not save the \(kind.displayName) token: "
                + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Removes a stored token. The config keeps the service switched on, so the
    /// row reports a missing token rather than silently going quiet.
    func removeToken(for kind: Source.Kind) {
        do {
            let existed = try TokenStore.delete(for: kind)
            Log.info(existed
                     ? "removed the \(kind.displayName) token"
                     : "no \(kind.displayName) token was stored")
            notice = existed
                ? "Removed the \(kind.displayName) token."
                : "There was no stored \(kind.displayName) token."
        } catch {
            notice = "Could not remove the \(kind.displayName) token: "
                + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func setEnabled(_ enabled: Bool, for kind: Source.Kind) {
        draft.tokens[kind] = enabled ? true : nil
    }

    /// Whether the pickers can do anything. They need a token; without one the
    /// manual entry fields are the only route, which is why they are always
    /// available rather than gated on this.
    func canDiscover(_ kind: Source.Kind) -> Bool {
        usableToken(for: kind) != nil
    }

    // MARK: - Discovery

    /// Lists what the token can see. Errors land in the service's own state so
    /// a bad Vercel token does not look like a broken GitHub picker.
    func discoverRepos() {
        guard let token = usableToken(for: .github) else {
            repos.error = "Set a GitHub token first."
            Log.info("discovery: repositories skipped, no GitHub token")
            return
        }
        repos.isLoading = true
        repos.error = nil
        Log.info("discovery: listing GitHub repositories")
        Task {
            do {
                let result = try await discovery.githubRepos(token: token)
                repos.set(result)
                Log.info("discovery: \(result.count) GitHub repositories"
                         + (result.wasTruncated ? " (first page only)" : ""))
                if result.isEmpty {
                    repos.error = "No repositories visible to this token."
                }
            } catch {
                repos.isLoading = false
                repos.error = Self.describe(error)
                Log.warning("discovery: listing GitHub repositories failed: \(Self.describe(error))")
            }
        }
    }

    func discoverBranches(for repo: Discovery.Repo) {
        guard let token = usableToken(for: .github) else {
            branches.error = "Set a GitHub token first."
            Log.info("discovery: branches skipped for \(repo.id), no GitHub token")
            return
        }
        branches.isLoading = true
        branches.error = nil
        Log.info("discovery: listing branches for \(repo.id)")
        Task {
            do {
                let result = try await discovery.githubBranches(token: token,
                                                               owner: repo.owner, repo: repo.name)
                branches.set(result)
                Log.info("discovery: \(result.count) branches for \(repo.id)")
                if result.isEmpty {
                    branches.error = "\(repo.id) has no branches."
                }
            } catch {
                branches.isLoading = false
                branches.error = Self.describe(error)
                Log.warning("discovery: listing branches for \(repo.id) failed: "
                            + Self.describe(error))
            }
        }
    }

    func discoverProjects(for kind: Source.Kind) {
        guard let token = usableToken(for: kind) else {
            projects.error = "Set a \(kind.displayName) token first."
            return
        }
        projects.isLoading = true
        projects.error = nil
        let teamId: String? = kind == .vercel ? vercelTeamId() : nil
        Task {
            do {
                switch kind {
                case .vercel:
                    projects.set(try await discovery.vercelProjects(token: token, teamId: teamId))
                case .github:
                    projects.reset()
                    return
                case .sentry:
                    // Sentry needs an org, which is chosen first.
                    let slug = sentryOrgSlug()
                    guard let slug else {
                        projects.isLoading = false
                        projects.error = "Choose a Sentry organisation first."
                        return
                    }
                    projects.set(try await discovery.sentryProjects(token: token, org: slug))
                }
                if projects.items.isEmpty {
                    projects.error = "No projects visible to this token."
                }
            } catch {
                projects.isLoading = false
                projects.error = Self.describe(error)
            }
        }
    }

    /// Vercel branches are derived from recent deployments, and kept apart from
    /// GitHub's so the two pickers do not overwrite each other's list.
    let vercelBranches = ServiceState<String>()

    func discoverVercelBranches(projectId: String) {
        guard let token = usableToken(for: .vercel) else {
            vercelBranches.error = "Set a Vercel token first, or type branches in Edit…."
            Log.info("discovery: Vercel branches skipped, no token")
            return
        }
        vercelBranches.isLoading = true
        vercelBranches.error = nil
        Log.info("discovery: listing Vercel branches for \(projectId)")
        Task {
            do {
                let result = try await discovery.vercelBranches(token: token, projectId: projectId)
                vercelBranches.set(result)
                Log.info("discovery: \(result.count) Vercel branches for \(projectId)")
                if result.isEmpty {
                    vercelBranches.error = "No deployments found, so no branches to offer."
                }
            } catch {
                vercelBranches.isLoading = false
                vercelBranches.error = Self.describe(error)
                Log.warning("discovery: listing Vercel branches for \(projectId) failed: "
                            + Self.describe(error))
            }
        }
    }

    func discoverOrgs() {
        guard let token = usableToken(for: .sentry) else {
            orgs.error = "Set a Sentry token first."
            return
        }
        orgs.isLoading = true
        orgs.error = nil
        Task {
            do {
                let result = try await discovery.sentryOrgs(token: token)
                orgs.set(result)
                if result.isEmpty {
                    orgs.error = "No Sentry organisations visible to this token."
                }
            } catch {
                orgs.isLoading = false
                orgs.error = Self.describe(error)
            }
        }
    }

    /// Turns an API failure into something a person can act on.
    static func describe(_ error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if case HTTPError.status(401, _) = error {
            return "\(message) — the token was rejected."
        }
        if case HTTPError.status(403, _) = error {
            return "\(message) — the token lacks access, or has not been granted this scope."
        }
        if case ConfigError.missingToken = error {
            return "No token. Store one in Settings, or type the values in by hand."
        }
        return message
    }

    // MARK: - Editing services

    /// Reads the team id off the first Vercel target, so it is asked once
    /// rather than per project.
    private func vercelTeamId() -> String? {
        draft.services.vercel.first?.teamId
    }

    private func sentryOrgSlug() -> String? {
        draft.services.sentry.first?.org
    }

    func addGitHub(_ repo: Discovery.Repo) {
        guard !draft.services.github.contains(where: { $0.id == repo.id }) else { return }
        draft.services.github.append(.init(owner: repo.owner, repo: repo.name))
    }

    func addVercel(_ project: Discovery.Project, teamId: String?) {
        guard !draft.services.vercel.contains(where: { $0.id == project.id }) else { return }
        draft.services.vercel.append(.init(projectId: project.id, teamId: teamId, name: project.name))
    }

    func addSentry(_ project: Discovery.Project, org: String) {
        let slug = project.slug ?? project.name
        guard !draft.services.sentry.contains(where: { $0.id == "\(org)/\(slug)" }) else { return }
        draft.services.sentry.append(.init(org: org, project: project.slug ?? project.name,
                                          name: project.name))
    }

    // MARK: - Manual entry
    //
    // The pickers are a convenience. Everything they set is a field the config
    // already accepts, so a token that cannot list projects, or a service with
    // no browsable list at all, still gets configured by typing it in.

    func addGitHubManually(owner: String, repo: String, branches: [String]) {
        let owner = owner.trimmingCharacters(in: .whitespaces)
        let repo = repo.trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty, !repo.isEmpty else { return }
        let target = Config.GitHubTarget(owner: owner, repo: repo, branches: branches)
        // Adding the same repository twice would double every row in the menu,
        // so an existing entry has its branches merged instead.
        if let index = draft.services.github.firstIndex(where: { $0.id == target.id }) {
            for branch in branches where !draft.services.github[index].branches.contains(branch) {
                draft.services.github[index].branches.append(branch)
            }
        } else {
            draft.services.github.append(target)
        }
    }

    func addVercelManually(projectId: String, teamId: String?, branches: [String]) {
        let projectId = projectId.trimmingCharacters(in: .whitespaces)
        guard !projectId.isEmpty else { return }
        let teamId = teamId?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let target = Config.VercelTarget(projectId: projectId, teamId: teamId, branches: branches)
        if let index = draft.services.vercel.firstIndex(where: { $0.id == target.id }) {
            for branch in branches where !draft.services.vercel[index].branches.contains(branch) {
                draft.services.vercel[index].branches.append(branch)
            }
            if teamId != nil { draft.services.vercel[index].teamId = teamId }
        } else {
            draft.services.vercel.append(target)
        }
    }

    func addSentryManually(org: String, project: String, newWithinHours: Int?) {
        let org = org.trimmingCharacters(in: .whitespaces)
        let project = project.trimmingCharacters(in: .whitespaces)
        guard !org.isEmpty, !project.isEmpty else { return }
        let target = Config.SentryTarget(org: org, project: project, newWithinHours: newWithinHours)
        if let index = draft.services.sentry.firstIndex(where: { $0.id == target.id }) {
            draft.services.sentry[index].newWithinHours = newWithinHours
        } else {
            draft.services.sentry.append(target)
        }
    }

    func removeGitHub(at offsets: IndexSet) {
        draft.services.github.remove(atOffsets: offsets)
    }

    func removeVercel(at offsets: IndexSet) {
        draft.services.vercel.remove(atOffsets: offsets)
    }

    func removeSentry(at offsets: IndexSet) {
        draft.services.sentry.remove(atOffsets: offsets)
    }

    // MARK: - Editing an existing target
    //
    // The rules live on `Config.Services` so they can be unit tested; these are
    // the thin wrappers that also log, which is what makes "I edited it and it
    // did not change" answerable from the log alone.

    func updateGitHub(at index: Int, owner: String, repo: String, branches: [String],
                      name: String?, strategy: GitHubProvider.Strategy?,
                      dashboardURL: String?) -> Bool {
        let before = draft.services.github.indices.contains(index)
            ? draft.services.github[index].id : nil
        let ok = draft.services.updateGitHub(at: index, owner: owner, repo: repo,
                                              branches: branches,
                                              name: name, strategy: strategy,
                                              dashboardURL: dashboardURL)
        if ok, let before {
            let after = draft.services.github[index].id
            Log.info("edited GitHub target \(before) -> \(after)")
        } else if !ok {
            Log.warning("refused to edit GitHub target at \(index): \(owner)/\(repo) "
                        + "(invalid, or already in the list)")
        }
        return ok
    }

    func updateVercel(at index: Int, projectId: String, teamId: String?, branches: [String],
                      name: String?, dashboardURL: String?) -> Bool {
        let before = draft.services.vercel.indices.contains(index)
            ? draft.services.vercel[index].id : nil
        let ok = draft.services.updateVercel(at: index, projectId: projectId,
                                             teamId: teamId, branches: branches,
                                             name: name, dashboardURL: dashboardURL)
        if ok, let before {
            Log.info("edited Vercel target \(before) -> \(projectId)")
        } else if !ok {
            Log.warning("refused to edit Vercel target at \(index): \(projectId) "
                        + "(invalid, or already in the list)")
        }
        return ok
    }

    func updateSentry(at index: Int, org: String, project: String, newWithinHours: Int?,
                      name: String?, dashboardURL: String?) -> Bool {
        let before = draft.services.sentry.indices.contains(index)
            ? draft.services.sentry[index].id : nil
        let ok = draft.services.updateSentry(at: index, org: org, project: project,
                                             newWithinHours: newWithinHours,
                                             name: name, dashboardURL: dashboardURL)
        if ok, let before {
            Log.info("edited Sentry target \(before) -> \(org)/\(project)")
        } else if !ok {
            Log.warning("refused to edit Sentry target at \(index): \(org)/\(project) "
                        + "(invalid, or already in the list)")
        }
        return ok
    }

    /// Adds or removes one branch, addressed by target id so a stale sheet cannot
    /// edit whichever row happens to have moved into that position.
    func toggleBranch(_ branch: String, forGitHub id: String) {
        guard let index = draft.services.indexOfGitHub(id) else { return }
        draft.services.toggleBranch(branch, forGitHub: index)
        let now = draft.services.github[index].branches
        Log.debug("\(id) branches: \(now.isEmpty ? "main only" : now.joined(separator: ", "))")
    }

    func toggleBranch(_ branch: String, forVercel id: String) {
        guard let index = draft.services.indexOfVercel(id) else { return }
        draft.services.toggleBranch(branch, forVercel: index)
        let now = draft.services.vercel[index].branches
        Log.debug("\(id) branches: \(now.isEmpty ? "main only" : now.joined(separator: ", "))")
    }

    /// Adds a branch to a target, ignoring a duplicate, because the list is
    /// also editable by typing and both routes reach here.
    func addBranch(_ branch: String, toGitHub index: Int) {
        guard draft.services.github.indices.contains(index) else { return }
        append(branch, to: &draft.services.github[index].branches)
    }

    func addBranch(_ branch: String, toVercel index: Int) {
        guard draft.services.vercel.indices.contains(index) else { return }
        append(branch, to: &draft.services.vercel[index].branches)
    }

    private func append(_ branch: String, to list: inout [String]) {
        let trimmed = branch.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !list.contains(trimmed) else { return }
        list.append(trimmed)
    }

    /// Branches a target already watches, so the picker can show them ticked.
    func watchedBranches(_ target: Config.GitHubTarget) -> Set<String> {
        Set(Config.branchesOrDefaultForDisplay(target.branches))
    }

    func watchedBranches(_ target: Config.VercelTarget) -> Set<String> {
        Set(Config.branchesOrDefaultForDisplay(target.branches))
    }

    // MARK: - Saving

    func save() {
        isSaving = true
        // The window can be closed while the write is in flight, so the result
        // is applied here rather than through `notice` alone.

        // Which services end up switched on.
        //
        // A service the user ticked, or one that already has a token stored, is
        // on. The second case is what fixes "configured but nothing works":
        // storing a token from the terminal and then adding targets in this window
        // used to leave a config with targets and no `tokens` section, so every row
        // reported its service as not enabled.
        //
        // Written as `true` only; a service that is off is left out entirely
        // rather than serialised as `false`.
        var tokens = Config.Tokens()
        for kind in Source.Kind.allCases where draft.tokens.isEnabled(kind) {
            tokens[kind] = true
        }
        for kind in Source.Kind.allCases
        where tokens[kind] == nil && TokenStore.hasToken(for: kind) {
            tokens[kind] = true
            Log.info("enabled \(kind.displayName) on save: a token is stored for it")
        }
        let trimmed = Config(
            pollIntervalSeconds: draft.pollIntervalSeconds.map { max(15, $0) },
            tokens: tokens,
            services: draft.services
        )
        if monitor.apply(trimmed) {
            saved = trimmed
            draft = trimmed
            Log.info("settings saved: \(trimmed.expandedSources.count) row(s), "
                     + trimmed.services.enabledTargetsDescription)
            notice = "Saved. \(trimmed.expandedSources.count) row(s) will be polled."
        } else {
            Log.error("settings could not be saved: \(monitor.configError ?? "unknown error")")
            notice = monitor.configError ?? "Could not save."
        }
        isSaving = false
    }
}

private extension String {
    /// Turns a blank field into "unset", so saving does not persist `"  "`.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Optional where Wrapped == String {
    /// Trims, then drops a blank, so an emptied optional field is removed from
    /// the config rather than written as `""`.
    var trimmedNil: String? {
        guard let value = self?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}

private extension String {
    /// Trimmed, then nil if blank. The shape the optional fields take.
    var trimmedNil: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}