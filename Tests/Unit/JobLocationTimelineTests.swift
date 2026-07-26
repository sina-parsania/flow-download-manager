// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Persistence
import XCTest

final class JobLocationTimelineTests: XCTestCase {
    func testSetsStartedAtOnFirstConnecting() {
        var job = sampleJob(state: .queued)
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        JobLocationTimeline.applyStateTransition(
            &job, from: .queued, to: .connecting, at: now
        )
        XCTAssertEqual(job.startedAt, now)
        XCTAssertNil(job.completedAt)
    }

    func testSetsCompletedAtOnTerminalAndClearsOnRetry() {
        var job = sampleJob(state: .downloading)
        job.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let finished = Date(timeIntervalSince1970: 1_700_000_200)
        JobLocationTimeline.applyStateTransition(
            &job, from: .downloading, to: .failed, at: finished
        )
        XCTAssertEqual(job.completedAt, finished)

        JobLocationTimeline.applyStateTransition(
            &job, from: .failed, to: .queued, at: Date(timeIntervalSince1970: 1_700_000_300)
        )
        XCTAssertNil(job.completedAt)
        XCTAssertEqual(job.startedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testClearForRestartWipesTimeline() {
        var job = sampleJob(state: .failed)
        job.startedAt = Date(timeIntervalSince1970: 1)
        job.completedAt = Date(timeIntervalSince1970: 2)
        JobLocationTimeline.clearForRestart(&job)
        XCTAssertNil(job.startedAt)
        XCTAssertNil(job.completedAt)
    }

    private func sampleJob(state: JobState) -> JobRecord {
        JobRecord(
            id: "00000000-0000-7000-8000-000000000001",
            batchID: nil,
            resourceID: "00000000-0000-7000-8000-0000000000a1",
            state: state.rawValue,
            priority: 0,
            queuePosition: 0,
            categoryID: "00000000-0000-7000-8000-0000000000c1",
            projectID: nil,
            destinationProfileID: "00000000-0000-7000-8000-0000000000d1",
            scheduleID: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            revision: 1,
            terminalReason: nil
        )
    }
}
