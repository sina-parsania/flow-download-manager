// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TransferCore
import XCTest

/// The defect these guard: a per-transfer token bucket cannot enforce an
/// aggregate ceiling. Every assertion here is an UPPER bound on throughput —
/// the pre-existing bandwidth test only lower-bounded elapsed time, which is why
/// five concurrent downloads each running at the full rate stayed green.
final class SharedRateLimiterTests: XCTestCase {
    /// Elapsed seconds while `body` runs, on the same monotonic clock the
    /// limiter uses.
    private func elapsed(_ body: () -> Void) -> TimeInterval {
        let start = ProcessInfo.processInfo.systemUptime
        body()
        return ProcessInfo.processInfo.systemUptime - start
    }

    func testNoLimitConfiguredDoesNotSleep() {
        let limiter = SharedRateLimiter()
        XCTAssertFalse(limiter.isLimited(host: "example.test"))
        let took = elapsed { limiter.charge(bytes: 100_000_000, host: "example.test") }
        XCTAssertLessThan(took, 0.05, "an unlimited charge must be a lock-free early return")
    }

    func testGlobalLimitThrottlesASingleCharger() {
        let limiter = SharedRateLimiter()
        limiter.setGlobalLimit(bytesPerSecond: 100_000)
        // Prime the queue, then measure the next charge: the first charge starts
        // from `now` and is free, which is intended (no burst penalty at start).
        limiter.charge(bytes: 50000, host: nil)
        let took = elapsed { limiter.charge(bytes: 50000, host: nil) }
        XCTAssertGreaterThan(took, 0.2, "50 KB at 100 KB/s must wait ~0.5 s")
    }

    /// The core regression. Four threads charging concurrently must drain at the
    /// configured rate in TOTAL, not at the rate each.
    func testConcurrentChargersShareOneGlobalBudget() {
        let limiter = SharedRateLimiter()
        let rate: Int64 = 200_000
        limiter.setGlobalLimit(bytesPerSecond: rate)

        let threads = 4
        let bytesEach: Int64 = 50000
        let group = DispatchGroup()
        let took = elapsed {
            for _ in 0 ..< threads {
                DispatchQueue.global().async(group: group) {
                    limiter.charge(bytes: bytesEach, host: nil)
                }
            }
            group.wait()
        }

        // 200 KB total at 200 KB/s = ~1 s of work. The first reservation is free
        // (starts at now), so expect ~0.75 s. Before the fix each thread had its
        // own bucket and this finished effectively instantly.
        XCTAssertGreaterThan(
            took, 0.4,
            "four concurrent chargers must serialise into one shared budget, not run at 4x"
        )
        XCTAssertLessThan(took, 2.0, "sleeps must take the max of deadlines, never the sum")
    }

    func testHostLimitAppliesPerHostAndIsIndependent() {
        let limiter = SharedRateLimiter()
        limiter.setHostLimit(host: "slow.test", bytesPerSecond: 100_000)
        XCTAssertTrue(limiter.isLimited(host: "slow.test"))
        XCTAssertFalse(
            limiter.isLimited(host: "other.test"),
            "a limit on one host must not throttle another"
        )
        let untouched = elapsed { limiter.charge(bytes: 10_000_000, host: "other.test") }
        XCTAssertLessThan(untouched, 0.05)
    }

    func testHostMatchingIsCaseInsensitive() {
        let limiter = SharedRateLimiter()
        limiter.setHostLimit(host: "CDN.Test", bytesPerSecond: 50000)
        XCTAssertTrue(
            limiter.isLimited(host: "cdn.test"),
            "hosts differing only in case are the same host"
        )
    }

    /// The most dangerous implementation error: charging the global and host
    /// queues as two separate sleeps adds the durations, so a user who asked for
    /// one rate silently gets less, with nothing reporting an error.
    func testGlobalAndHostChargesTakeTheMaxNotTheSum() {
        let limiter = SharedRateLimiter()
        limiter.setGlobalLimit(bytesPerSecond: 100_000)
        limiter.setHostLimit(host: "a.test", bytesPerSecond: 100_000)

        limiter.charge(bytes: 50000, host: "a.test")
        let took = elapsed { limiter.charge(bytes: 50000, host: "a.test") }

        // Identical rates: max is ~0.5 s, sum would be ~1.0 s.
        XCTAssertGreaterThan(took, 0.2)
        XCTAssertLessThan(
            took, 0.85,
            "two equal ceilings charged the same bytes must cost one wait, not two"
        )
    }

    func testNarrowerOfGlobalAndHostWins() {
        let limiter = SharedRateLimiter()
        limiter.setGlobalLimit(bytesPerSecond: 1_000_000)
        limiter.setHostLimit(host: "a.test", bytesPerSecond: 100_000)
        limiter.charge(bytes: 50000, host: "a.test")
        let took = elapsed { limiter.charge(bytes: 50000, host: "a.test") }
        XCTAssertGreaterThan(took, 0.2, "the 100 KB/s host limit must dominate the 1 MB/s global")
    }

    func testClearingALimitStopsThrottling() {
        let limiter = SharedRateLimiter()
        limiter.setGlobalLimit(bytesPerSecond: 10000)
        limiter.charge(bytes: 10000, host: nil)
        limiter.setGlobalLimit(bytesPerSecond: 0)
        XCTAssertFalse(limiter.isLimited(host: nil))
        let took = elapsed { limiter.charge(bytes: 10_000_000, host: nil) }
        XCTAssertLessThan(took, 0.05, "clearing the limit must also reset the queue cursor")
    }

    func testForgetHostDropsAccounting() {
        let limiter = SharedRateLimiter()
        limiter.setHostLimit(host: "a.test", bytesPerSecond: 10000)
        limiter.forgetHost("a.test")
        XCTAssertFalse(limiter.isLimited(host: "a.test"))
    }

    func testForgetHostIsCaseInsensitive() {
        let limiter = SharedRateLimiter()
        limiter.setHostLimit(host: "a.test", bytesPerSecond: 10000)
        limiter.forgetHost("A.TEST")
        XCTAssertFalse(
            limiter.isLimited(host: "a.test"),
            "teardown passes whatever spelling the job used; it must still match"
        )
    }

    /// A single very large charge against a tiny rate must not park a curl thread
    /// beyond the sleep ceiling, or the abort flag stops being observable.
    func testOneChargeCannotSleepPastTheCeiling() {
        let limiter = SharedRateLimiter()
        limiter.setGlobalLimit(bytesPerSecond: 1)
        let took = elapsed { limiter.charge(bytes: 10_000_000, host: nil) }
        XCTAssertLessThan(took, 31, "a single charge must be bounded by maxSleepSeconds")
    }

    func testZeroAndNegativeChargesAreFree() {
        let limiter = SharedRateLimiter()
        limiter.setGlobalLimit(bytesPerSecond: 1)
        let took = elapsed {
            limiter.charge(bytes: 0, host: nil)
            limiter.charge(bytes: -5, host: nil)
        }
        XCTAssertLessThan(took, 0.05)
    }
}

final class RateLimitedProgressMeterTests: XCTestCase {
    /// curl reports cumulative bytes. Charging the cumulative value instead of
    /// the delta would bill the same bytes over and over and throttle to a
    /// crawl — the meter exists to convert one into the other.
    func testCumulativeProgressIsChargedAsDeltas() {
        let limiter = SharedRateLimiter()
        limiter.setGlobalLimit(bytesPerSecond: 1_000_000)
        let meter = RateLimitedProgressMeter(limiter: limiter, host: nil)

        let start = ProcessInfo.processInfo.systemUptime
        for total in stride(from: Int64(10000), through: 100_000, by: 10000) {
            meter.noteProgress(totalWritten: total)
        }
        let took = ProcessInfo.processInfo.systemUptime - start

        // 100 KB total at 1 MB/s is ~0.1 s. Charging cumulatively would bill
        // 550 KB and take five times as long.
        XCTAssertLessThan(took, 0.4, "progress must be charged as deltas, not cumulative totals")
    }

    func testNonAdvancingProgressChargesNothing() {
        let limiter = SharedRateLimiter()
        limiter.setGlobalLimit(bytesPerSecond: 1000)
        let meter = RateLimitedProgressMeter(limiter: limiter, host: nil)
        meter.noteProgress(totalWritten: 1000)

        let start = ProcessInfo.processInfo.systemUptime
        meter.noteProgress(totalWritten: 1000)
        meter.noteProgress(totalWritten: 1000)
        let took = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(took, 0.05, "a repeated total is zero new bytes")
    }

    /// A restarted transfer reports a counter that went backwards. The meter must
    /// rebase to the new value, so bytes re-sent after the restart are charged
    /// again rather than being invisible.
    ///
    /// The discriminator is deliberate: without the rebase, `lastReportedWritten`
    /// stays at 50_000, the second climb back to 50_000 looks like zero new bytes,
    /// and the whole re-transfer passes through unthrottled. With the rebase it is
    /// charged, so the wait is what proves the rebase happened.
    func testCounterGoingBackwardsRebasesSoResentBytesAreStillCharged() {
        let limiter = SharedRateLimiter()
        limiter.setGlobalLimit(bytesPerSecond: 100_000)
        let meter = RateLimitedProgressMeter(limiter: limiter, host: nil)
        meter.noteProgress(totalWritten: 50000)

        let start = ProcessInfo.processInfo.systemUptime
        meter.noteProgress(totalWritten: 0)
        meter.noteProgress(totalWritten: 50000)
        let took = ProcessInfo.processInfo.systemUptime - start

        XCTAssertGreaterThan(
            took, 0.3,
            "bytes re-sent after a counter restart must be charged, not skipped"
        )
    }
}
