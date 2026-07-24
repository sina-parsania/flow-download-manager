// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import Application

/// Covers the validation and wording that App Intents apply to untrusted input.
///
/// The App target is not linked by this bundle, so `FlowIntentInput.swift` is
/// compiled into it directly (`Tests/Unit/FlowIntentInput.swift` is a link to the
/// one under `Sources/App/Intents`) — one definition, two modules, no copy to
/// drift. Everything under test is a plain value type with no engine behind it.
final class FlowIntentInputTests: XCTestCase {
    // MARK: - Links that are accepted

    func testAcceptsHTTPAndHTTPSUnchanged() throws {
        let secure = try FlowIntentInput.normalizedLink("https://example.com/a.zip")
        let plain = try FlowIntentInput.normalizedLink("http://example.com/a.zip")
        XCTAssertEqual(secure, "https://example.com/a.zip")
        XCTAssertEqual(plain, "http://example.com/a.zip")
    }

    func testTrimsSurroundingWhitespaceButNeverRewritesTheLink() throws {
        let link = try FlowIntentInput.normalizedLink("  https://example.com/A%20b.zip?x=1#f\n")
        XCTAssertEqual(link, "https://example.com/A%20b.zip?x=1#f")
    }

    func testAcceptsUppercaseScheme() throws {
        let link = try FlowIntentInput.normalizedLink("HTTPS://Example.com/a")
        XCTAssertEqual(link, "HTTPS://Example.com/a")
    }

    // MARK: - Links that are refused

    func testRejectsEmptyOrBlankLink() {
        assertFailure(.noLinkProvided) { try FlowIntentInput.normalizedLink("") }
        assertFailure(.noLinkProvided) { try FlowIntentInput.normalizedLink("   \n ") }
    }

    func testRejectsLinkOverThePayloadCeiling() {
        let long = "https://example.com/" + String(repeating: "a", count: FlowIntentInput.maxLinkBytes)
        assertFailure(.linkTooLong) { try FlowIntentInput.normalizedLink(long) }
    }

    func testRejectsTextThatIsNotALink() {
        assertFailure(.linkNotUnderstood) { try FlowIntentInput.normalizedLink("just some text") }
        assertFailure(.linkNotUnderstood) { try FlowIntentInput.normalizedLink("example.com/a.zip") }
    }

    func testRejectsSchemeWithoutHost() {
        assertFailure(.linkNotUnderstood) { try FlowIntentInput.normalizedLink("https://") }
    }

    func testRejectsControlCharactersInsideTheLink() {
        assertFailure(.linkNotUnderstood) { try FlowIntentInput.normalizedLink("https://example.com/a\u{0}b") }
        assertFailure(.linkNotUnderstood) { try FlowIntentInput.normalizedLink("https://example.com/a b") }
    }

    /// Only http/https genuinely download today, so everything else is refused
    /// with wording rather than accepted and failed later by the transfer.
    func testRejectsSchemesThatCannotDownloadToday() {
        assertFailure(.unsupportedScheme("ftp")) { try FlowIntentInput.normalizedLink("ftp://example.com/a.zip") }
        assertFailure(.unsupportedScheme("sftp")) { try FlowIntentInput.normalizedLink("sftp://example.com/a") }
        assertFailure(.unsupportedScheme("magnet")) { try FlowIntentInput.normalizedLink("magnet:?xt=urn:btih:abc") }
        assertFailure(.unsupportedScheme("file")) { try FlowIntentInput.normalizedLink("file:///etc/hosts") }
        assertFailure(.unsupportedScheme("javascript")) {
            try FlowIntentInput.normalizedLink("javascript:alert(1)")
        }
    }

    /// The refused scheme is echoed back to the person, so it is filtered and
    /// clipped first — intent input is not trusted just because it parsed.
    func testUnsupportedSchemeLabelIsClippedAndFiltered() {
        let scheme = String(repeating: "z", count: 40)
        do {
            _ = try FlowIntentInput.normalizedLink("\(scheme)://example.com/a")
            XCTFail("expected an unsupported-scheme failure")
        } catch let failure as FlowIntentFailure {
            guard case let .unsupportedScheme(label) = failure else {
                return XCTFail("expected unsupportedScheme, got \(failure)")
            }
            XCTAssertEqual(label.count, 12)
            XCTAssertEqual(label, String(repeating: "z", count: 12))
        } catch {
            XCTFail("expected FlowIntentFailure")
        }
    }

    // MARK: - File names

    func testBlankFileNameMeansNoPreference() throws {
        let missing = try FlowIntentInput.normalizedFileName(nil)
        let blank = try FlowIntentInput.normalizedFileName("   ")
        XCTAssertNil(missing)
        XCTAssertNil(blank)
    }

    func testKeepsAUsableFileName() throws {
        let name = try FlowIntentInput.normalizedFileName("  Report 2026.pdf ")
        XCTAssertEqual(name, "Report 2026.pdf")
    }

    func testRejectsFileNamesThatEscapeTheFolder() {
        assertFailure(.fileNameNotUsable) { try FlowIntentInput.normalizedFileName("../../etc/passwd") }
        assertFailure(.fileNameNotUsable) { try FlowIntentInput.normalizedFileName("a/b.zip") }
        assertFailure(.fileNameNotUsable) { try FlowIntentInput.normalizedFileName("..") }
        assertFailure(.fileNameNotUsable) { try FlowIntentInput.normalizedFileName(".") }
    }

    func testRejectsFileNamesWithSeparatorsOrControlCharacters() {
        assertFailure(.fileNameNotUsable) { try FlowIntentInput.normalizedFileName("Volume:name.zip") }
        assertFailure(.fileNameNotUsable) { try FlowIntentInput.normalizedFileName("a\u{0}b.zip") }
    }

    func testRejectsOverlongFileName() {
        let long = String(repeating: "a", count: FlowIntentInput.maxFileNameBytes + 1)
        assertFailure(.fileNameNotUsable) { try FlowIntentInput.normalizedFileName(long) }
    }

    func testValidateCombinesLinkAndFileName() throws {
        let request = try FlowIntentInput.validate(link: " https://example.com/a.zip ", fileName: " a.zip ")
        XCTAssertEqual(request, ValidatedDownload(link: "https://example.com/a.zip", fileName: "a.zip"))
    }

    // MARK: - Batches

    func testBatchKeepsOrderAndDropsRepeats() throws {
        let batch = try FlowIntentInput.validate(links: [
            "https://example.com/a.zip",
            " https://example.com/b.zip ",
            "https://example.com/a.zip"
        ])
        XCTAssertEqual(batch.accepted.map(\.link), [
            "https://example.com/a.zip",
            "https://example.com/b.zip"
        ])
        XCTAssertEqual(batch.skippedCount, 1)
    }

    /// One bad link in a scraped list must not cost the person the good ones.
    func testBatchAcceptsWhatItCanAndCountsWhatItDropped() throws {
        let batch = try FlowIntentInput.validate(links: [
            "https://example.com/a.zip",
            "magnet:?xt=urn:btih:abc",
            "not a link",
            "http://example.com/b.zip"
        ])
        XCTAssertEqual(batch.accepted.count, 2)
        XCTAssertEqual(batch.skippedCount, 2)
    }

    func testBatchWithNothingUsableThrowsTheFirstReason() {
        assertFailure(.unsupportedScheme("magnet")) {
            try FlowIntentInput.validate(links: ["magnet:?xt=urn:btih:abc", "nope"])
        }
    }

    func testEmptyBatchIsRefused() {
        assertFailure(.noLinkProvided) { try FlowIntentInput.validate(links: []) }
    }

    func testBatchOverTheLimitIsRefused() {
        let links = Array(repeating: "https://example.com/a.zip", count: FlowIntentInput.maxLinksPerRequest + 1)
        assertFailure(.tooManyLinks(limit: FlowIntentInput.maxLinksPerRequest)) {
            try FlowIntentInput.validate(links: links)
        }
    }

    // MARK: - Wording

    /// A shortcut runs with no window to explain itself afterwards, so every
    /// failure has to be a sentence a non-engineer can act on.
    func testEveryFailureReadsAsPlainLanguage() {
        let failures: [FlowIntentFailure] = [
            .noLinkProvided,
            .linkTooLong,
            .linkNotUnderstood,
            .unsupportedScheme("ftp"),
            .tooManyLinks(limit: 250),
            .fileNameNotUsable,
            .engineUnavailable,
            .addFailed,
            .updateFailed
        ]
        let banned = [
            "XPC", "LaunchAgent", "SMAppService", "plist", "SQLite",
            "Application Support", "segmap", "NSError", "Optional",
            "debug", "daemon", "socket", "localhost"
        ]
        for failure in failures {
            let message = failure.message
            XCTAssertFalse(message.isEmpty, "\(failure) has no wording")
            XCTAssertTrue(message.hasSuffix("."), "\(failure) is not a sentence: \(message)")
            XCTAssertFalse(message.contains("Tap"), "macOS says Click, not Tap: \(message)")
            for word in banned {
                XCTAssertFalse(
                    message.localizedCaseInsensitiveContains(word),
                    "\(failure) leaks engineering vocabulary “\(word)”: \(message)"
                )
            }
        }
    }

    /// The engine can genuinely be off when a shortcut fires; the wording has to
    /// say what to do about it, not what failed underneath.
    func testEngineUnavailableTellsThePersonWhatToDo() {
        let message = FlowIntentFailure.engineUnavailable.message
        XCTAssertTrue(message.contains("Open Flow"), message)
    }

    // MARK: - Helpers

    private func assertFailure(
        _ expected: FlowIntentFailure,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> some Any
    ) {
        do {
            _ = try body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let failure as FlowIntentFailure {
            XCTAssertEqual(failure, expected, file: file, line: line)
        } catch {
            XCTFail("expected FlowIntentFailure, got \(error)", file: file, line: line)
        }
    }
}
