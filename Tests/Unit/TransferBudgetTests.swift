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
        let ledger = TransferBudgetLedger(maxActiveJobs: 1, maxTotalSockets: 8, maxSocketsPerHost: 8)
        let first = await ledger.tryBeginJob()
        let second = await ledger.tryBeginJob()
        await ledger.endJob()
        let afterEnd = await ledger.tryBeginJob()
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertTrue(afterEnd)
    }
}
