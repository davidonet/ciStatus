import Foundation
import XCTest
@testable import CIStatusKit

/// A stub that answers with canned responses, so the polling and fallback
/// behaviour can be exercised without touching the network.
final class StubHTTP: HTTP, @unchecked Sendable {
    typealias Responder = @Sendable () throws -> Data

    struct Stub {
        let match: @Sendable (String) -> Bool
        let respond: Responder
    }

    private let lock = NSLock()
    private var _requested: [String] = []
    private let stubs: [Stub]

    /// Every URL the provider asked for, in order.
    var requested: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requested
    }

    init(_ stubs: [Stub]) { self.stubs = stubs }

    /// Matches on a substring of the URL. Longer keys win, so `/actions/runs`
    /// is tried before a shorter catch-all.
    convenience init(map: [String: Responder]) {
        let ordered = map.sorted { $0.key.count > $1.key.count }
        self.init(ordered.map { entry in
            Stub(match: { $0.contains(entry.key) }, respond: entry.value)
        })
    }

    override func get<T: Decodable>(_ type: T.Type, url: URL, token: String?,
                                    accept: String = "application/json") async throws -> T {
        lock.lock(); _requested.append(url.absoluteString); lock.unlock()
        guard let stub = stubs.first(where: { $0.match(url.absoluteString) }) else {
            throw HTTPError.status(404, "no stub matched \(url.absoluteString)")
        }
        return try JSONDecoder().decode(T.self, from: try stub.respond())
    }
}

/// Internal rather than private so the discovery tests can share it.
func json(_ literal: String) -> Data { Data(literal.utf8) }

/// A source with the given strategy, or no strategy key at all.
///
/// Answers from a stub token store rather than the real one, so these results do
/// not depend on whether the machine running them has a GitHub token on disk.
private func source(strategy: GitHubProvider.Strategy? = nil) -> Source {
    TokenStore.TestSupport.useReader { [Source.Kind.github: "test-token"] }
    return Config(
        tokens: Config.Tokens(github: true),
        services: Config.Services(github: [
            .init(owner: "o", repo: "r", branches: ["main"], strategy: strategy)
        ])
    ).expandedSources[0]
}

final class GitHubStrategyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        setenv("CI_T", "token", 1)
    }

    override func tearDown() {
        unsetenv("CI_T")
        TokenStore.TestSupport.use(url: nil)
        GitHubProvider.forcedStrategy = nil
        super.tearDown()
    }

    private let checkRunsPayload = json("""
    {"total_count": 2, "check_runs": [
      {"name": "build", "status": "completed", "conclusion": "success"},
      {"name": "lint",  "status": "completed", "conclusion": "failure"}
    ]}
    """)

    private let workflowRunsPayload = json("""
    {"total_count": 2, "workflow_runs": [
      {"id": 1, "name": "CI", "head_sha": "abc", "status": "completed", "conclusion": "success"},
      {"id": 2, "name": "Deploy", "head_sha": "abc", "status": "in_progress", "conclusion": null}
    ]}
    """)

    private let statusPayload = json("""
    {"state": "pending", "sha": "abc", "total_count": 0, "statuses": []}
    """)

    /// The token cannot read check runs, which is exactly the reported problem:
    /// `Checks` is not offered for the account.
    func testAutoFallsBackToActionsWhenChecksIsForbidden() async throws {
        let http = StubHTTP(map: [
            "/check-runs": { throw HTTPError.status(403, "Resource not accessible") },
            "/actions/runs": { self.workflowRunsPayload },
            "/status": { self.statusPayload }
        ])

        let status = await GitHubProvider(http: http, source: source()).poll()

        XCTAssertEqual(status.health, .pending, "one success and one in flight run")
        XCTAssertTrue(status.summary.contains("1 passed"), status.summary)
        XCTAssertTrue(status.summary.contains("1 running"), status.summary)
        XCTAssertTrue(status.detail?.contains("actions only") == true,
                      "the menu should say it fell back: \(status.detail ?? "nil")")
    }

    /// A check that fails must still be red through the fallback.
    func testAutoFallbackStillReportsAFailure() async throws {
        let failing = json("""
        {"total_count": 1, "workflow_runs": [
          {"id": 1, "name": "CI", "head_sha": "abc", "status": "completed", "conclusion": "failure"}
        ]}
        """)
        let http = StubHTTP(map: [
            "/check-runs": { throw HTTPError.status(403, "nope") },
            "/actions/runs": { failing },
            "/status": { self.statusPayload }
          ])

        let status = await GitHubProvider(http: http, source: source()).poll()
        XCTAssertEqual(status.health, .failing)
        XCTAssertEqual(status.failingItems, ["CI"])
    }

    /// With the Checks permission available there is no reason to fall back,
    /// and third party checks are then included.
    func testAutoPrefersChecksWhenItIsAllowed() async throws {
        let http = StubHTTP(map: [
            "/check-runs": { self.checkRunsPayload },
            "/status": { self.statusPayload }
        ])

        let status = await GitHubProvider(http: http, source: source()).poll()

        XCTAssertEqual(status.health, .failing)
        XCTAssertEqual(status.failingItems, ["lint"])
        XCTAssertFalse(status.detail?.contains("actions only") == true)
        XCTAssertFalse(http.requested.contains { $0.contains("/actions/runs") },
                       "Actions should not be queried when Checks works")
    }

    /// Pinning the strategy stops the fallback, so a genuine permission problem
    /// is reported rather than silently masked by a lesser source.
    func testPinnedChecksDoesNotFallBack() async throws {
        let http = StubHTTP(map: ["/check-runs": { throw HTTPError.status(403, "nope") }])

        let status = await GitHubProvider(http: http, source: source(strategy: .checks)).poll()
        XCTAssertEqual(status.health, .unknown)
        XCTAssertEqual(status.summary, "checks not permitted")
        // The user has to be told what to do about it, not just that it broke.
        XCTAssertTrue(status.detail?.contains("\"strategy\": \"actions\"") == true,
                      "the fix should be spelled out: \(status.detail ?? "no detail")")
        XCTAssertFalse(http.requested.contains { $0.contains("/actions/runs") })
    }

    func testPinnedActionsSkipsTheChecksCallEntirely() async throws {
        let http = StubHTTP(map: [
            "/actions/runs": { self.workflowRunsPayload },
            "/status": { self.statusPayload }
        ])

        let status = await GitHubProvider(http: http, source: source(strategy: .actions)).poll()
        XCTAssertEqual(status.health, .pending)
        XCTAssertFalse(http.requested.contains { $0.contains("/check-runs") },
                       "a pinned strategy should not try the other API")
    }

    /// The head SHA must be resolved first, otherwise historical runs on the
    /// branch leak in and an old failure pins the dot red.
    func testFallbackResolvesTheHeadSHAAndQueriesByIt() async throws {
        let http = StubHTTP(map: [
            "/check-runs": { throw HTTPError.status(403, "nope") },
            "/actions/runs": { self.workflowRunsPayload },
            "/status": { self.statusPayload }
        ])

        _ = await GitHubProvider(http: http, source: source()).poll()

        let runs = http.requested.filter { $0.contains("/actions/runs") }
        XCTAssertEqual(runs.count, 1)
        XCTAssertTrue(runs[0].contains("head_sha=abc"), runs[0])
        XCTAssertFalse(runs[0].contains("branch="), "filtering by branch alone is the bug: \(runs[0])")
    }

    /// The branch must be resolved to a SHA even when no checks exist yet.
    func testBranchWithNoRunsIsGreen() async throws {
        let http = StubHTTP(map: [
            "/check-runs": { throw HTTPError.status(403, "nope") },
            "/actions/runs": { json(#"{"total_count":0,"workflow_runs":[]}"#) },
            "/status": { self.statusPayload }
          ])

        let status = await GitHubProvider(http: http, source: source()).poll()
        XCTAssertEqual(status.health, .ok, "a push with no CI yet is not a failure")
        XCTAssertTrue(status.summary.contains("no checks"), status.summary)
    }

    /// An unknown branch is a configuration mistake, not a transient failure.
    func testUnknownBranchIsReportedAsSuch() async throws {
        let http = StubHTTP(map: [
            "/check-runs": { throw HTTPError.status(422, "No commit found") }
        ])

        let status = await GitHubProvider(http: http, source: source()).poll()
        XCTAssertEqual(status.health, .unknown)
        XCTAssertEqual(status.summary, "branch not found")
    }

    /// A missing repository should not be confused with a permission problem.
    func testMissingRepositoryIsReportedAsNotFound() async throws {
        let http = StubHTTP(map: ["/check-runs": { throw HTTPError.status(404, "Not Found") }])

        let status = await GitHubProvider(http: http, source: source()).poll()
        XCTAssertEqual(status.health, .unknown)
        XCTAssertEqual(status.summary, "not found")
    }

    /// A truncated page must say so rather than reporting a partial count as
    /// if it were the whole picture.
    func testTruncatedPageIsSurfacedInTheMenu() async throws {
        let truncated = json("""
        {"total_count": 184, "workflow_runs": [
          {"id": 1, "name": "CI", "head_sha": "abc", "status": "completed", "conclusion": "success"}
        ]}
        """)
        let http = StubHTTP(map: [
            "/check-runs": { throw HTTPError.status(403, "nope") },
            "/actions/runs": { truncated },
            "/status": { self.statusPayload }
        ])

        let status = await GitHubProvider(http: http, source: source()).poll()
        // The placeholder is pending so a partial page never reads as all clear.
        XCTAssertEqual(status.health, .pending)
        XCTAssertTrue(status.summary.contains("183 more not shown"), status.summary)
    }

    /// A service switched on with no stored token must say where to fix it, and
    /// offer the command that fixes it.
    func testMissingTokenIsReported() async {
        let http = StubHTTP(map: [:])
        // The source is built first: `source()` installs a token, so emptying it
        // has to come afterwards.
        let configured = source()
        TokenStore.TestSupport.useReader { [:] }

        let status = await GitHubProvider(http: http, source: configured).poll()
        XCTAssertEqual(status.health, .unknown)
        let detail = status.detail ?? ""
        XCTAssertTrue(detail.contains("no GitHub token stored"), detail)
        XCTAssertTrue(detail.contains("--store-token github"), detail)
        XCTAssertFalse(detail.contains("environment variable"), detail)
    }

    /// With the service switched off there is no token to look for, so the
    /// advice is to switch it on rather than to paste a token.
    func testDisabledServiceIsReportedAsNotEnabled() async {
        TokenStore.TestSupport.useReader { [.github: "a-real-looking-token"] }

        let disabled = Config.Services(github: [
            .init(owner: "o", repo: "r", branches: ["main"], strategy: .actions)
        ])
        let off = Config(services: disabled).expandedSources[0]
        XCTAssertFalse(off.usesToken)

        let status = await GitHubProvider(http: StubHTTP(map: [:]), source: off).poll()
        XCTAssertEqual(status.health, .unknown)
        let detail = status.detail ?? ""
        XCTAssertTrue(detail.contains("not enabled"), detail)
        XCTAssertTrue(detail.contains("tokens"), "should name the config key: \(detail)")
    }
}
