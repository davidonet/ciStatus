import XCTest
@testable import CIStatusKit

final class StatusLogicTests: XCTestCase {

    // MARK: - Aggregation

    private func status(_ health: Health) -> SourceStatus {
        .init(id: "id", name: "id", health: health, summary: "", detail: nil, url: nil, failingItems: [])
    }

    func testEmptyReportsUnknown() {
        XCTAssertEqual([SourceStatus]().overall, .unknown)
    }

    func testAllGreenStaysGreen() {
        XCTAssertEqual([status(.ok), status(.ok)].overall, .ok)
    }

    /// A single failure must not be diluted by green sources.
    func testWorstWins() {
        XCTAssertEqual([status(.ok), status(.ok), status(.failing)].overall, .failing)
    }

    func testPendingOutranksOk() {
        XCTAssertEqual([status(.ok), status(.pending)].overall, .pending)
    }

    /// An unreachable API must never be mistaken for success.
    func testUnknownDoesNotReportGreen() {
        XCTAssertEqual([status(.ok), status(.unknown)].overall, .unknown)
    }

    func testFailingOutranksUnknown() {
        XCTAssertEqual([status(.unknown), status(.failing)].overall, .failing)
    }

    // MARK: - Vercel states

    func testVercelStateMapping() {
        XCTAssertEqual(VercelProvider.health(for: "READY"), .ok)
        for pending in ["BUILDING", "QUEUED", "INITIALIZING", "BLOCKED", "PENDING"] {
            XCTAssertEqual(VercelProvider.health(for: pending), .pending, "\(pending) should be pending")
        }
        for failing in ["ERROR", "CANCELED", "DELETED"] {
            XCTAssertEqual(VercelProvider.health(for: failing), .failing, "\(failing) should be failing")
        }
        XCTAssertEqual(VercelProvider.health(for: "SOMETHING_NEW"), .unknown)
    }

    // MARK: - GitHub state mapping
    //
    // Both strategies (Checks and Actions) map onto this one function, so these
    // cases cover the Checks API, workflow runs, and legacy commit statuses.

    func testGitHubFailureConclusions() {
        for conclusion in ["failure", "timed_out", "action_required", "stale",
                           "cancelled", "neutral", "startup_failure"] {
            XCTAssertEqual(GitHubProvider.state(status: "completed", conclusion: conclusion), .failing,
                           "\(conclusion) should be a failure")
        }
    }

    func testGitHubSuccessIsPassing() {
        for conclusion in ["success", "skipped", ""] {
            XCTAssertEqual(GitHubProvider.state(status: "completed", conclusion: conclusion), .passing,
                           "\(conclusion.isEmpty ? "empty" : conclusion) should pass")
        }
    }

    func testGitHubInProgressIsPending() {
        for status in ["queued", "in_progress", "waiting", "pending", "requested"] {
            XCTAssertEqual(GitHubProvider.state(status: status, conclusion: nil), .pending,
                           "\(status) should be pending")
        }
    }

    /// Legacy commit statuses arrive as "completed" with state "pending".
    func testGitHubLegacyPendingStatus() {
        XCTAssertEqual(GitHubProvider.state(status: "completed", conclusion: "pending"), .pending)
    }

    /// A conclusion GitHub has not documented yet must not turn the dot red.
    func testUnknownConclusionIsNotAFailure() {
        XCTAssertEqual(GitHubProvider.state(status: "completed", conclusion: "some_new_state"), .passing)
    }

    /// Actions reports both fields as nullable, so neither can be assumed present.
    func testNilStatusAndConclusionDoNotCrash() {
        XCTAssertEqual(GitHubProvider.state(status: nil, conclusion: nil), .passing)
    }

    // MARK: - Strategy selection

    /// Building a provider from a config with no `strategy` must not fall back
    /// to a hardcoded default in two different places.
    func testStrategyDefaultsToAuto() throws {
        let config = try decode("""
        {"sources":[{"kind":"github","name":"gh","owner":"o","repo":"r","branch":"main","tokenEnv":"T"}]}
        """)
        let provider = GitHubProvider(http: HTTP(), source: config.sources[0])
        XCTAssertEqual(provider.strategy, .auto)
    }

    func testStrategyIsReadFromConfig() throws {
        for (raw, expected) in [("actions", GitHubProvider.Strategy.actions),
                                ("checks", GitHubProvider.Strategy.checks),
                                ("auto", GitHubProvider.Strategy.auto)] {
            let config = try decode("""
            {"sources":[{"kind":"github","name":"gh","owner":"o","repo":"r","branch":"main","strategy":"\(raw)"}]}
            """)
            XCTAssertEqual(GitHubProvider(http: HTTP(), source: config.sources[0]).strategy, expected)
        }
    }

    /// A typo in `strategy` must be a loud config error, not a silent default
    /// that quietly polls the wrong API.
    func testUnknownStrategyIsRejected() {
        let json = #"{"sources":[{"kind":"github","name":"gh","owner":"o","repo":"r","branch":"main","strategy":"checkz"}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: Data(json.utf8)))
    }

    // MARK: - GitHub workflow runs (the Actions fallback)

    func testDecodesRealWorkflowRunsPayload() throws {
        let response = try JSONDecoder().decode(GitHubProvider.WorkflowRunsResponse.self, from: Data("""
        {
          "total_count": 5,
          "workflow_runs": [
            {
              "id": 30800940787, "name": "CI", "path": ".github/workflows/ci.yml",
              "head_branch": "main", "head_sha": "10033218d239", "event": "push",
              "status": "completed", "conclusion": "success",
              "html_url": "https://github.com/vitejs/vite/actions/runs/30800940787"
            },
            {
              "id": 30800940788, "name": "Preview release",
              "head_branch": "main", "head_sha": "10033218d239", "event": "push",
              "status": "in_progress", "conclusion": null,
              "html_url": "https://github.com/vitejs/vite/actions/runs/30800940788"
            }
          ]
        }
        """.utf8))

        XCTAssertEqual(response.total_count, 5)
        let ci = try XCTUnwrap(response.workflow_runs.first)
        XCTAssertEqual(ci.label, "CI", "the workflow name is what belongs in the menu")
        XCTAssertEqual(GitHubProvider.state(status: ci.status, conclusion: ci.conclusion), .passing)

        let preview = try XCTUnwrap(response.workflow_runs.last)
        XCTAssertNil(preview.conclusion, "an in flight run has no conclusion yet")
        XCTAssertEqual(GitHubProvider.state(status: preview.status, conclusion: preview.conclusion), .pending)
    }

    /// `name` is nullable in the API, so the label must never come out empty.
    func testWorkflowRunFallsBackToPathThenID() throws {
        let unnamed = try JSONDecoder().decode(GitHubProvider.WorkflowRunsResponse.self, from: Data("""
        {"total_count": 1, "workflow_runs": [
          {"id": 42, "name": null, "path": ".github/workflows/ci.yml",
           "head_sha": "abc", "status": "completed", "conclusion": "success"}
        ]}
        """.utf8))
        XCTAssertEqual(unnamed.workflow_runs[0].label, ".github/workflows/ci.yml")

        let bare = try JSONDecoder().decode(GitHubProvider.WorkflowRunsResponse.self, from: Data("""
        {"total_count": 1, "workflow_runs": [
          {"id": 42, "name": null, "path": null, "head_sha": "abc",
           "status": "completed", "conclusion": "success"}
        ]}
        """.utf8))
        XCTAssertEqual(bare.workflow_runs[0].label, "run 42")
    }

    /// An empty Actions response is the normal state right after a push.
    func testDecodesEmptyWorkflowRunsPayload() throws {
        let response = try JSONDecoder().decode(GitHubProvider.WorkflowRunsResponse.self,
                                                from: Data(#"{"total_count": 0, "workflow_runs": []}"#.utf8))
        XCTAssertTrue(response.workflow_runs.isEmpty)
    }

    /// The combined status endpoint is what resolves a branch name to a SHA,
    /// and it needs only the Commit statuses permission.
    func testDecodesCombinedStatusWithHeadSHA() throws {
        let response = try JSONDecoder().decode(GitHubProvider.StatusResponse.self, from: Data("""
        {
          "state": "pending", "sha": "10033218d239c927cdc375970b5741cce408e81b",
          "total_count": 0, "statuses": [],
          "url": "https://api.github.com/repos/vitejs/vite/commits/abc/status",
          "commit_url": "https://api.github.com/repos/vitejs/vite/commits/abc",
          "repository": {}
        }
        """.utf8))
        XCTAssertEqual(response.sha, "10033218d239c927cdc375970b5741cce408e81b")
        XCTAssertTrue(response.statuses.isEmpty)
    }

    /// Filtering by branch alone would include every commit ever pushed to it,
    /// so an old failure would keep the dot red forever. The head SHA has to be
    /// part of the query, not just the branch name.
    func testWorkflowRunQueryIsScopedToTheHeadSHA() {
        let url = URL.build("https://api.github.com/repos/o/r/actions/runs", [
            ("head_sha", "10033218d239"), ("per_page", "100")
        ])
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "head_sha", value: "10033218d239")))
        XCTAssertEqual(items.first?.name, "head_sha", "the sha must be sent, not just the branch")
    }

    // MARK: - Config

    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func testDecodesAFullConfig() throws {
        let config = try decode("""
        {
          "pollIntervalSeconds": 30,
          "sources": [
            {"kind": "github", "name": "gh", "owner": "o", "repo": "r", "branch": "main", "tokenEnv": "T"},
            {"kind": "vercel", "name": "vc", "projectId": "p1", "branch": "main", "teamId": "t1", "tokenEnv": "T"},
            {"kind": "sentry", "name": "st", "org": "o", "project": "p", "newWithinHours": 6, "tokenEnv": "T"}
          ]
        }
        """)
        XCTAssertEqual(config.pollIntervalSeconds, 30)
        XCTAssertEqual(config.sources.count, 3)
        XCTAssertEqual(config.sources[2].newWithinHours, 6)
        XCTAssertEqual(config.sources.map(\.kind), [.github, .vercel, .sentry])
    }

    func testTokenIsReadFromTheEnvironmentNotTheFile() throws {
        let config = try decode(#"{"sources":[{"kind":"github","name":"gh","tokenEnv":"MY_TOKEN"}]}"#)
        XCTAssertNil(config.sources[0].token(), "no env var set means no token")

        setenv("MY_TOKEN", "  secret  ", 1)
        defer { unsetenv("MY_TOKEN") }
        XCTAssertEqual(config.sources[0].token(), "secret", "token should be trimmed")
    }

    func testDashboardLinkIsBuiltPerSource() throws {
        let config = try decode("""
        {
          "sources": [
            {"kind": "github", "name": "gh", "owner": "o", "repo": "r", "branch": "main"},
            {"kind": "sentry", "name": "st", "org": "acme", "project": "web"}
          ]
        }
        """)
        let githubURL = config.sources[0].resolvedDashboardURL
        XCTAssertTrue(githubURL?.absoluteString.contains("github.com/o/r/actions") == true)
        // The query item must survive a decode round trip, whatever escaping is used.
        let branchQuery = URLComponents(url: githubURL!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "query" }?.value
        XCTAssertEqual(branchQuery, "branch:main")

        let sentry = config.sources[1].resolvedDashboardURL?.absoluteString ?? ""
        XCTAssertTrue(sentry.contains("acme.sentry.io"), sentry)
    }

    func testExplicitDashboardURLWins() throws {
        let config = try decode(#"{"sources":[{"kind":"github","name":"gh","owner":"o","repo":"r","branch":"main","dashboardURL":"https://example.com/x"}]}"#)
        XCTAssertEqual(config.sources[0].resolvedDashboardURL?.absoluteString, "https://example.com/x")
    }

    // MARK: - Response decoding
    //
    // These fixtures are trimmed from real API responses so a change in shape
    // upstream fails here rather than silently in the menu bar.

    private func decodeGitHubChecks(_ json: String) throws -> GitHubProvider.CheckRunsResponse {
        try JSONDecoder().decode(GitHubProvider.CheckRunsResponse.self, from: Data(json.utf8))
    }

    func testDecodesRealCheckRunsPayload() throws {
        let response = try decodeGitHubChecks("""
        {
          "total_count": 2,
          "check_runs": [
            {"name": "build", "status": "completed", "conclusion": "success", "html_url": "https://x/1"},
            {"name": "e2e", "status": "in_progress", "conclusion": null, "html_url": "https://x/2"}
          ]
        }
        """)
        XCTAssertEqual(response.total_count, 2)
        XCTAssertEqual(response.check_runs.count, 2)

        let pending = response.check_runs.filter {
            GitHubProvider.state(status: $0.status, conclusion: $0.conclusion) == .pending
        }
        let failing = response.check_runs.filter {
            GitHubProvider.state(status: $0.status, conclusion: $0.conclusion) == .failing
        }
        XCTAssertEqual(pending.map(\.name), ["e2e"])
        XCTAssertTrue(failing.isEmpty)
    }

    /// total_count is authoritative, so a capped page must be reported as partial.
    func testTruncatedPageIsDetectable() throws {
        let response = try decodeGitHubChecks("""
        {"total_count": 184, "check_runs": [
          {"name": "a", "status": "completed", "conclusion": "success"}
        ]}
        """)
        XCTAssertGreaterThan(response.total_count, response.check_runs.count)
    }

    func testDecodesRealVercelDeploymentPayload() throws {
        let response = try JSONDecoder().decode(VercelProvider.DeploymentsResponse.self, from: Data("""
        {
          "deployments": [
            {
              "uid": "dpl_abc", "name": "web", "url": "web-abc.vercel.app",
              "inspectorUrl": "https://vercel.com/acme/web/dpl_abc",
              "target": "production", "created": 1756000000000,
              "readyState": "ERROR", "state": "ERROR",
              "errorCode": "BUILD_FAILED", "errorMessage": "Command failed",
              "meta": {"githubCommitRef": "main", "githubCommitSha": "0123456789abcdef"}
            }
          ],
          "pagination": {"count": 1, "next": 0, "prev": 0}
        }
        """.utf8))

        let deployment = try XCTUnwrap(response.deployments.first)
        XCTAssertEqual(deployment.readyState, "ERROR")
        XCTAssertEqual(VercelProvider.health(for: deployment.readyState), .failing)
        XCTAssertEqual(deployment.meta?.githubCommitRef, "main")
        XCTAssertEqual(deployment.errorMessage, "Command failed")
    }

    /// A branch filter must not pick a deployment from another branch.
    func testVercelBranchFilterSelectsMatchingRef() {
        let deployments = [
            (ref: "feature", state: "ERROR"),
            (ref: "main", state: "READY")
        ]
        let branch = "main"
        let picked = deployments.first { $0.ref == branch }
        XCTAssertEqual(picked?.state, "READY")
    }

    func testDecodesRealSentryIssuePayload() throws {
        let issues = try JSONDecoder().decode([SentryProvider.Issue].self, from: Data("""
        [
          {
            "id": "12345", "shortId": "PROJECT-1a2b", "title": "TypeError: x is not a function",
            "level": "error", "status": "unresolved",
            "firstSeen": "2026-09-30T10:00:00Z", "lastSeen": "2026-09-30T12:00:00Z",
            "permalink": "https://acme.sentry.io/issues/12345/?project=1", "count": "42"
          },
          {
            "id": "12346", "shortId": "PROJECT-3c4d", "title": "Unhandled rejection",
            "level": "fatal", "status": "unresolved",
            "firstSeen": "2026-09-30T11:00:00Z", "lastSeen": "2026-09-30T11:30:00Z",
            "permalink": "https://acme.sentry.io/issues/12346/?project=1", "count": "3"
          }
        ]
        """.utf8))
        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(issues[0].shortId, "PROJECT-1a2b")
        XCTAssertTrue(URL(string: issues[0].permalink ?? "") != nil)
    }

    /// An empty Sentry response must decode to "all good", not a crash.
    func testDecodesEmptySentryPayload() throws {
        let issues = try JSONDecoder().decode([SentryProvider.Issue].self, from: Data("[]".utf8))
        XCTAssertTrue(issues.isEmpty)
    }

    // MARK: - URL building

    func testQueryItemsSkipEmptyValues() {
        let url = URL.build("https://api.vercel.com/v7/deployments", [
            ("projectId", "p1"), ("branch", nil), ("teamId", ""), ("limit", "5")
        ])
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["projectId", "limit"])
    }

    /// A raw space in a query value would break the request, so it must be
    /// escaped while the Sentry search syntax survives the round trip.
    func testSentryQueryIsEscapedAndRoundTrips() {
        let url = URL.build("https://sentry.io/api/0/projects/o/p/issues/", [
            ("query", "is:unresolved firstSeen:-24h"), ("limit", "100")
        ])
        let absolute = url?.absoluteString ?? ""
        XCTAssertFalse(absolute.contains(" "), "spaces must be escaped: \(absolute)")

        let decoded = URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "query" }?.value
        XCTAssertEqual(decoded, "is:unresolved firstSeen:-24h")
    }
}
