// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Presentation

final class RemainingTimeSmootherTests: XCTestCase {
    func testFirstSampleUsesInstantEstimate() {
        var smoother = RemainingTimeSmoother()
        // 60_000_000 bytes @ 1_000_000 B/s → 60s
        let eta = smoother.update(
            remainingBytes: 60_000_000,
            speedBytesPerSecond: 1_000_000,
            elapsedSeconds: 1
        )
        XCTAssertEqual(eta, 60)
    }

    func testSpeedSpikeDoesNotCollapseETAInOneTick() {
        var smoother = RemainingTimeSmoother()
        _ = smoother.update(
            remainingBytes: 600_000_000,
            speedBytesPerSecond: 500_000,
            elapsedSeconds: 1
        )
        // Instant would be ~1200s; then speed jumps 4× → instant ~300s.
        // With clamp, one second must not jump all the way to 300.
        let afterSpike = smoother.update(
            remainingBytes: 600_000_000,
            speedBytesPerSecond: 2_000_000,
            elapsedSeconds: 1
        )
        XCTAssertNotNil(afterSpike)
        XCTAssertGreaterThan(afterSpike ?? 0, 900)
        XCTAssertLessThan(afterSpike ?? 0, 1200)
    }

    func testCountdownAdvancesWithElapsedTime() {
        var smoother = RemainingTimeSmoother(displayedSeconds: 100)
        let eta = smoother.update(
            remainingBytes: 100_000_000,
            speedBytesPerSecond: 1_000_000,
            elapsedSeconds: 5
        )
        // After 5s countdown from 100 → ~95, then slight blend toward instant 100.
        XCTAssertNotNil(eta)
        XCTAssertGreaterThanOrEqual(eta ?? 0, 90)
        XCTAssertLessThanOrEqual(eta ?? 0, 100)
    }

    func testZeroSpeedClearsEstimate() {
        var smoother = RemainingTimeSmoother(displayedSeconds: 40)
        XCTAssertNil(
            smoother.update(
                remainingBytes: 10_000_000,
                speedBytesPerSecond: 0,
                elapsedSeconds: 1
            )
        )
    }
}
