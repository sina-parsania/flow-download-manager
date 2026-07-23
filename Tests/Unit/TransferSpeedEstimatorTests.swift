// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import EngineAgent

final class TransferSpeedEstimatorTests: XCTestCase {
    func testFirstSampleDoesNotInventSpeed() {
        var estimator = TransferSpeedEstimator(minSampleSeconds: 0.25)
        let t0 = ContinuousClock.Instant.now
        XCTAssertEqual(estimator.record(bytes: 0, at: t0), 0)
        XCTAssertEqual(estimator.speedBytesPerSecond, 0)
    }

    func testComputesBytesPerSecondFromTimedDelta() {
        var estimator = TransferSpeedEstimator(minSampleSeconds: 0.25, priorWeight: 0)
        let t0 = ContinuousClock.Instant.now
        _ = estimator.record(bytes: 0, at: t0)
        let t1 = t0.advanced(by: .milliseconds(500))
        // 500_000 bytes in 0.5s → 1_000_000 B/s
        let speed = estimator.record(bytes: 500_000, at: t1)
        XCTAssertEqual(speed, 1_000_000)
    }

    func testIgnoresSamplesBelowMinInterval() {
        var estimator = TransferSpeedEstimator(minSampleSeconds: 0.25, priorWeight: 0)
        let t0 = ContinuousClock.Instant.now
        _ = estimator.record(bytes: 0, at: t0)
        let tTooSoon = t0.advanced(by: .milliseconds(50))
        let speed = estimator.record(bytes: 500_000, at: tTooSoon)
        XCTAssertEqual(speed, 0)
    }

    func testResetClearsSpeed() {
        var estimator = TransferSpeedEstimator(minSampleSeconds: 0.1, priorWeight: 0)
        let t0 = ContinuousClock.Instant.now
        _ = estimator.record(bytes: 0, at: t0)
        _ = estimator.record(bytes: 200_000, at: t0.advanced(by: .milliseconds(200)))
        XCTAssertGreaterThan(estimator.speedBytesPerSecond, 0)
        estimator.reset()
        XCTAssertEqual(estimator.speedBytesPerSecond, 0)
    }
}
