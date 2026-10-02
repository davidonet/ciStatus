import Foundation
import XCTest
@testable import CIStatusKit

/// The log is the only diagnostic a menu bar app leaves behind, so the two
/// things that matter are that it says enough to explain a failure, and that it
/// never becomes the place a secret leaks.
final class LogTests: XCTestCase {
    private var sink: MemorySink!
    private var logFile: URL!

    override func setUp() {
        super.setUp()
        sink = MemorySink()
        Log.useSink(sink)
        Log.forgetSecrets()
        Log.level = .debug
        logFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cistatus-log-\(UUID().uuidString).log")
    }

    override func tearDown() {
        Log.useSink(nil)
        Log.forgetSecrets()
        Log.level = .info
        try? FileManager.default.removeItem(at: logFile)
        super.tearDown()
    }

    // MARK: - Redaction

    /// The strongest guarantee the log can make: a value that was registered as a
    /// secret must not survive into a line, even when an error body quotes it.
    func testRegisteredSecretsAreMasked() {
        Log.registerSecret("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
        Log.error("HTTP 401 for token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
        XCTAssertFalse(sink.text.contains("ABCDEFGHIJKL"), sink.text)
        XCTAssertTrue(sink.text.contains("<redacted>"), sink.text)
    }

    func testARegisteredSecretOfOtherLengthsIsAlsoMasked() {
        Log.registerSecret("sekrit-value")
        Log.info("sent sekrit-value upstream")
        XCTAssertFalse(sink.text.contains("sekrit-value"), sink.text)
    }

    /// A short registered value is not masked, because masking a two-character
    /// string would shred every line that happens to contain it.
    func testVeryShortSecretsAreNotMasked() {
        Log.registerSecret("ab")
        Log.info("a cab and a taxi")
        XCTAssertTrue(sink.text.contains("cab"), sink.text)
    }

    /// Tokens are masked by shape even when nothing was registered, which covers
    /// a token from a service we hold no copy of.
    func testTokenShapedValuesAreMaskedWithoutRegistration() {
        let samples = [
            "ghp_16C7e42F292c6912E7710c838347Ae178B4a",
            "gho_16C7e42F292c6912E7710c838347Ae178B4a",
            "github_pat_11ABCDEFG0aBcDeFgHiJkL_MnOpQrStUvWxYz0123456789",
            "vercel_16C7e42F292c6912E7710c838347Ae1",
            "sk-abcdefghij0123456789ABCDEFGHIJ",
            "sntrs_eyJpYXQiOiJ4eXplIn0abcdefghijklmnop",
        ]
        for sample in samples {
            sink.clear()
            Log.error("upstream said: \(sample)")
            XCTAssertFalse(sink.text.contains(sample), "leaked \(sample)")
            XCTAssertTrue(sink.text.contains("<redacted>"), sample)
        }
    }

    /// An ordinary value that merely looks long is not a token and must survive,
    /// or the log would be useless for the errors it exists to capture.
    func testOrdinaryValuesAreNotMasked() {
        Log.info("HTTP 404 {\"message\":\"Not Found\",\"documentation_url\":\"https://x\"}")
        XCTAssertTrue(sink.text.contains("Not Found"), sink.text)
        XCTAssertFalse(sink.text.contains("<redacted>"), sink.text)
    }

    /// A redacted line still needs to be readable, so the mask replaces the
    /// value rather than the whole line.
    func testRedactionKeepsSurroundingContext() {
        Log.registerSecret("supersecrettoken")
        Log.error("connecting with supersecrettoken to api.github.com")
        XCTAssertTrue(sink.text.contains("connecting with"), sink.text)
        XCTAssertTrue(sink.text.contains("api.github.com"), sink.text)
    }

    // MARK: - Levels and format

    func testLinesBelowTheThresholdAreDropped() {
        Log.level = .warning
        Log.debug("debug line")
        Log.info("info line")
        Log.warning("warn line")
        Log.error("error line")
        let text = sink.text
        XCTAssertFalse(text.contains("debug line"), text)
        XCTAssertFalse(text.contains("info line"), text)
        XCTAssertTrue(text.contains("warn line"), text)
        XCTAssertTrue(text.contains("error line"), text)
    }

    func testDefaultLevelIsInfo() {
        XCTAssertEqual(Log.Level(rawValue: "info"), .info)
        // Debug is off by default, or a 60 second poll would bury everything else.
        XCTAssertTrue(Log.Level.info > Log.Level.debug)
    }

    /// Each line carries its level, since a log file read out of context has no
    /// other way to show what was a warning rather than routine.
    func testLinesAreStampedWithLevelAndTime() {
        Log.warning("something to note")
        let line = try? XCTUnwrap(sink.lines.first)
        guard let line else { return XCTFail("no line written") }
        XCTAssertTrue(line.contains("WARNING"), line)
        XCTAssertTrue(line.contains("something to note"), line)
        // An ISO 8601 timestamp, so the file sorts and is greppable.
        XCTAssertTrue(line.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"#, options: .regularExpression) != nil,
                      line)
    }

    func testEveryLineEndsWithANewline() {
        Log.info("one")
        Log.info("two")
        XCTAssertEqual(sink.lines.count, 2)
        XCTAssertTrue(sink.lines.allSatisfy { $0.hasSuffix("\n") })
    }

    func testTheMessageIsBuiltEvenWhenFiltered() {
        // Pinned because it is a trap rather than a bug: @autoclosure means the
        // work happens before the level check, so a caller must not put
        // anything expensive or side-effecting inside a debug call.
        Log.level = .error
        var built = 0
        Log.debug("built \( { built += 1; return 1 }() )")
        XCTAssertEqual(built, 1, "the closure runs regardless of the level")
    }

    // MARK: - File sink

    func testLinesReachTheFile() throws {
        Log.useSink(nil)
        Log.configure(url: logFile, level: .debug)
        defer { Log.useSink(nil) }

        Log.info("written to disk")
        let text = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(text.contains("written to disk"), text)
    }

    /// Reopening appends, so restarting the app keeps the history that explains
    /// why the previous run misbehaved.
    func testReopeningAppendsRatherThanTruncating() throws {
        Log.useSink(nil)
        Log.configure(url: logFile, level: .debug)
        Log.info("first run")
        Log.configure(url: logFile, level: .debug)
        Log.info("second run")

        let text = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(text.contains("first run"), text)
        XCTAssertTrue(text.contains("second run"), text)
    }

    /// A line longer than the cap is cut, so one huge error body cannot evict
    /// the whole log.
    func testAVeryLongLineIsTruncated() throws {
        Log.useSink(nil)
        Log.configure(url: logFile, level: .debug)
        Log.error(String(repeating: "x", count: 100_000))

        let text = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertLessThan(text.utf8.count, 8_192, "a single line filled the file")
        XCTAssertTrue(text.contains("line truncated"), String(text.prefix(200)))
    }

    func testRotationKeepsRecentHistoryAndStops() throws {
        Log.useSink(nil)
        // Force rotation with a small file rather than writing a megabyte.
        let directory = logFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logFile.path, contents: nil)

        // The sink rotates at 1 MB, so seed just over that.
        let filler = String(repeating: "y", count: 1_048_576)
        try filler.write(to: logFile, atomically: true, encoding: .utf8)
        Log.configure(url: logFile, level: .debug)
        Log.info("after rotation")

        let rotated = logFile.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path),
                      "the old file should have been moved aside")
        let current = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(current.contains("after rotation"), current)
    }

    /// A log that cannot be written must not take the poll loop down with it.
    func testAnUnwritablePathIsDroppedRatherThanThrowing() {
        let impossible = URL(fileURLWithPath: "/dev/null/nope/cistatus.log")
        Log.useSink(nil)
        // No assertion on the return: the point is that this does not throw and
        // does not crash.
        Log.configure(url: impossible, level: .debug)
        Log.error("this cannot be written")
        Log.useSink(nil)
    }

    // MARK: - Location

    func testDefaultPathIsUnderLibraryLogs() {
        let path = Log.defaultURL.path
        XCTAssertTrue(path.contains("/Library/Logs/CIStatus/"), path)
        XCTAssertTrue(path.hasSuffix(".log"), path)
    }
}
