// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Domain
import XCTest

final class DeleteJobGuardTests: XCTestCase {
    func testAllowsDeleteForEveryState() {
        for state in JobState.allCases {
            XCTAssertTrue(
                DeleteJobGuard.allowsDelete(state),
                "\(state.rawValue) should allow remove from list / remove files"
            )
        }
    }

    func testClearFailedOnlyFailed() {
        XCTAssertTrue(DeleteJobGuard.allowsClearFailed(.failed))
        for state in JobState.allCases where state != .failed {
            XCTAssertFalse(DeleteJobGuard.allowsClearFailed(state))
        }
    }
}
