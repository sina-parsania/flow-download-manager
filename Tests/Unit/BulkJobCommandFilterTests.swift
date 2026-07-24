// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Domain
import XCTest

final class BulkJobCommandFilterTests: XCTestCase {
    func testPauseTargetsActiveQueuedAndScheduled() {
        let pauseStates: [JobState] = [
            .queued, .connecting, .downloading, .scheduled, .retryWaiting,
            .ready, .verifying, .merging, .postProcessing
        ]
        for state in pauseStates {
            XCTAssertTrue(
                BulkJobCommandFilter.canPause(state),
                "\(state.rawValue) should receive pause"
            )
        }
        for state: JobState in [.completed, .failed, .cancelled, .paused] {
            XCTAssertFalse(BulkJobCommandFilter.canPause(state), state.rawValue)
        }
    }

    func testResumeTargetsPausedAndRetryWaiting() {
        XCTAssertTrue(BulkJobCommandFilter.canResume(.paused))
        XCTAssertTrue(BulkJobCommandFilter.canResume(.retryWaiting))
        XCTAssertFalse(BulkJobCommandFilter.canResume(.downloading))
        XCTAssertFalse(BulkJobCommandFilter.canResume(.completed))
    }

    func testCancelDisabledOnTerminal() {
        for state in JobState.terminalStates {
            XCTAssertFalse(BulkJobCommandFilter.canCancel(state), state.rawValue)
        }
        XCTAssertTrue(BulkJobCommandFilter.canCancel(.downloading))
        XCTAssertTrue(BulkJobCommandFilter.canCancel(.paused))
        XCTAssertTrue(BulkJobCommandFilter.canCancel(.queued))
    }

    func testSelectionAnyHelpers() {
        let mixed: [JobState] = [.completed, .paused, .failed]
        XCTAssertTrue(BulkJobCommandFilter.anyCanResume(mixed))
        XCTAssertFalse(BulkJobCommandFilter.anyCanPause(mixed))
        XCTAssertTrue(BulkJobCommandFilter.anyCanRetry(mixed))
        XCTAssertTrue(BulkJobCommandFilter.anyCanRemove(mixed))
        // Paused is non-terminal, so Cancel stays available for the selection.
        XCTAssertTrue(BulkJobCommandFilter.anyCanCancel(mixed))

        let onlyTerminal: [JobState] = [.completed, .failed, .cancelled]
        XCTAssertFalse(BulkJobCommandFilter.anyCanCancel(onlyTerminal))
        XCTAssertFalse(BulkJobCommandFilter.anyCanPause(onlyTerminal))
    }
}
