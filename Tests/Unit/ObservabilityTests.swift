// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SharedObservability
import XCTest

/// Redaction primitives must never echo sensitive material
/// (`02-architecture.md` §16, `06-licensing-security-privacy.md` §4).
final class ObservabilityRedactionTests: XCTestCase {
    func testRedactedErrorIsDomainAndCodeOnly() {
        let error = NSError(domain: "TestDomain", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "/Users/someone/Secret Folder/file.mov failed"
        ])
        let redacted = EngineLog.redacted(error)
        XCTAssertEqual(redacted, "TestDomain#42")
        XCTAssertFalse(redacted.contains("Secret Folder"))
        XCTAssertFalse(redacted.contains("/Users"))
    }

    func testRedactedURLDropsPathAndQuery() throws {
        let url = try XCTUnwrap(URL(string: "https://user:pass@example.test/private/path?token=abc123"))
        let redacted = EngineLog.redacted(url)
        XCTAssertEqual(redacted, "https://example.test")
        XCTAssertFalse(redacted.contains("token"))
        XCTAssertFalse(redacted.contains("abc123"))
        XCTAssertFalse(redacted.contains("private"))
        XCTAssertFalse(redacted.contains("pass"))
    }

    func testRedactedInvalidURL() {
        let url = URL(fileURLWithPath: "/tmp") // no host
        XCTAssertEqual(EngineLog.redacted(url), "<invalid-url>")
    }
}
