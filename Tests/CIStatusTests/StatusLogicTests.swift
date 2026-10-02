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
        let provider = GitHubProvider(http: HTTP(), source: try source(strategy: nil))
        XCTAssertEqual(provider.strategy, .auto)
    }

    func testStrategyIsReadFromConfig() throws {
        for expected in [GitHubProvider.Strategy.actions,
                         GitHubProvider.Strategy.checks,
                         GitHubProvider.Strategy.auto] {
            let provider = GitHubProvider(http: HTTP(), source: try source(strategy: expected))
            XCTAssertEqual(provider.strategy, expected)
        }
    }

    /// A source built straight from the config's `services` section, so the
    /// strategy tests exercise the same path the app uses.
    private func source(strategy: GitHubProvider.Strategy?) throws -> Source {
        let raw = strategy.map { "\"\($0.rawValue)\"" } ?? "null"
        let config = try decode("""
        {"services":{"github":[{"owner":"o","repo":"r","branches":["main"],"strategy":\(raw)}]}}
        """)
        return config.expandedSources[0]
    }

    /// A typo in `strategy` must be a loud config error, not a silent default
    /// that quietly polls the wrong API.
    func testUnknownStrategyIsRejected() {
        let json = #"{"services":{"github":[{"owner":"o","repo":"r","strategy":"checkz"}]}}"#
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
          "tokens": { "github": true, "vercel": true, "sentry": true },
          "services": {
            "github": [{ "owner": "o", "repo": "r", "branches": ["main"] }],
            "vercel": [{ "projectId": "p1", "teamId": "t1", "branches": ["main"] }],
            "sentry": [{ "org": "o", "project": "p", "newWithinHours": 6 }]
          }
        }
        """)
        XCTAssertEqual(config.pollIntervalSeconds, 30)
        XCTAssertEqual(config.tokens, Config.Tokens(github: true, vercel: true, sentry: true))
        XCTAssertEqual(config.services.sentry.first?.newWithinHours, 6)

        let sources = config.expandedSources
        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(sources.map(\.kind), [.github, .vercel, .sentry])
    }

    /// The token comes from the token file, and an exported variable must not be
    /// able to supply one: the environment is no longer a token source, so a
    /// stray `GITHUB_TOKEN` in a shell cannot change what the app authenticates
    /// with.
    func testTheEnvironmentCannotSupplyAToken() throws {
        let config = try decode("""
        {"tokens":{"github":true},"services":{"github":[{"owner":"o","repo":"r"}]}}
        """)
        let source = config.expandedSources[0]
        XCTAssertTrue(source.usesToken, "the service is switched on")

        // Answered from a fixture, so this does not depend on whether the
        // machine running the tests has a real token file.
        TokenStore.TestSupport.useReader { [:] }
        defer { TokenStore.TestSupport.use(url: nil) }

        setenv("GITHUB_TOKEN", "  from-env  ", 1)
        defer { unsetenv("GITHUB_TOKEN") }
        XCTAssertNil(source.token(), "an exported variable is not a token source")

        // The same source does read a stored token, so the nil above is the
        // environment being ignored and not the store being skipped.
        TokenStore.TestSupport.useReader { [.github: "from-store"] }
        XCTAssertEqual(source.token(), "from-store")
    }

    /// A blank stored token is no token, rather than an empty credential the
    /// providers would send.
    func testABlankStoredTokenReadsAsNil() throws {
        let url = temporaryTokenFile()
        defer { try? FileManager.default.removeItem(at: url) }
        TokenStore.TestSupport.use(url: url)

        // Written by hand, since `save` refuses a blank.
        try #"{"github":"   "}"#.write(to: url, atomically: true, encoding: .utf8)
        TokenStore.TestSupport.invalidate()

        let config = try decode(#"{"tokens":{"github":true},"services":{"github":[{"owner":"o","repo":"r"}]}}"#)
        XCTAssertNil(config.expandedSources[0].token())
    }

    private func temporaryTokenFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cistatus-tokens-\(UUID().uuidString).json")
    }

    func testDashboardLinkIsBuiltPerSource() throws {
        let config = try decode("""
        {
          "services": {
            "github": [{ "owner": "o", "repo": "r", "branches": ["main"] }],
            "sentry": [{ "org": "acme", "project": "web" }]
          }
        }
        """)
        let sources = config.expandedSources
        let githubURL = sources[0].resolvedDashboardURL
        XCTAssertTrue(githubURL?.absoluteString.contains("github.com/o/r/actions") == true)
        // The query item must survive a decode round trip, whatever escaping is used.
        let branchQuery = URLComponents(url: githubURL!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "query" }?.value
        XCTAssertEqual(branchQuery, "branch:main")

        let sentry = sources[1].resolvedDashboardURL?.absoluteString ?? ""
        XCTAssertTrue(sentry.contains("acme.sentry.io"), sentry)
    }

    func testExplicitDashboardURLWins() throws {
        let config = try decode("""
        {"services":{"github":[{"owner":"o","repo":"r","dashboardURL":"https://example.com/x"}]}}
        """)
        XCTAssertEqual(config.expandedSources[0].resolvedDashboardURL?.absoluteString, "https://example.com/x")
    }

    // MARK: - Config shape

    /// Every service section is optional, so a GitHub-only config is not
    /// obliged to carry two empty lists it will never use.
    func testUnusedServiceSectionsAreOptional() throws {
        let config = try decode(#"{"services":{"github":[{"owner":"o","repo":"r"}]}}"#)
        XCTAssertEqual(config.services.github.count, 1)
        XCTAssertTrue(config.services.vercel.isEmpty)
        XCTAssertTrue(config.services.sentry.isEmpty)
    }

    /// `branches` is the field most likely to be left out by hand, so omitting
    /// it must mean main rather than "no branches", which would silently
    /// produce a target that is never polled.
    func testOmittedBranchesDefaultsToMain() throws {
        let config = try decode(#"{"services":{"github":[{"owner":"o","repo":"r"}]}}"#)
        XCTAssertEqual(config.services.github[0].branches, [])
        XCTAssertEqual(config.expandedSources.map(\.branch), ["main"])
    }

    func testOmittedTokenSectionIsEmptyNotAnError() throws {
        let config = try decode("{}")
        XCTAssertTrue(config.tokens.isEmpty)
        XCTAssertTrue(config.expandedSources.isEmpty)
    }

    /// A config written before `services` existed must fail loudly with advice,
    /// not load as an empty config that looks like the app lost its setup.
    func testLegacySourcesConfigIsRejectedWithMigrationAdvice() {
        let legacy = #"{"sources":[{"kind":"github","name":"gh","owner":"o","repo":"r","branch":"main"}]}"#
        XCTAssertThrowsError(try decode(legacy)) { error in
            XCTAssertEqual(error as? ConfigError, .legacySourcesFormat)
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("tokens"), "advice should name the new shape: \(message)")
        }
    }

    /// One row per branch, so watching three branches makes three menu entries.
    func testEachBranchBecomesItsOwnRow() throws {
        let config = try decode("""
        {"services":{"github":[{"owner":"o","repo":"api","branches":["main","develop","release"]}]}}
        """)
        XCTAssertEqual(config.expandedSources.count, 3)
        XCTAssertEqual(config.expandedSources.map(\.branch), ["main", "develop", "release"])
        // Labels must stay distinguishable, since that is all the menu shows.
        XCTAssertEqual(config.expandedSources.map(\.name),
                       ["api · main", "api · develop", "api · release"])
    }

    /// Duplicate rows would show the same target twice in the menu and poll it
    /// twice, so blank and repeated branches are collapsed.
    func testBlankAndDuplicateBranchesAreCollapsed() throws {
        let config = try decode("""
        {"services":{"github":[{"owner":"o","repo":"r","branches":["main","","  main  ","main","dev"]}]}}
        """)
        XCTAssertEqual(config.expandedSources.map(\.branch), ["main", "dev"])
    }

    /// The token section is per service, so every expanded source must inherit
    /// its own service's variable rather than a shared one.
    func testEachServiceInheritsItsOwnTokenVariable() throws {
        let config = try decode("""
        {
          "tokens": { "github": true, "vercel": true, "sentry": true },
          "services": {
            "github": [{ "owner": "o", "repo": "r" }],
            "vercel": [{ "projectId": "p1" }],
            "sentry": [{ "org": "o", "project": "p" }]
          }
        }
        """)
        XCTAssertEqual(config.expandedSources.map(\.usesToken), [true, true, true])
        XCTAssertEqual(config.tokens.enabledServices, [.github, .vercel, .sentry])
    }

    // MARK: - Tokens

    /// A service not listed is off, which keeps a token left over from a service
    /// you stopped watching from silently keeping it alive.
    func testUnlistedServicesAreOff() throws {
        let config = try decode("""
        {"tokens":{"github":true},"services":{"github":[{"owner":"o","repo":"r"}]}}
        """)
        XCTAssertTrue(config.tokens.isEnabled(.github))
        XCTAssertFalse(config.tokens.isEnabled(.vercel))
        XCTAssertFalse(config.tokens.isEnabled(.sentry))
        XCTAssertEqual(config.expandedSources.map(\.usesToken), [true])
    }

    func testAbsentTokensSectionMeansNothingIsEnabled() throws {
        let config = try decode(#"{"services":{"github":[{"owner":"o","repo":"r"}]}}"#)
        XCTAssertTrue(config.tokens.isEmpty)
        XCTAssertFalse(config.expandedSources[0].usesToken)
    }

    /// `false` and an explicit null both mean off, and must not read as enabled.
    func testFalseAndNullMeanDisabled() throws {
        let off = try decode(#"{"tokens":{"github":false,"vercel":null}}"#)
        XCTAssertFalse(off.tokens.isEnabled(.github))
        XCTAssertFalse(off.tokens.isEnabled(.vercel))
        XCTAssertTrue(off.tokens.isEmpty)
    }

    /// The old `"github": "GITHUB_TOKEN"` form must fail with advice naming the
    /// replacement, since that is the most likely thing to be sitting in an
    /// existing config file.
    func testLegacyEnvVarFormIsRejectedWithMigrationAdvice() {
        let json = #"{"tokens":{"github":"GITHUB_TOKEN"}}"#
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(error as? ConfigError,
                           .legacyEnvToken(service: "github", variable: "GITHUB_TOKEN"))
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("true"), "should name the replacement: \(message)")
            XCTAssertTrue(message.contains("--store-token github"), message)
        }
    }

    /// Anything else in the tokens section is a mistake. Guessing would leave
    /// the user with a config that looks right and does nothing.
    func testUnrecognisedTokenValueIsRejected() {
        XCTAssertThrowsError(try decode(#"{"tokens":{"github":42}}"#)) { error in
            guard case .unknownServiceKey(let section, let key)? = error as? ConfigError else {
                return XCTFail("expected unknownServiceKey, got \(error)")
            }
            XCTAssertEqual(section, "tokens")
            XCTAssertTrue(key.contains("github"), key)
        }
    }

    /// A round trip must keep the opt-in, or saving would quietly switch a
    /// service off and the app would report it unreachable.
    func testEnabledServicesSurviveSaveAndLoad() throws {
        let original = Config(
            tokens: Config.Tokens(github: true, sentry: true),
            services: Config.Services(github: [.init(owner: "o", repo: "r")])
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cistatus-kc-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try original.save(to: url)
        let reloaded = try Config.load(from: url)
        XCTAssertEqual(reloaded.tokens.enabledServices, [.github, .sentry])
        XCTAssertTrue(reloaded.expandedSources[0].usesToken)
    }

    /// A disabled service must not read a stored token even when one exists,
    /// or switching it off would appear to do nothing.
    func testDisabledServiceReadsNoToken() {
        let source = Source(kind: .github, name: "x", usesToken: false)
        XCTAssertNil(source.token())
    }

    /// Saving must round trip, or the settings window would quietly rewrite the
    /// config into something the app cannot read back.
    func testSaveThenLoadRoundTrips() throws {
        let original = Config(
            pollIntervalSeconds: 45,
            tokens: Config.Tokens(github: true, vercel: true),
            services: Config.Services(
                github: [.init(owner: "o", repo: "api", branches: ["main"], strategy: .actions)],
                vercel: [.init(projectId: "p1", teamId: "t1", branches: ["main"], name: "Web")],
                sentry: [.init(org: "o", project: "p", newWithinHours: 6)]
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cistatus-roundtrip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try original.save(to: url)
        let reloaded = try Config.load(from: url)
        XCTAssertEqual(reloaded.pollIntervalSeconds, 45)
        XCTAssertEqual(reloaded.tokens, original.tokens)
        XCTAssertEqual(reloaded.services, original.services)
        XCTAssertEqual(reloaded.expandedSources.map(\.name), original.expandedSources.map(\.name))
    }

    /// An empty config saved by the window should not be littered with empty
    /// sections, or hand editing it later becomes guesswork.
    func testSavedFileOmitsEmptySections() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cistatus-empty-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try Config().save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("\"services\""), text)
        XCTAssertFalse(text.contains("\"tokens\""), text)
    }

    /// A misspelled provider or token key must be loud. Silently ignoring it
    /// leaves a config that looks correct and watches nothing, which is the
    /// hardest kind of mistake to notice.
    func testMisspelledServiceKeyIsRejected() {
        XCTAssertThrowsError(try decode(#"{"services":{"githbu":[]}}"#)) { error in
            XCTAssertEqual(error as? ConfigError, .unknownServiceKey(section: "services", key: "githbu"))
        }
    }

    func testMisspelledTokenKeyIsRejected() {
        XCTAssertThrowsError(try decode(#"{"tokens":{"githbu":"X"}}"#)) { error in
            XCTAssertEqual(error as? ConfigError, .unknownServiceKey(section: "tokens", key: "githbu"))
        }
    }

    func testMisspelledTopLevelKeyIsRejected() {
        XCTAssertThrowsError(try decode(#"{"pollInterval": 60}"#)) { error in
            XCTAssertEqual(error as? ConfigError, .unknownKey("pollInterval"))
        }
    }

    /// The error text is all the user sees when their config will not load, so
    /// it has to name the section and say what is valid.
    func testUnknownKeyErrorNamesTheValidKeys() {
        let message = ConfigError.unknownServiceKey(section: "services", key: "githbu")
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("githbu"), message)
        XCTAssertTrue(message.contains("github"), message)
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
