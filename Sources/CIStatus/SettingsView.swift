import CIStatusKit
import SwiftUI

/// The settings window: a Tokens section and a Services section.
///
/// The window edits a draft and only writes on Save, so a half-finished change
/// never changes what the menu bar is showing.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    /// Which sheet, if any, is open.
    ///
    /// One enum rather than a kind plus a separate branch flag: a Vercel row's
    /// **Branches…** and its **Browse…** are different sheets, and when both were
    /// tracked separately the branch button opened the project picker.
    @State private var sheet: Sheet?
    /// Which provider's add sheet is open. Nil means none.
    @State private var adding: Source.Kind?
    /// The target being edited, if any.
    @State private var editing: EditRequest?

    enum Sheet: Identifiable {
        /// Pick a repository or project to add.
        case browse(Source.Kind)
        /// Pick branches for a repository already in the list.
        case branchesGitHub(Discovery.Repo)
        /// Pick branches for a Vercel project already in the list.
        case branchesVercel(projectId: String, label: String)

        var id: String {
            switch self {
            case let .browse(kind): return "browse-\(kind.rawValue)"
            case let .branchesGitHub(repo): return "branches-\(repo.id)"
            case let .branchesVercel(projectId, _): return "branches-\(projectId)"
            }
        }
    }

    /// Identifies a target to edit, by service and id.
    ///
    /// Addressing by id rather than index because an edit can change the id, and
    /// looking the row up again at save time is what keeps that from editing the
    /// wrong entry.
    struct EditRequest: Identifiable {
        let kind: Source.Kind
        let id: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    tokensSection
                    servicesSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 620)
        .sheet(item: $sheet) { sheet in
            picker(for: sheet)
        }
        .sheet(item: $adding) { kind in
            TargetEditorSheet(kind: kind, subject: .add, model: model) { adding = nil }
        }
        .sheet(item: $editing) { request in
            editor(for: request)
        }
    }

    /// The edit sheet, with the existing target's values loaded into it.
    ///
    /// Falls back to the add sheet when the target has gone, which can happen if
    /// the config was reloaded while the sheet was open. Adding is a better
    /// outcome than an empty editor with no explanation.
    @ViewBuilder
    private func editor(for request: EditRequest) -> some View {
        switch request.kind {
        case .github:
            if let target = model.draft.services.github.first(where: { $0.id == request.id }) {
                TargetEditorSheet(kind: .github, subject: .editGitHub(target), model: model) {
                    editing = nil
                }
            } else {
                TargetEditorSheet(kind: .github, subject: .add, model: model) { editing = nil }
            }
        case .vercel:
            if let target = model.draft.services.vercel.first(where: { $0.id == request.id }) {
                TargetEditorSheet(kind: .vercel, subject: .editVercel(target), model: model) {
                    editing = nil
                }
            } else {
                TargetEditorSheet(kind: .vercel, subject: .add, model: model) { editing = nil }
            }
        case .sentry:
            if let target = model.draft.services.sentry.first(where: { $0.id == request.id }) {
                TargetEditorSheet(kind: .sentry, subject: .editSentry(target), model: model) {
                    editing = nil
                }
            } else {
                TargetEditorSheet(kind: .sentry, subject: .add, model: model) { editing = nil }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ciStatus").font(.headline)
                Text("Tokens are stored in their own file; this config holds no secrets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Stepper(value: intervalBinding, in: 15...3600, step: 15) {
                Text("Every \(model.draft.pollIntervalSeconds ?? 60)s")
                    .font(.caption).monospacedDigit()
            }
            .fixedSize()
        }
        .padding(20)
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { model.draft.pollIntervalSeconds ?? 60 },
            set: { model.draft.pollIntervalSeconds = $0 }
        )
    }

    // MARK: - Tokens

    private var tokensSection: some View {
        SectionBox(title: "Tokens",
                   subtitle: "In tokens.json, readable only by you. The config file holds no secrets.") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Source.Kind.allCases) { kind in
                    TokenRow(kind: kind, model: model)
                }
                Text("A service without a stored token is reported as unreachable, which is "
                     + "why you can configure everything below and add tokens afterwards.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Services

    private var servicesSection: some View {
        SectionBox(title: "Services", subtitle: "What to watch. Each branch becomes its own row in the menu.") {
            VStack(alignment: .leading, spacing: 22) {
                githubSection
                vercelSection
                sentrySection
            }
        }
    }

    private var githubSection: some View {
        ServiceBox(kind: .github, model: model, onPick: {
            sheet = .browse(.github)
        }, onManual: {
            adding = .github
        }) {
            if model.draft.services.github.isEmpty {
                EmptyHint(text: "No repositories yet.")
            }
            ForEach(model.draft.services.github, id: \.id) { target in
                TargetRow(
                    title: target.id,
                    subtitle: target.branches.isEmpty ? "main" : target.branches.joined(separator: ", "),
                    onEdit: { editing = EditRequest(kind: .github, id: target.id) },
                    onRemove: { model.draft.services.github.removeAll { $0.id == target.id } },
                    onPickBranches: {
                        sheet = .branchesGitHub(Discovery.Repo(owner: target.owner, name: target.repo))
                    })
            }
        }
    }

    private var vercelSection: some View {
        ServiceBox(kind: .vercel, model: model, onPick: {
            sheet = .browse(.vercel)
        }, onManual: {
            adding = .vercel
        }) {
            if model.draft.services.vercel.isEmpty {
                EmptyHint(text: "No projects yet.")
            }
            ForEach(model.draft.services.vercel, id: \.id) { target in
                TargetRow(
                    title: target.name ?? target.projectId,
                    subtitle: target.branches.isEmpty ? "main" : target.branches.joined(separator: ", "),
                    onEdit: { editing = EditRequest(kind: .vercel, id: target.id) },
                    onRemove: { model.draft.services.vercel.removeAll { $0.id == target.id } },
                    onPickBranches: {
                        sheet = .branchesVercel(projectId: target.projectId,
                                                label: target.name ?? target.projectId)
                    })
            }
        }
    }

    private var sentrySection: some View {
        ServiceBox(kind: .sentry, model: model, onPick: {
            sheet = .browse(.sentry)
        }, onManual: {
            adding = .sentry
        }) {
            if model.draft.services.sentry.isEmpty {
                EmptyHint(text: "No projects yet.")
            }
            ForEach(model.draft.services.sentry, id: \.id) { target in
                TargetRow(
                    title: target.name ?? target.project,
                    subtitle: target.newWithinHours.map { "new issues in \($0)h" } ?? "new issues in 24h",
                    onEdit: { editing = EditRequest(kind: .sentry, id: target.id) },
                    onRemove: { model.draft.services.sentry.removeAll { $0.id == target.id } },
                    onPickBranches: nil
                )
            }
        }
    }

    // MARK: - Pickers

    @ViewBuilder
    private func picker(for sheet: Sheet) -> some View {
        switch sheet {
        case let .browse(kind):
            switch kind {
            case .github:
                RepoPicker(model: model) { self.sheet = nil }
            case .vercel:
                ProjectPicker(kind: .vercel, model: model, onAdd: { project in
                    model.addVercel(project, teamId: model.draft.services.vercel.first?.teamId)
                }, onDone: {
                    self.sheet = nil
                })
            case .sentry:
                ProjectPicker(kind: .sentry, model: model, onAdd: { project in
                    model.addSentry(project, org: model.draft.services.sentry.first?.org ?? "")
                }, onDone: {
                    self.sheet = nil
                })
            }
        case let .branchesGitHub(repo):
            let watched = model.watchedBranches(
                model.draft.services.github.first { $0.id == repo.id }
                    ?? Config.GitHubTarget(owner: repo.owner, repo: repo.name))
            BranchPicker(
                title: repo.id,
                branches: model.branches,
                error: model.branches.error,
                isLoading: model.branches.isLoading,
                watched: watched,
                load: { model.discoverBranches(for: repo) },
                toggle: { branch in model.toggleBranch(branch, forGitHub: repo.id) })
        case let .branchesVercel(projectId, label):
            BranchPicker(
                title: label,
                branches: model.vercelBranches,
                error: model.vercelBranches.error,
                isLoading: model.vercelBranches.isLoading,
                watched: Set(Config.branchesOrDefaultForDisplay(
                    model.draft.services.vercel.first { $0.id == projectId }?.branches ?? [])),
                load: { model.discoverVercelBranches(projectId: projectId) },
                toggle: { branch in model.toggleBranch(branch, forVercel: projectId) })
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Revert") { model.revert() }
                .disabled(!model.hasChanges)
            Button("Save") { model.save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.hasChanges || model.isSaving)
        }
        .padding(20)
    }
}

// MARK: - Sections

private struct SectionBox<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content
        }
    }
}

/// One provider's block: its two ways of adding a target, plus the list.
///
/// Browsing and typing are both always offered. Browsing needs a token, and it
/// is disabled without one, but typing the same values needs nothing, so a
/// service with no token is still configurable rather than a dead end.
private struct ServiceBox<Content: View>: View {
    let kind: Source.Kind
    @ObservedObject var model: SettingsModel
    let onPick: () -> Void
    let onManual: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(kind.displayName, systemImage: icon).font(.subheadline.weight(.semibold))
                Spacer()
                Button("Add manually…", action: onManual)
                Button("Browse…", action: onPick)
                    .disabled(!model.canDiscover(kind))
                    .help(model.canDiscover(kind)
                          ? "Pick from what your token can see."
                          : "Needs a \(kind.displayName) token first. Use Add manually… instead.")
            }
            content
            // Only the browse state is shown here. The branch pickers report
            // their own failures inside their own sheet, so a failed branch
            // lookup does not leave a stale error sitting under the list.
            if let error = browseError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if browseTruncated {
                Text("Showing the first page only; some entries may be missing.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch kind {
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .vercel: return "triangle"
        case .sentry: return "exclamationmark.triangle"
        }
    }

    private var browseError: String? {
        switch kind {
        case .github: return model.repos.error
        case .vercel, .sentry: return model.projects.error
        }
    }

    private var browseTruncated: Bool {
        switch kind {
        case .github: return model.repos.wasTruncated
        case .vercel, .sentry: return model.projects.wasTruncated
        }
    }
}

/// A configured target, with the ways it can be changed.
///
/// **Edit…** covers every field, including the identity ones, so a typo in a
/// repository or project id is fixable without deleting the entry. Branches keep
/// their own button because picking them from the API is quicker than typing when
/// a token is available.
private struct TargetRow: View {
    let title: String
    let subtitle: String
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onPickBranches: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let onPickBranches {
                Button("Branches…", action: onPickBranches)
                    .font(.caption)
            }
            Button("Edit…", action: onEdit)
                .font(.caption)
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

private struct TokenRow: View {
    let kind: Source.Kind
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(kind.displayName).frame(width: 66, alignment: .leading)

                SecureField(placeholder, text: tokenBinding)
                    .textFieldStyle(.roundedBorder)

                Button("Save") {
                    model.storeToken(tokenBinding.wrappedValue, for: kind)
                }
                .disabled(tokenBinding.wrappedValue
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Remove") { model.removeToken(for: kind) }
                    .disabled(model.storedToken(for: kind) == nil)

                storedBadge
            }
        }
    }

    /// Says whether a token is actually there, since an empty field looks the
    /// same whether one is stored or not.
    @ViewBuilder
    private var storedBadge: some View {
        if model.storedToken(for: kind) != nil {
            Label("stored", systemImage: "key.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
                .help("A token for \(kind.displayName) is stored.")
        } else {
            Text("not stored").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var placeholder: String {
        model.storedToken(for: kind) == nil
            ? "\(kind.displayName) token"
            : "replace the stored token"
    }

    private var tokenBinding: Binding<String> {
        Binding(
            get: { model.tokens[kind] ?? "" },
            set: { model.tokens[kind] = $0 }
        )
    }
}

private struct EmptyHint: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Picker sheets

private struct RepoPicker: View {
    @ObservedObject var model: SettingsModel
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        List {
            ForEach(filtered, id: \.id) { repo in
                Button {
                    model.addGitHub(repo)
                    onDone()
                    dismiss()
                } label: {
                    HStack {
                        Text(repo.id)
                        Spacer()
                        Image(systemName: "plus.circle")
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .searchable(text: $search, prompt: "Filter repositories")
        .overlay { if model.repos.isLoading { ProgressView() } }
        .navigationTitle("Add a repository")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .frame(width: 440, height: 420)
        .task {
            // Fetch on appear so the list is never empty for no stated reason.
            if model.repos.items.isEmpty { model.discoverRepos() }
        }
    }

    private var filtered: [Discovery.Repo] {
        guard !search.isEmpty else { return model.repos.items }
        return model.repos.items.filter {
            $0.id.localizedCaseInsensitiveContains(search)
        }
    }
}

/// Picks which branches a configured target watches.
///
/// Branches are toggled rather than added one at a time, so unticking one is
/// possible too. A typed entry is always offered as well, since the list comes
/// from the API and a branch with no recent activity will not be in it.
private struct BranchPicker: View {
    let title: String
    @ObservedObject var branches: SettingsModel.ServiceState<String>
    let error: String?
    let isLoading: Bool
    let watched: Set<String>
    let load: () -> Void
    let toggle: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var manual = ""

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(branches.items, id: \.self) { branch in
                    Button {
                        toggle(branch)
                    } label: {
                        HStack {
                            Image(systemName: watched.contains(branch) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(watched.contains(branch) ? Color.green : Color.secondary)
                            Text(branch)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                } else if let error {
                    VStack(spacing: 6) {
                        Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try again", action: load).font(.caption)
                    }
                    .padding()
                } else if branches.items.isEmpty {
                    EmptyHint(text: "No branches returned.")
                        .padding()
                }
            }

            Divider()
            HStack {
                TextField("or type a branch", text: $manual)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addManual)
                Button("Add", action: addManual)
                    .disabled(manual.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .navigationTitle(title)
        .frame(width: 420, height: 440)
        .task { load() }
    }

    private func addManual() {
        let branch = manual.trimmingCharacters(in: .whitespaces)
        guard !branch.isEmpty else { return }
        toggle(branch)
        manual = ""
    }
}

private struct ProjectPicker: View {
    let kind: Source.Kind
    @ObservedObject var model: SettingsModel
    let onAdd: (Discovery.Project) -> Void
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            if kind == .sentry { sentryOrgBar }
            List {
                ForEach(filtered, id: \.id) { project in
                    Button {
                        onAdd(project)
                        dismiss()
                    } label: {
                        HStack {
                            Text(project.name)
                            Text(project.slug ?? project.id)
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "plus.circle")
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $search, prompt: "Filter projects")
            .overlay { if model.projects.isLoading { ProgressView() } }

            Divider()
            HStack {
                if let error = model.projects.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .navigationTitle("Add a \(kind.displayName) project")
        .frame(width: 460, height: 440)
        .task {
            model.discoverProjects(for: kind)
        }
    }

    /// Sentry projects live inside an organisation, so it is chosen before the
    /// project list is meaningful.
    private var sentryOrgBar: some View {
        HStack {
            Text("Organisation")
            if model.orgs.items.isEmpty {
                Button("Load organisations") { model.discoverOrgs() }
            } else {
                Picker("", selection: sentryOrgBinding) {
                    Text("Choose…").tag(String?.none)
                    ForEach(model.orgs.items) { org in
                        Text(org.name).tag(String?.some(org.slug))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var sentryOrgBinding: Binding<String?> {
        Binding(
            get: { model.draft.services.sentry.first?.org },
            set: { newValue in
                guard let newValue else { return }
                // Stored on every Sentry target so the org survives a project
                // being the only one configured.
                for index in model.draft.services.sentry.indices {
                    model.draft.services.sentry[index].org = newValue
                }
                model.discoverProjects(for: .sentry)
            }
        )
    }

    private var filtered: [Discovery.Project] {
        guard !search.isEmpty else { return model.projects.items }
        return model.projects.items.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || ($0.slug?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }
}