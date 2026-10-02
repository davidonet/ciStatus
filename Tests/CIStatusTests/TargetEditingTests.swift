import Foundation
import XCTest
@testable import CIStatusKit

/// Editing rules for the configured target lists.
///
/// These live in `CIStatusKit` rather than the settings window because the window
/// is an executable target and cannot be tested. Each rule here exists because
/// getting it wrong produces something confusing rather than an error.
final class TargetEditingTests: XCTestCase {

    // MARK: - GitHub

    /// An edit keeps the target where it was. The config order is what the menu
    /// shows, so a row jumping to the bottom would read as delete-and-recreate.
    func testEditingKeepsTheTargetsPosition() throws {
        var services = Config.Services(github: [
            .init(owner: "a", repo: "one"),
            .init(owner: "a", repo: "two"),
            .init(owner: "a", repo: "three"),
        ])
        XCTAssertTrue(services.updateGitHub(at: 0, owner: "a", repo: "renamed",
                                            branches: ["main"], name: nil,
                                            strategy: nil, dashboardURL: nil))
        XCTAssertEqual(services.github.map(\.id), ["a/renamed", "a/two", "a/three"])
    }

    /// A renamed target is still the same row, now producing new menu entries.
    func testEditingChangesTheIdentityFields() throws {
        var services = Config.Services(github: [
            .init(owner: "a", repo: "typo", branches: ["main"]),
        ])
        XCTAssertTrue(services.updateGitHub(at: 0, owner: "a", repo: "fixed",
                                            branches: ["main", "develop"], name: "API",
                                            strategy: .actions, dashboardURL: "https://x"))
        let target = services.github[0]
        XCTAssertEqual(target.repo, "fixed")
        XCTAssertEqual(target.branches, ["main", "develop"])
        XCTAssertEqual(target.name, "API")
        XCTAssertEqual(target.strategy, .actions)
        XCTAssertEqual(target.dashboardURL, "https://x")
    }

    /// Editing one row into another would leave the same repository watched
    /// twice, so it is refused rather than merged.
    func testEditingIntoAnExistingTargetIsRefused() throws {
        var services = Config.Services(github: [
            .init(owner: "a", repo: "one"),
            .init(owner: "a", repo: "two"),
        ])
        XCTAssertFalse(services.updateGitHub(at: 0, owner: "a", repo: "two",
                                             branches: ["main"], name: nil,
                                             strategy: nil, dashboardURL: nil))
        XCTAssertEqual(services.github.map(\.id), ["a/one", "a/two"],
                       "nothing should have changed")
    }

    /// Saving a target unchanged must not be refused as its own duplicate,
    /// which is the case a naive "is this id already present" check gets wrong.
    func testEditingATargetToItselfIsAllowed() throws {
        var services = Config.Services(github: [
            .init(owner: "a", repo: "one", branches: ["main"]),
        ])
        XCTAssertTrue(services.updateGitHub(at: 0, owner: "a", repo: "one",
                                            branches: ["main", "dev"], name: nil,
                                            strategy: nil, dashboardURL: nil))
        XCTAssertEqual(services.github[0].branches, ["main", "dev"])
    }

    func testEditingRefusesBlankIdentityFields() {
        var services = Config.Services(github: [.init(owner: "a", repo: "one")])
        XCTAssertFalse(services.updateGitHub(at: 0, owner: "  ", repo: "one",
                                             branches: [], name: nil,
                                             strategy: nil, dashboardURL: nil))
        XCTAssertFalse(services.updateGitHub(at: 0, owner: "a", repo: "",
                                             branches: [], name: nil,
                                             strategy: nil, dashboardURL: nil))
        XCTAssertEqual(services.github.map(\.id), ["a/one"])
    }

    /// An out of range index is the window being stale, not a user error.
    func testEditingOutOfRangeIsRefused() {
        var services = Config.Services(github: [.init(owner: "a", repo: "one")])
        XCTAssertFalse(services.updateGitHub(at: 7, owner: "a", repo: "one",
                                             branches: [], name: nil,
                                             strategy: nil, dashboardURL: nil))
    }

    /// Whitespace in a pasted value must not end up as a row labelled "a / one".
    func testIdentityFieldsAreTrimmed() {
        var services = Config.Services(github: [.init(owner: "a", repo: "one")])
        XCTAssertTrue(services.updateGitHub(at: 0, owner: "  b  ", repo: "  two  ",
                                            branches: [], name: nil,
                                            strategy: nil, dashboardURL: nil))
        XCTAssertEqual(services.github[0].id, "b/two")
    }

    /// An optional field cleared in the editor is removed from the target, not
    /// written as an empty string.
    func testClearingOptionalFieldsRemovesThem() {
        var services = Config.Services(github: [
            .init(owner: "a", repo: "one", name: "Old label", dashboardURL: "https://old"),
        ])
        XCTAssertTrue(services.updateGitHub(at: 0, owner: "a", repo: "one", branches: [],
                                            name: "   ", strategy: nil, dashboardURL: ""))
        XCTAssertNil(services.github[0].name)
        XCTAssertNil(services.github[0].dashboardURL)
    }

    // MARK: - Vercel and Sentry

    func testEditingAVercelTeamId() {
        var services = Config.Services(vercel: [
            .init(projectId: "prj_1", teamId: "team_old", branches: ["main"]),
        ])
        XCTAssertTrue(services.updateVercel(at: 0, projectId: "prj_1", teamId: " team_new ",
                                            branches: ["main", "dev"], name: nil,
                                            dashboardURL: nil))
        XCTAssertEqual(services.vercel[0].teamId, "team_new")
        XCTAssertEqual(services.vercel[0].branches, ["main", "dev"])
    }

    /// A personal Vercel token needs no team, so the field has to be clearable.
    func testAVercelTeamIdCanBeCleared() {
        var services = Config.Services(vercel: [
            .init(projectId: "prj_1", teamId: "team_old"),
        ])
        XCTAssertTrue(services.updateVercel(at: 0, projectId: "prj_1", teamId: nil,
                                            branches: [], name: nil, dashboardURL: nil))
        XCTAssertNil(services.vercel[0].teamId)
    }

    func testEditingIntoAnExistingVercelProjectIsRefused() {
        var services = Config.Services(vercel: [
            .init(projectId: "prj_1"),
            .init(projectId: "prj_2"),
        ])
        XCTAssertFalse(services.updateVercel(at: 0, projectId: "prj_2", teamId: nil,
                                             branches: [], name: nil, dashboardURL: nil))
        XCTAssertEqual(services.vercel.map(\.id), ["prj_1", "prj_2"])
    }

    func testEditingASentryWindow() {
        var services = Config.Services(sentry: [
            .init(org: "o", project: "p", newWithinHours: 24),
        ])
        XCTAssertTrue(services.updateSentry(at: 0, org: "o", project: "p",
                                            newWithinHours: 6, name: "Web", dashboardURL: nil))
        XCTAssertEqual(services.sentry[0].newWithinHours, 6)
        XCTAssertEqual(services.sentry[0].name, "Web")
    }

    /// A blank window falls back to the provider's own default rather than
    /// meaning "new issues ever", which would leave the dot red forever.
    func testASentryWindowCanBeClearedToTheDefault() {
        var services = Config.Services(sentry: [
            .init(org: "o", project: "p", newWithinHours: 24),
        ])
        XCTAssertTrue(services.updateSentry(at: 0, org: "o", project: "p",
                                            newWithinHours: nil, name: nil, dashboardURL: nil))
        XCTAssertNil(services.sentry[0].newWithinHours)
    }

    func testEditingIntoAnExistingSentryProjectIsRefused() {
        var services = Config.Services(sentry: [
            .init(org: "o", project: "web"),
            .init(org: "o", project: "api"),
        ])
        XCTAssertFalse(services.updateSentry(at: 0, org: "o", project: "api",
                                             newWithinHours: nil, name: nil, dashboardURL: nil))
        XCTAssertEqual(services.sentry.map(\.id), ["o/web", "o/api"])
    }

    // MARK: - Branch toggling

    /// Ticking and unticking, because the branch picker is a checkbox list and an
    /// untick that does nothing looks broken.
    func testTogglingABranchAddsThenRemovesIt() {
        var services = Config.Services(github: [.init(owner: "a", repo: "one")])
        services.toggleBranch("main", forGitHub: 0)
        XCTAssertEqual(services.github[0].branches, ["main"])
        services.toggleBranch("main", forGitHub: 0)
        XCTAssertEqual(services.github[0].branches, [], "unticking must remove it")
    }

    /// An empty list means main only, so it is a legitimate end state rather than
    /// a target that is suddenly not polled.
    func testAnEmptyBranchListStillPollsMain() throws {
        var services = Config.Services(github: [
            .init(owner: "a", repo: "one", branches: ["main", "dev"]),
        ])
        services.toggleBranch("main", forGitHub: 0)
        services.toggleBranch("dev", forGitHub: 0)
        XCTAssertTrue(services.github[0].branches.isEmpty)
        let config = Config(services: services)
        XCTAssertEqual(config.expandedSources.map(\.branch), ["main"],
                       "an empty list falls back to main rather than polling nothing")
    }

    func testTogglingIsTrimmedAndIgnoresBlank() {
        var services = Config.Services(github: [.init(owner: "a", repo: "one")])
        services.toggleBranch("  develop  ", forGitHub: 0)
        XCTAssertEqual(services.github[0].branches, ["develop"])
        services.toggleBranch("   ", forGitHub: 0)
        XCTAssertEqual(services.github[0].branches, ["develop"], "blank is ignored")
    }

    /// Two entries differing only in whitespace must toggle as one branch, or the
    /// second tick silently un-ticks the first.
    func testTogglingMatchesAfterTrimming() {
        var services = Config.Services(github: [.init(owner: "a", repo: "one")])
        services.toggleBranch("dev", forGitHub: 0)
        services.toggleBranch(" dev ", forGitHub: 0)
        XCTAssertEqual(services.github[0].branches, [])
    }

    func testTogglingOutOfRangeIsIgnored() {
        var services = Config.Services(github: [.init(owner: "a", repo: "one")])
        services.toggleBranch("main", forGitHub: 9)
        XCTAssertEqual(services.github[0].branches, [])
    }

    func testVercelBranchToggling() {
        var services = Config.Services(vercel: [.init(projectId: "prj_1")])
        services.toggleBranch("main", forVercel: 0)
        XCTAssertEqual(services.vercel[0].branches, ["main"])
        services.toggleBranch("main", forVercel: 0)
        XCTAssertEqual(services.vercel[0].branches, [])
    }

    // MARK: - Lookup

    /// The window addresses targets by id, so a stale sheet cannot edit whichever
    /// row moved into that position.
    func testLookupById() {
        let services = Config.Services(
            github: [.init(owner: "a", repo: "one")],
            vercel: [.init(projectId: "prj_1")],
            sentry: [.init(org: "o", project: "p")])
        XCTAssertEqual(services.indexOfGitHub("a/one"), 0)
        XCTAssertEqual(services.indexOfVercel("prj_1"), 0)
        XCTAssertEqual(services.indexOfSentry("o/p"), 0)
        XCTAssertNil(services.indexOfGitHub("a/missing"))
    }

    /// An edit has to survive a save and reload, or it only appears to work until
    /// the app restarts.
    func testEditsSurviveSaveAndLoad() throws {
        var original = Config(
            services: Config.Services(github: [.init(owner: "a", repo: "typo", branches: ["main"])])
        )
        XCTAssertTrue(original.services.updateGitHub(at: 0, owner: "a", repo: "fixed",
                                                     branches: ["main", "develop"],
                                                     name: "API", strategy: .checks,
                                                     dashboardURL: nil))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cistatus-edit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try original.save(to: url)
        let reloaded = try Config.load(from: url)
        XCTAssertEqual(reloaded.services.github[0].id, "a/fixed")
        XCTAssertEqual(reloaded.services.github[0].branches, ["main", "develop"])
        XCTAssertEqual(reloaded.services.github[0].strategy, .checks)
        XCTAssertEqual(reloaded.expandedSources.map(\.name), ["API · main", "API · develop"])
    }
}
