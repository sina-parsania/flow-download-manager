// SPDX-License-Identifier: GPL-3.0-or-later

import TransferCore
import XCTest

final class TransferBudgetTests: XCTestCase {
    func testHostSocketBudget() async {
        let ledger = TransferBudgetLedger(maxActiveJobs: 2, maxTotalSockets: 3, maxSocketsPerHost: 1)
        let first = await ledger.tryAcquireSocket(host: "a.example")
        let secondSameHost = await ledger.tryAcquireSocket(host: "a.example")
        let otherHost = await ledger.tryAcquireSocket(host: "b.example")
        await ledger.releaseSocket(host: "a.example")
        let afterRelease = await ledger.tryAcquireSocket(host: "a.example")
        XCTAssertTrue(first)
        XCTAssertFalse(secondSameHost)
        XCTAssertTrue(otherHost)
        XCTAssertTrue(afterRelease)
    }

    func testActiveJobBudget() async {
        let ledger = TransferBudgetLedger(maxActiveJobs: 2, maxTotalSockets: 8, maxSocketsPerHost: 8)
        let limit = await ledger.maxActiveJobsLimit()
        XCTAssertEqual(limit, 2)

        let slotsOpen = await ledger.availableJobSlots()
        XCTAssertEqual(slotsOpen, 2)

        let first = await ledger.tryBeginJob()
        let slotsAfterFirst = await ledger.availableJobSlots()
        XCTAssertEqual(slotsAfterFirst, 1)

        let second = await ledger.tryBeginJob()
        let slotsFull = await ledger.availableJobSlots()
        XCTAssertEqual(slotsFull, 0)

        let third = await ledger.tryBeginJob()
        await ledger.endJob()
        let afterEnd = await ledger.tryBeginJob()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertFalse(third)
        XCTAssertTrue(afterEnd)
    }

    func testSyncBandwidthGovernorCapsThroughput() {
        let governor = SyncBandwidthGovernor(bytesPerSecond: 5000)
        // Drain the initial full bucket so subsequent consumes must wait.
        governor.consume(bytes: 5000)
        let started = ProcessInfo.processInfo.systemUptime
        governor.consume(bytes: 2500)
        let seconds = ProcessInfo.processInfo.systemUptime - started
        // 2500 bytes at 5000 B/s needs ~0.5s; allow CI slack.
        XCTAssertGreaterThanOrEqual(seconds, 0.25)
        XCTAssertLessThan(seconds, 4.0)
    }
}
