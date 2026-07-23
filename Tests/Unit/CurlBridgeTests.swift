// SPDX-License-Identifier: GPL-3.0-or-later

import TransferCurlBridge
import XCTest

final class CurlBridgeTests: XCTestCase {
    override func setUpWithError() throws {
        try CurlBridge.initialize()
    }

    func testPinnedBuildExposesRequiredProtocols() {
        let caps = CurlBridge.capabilities()
        XCTAssertTrue(caps.version.hasPrefix("8."), "expected curl 8.x, got \(caps.version)")
        XCTAssertTrue(caps.supportsHTTP)
        XCTAssertTrue(caps.supportsHTTPS)
        XCTAssertTrue(caps.supportsFTP)
        XCTAssertTrue(caps.supportsFTPS)
        XCTAssertTrue(caps.supportsSFTP)
        XCTAssertTrue(caps.supportsHTTP2)
        XCTAssertNotNil(caps.sslVersion)
        XCTAssertNotNil(caps.libsshVersion)
        XCTAssertNotNil(caps.nghttp2Version)
        // Pinned OpenSSL backend (Secure Transport removed upstream in curl 8.21+).
        XCTAssertTrue(
            (caps.sslVersion ?? "").localizedCaseInsensitiveContains("OpenSSL"),
            "expected OpenSSL TLS backend, got \(caps.sslVersion ?? "nil")"
        )
    }

    func testURLParserAcceptsPhase1Schemes() throws {
        let https = try CurlURLParser.parse("https://Example.COM:443/path?q=1")
        XCTAssertEqual(https.scheme, "https")
        XCTAssertEqual(https.host?.lowercased(), "example.com")
        XCTAssertEqual(https.path, "/path")
        XCTAssertEqual(https.query, "q=1")
        XCTAssertTrue(https.isPhase1Supported)
        XCTAssertEqual(https.normalizationKey, "https://example.com/path?q=1")

        let sftp = try CurlURLParser.parse("sftp://files.example/a.bin")
        XCTAssertTrue(sftp.isPhase1Supported)
    }

    func testURLParserRejectsEmpty() {
        XCTAssertThrowsError(try CurlURLParser.parse("")) { error in
            XCTAssertEqual(error as? CurlBridgeError, .emptyURL)
        }
    }
}
