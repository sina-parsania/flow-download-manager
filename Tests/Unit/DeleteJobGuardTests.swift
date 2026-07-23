// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Domain
import XCTest

final class DeleteJobGuardTests: XCTestCase {
    func testAllowsDeleteOnlyTerminalStates() {
        for state in JobState.terminalStates {
            XCTAssertTrue(
                DeleteJobGuard.allowsDelete(state),
                "\(state.rawValue) should allow delete"
            )
        }
        for state in JobState.allCases where !JobState.terminalStates.contains(state) {
            XCTAssertFalse(
                DeleteJobGuard.allowsDelete(state),
                "\(state.rawValue) must not allow delete"
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
