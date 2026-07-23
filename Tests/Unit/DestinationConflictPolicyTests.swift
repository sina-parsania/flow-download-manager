// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import XCTest

final class DestinationConflictPolicyTests: XCTestCase {
    func testParseRecognizesPolicies() {
        XCTAssertEqual(DestinationConflictPolicy.parse("uniquify"), .uniquify)
        XCTAssertEqual(DestinationConflictPolicy.parse("rename"), .uniquify)
        XCTAssertEqual(DestinationConflictPolicy.parse("overwrite"), .overwrite)
        XCTAssertEqual(DestinationConflictPolicy.parse("fail"), .fail)
        XCTAssertEqual(DestinationConflictPolicy.parse("unknown"), .uniquify)
    }

    func testActionWhenMissingUsesPreferred() {
        XCTAssertEqual(
            DestinationConflictResolver.action(policy: .uniquify, destinationExists: false),
            .usePreferred
        )
        XCTAssertEqual(
            DestinationConflictResolver.action(policy: .overwrite, destinationExists: false),
            .usePreferred
        )
        XCTAssertEqual(
            DestinationConflictResolver.action(policy: .fail, destinationExists: false),
            .usePreferred
        )
    }

    func testActionWhenExistsSelectsPolicy() {
        XCTAssertEqual(
            DestinationConflictResolver.action(policy: .uniquify, destinationExists: true),
            .uniquify
        )
        XCTAssertEqual(
            DestinationConflictResolver.action(policy: .overwrite, destinationExists: true),
            .overwrite
        )
        XCTAssertEqual(
            DestinationConflictResolver.action(policy: .fail, destinationExists: true),
            .fail
        )
    }
}
