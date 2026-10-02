import Foundation
import XCTest
@testable import CIStatusKit

/// Discovery is what turns "type owner/repo from memory" into "pick from a
/// list", so the parsing and the failure wording both matter: a wrong branch
/// list here becomes a wrong config in someone's menu bar.
final class DiscoveryTests: XCTestCase {
    private let discovery = Discovery()

    // MARK: - GitHub

    private let reposPayload = json("""
    [
      {"name": "api",     "full_name": "acme/api",     "owner": {"login": "acme"}, "archived": false, "fork": false},
      {"name": "web",     "full_name": "acme/web",     "owner": {"login": "acme"}, "archived": false, "fork": false},
      {"name": "api-docs","full_name": "acme/api-docs","owner": {"login": "acme"}, "archived": false, "fork": false},
      {"name": "old",     "full_name": "acme/old",     "owner": {"login": "acme"}, "archived": true,  "fork": false},
      {"name": "api-fork","full_name": "acme/api-fork","owner": {"login": "acme"}, "archived": false, "fork": true},
      {"name": "solo",    "full_name": "me/solo",      "owner": {"login": "me"},   "archived": false, "fork": false}
    ]
    """)

    /// The owner must come from the payload, not from a remembered constant, or
    /// a repo owned by someone else is filed under the wrong account.
    func testGitHubReposUseTheOwnersFromTheResponse() async throws {
        let http = StubHTTP(map: ["/repos": { self.reposPayload }])
        let repos = try await Discovery(http: http).githubRepos(token: "t")
        let owners = Set(repos.map(\.owner))
        XCTAssertTrue(owners.contains("acme"))
        XCTAssertTrue(owners.contains("me"), "a second owner must not be folded into the first")
    }

    /// Archived repositories and forks are almost never what you want to watch,
    /// so they are kept out of the picker rather than listed and ignored.
    func testGitHubReposHideArchivedAndForks() async throws {
        let http = StubHTTP(map: ["/repos": { self.reposPayload }])
        let repos = try await Discovery(http: http).githubRepos(token: "t")
        let ids = repos.map(\.id)
        XCTAssertFalse(ids.contains("acme/old"), "archived repositories are noise")
        XCTAssertFalse(ids.contains("acme/api-fork"), "forks are noise")
        // Two owners coexist in one list, so the id must disambiguate them.
        XCTAssertEqual(ids, ["acme/api", "acme/api-docs", "acme/web", "me/solo"])
    }

    /// Without an owner the token's whole visible world is the useful answer,
    /// so the token has to see repositories it does not own.
    func testGitHubReposWithoutOwnerAsksForEverythingVisible() async throws {
        let http = StubHTTP(map: ["/user/repos": { self.reposPayload }])
        _ = try await Discovery(http: http).githubRepos(token: "t")
        let requested = try XCTUnwrap(http.requested.first)
        // Without this a fine grained token silently sees only what it owns.
        XCTAssertTrue(requested.contains("affiliation="), requested)
    }

    func testGitHubReposWithOwnerQueriesThatOwner() async throws {
        let http = StubHTTP(map: ["/users/acme/repos": { self.reposPayload }])
        _ = try await Discovery(http: http).githubRepos(token: "t", owner: "acme")
        let requested = try XCTUnwrap(http.requested.first)
        XCTAssertTrue(requested.contains("/users/acme/repos"), requested)
    }

    /// The same repository can arrive more than once across affiliations, and
    /// a duplicate id would make the selection list misbehave.
    func testGitHubReposAreDeduplicated() async throws {
        let duplicate = json("""
        [{"name":"api","owner":{"login":"acme"}},{"name":"api","owner":{"login":"acme"}}]
        """)
        let http = StubHTTP(map: ["/repos": { duplicate }])
        let repos = try await Discovery(http: http).githubRepos(token: "t")
        XCTAssertEqual(repos.count, 1)
    }

    /// Protected branches lead the list, because they are the ones people
    /// actually watch and the ones whose failures matter.
    func testGitHubBranchesPutProtectedFirst() async throws {
        let payload = json("""
        [
          {"name":"feature/x","protected":false,"commit":{"sha":"1"}},
          {"name":"main","protected":true,"commit":{"sha":"2"}},
          {"name":"develop","protected":true,"commit":{"sha":"3"}},
          {"name":"aaa","protected":false,"commit":{"sha":"4"}}
        ]
        """)
        let http = StubHTTP(map: ["/branches": { payload }])
        let branches = try await Discovery(http: http)
            .githubBranches(token: "t", owner: "acme", repo: "api")
        XCTAssertEqual(branches.items, ["develop", "main", "aaa", "feature/x"])
    }

    func testGitHubBranchesQueryTheRepository() async throws {
        let http = StubHTTP(map: ["/branches": { json("[]") }])
        _ = try await Discovery(http: http).githubBranches(token: "t", owner: "acme", repo: "api")
        let requested = try XCTUnwrap(http.requested.first)
        XCTAssertTrue(requested.contains("/repos/acme/api/branches"), requested)
    }

    // MARK: - Vercel

    private let vercelProjectsPayload = json("""
    [{"id":"prj_web","name":"web"},{"id":"prj_api","name":"api"}]
    """)

    func testVercelProjectsCarryBothIdAndName() async throws {
        let http = StubHTTP(map: ["/v9/projects": { self.vercelProjectsPayload }])
        let projects = try await Discovery(http: http).vercelProjects(token: "t")
        XCTAssertEqual(projects.items.map(\.id), ["prj_api", "prj_web"])
        XCTAssertEqual(projects.items.map(\.name), ["api", "web"])
    }

    /// A token scoped to one team must be sent the team, or it lists the wrong
    /// account's projects.
    func testVercelProjectsPassTeamId() async throws {
        let http = StubHTTP(map: ["/v9/projects": { self.vercelProjectsPayload }])
        _ = try await Discovery(http: http).vercelProjects(token: "t", teamId: "team_1")
        let requested = try XCTUnwrap(http.requested.first)
        XCTAssertTrue(requested.contains("teamId=team_1"), requested)
    }

    /// Vercel has no branch endpoint, so branches are derived from deployments.
    /// Deployments without a git ref are not branches and must not appear.
    func testVercelBranchesComeFromDeploymentRefs() async throws {
        let payload = json("""
        {"deployments":[
          {"uid":"d1","name":"web","created":1,"readyState":"READY","meta":{"githubCommitRef":"main"}},
          {"uid":"d2","name":"web","created":2,"readyState":"READY","meta":{"githubCommitRef":"develop"}},
          {"uid":"d3","name":"web","created":3,"readyState":"READY","meta":{"githubCommitRef":"main"}},
          {"uid":"d4","name":"web","created":4,"readyState":"ERROR","meta":null},
          {"uid":"d5","name":"web","created":5,"readyState":"READY","meta":{"githubCommitRef":""}}
        ]}
        """)
        let http = StubHTTP(map: ["/v7/deployments": { payload }])
        let branches = try await Discovery(http: http).vercelBranches(token: "t", projectId: "prj_web")
        XCTAssertEqual(branches.items, ["develop", "main"])
    }

    func testVercelBranchesFilterByProject() async throws {
        let http = StubHTTP(map: ["/v7/deployments": { json("{\"deployments\":[]}") }])
        _ = try await Discovery(http: http).vercelBranches(token: "t", projectId: "prj_web")
        let requested = try XCTUnwrap(http.requested.first)
        XCTAssertTrue(requested.contains("projectId=prj_web"), requested)
    }

    // MARK: - Sentry

    private let sentryProjectsPayload = json("""
    [{"id":"1","slug":"web","name":"Web"},{"id":"2","slug":"api","name":"API"}]
    """)

    func testSentryProjectsCarrySlugAndName() async throws {
        let http = StubHTTP(map: ["/organizations/acme/projects": { self.sentryProjectsPayload }])
        let projects = try await Discovery(http: http).sentryProjects(token: "t", org: "acme")
        XCTAssertEqual(projects.items.map(\.slug), ["api", "web"])
        XCTAssertEqual(projects.items.map(\.name), ["API", "Web"])
    }

    func testSentryOrgsAreListed() async throws {
        let payload = json("""
        [{"id":"1","slug":"acme","name":"Acme Inc"},{"id":"2","slug":"other","name":"Other"}]
        """)
        let http = StubHTTP(map: ["/organizations/": { payload }])
        let orgs = try await Discovery(http: http).sentryOrgs(token: "t")
        XCTAssertEqual(orgs.items.map(\.slug), ["acme", "other"])
    }

    // MARK: - Truncation

    /// A full page might be the whole story or the first of many. Saying so
    /// beats presenting a truncated list as if it were complete.
    func testAFullPageIsReportedAsPossiblyTruncated() async throws {
        let entry = #"{"id":"prj_x","name":"x"},"#
        let payload = json("[" + String(repeating: entry, count: 99)
            + #"{"id":"prj_last","name":"last"}]"#)
        let http = StubHTTP(map: ["/v9/projects": { payload }])
        let projects = try await Discovery(http: http).vercelProjects(token: "t")
        XCTAssertEqual(projects.items.count, 100)
        XCTAssertTrue(projects.wasTruncated)
    }

    func testAShortPageIsNotReportedAsTruncated() async throws {
        let http = StubHTTP(map: ["/v9/projects": { self.vercelProjectsPayload }])
        let projects = try await Discovery(http: http).vercelProjects(token: "t")
        XCTAssertFalse(projects.wasTruncated)
    }

    // MARK: - Failure wording

    /// A discovery failure is shown in a settings window, so it must say what
    /// went wrong in words a person can act on, not "Error 1".
    func testAPermissionFailureCarriesTheStatusCode() async {
        let http = StubHTTP(map: ["/v9/projects": { throw HTTPError.status(403, "Forbidden") }])
        do {
            _ = try await Discovery(http: http).vercelProjects(token: "t")
            XCTFail("expected a thrown error")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("403"), message)
            XCTAssertFalse(message.contains("Error "), "raw enum leaks: \(message)")
        }
    }
}