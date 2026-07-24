// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Application

final class AppVersionTests: XCTestCase {
    func testParseAcceptsLeadingVAndDefaultsPatch() {
        XCTAssertEqual(AppVersion.parse("v1.2"), AppVersion(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(AppVersion.parse("0.2.0"), AppVersion(major: 0, minor: 2, patch: 0))
        XCTAssertEqual(AppVersion.parse("1.0.0-beta"), AppVersion(major: 1, minor: 0, patch: 0))
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(AppVersion.parse(""))
        XCTAssertNil(AppVersion.parse("latest"))
        XCTAssertNil(AppVersion.parse("1"))
    }

    func testOrdering() throws {
        let older = try XCTUnwrap(AppVersion.parse("0.2.0"))
        let newer = try XCTUnwrap(AppVersion.parse("0.3.0"))
        XCTAssertTrue(older < newer)
        XCTAssertFalse(newer < older)
        XCTAssertEqual(older, AppVersion.parse("v0.2.0"))
    }
}
