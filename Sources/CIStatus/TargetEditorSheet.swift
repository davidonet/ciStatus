import CIStatusKit
import SwiftUI

/// Adds a target, or edits one that is already configured.
///
/// Every field is the same one the config already accepts, so this is a
/// convenience over hand editing. It is always available: browsing needs a
/// token, this does not, and a service with no token is still configurable.
///
/// In edit mode the fields come pre-filled, and the identity fields (owner/repo,
/// projectId, org/project) can be changed. That is deliberate: an entry added
/// with a typo is otherwise only fixable by deleting it and adding it again.
struct TargetEditorSheet: View {
    /// What is being edited, if anything. Nil means add.
    enum Subject {
        case add
        case editGitHub(Config.GitHubTarget)
        case editVercel(Config.VercelTarget)
        case editSentry(Config.SentryTarget)

        var isEdit: Bool {
            if case .add = self { return false }
            return true
        }
    }

    let kind: Source.Kind
    let subject: Subject
    @ObservedObject var model: SettingsModel
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var owner = ""
    @State private var repo = ""
    @State private var branches = ""
    @State private var projectId = ""
    @State private var teamId = ""
    @State private var org = ""
    @State private var project = ""
    @State private var newWithinHours = ""
    @State private var label = ""
    @State private var dashboardURL = ""
    @State private var strategy: GitHubProvider.Strategy = .auto

    /// Shown when an edit is refused, since the button going dead would not say why.
    @State private var failure: String?

    init(kind: Source.Kind, subject: Subject = .add, model: SettingsModel,
         onDone: @escaping () -> Void) {
        self.kind = kind
        self.subject = subject
        self.model = model
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch kind {
                    case .github: githubFields
                    case .vercel: vercelFields
                    case .sentry: sentryFields
                    }
                    commonFields
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 520)
        // Prefilled once, on first appearance, so a later edit to the draft does
        // not overwrite what is being typed.
        .onAppear(perform: prefill)
    }

    private var header: some View {
        HStack {
            Text(subject.isEdit
                 ? "Edit \(kind.displayName) target"
                 : "Add a \(kind.displayName) target")
                .font(.headline)
            Spacer()
        }
        .padding(20)
    }

    // MARK: - Fields

    @ViewBuilder
    private var githubFields: some View {
        LabelledField(label: "Owner", placeholder: "your-org", text: $owner)
        LabelledField(label: "Repository", placeholder: "api", text: $repo)
        BranchesField(text: $branches)
        Picker("Strategy", selection: $strategy) {
            Text("Auto (Checks, falling back to Actions)").tag(GitHubProvider.Strategy.auto)
            Text("Checks only").tag(GitHubProvider.Strategy.checks)
            Text("Actions only").tag(GitHubProvider.Strategy.actions)
        }
        .pickerStyle(.menu)
        .help("Which GitHub API to read. See the README for what each one can see.")
        Text("Leave branches empty to watch main only.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var vercelFields: some View {
        LabelledField(label: "Project ID", placeholder: "prj_…", text: $projectId)
        LabelledField(label: "Team ID", placeholder: "team_… (optional)", text: $teamId)
        BranchesField(text: $branches)
        Text("The team must match the token's scope, or every call returns 403. "
             + "Leave branches empty to watch main only.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var sentryFields: some View {
        LabelledField(label: "Organisation", placeholder: "your-org", text: $org)
        LabelledField(label: "Project", placeholder: "web (the slug, not the name)", text: $project)
        LabelledField(label: "New within hours", placeholder: "24", text: $newWithinHours)
        Text("Sentry has no branches. A project counts as new when an issue was "
             + "first seen within this window.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    /// Applied to every service.
    @ViewBuilder
    private var commonFields: some View {
        Divider()
        LabelledField(label: "Menu label", placeholder: "optional", text: $label)
        LabelledField(label: "Dashboard link", placeholder: "optional", text: $dashboardURL)
        Text("The label is what the menu shows. The link overrides the one derived "
             + "from the other fields.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let message = failure ?? problem {
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button(subject.isEdit ? "Save" : "Add") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(failure == nil && problem != nil)
        }
        .padding(20)
    }

    // MARK: - Validation

    /// Why the button is disabled, or nil when it is not.
    private var problem: String? {
        if let failure { return failure }
        switch kind {
        case .github:
            if owner.trimmingCharacters(in: .whitespaces).isEmpty { return "Owner is required." }
            if repo.trimmingCharacters(in: .whitespaces).isEmpty { return "Repository is required." }
            if clashes(id: "\(owner.trimmingCharacters(in: .whitespaces))/\(repo.trimmingCharacters(in: .whitespaces))") {
                return "Already in the list."
            }
        case .vercel:
            if projectId.trimmingCharacters(in: .whitespaces).isEmpty { return "Project ID is required." }
            if clashes(id: projectId.trimmingCharacters(in: .whitespaces)) {
                return "Already in the list."
            }
        case .sentry:
            if org.trimmingCharacters(in: .whitespaces).isEmpty { return "Organisation is required." }
            if project.trimmingCharacters(in: .whitespaces).isEmpty { return "Project is required." }
            if clashes(id: "\(org.trimmingCharacters(in: .whitespaces))/\(project.trimmingCharacters(in: .whitespaces))") {
                return "Already in the list."
            }
        }
        if kind == .sentry, !newWithinHours.isEmpty, Int(newWithinHours) == nil {
            return "New within hours must be a number."
        }
        return nil
    }

    /// True when another target, other than the one being edited, has this id.
    ///
    /// In add mode nothing is being edited, so any match is a duplicate. In edit
    /// mode the target being edited always matches its own id, so it is excluded
    /// or every edit would look like a duplicate.
    private func clashes(id: String) -> Bool {
        let others: [String]
        switch subject {
        case .add:
            others = allIds
        case let .editGitHub(current) where kind == .github:
            others = allIds.filter { $0 != current.id }
        case let .editVercel(current) where kind == .vercel:
            others = allIds.filter { $0 != current.id }
        case let .editSentry(current) where kind == .sentry:
            others = allIds.filter { $0 != current.id }
        default:
            // A mismatched pair should not happen, but treating it as add is the
            // safe reading: refuse rather than silently overwrite.
            others = allIds
        }
        return others.contains(id)
    }

    private var allIds: [String] {
        switch kind {
        case .github: return model.draft.services.github.map(\.id)
        case .vercel: return model.draft.services.vercel.map(\.id)
        case .sentry: return model.draft.services.sentry.map(\.id)
        }
    }

    // MARK: - Applying

    private var parsedBranches: [String] {
        branches
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var parsedHours: Int? {
        let trimmed = newWithinHours.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Int(trimmed)
    }

    private func apply() {
        failure = nil
        let name = label.trimmedOrNil
        let link = dashboardURL.trimmedOrNil

        switch kind {
        case .github:
            if case let .editGitHub(current) = subject,
               let index = model.draft.services.github.firstIndex(where: { $0.id == current.id }) {
                if model.updateGitHub(at: index, owner: owner, repo: repo,
                                      branches: parsedBranches, name: name, strategy: strategy,
                                      dashboardURL: link) {
                    Log.info("edited GitHub target \(current.id)")
                    finish()
                } else {
                    failure = "Could not save that change."
                }
            } else {
                model.addGitHubManually(owner: owner, repo: repo, branches: parsedBranches)
                applyNameAndLink(name: name, link: link)
                Log.info("added GitHub target \(owner)/\(repo)")
                finish()
            }
        case .vercel:
            if case let .editVercel(current) = subject,
               let index = model.draft.services.vercel.firstIndex(where: { $0.id == current.id }) {
                if model.updateVercel(at: index, projectId: projectId, teamId: teamId,
                                      branches: parsedBranches, name: name, dashboardURL: link) {
                    Log.info("edited Vercel target \(current.id)")
                    finish()
                } else {
                    failure = "Could not save that change."
                }
            } else {
                model.addVercelManually(projectId: projectId, teamId: teamId,
                                        branches: parsedBranches)
                applyNameAndLink(name: name, link: link)
                Log.info("added Vercel target \(projectId)")
                finish()
            }
        case .sentry:
            if case let .editSentry(current) = subject,
               let index = model.draft.services.sentry.firstIndex(where: { $0.id == current.id }) {
                if model.updateSentry(at: index, org: org, project: project,
                                      newWithinHours: parsedHours, name: name,
                                      dashboardURL: link) {
                    Log.info("edited Sentry target \(current.id)")
                    finish()
                } else {
                    failure = "Could not save that change."
                }
            } else {
                model.addSentryManually(org: org, project: project, newWithinHours: parsedHours)
                applyNameAndLink(name: name, link: link)
                Log.info("added Sentry target \(org)/\(project)")
                finish()
            }
        }
    }

    /// The label and link are not arguments to the add helpers, so they are
    /// applied to the row that was just added.
    private func applyNameAndLink(name: String?, link: String?) {
        guard name != nil || link != nil else { return }
        switch kind {
        case .github:
            if let last = model.draft.services.github.indices.last {
                model.draft.services.github[last].name = name
                model.draft.services.github[last].dashboardURL = link
            }
        case .vercel:
            if let last = model.draft.services.vercel.indices.last {
                model.draft.services.vercel[last].name = name
                model.draft.services.vercel[last].dashboardURL = link
            }
        case .sentry:
            if let last = model.draft.services.sentry.indices.last {
                model.draft.services.sentry[last].name = name
                model.draft.services.sentry[last].dashboardURL = link
            }
        }
    }

    private func finish() {
        onDone()
        dismiss()
    }

    private func prefill() {
        switch subject {
        case .add:
            break
        case let .editGitHub(target):
            owner = target.owner
            repo = target.repo
            branches = target.branches.joined(separator: ", ")
            label = target.name ?? ""
            dashboardURL = target.dashboardURL ?? ""
            strategy = target.strategy ?? .auto
        case let .editVercel(target):
            projectId = target.projectId
            teamId = target.teamId ?? ""
            branches = target.branches.joined(separator: ", ")
            label = target.name ?? ""
            dashboardURL = target.dashboardURL ?? ""
        case let .editSentry(target):
            org = target.org
            project = target.project
            newWithinHours = target.newWithinHours.map(String.init) ?? ""
            label = target.name ?? ""
            dashboardURL = target.dashboardURL ?? ""
        }
    }
}

private extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct LabelledField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).frame(width: 120, alignment: .leading)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct BranchesField: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabelledField(label: "Branches", placeholder: "main, develop", text: $text)
            Text("Separate with commas. Each branch becomes its own row in the menu.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
