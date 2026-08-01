// SPDX-License-Identifier: GPL-3.0-or-later

import TransferCore
import XCTest
@testable import EngineAgent

/// A ramping transfer must not eat the whole host budget.
///
/// `tryAcquireSocket` refuses once a host holds `maxSocketsPerHost`. Before the
/// connection ramp every job took a fixed 8, so four downloads from one CDN fitted
/// comfortably. Once one job could climb to 32 it could hold the entire host
/// allowance, and the next episode from the same site could not acquire even its
/// primary socket — it bounced off the pump every 200 ms and sat in **queued**
/// until the first download finished.
final class RampSiblingStarvationTests: XCTestCase {
    private func ledger() -> TransferBudgetLedger {
        TransferBudgetLedger(maxActiveJobs: 5, maxTotalSockets: 96, maxSocketsPerHost: 32)
    }

    /// The mechanism, at the budget layer: a host drained to its ceiling turns
    /// every sibling away.
    func testAHostDrainedToItsCeilingRefusesEverySibling() async {
        let budget = ledger()
        let host = "cdn.example"

        await budget.beginHostJob(host)
        let first = await budget.tryAcquireSocket(host: host)
        XCTAssertTrue(first)
        let grabbed = await budget.reserveSockets(host: host, upTo: 31)
        XCTAssertEqual(grabbed, 31, "one ramping job can take the whole host allowance")

        await budget.beginHostJob(host)
        let sibling = await budget.tryAcquireSocket(host: host)
        XCTAssertFalse(
            sibling,
            "sibling cannot even get a primary socket — this is the queued stall"
        )
    }

    /// The fix: growth is clamped so a floor always survives for siblings.
    func testGrowthCeilingLeavesRoomForEveryOtherActiveJob() {
        let alone = TransferOrchestrator.rampGrowthCeiling(
            fairCap: 32,
            hostMax: 32,
            activeJobLimit: 5
        )
        XCTAssertEqual(alone, 28, "32 minus one primary socket for each of 4 possible siblings")

        let shared = TransferOrchestrator.rampGrowthCeiling(
            fairCap: 8,
            hostMax: 32,
            activeJobLimit: 5
        )
        XCTAssertEqual(shared, 8, "never grow past this job's fair share")

        let tiny = TransferOrchestrator.rampGrowthCeiling(
            fairCap: 1,
            hostMax: 2,
            activeJobLimit: 8
        )
        XCTAssertEqual(tiny, 1, "never returns zero, however tight the budget")
    }

    /// After the clamp, a sibling can always start.
    func testSiblingStartsEvenAfterTheFirstJobHasRamped() async {
        let budget = ledger()
        let host = "cdn.example"

        await budget.beginHostJob(host)
        let first = await budget.tryAcquireSocket(host: host)
        XCTAssertTrue(first)

        let fair = await budget.fairConnectionCap(forHost: host)
        let ceiling = TransferOrchestrator.rampGrowthCeiling(
            fairCap: fair,
            hostMax: 32,
            activeJobLimit: 5
        )
        _ = await budget.reserveSockets(host: host, upTo: ceiling - 1)

        await budget.beginHostJob(host)
        let sibling = await budget.tryAcquireSocket(host: host)
        XCTAssertTrue(
            sibling,
            "a second download from the same host must still be able to start"
        )
    }
}
