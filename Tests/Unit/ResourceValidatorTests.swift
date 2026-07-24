// SPDX-License-Identifier: GPL-3.0-or-later

import TransferCore
import XCTest

/// Resume identity checks.
///
/// Before validators existed the only resume check was byte count, so a resource
/// that changed but kept its length was resumed into — old bytes stitched to new
/// ones, producing a right-sized corrupt file that passed every later check. On a
/// link that disconnects often, resumes are the common case, so this is the most
/// likely corruption path in the whole engine.
final class ResourceValidatorTests: XCTestCase {
    private let total: Int64 = 4096

    private func stored(etag: String? = nil, lastModified: String? = nil) -> ResourceValidator {
        ResourceValidator(etag: etag, lastModified: lastModified, totalBytes: total)
    }

    // MARK: Rejects

    func testDifferentStrongETagRejectsResume() {
        let verdict = stored(etag: "\"v1\"").compare(
            probeETag: "\"v2\"", probeLastModified: nil, probeTotalBytes: total
        )
        XCTAssertEqual(verdict, .changed(reason: "etag"))
    }

    func testDifferentLengthRejectsResumeEvenWhenETagMatches() {
        let verdict = stored(etag: "\"v1\"").compare(
            probeETag: "\"v1\"", probeLastModified: nil, probeTotalBytes: total + 1
        )
        XCTAssertEqual(verdict, .changed(reason: "length"))
    }

    func testDifferentLastModifiedRejectsWhenNoETag() {
        let verdict = stored(lastModified: "Mon, 01 Jan 2024 00:00:00 GMT").compare(
            probeETag: nil,
            probeLastModified: "Tue, 02 Jan 2024 00:00:00 GMT",
            probeTotalBytes: total
        )
        XCTAssertEqual(verdict, .changed(reason: "lastModified"))
    }

    // MARK: Accepts

    func testMatchingStrongETagResumes() {
        XCTAssertEqual(
            stored(etag: "\"v1\"").compare(
                probeETag: "\"v1\"", probeLastModified: nil, probeTotalBytes: total
            ),
            .matches
        )
    }

    /// A strong ETag outranks a changed `Last-Modified` — some servers rewrite the
    /// timestamp without changing a byte.
    func testStrongETagWinsOverDisagreeingLastModified() {
        XCTAssertEqual(
            stored(etag: "\"v1\"", lastModified: "Mon, 01 Jan 2024 00:00:00 GMT").compare(
                probeETag: "\"v1\"",
                probeLastModified: "Tue, 02 Jan 2024 00:00:00 GMT",
                probeTotalBytes: total
            ),
            .matches
        )
    }

    /// Servers that send nothing must stay resumable, or resume breaks for a large
    /// slice of the internet.
    func testNoValidatorEitherSideStillResumes() {
        XCTAssertEqual(
            stored().compare(probeETag: nil, probeLastModified: nil, probeTotalBytes: total),
            .matches
        )
    }

    /// A map written before validators existed decodes with none. That must not
    /// block a resume — absence is not contradiction.
    func testValidatorPresentOnOneSideOnlyDoesNotReject() {
        XCTAssertEqual(
            stored().compare(probeETag: "\"v9\"", probeLastModified: nil, probeTotalBytes: total),
            .matches
        )
        XCTAssertEqual(
            stored(etag: "\"v9\"").compare(
                probeETag: nil, probeLastModified: nil, probeTotalBytes: total
            ),
            .matches
        )
    }

    func testUnknownRemoteLengthAndNoValidatorIsUnverifiable() {
        XCTAssertEqual(
            stored().compare(probeETag: nil, probeLastModified: nil, probeTotalBytes: nil),
            .unverifiable
        )
    }

    // MARK: Weak validators

    /// `W/` promises semantic equivalence, not identical bytes. Stitching two
    /// halves together needs byte equality, so a weak tag must not license a
    /// resume on its own — it falls through to the weaker signals.
    func testWeakETagIsNotTrustedForByteIdentity() {
        XCTAssertEqual(
            stored(etag: "W/\"v1\"").compare(
                probeETag: "W/\"v2\"", probeLastModified: nil, probeTotalBytes: total
            ),
            .matches,
            "weak tags must be ignored, not compared"
        )
        XCTAssertEqual(
            stored(etag: "W/\"v1\"", lastModified: "Mon, 01 Jan 2024 00:00:00 GMT").compare(
                probeETag: "W/\"v1\"",
                probeLastModified: "Tue, 02 Jan 2024 00:00:00 GMT",
                probeTotalBytes: total
            ),
            .changed(reason: "lastModified"),
            "with the weak tag ignored, Last-Modified must decide"
        )
    }

    func testWhitespaceAndEmptyValuesAreTreatedAsAbsent() {
        XCTAssertEqual(
            ResourceValidator(etag: "  ", lastModified: "", totalBytes: total).compare(
                probeETag: "\"v1\"", probeLastModified: nil, probeTotalBytes: total
            ),
            .matches
        )
    }
}
