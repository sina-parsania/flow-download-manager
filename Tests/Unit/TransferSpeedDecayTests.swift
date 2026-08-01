// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import EngineAgent

/// A stalled transfer must read as stalled.
///
/// The estimator is only ever fed when new bytes arrive, so a connection that
/// goes quiet leaves the last computed speed on screen indefinitely. On a lossy
/// link that is tens of seconds of "5 MB/s" while nothing moves —
/// `CURLOPT_LOW_SPEED_TIME` alone lets a dead connection sit for 10 s before
/// libcurl kills it, and the map loop then backs off up to 30 s.
///
/// These pin the decay behaviour any fix depends on: fed the *same* cumulative
/// byte count as time passes, the estimate has to fall toward zero.
final class TransferSpeedDecayTests: XCTestCase {
    func testRepeatedIdenticalTotalsDecayTheEstimateTowardZero() {
        var estimator = TransferSpeedEstimator()
        let start = ContinuousClock.now

        // Establish a real rate first: 1 MB over 1 s.
        _ = estimator.record(bytes: 0, at: start)
        let moving = estimator.record(bytes: 1_000_000, at: start.advanced(by: .seconds(1)))
        XCTAssertGreaterThan(moving, 0, "a moving transfer must report a rate")

        // Now the transfer stalls: same cumulative total, time keeps passing.
        var speed = moving
        for tick in 2 ... 25 {
            speed = estimator.record(
                bytes: 1_000_000,
                at: start.advanced(by: .seconds(tick))
            )
        }

        XCTAssertLessThan(
            speed, moving / 100,
            "a stalled transfer still reported \(speed) B/s after 24 s of no progress"
        )
    }

    /// The decay must not be so eager that ordinary jitter between progress
    /// ticks reads as a stall — one quiet sample should barely move it.
    func testASingleQuietSampleDoesNotCollapseTheEstimate() {
        var estimator = TransferSpeedEstimator()
        let start = ContinuousClock.now
        _ = estimator.record(bytes: 0, at: start)
        let moving = estimator.record(bytes: 1_000_000, at: start.advanced(by: .seconds(1)))

        let afterOneQuietTick = estimator.record(
            bytes: 1_000_000,
            at: start.advanced(by: .milliseconds(1500))
        )

        XCTAssertGreaterThan(
            afterOneQuietTick, moving / 2,
            "one quiet tick should not halve the reported speed"
        )
    }
}
