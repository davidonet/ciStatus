import Foundation
import XCTest
@testable import CIStatusKit

/// The token file is deliberately a plain file: the login Keychain prompted on
/// every rebuild because its ACL trusts the creating app by signature. These
/// tests pin the properties that a plain file then has to hold up on its own.
final class TokenStoreTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        super.setUp()
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cistatus-tok-\(UUID().uuidString).json")
        TokenStore.TestSupport.use(url: file)
    }

    override func tearDown() {
        TokenStore.TestSupport.use(url: nil)
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        super.tearDown()
    }

    // MARK: - Round trip

    func testAStoredTokenIsReadBack() throws {
        try TokenStore.save("ghp_secret", for: .github)
        TokenStore.TestSupport.invalidate()
        XCTAssertEqual(TokenStore.token(for: .github), "ghp_secret")
        XCTAssertTrue(TokenStore.hasToken(for: .github))
    }

    func testStoringASecondServiceKeepsTheFirst() throws {
        try TokenStore.save("a", for: .github)
        try TokenStore.save("b", for: .sentry)
        TokenStore.TestSupport.invalidate()
        XCTAssertEqual(TokenStore.token(for: .github), "a")
        XCTAssertEqual(TokenStore.token(for: .sentry), "b")
    }

    /// Re-saving replaces rather than duplicating, which is what happens when a
    /// token is rotated from the settings window.
    func testStoringAgainReplacesTheToken() throws {
        try TokenStore.save("old", for: .github)
        try TokenStore.save("new", for: .github)
        TokenStore.TestSupport.invalidate()
        XCTAssertEqual(TokenStore.token(for: .github), "new")
        XCTAssertEqual(TokenStore.all().count, 1)
    }

    /// The value is trimmed, so a paste with a trailing newline does not produce
    /// a token the API rejects as malformed.
    func testStoredTokensAreTrimmed() throws {
        try TokenStore.save("  secret\n", for: .github)
        XCTAssertEqual(TokenStore.token(for: .github), "secret")
    }

    func testABlankTokenIsRefused() {
        XCTAssertThrowsError(try TokenStore.save("   ", for: .github))
        XCTAssertThrowsError(try TokenStore.save("", for: .github))
    }

    // MARK: - Deleting

    func testDeleteRemovesAndReportsWhetherThereWasOne() throws {
        try TokenStore.save("a", for: .github)
        XCTAssertTrue(try TokenStore.delete(for: .github))
        XCTAssertFalse(TokenStore.hasToken(for: .github))
        // Deleting again is not an error, just nothing to do.
        XCTAssertFalse(try TokenStore.delete(for: .github))
    }

    func testDeleteLeavesOtherServicesAlone() throws {
        try TokenStore.save("a", for: .github)
        try TokenStore.save("b", for: .sentry)
        _ = try TokenStore.delete(for: .github)
        XCTAssertEqual(TokenStore.token(for: .sentry), "b")
    }

    // MARK: - Absent and malformed

    /// A fresh install has no token file, and that is an ordinary state rather
    /// than a failure to report.
    func testAMissingFileReadsAsNothing() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(TokenStore.all().isEmpty)
        XCTAssertNil(TokenStore.token(for: .github))
    }

    /// A corrupt file must not take the app down; it reads as no tokens, which
    /// the menu already reports as unreachable.
    func testAMalformedFileReadsAsNothing() throws {
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)
        TokenStore.TestSupport.invalidate()
        XCTAssertTrue(TokenStore.all().isEmpty)
    }

    /// One unrecognised service should not cost you the others: the file may have
    /// been written by a newer build.
    func testAnUnknownServiceIsIgnoredButTheRestSurvive() throws {
        try #"{"github":"a","gitlab":"b"}"#.write(to: file, atomically: true, encoding: .utf8)
        TokenStore.TestSupport.invalidate()
        XCTAssertEqual(TokenStore.token(for: .github), "a")
        XCTAssertNil(TokenStore.token(for: .sentry))
    }

    /// A blank entry in the file is no token, not an empty credential.
    func testABlankEntryInTheFileIsNotAToken() throws {
        try #"{"github":"   "}"#.write(to: file, atomically: true, encoding: .utf8)
        TokenStore.TestSupport.invalidate()
        XCTAssertNil(TokenStore.token(for: .github))
    }

    // MARK: - Permissions

    /// This is the whole security argument for a plaintext file, so it is worth
    /// pinning: `Data.write` creates with the umask, which is typically 644.
    func testTheFileIsOnlyReadableByItsOwner() throws {
        try TokenStore.save("secret", for: .github)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.int16Value, 0o600,
                       "expected -rw------- (600), got \(String(permissions.int16Value, radix: 8))")
    }

    func testTheDirectoryIsNotWorldReadable() throws {
        try TokenStore.save("secret", for: .github)
        let directory = file.deletingLastPathComponent()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.int16Value, 0o700)
    }

    /// Re-saving must not reset the permissions, or a rotated token would end up
    /// more readable than the one before it.
    func testPermissionsSurviveASecondWrite() throws {
        try TokenStore.save("a", for: .github)
        try TokenStore.save("b", for: .github)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.int16Value, 0o600)
    }

    /// The file must not be the kind of thing a build or a backup picks up by
    /// accident, so the content is only ever a flat service-to-token map.
    func testTheFileHoldsNothingButTheTokens() throws {
        try TokenStore.save("a", for: .github)
        try TokenStore.save("b", for: .vercel)
        let text = try String(contentsOf: file, encoding: .utf8)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(Set(parsed.keys), ["github", "vercel"])
    }

    // MARK: - Caching

    /// The cache exists so a poll of ten sources reads the file once. It has to
    /// be invalidated by anything that changes the file underneath it.
    func testTheCacheSeesAWriteThroughTheStore() throws {
        XCTAssertFalse(TokenStore.hasToken(for: .github))
        try TokenStore.save("a", for: .github)
        XCTAssertTrue(TokenStore.hasToken(for: .github), "a write must be visible without a reload")
    }

    func testInvalidatingTheCacheRereadsTheFile() throws {
        try TokenStore.save("a", for: .github)
        try #"{"github":"changed-outside"}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(TokenStore.token(for: .github), "a", "still the cached value")
        TokenStore.TestSupport.invalidate()
        XCTAssertEqual(TokenStore.token(for: .github), "changed-outside")
    }

    // MARK: - Location

    func testDefaultPathSitsNextToTheConfig() {
        let path = TokenStore.defaultURL.path
        XCTAssertTrue(path.hasSuffix("/CIStatus/tokens.json"), path)
        // No secrets in the config directory's name, and not in the project.
        XCTAssertFalse(path.contains("dev/ciStatus"), path)
    }

    func testTheEnvironmentOverridesTheLocation() {
        let previous = ProcessInfo.processInfo.environment["CISTATUS_TOKENS"]
        defer {
            if let previous { setenv("CISTATUS_TOKENS", previous, 1) } else { unsetenv("CISTATUS_TOKENS") }
        }
        setenv("CISTATUS_TOKENS", "/tmp/elsewhere.json", 1)
        // The override is read through `defaultURL`, and only when no explicit
        // override is installed.
        XCTAssertEqual(TokenStore.defaultURL.path, "/tmp/elsewhere.json")
    }
}
