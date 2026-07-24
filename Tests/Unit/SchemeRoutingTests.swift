// SPDX-License-Identifier: GPL-3.0-or-later

import TransferCurlBridge
import XCTest

/// Scheme routing for the transfer path.
///
/// `ftp`/`ftps`/`sftp` are accepted by the URL extractor and libcurl is built
/// with FTP + libssh2, but everything downstream assumed HTTP: the range probe,
/// the segment map, and a status gate demanding 200/206. FTP reports 226/250 on
/// success and SFTP reports 0, so every non-HTTP link was queued and then failed
/// once with a misleading "network unavailable". `isHTTPFamily` is what keeps
/// those schemes off the HTTP-only path.
final class SchemeRoutingTests: XCTestCase {
    private func parse(_ string: String) throws -> CurlURL {
        try CurlURLParser.parse(string)
    }

    func testHTTPFamilyCoversOnlyHTTPAndHTTPS() throws {
        XCTAssertTrue(try parse("http://example.com/a.bin").isHTTPFamily)
        XCTAssertTrue(try parse("https://example.com/a.bin").isHTTPFamily)
    }

    func testNonHTTPSupportedSchemesAreNotHTTPFamily() throws {
        for url in ["ftp://example.com/a.bin", "ftps://example.com/a.bin", "sftp://example.com/a.bin"] {
            let parsed = try parse(url)
            XCTAssertTrue(
                parsed.isPhase1Supported,
                "\(url) is offered to users, so it must remain a supported scheme"
            )
            XCTAssertFalse(
                parsed.isHTTPFamily,
                "\(url) must not take the HTTP range-probe path — it cannot return 200/206"
            )
        }
    }

    /// A scheme that is downloadable must never be HTTP-family without also
    /// being http/https — that pairing is what routes a transfer through range
    /// probing and the 200/206 gate.
    func testHTTPFamilyImpliesSupported() throws {
        for url in ["http://example.com/a", "https://example.com/a", "ftp://example.com/a"] {
            let parsed = try parse(url)
            if parsed.isHTTPFamily {
                XCTAssertTrue(parsed.isPhase1Supported)
            }
        }
    }

    func testUnsupportedSchemesStayUnsupported() throws {
        for url in ["file:///tmp/a", "gopher://example.com/a", "dict://example.com/a"] {
            let parsed = try parse(url)
            XCTAssertFalse(parsed.isPhase1Supported, "\(url) must not be downloadable")
            XCTAssertFalse(parsed.isHTTPFamily)
        }
    }
}
