// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Domain
import XCTest

final class BulkJobCommandFilterTests: XCTestCase {
    func testPauseTargetsActiveQueuedAndScheduled() {
        let pauseStates: [JobState] = [
            .queued, .connecting, .downloading, .scheduled, .retryWaiting
        ]
        for state in pauseStates {
            XCTAssertTrue(
                BulkJobCommandFilter.shouldReceivePause(state),
                "\(state.rawValue) should receive pause"
            )
            XCTAssertFalse(BulkJobCommandFilter.shouldReceiveResume(state))
        }
    }

    func testResumeTargetsOnlyPaused() {
        XCTAssertTrue(BulkJobCommandFilter.shouldReceiveResume(.paused))
        XCTAssertFalse(BulkJobCommandFilter.shouldReceivePause(.paused))

        for state: JobState in [.completed, .failed, .cancelled, .verifying] {
            XCTAssertFalse(BulkJobCommandFilter.shouldReceivePause(state))
            XCTAssertFalse(BulkJobCommandFilter.shouldReceiveResume(state))
        }
    }
}
