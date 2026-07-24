// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import EngineAgent

final class JobChangeLedgerTests: XCTestCase {
    func testDrainIdleThenPublishesUpserts() {
        let ledger = JobChangeLedger()
        let baseline = ledger.checkpointFullSync()
        XCTAssertEqual(baseline, 1)

        let idle = ledger.drain(since: baseline)
        XCTAssertTrue(idle.idle)
        XCTAssertFalse(idle.hasGap)
        XCTAssertEqual(idle.sequence, baseline)

        ledger.noteUpsert("a")
        ledger.noteUpsert("b")
        ledger.noteUpsert("a")
        let batch = ledger.drain(since: baseline)
        XCTAssertFalse(batch.idle)
        XCTAssertFalse(batch.hasGap)
        XCTAssertEqual(Set(batch.upsertIDs), Set(["a", "b"]))
        XCTAssertEqual(batch.sequence, baseline + 1)
    }

    func testRemovalAndGapOnFutureSince() {
        let ledger = JobChangeLedger()
        let baseline = ledger.checkpointFullSync()
        ledger.noteRemoval("gone")
        let batch = ledger.drain(since: baseline)
        XCTAssertEqual(batch.removedIDs, ["gone"])

        let gap = ledger.drain(since: batch.sequence + 10)
        XCTAssertTrue(gap.hasGap)
    }

    func testOverflowForcesGap() {
        let ledger = JobChangeLedger()
        _ = ledger.checkpointFullSync()
        for index in 0 ..< (JobChangeLedger.overflowThreshold + 1) {
            ledger.noteUpsert("job-\(index)")
        }
        let gap = ledger.drain(since: 1)
        XCTAssertTrue(gap.hasGap)
    }
}
