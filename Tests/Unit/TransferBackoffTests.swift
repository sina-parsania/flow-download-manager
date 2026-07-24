// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import TransferCore

/// Retry pacing on a link that drops.
///
/// The old rule was `Thread.sleep(Double(attempt))` — linear, unjittered, and
/// capped at 3 attempts for the whole job. Two things went wrong with it: a
/// multi-gigabyte download on a lossy link died after three blips, and 32
/// segments that dropped on the same blip all retried at the same instant,
/// recreating the burst that killed them.
final class TransferBackoffTests: XCTestCase {
    /// Deterministic probe: take the top of the window so growth is observable.
    private func window(stall: Int) -> Double {
        SegmentedTransfer.backoffSeconds(stall: stall, random: { $0.upperBound })
    }

    func testWindowGrowsExponentially() {
        XCTAssertEqual(window(stall: 1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(window(stall: 2), 1.0, accuracy: 0.0001)
        XCTAssertEqual(window(stall: 3), 2.0, accuracy: 0.0001)
        XCTAssertEqual(window(stall: 4), 4.0, accuracy: 0.0001)
    }

    /// Unbounded growth would strand a job for hours on a link that recovers.
    func testWindowIsCapped() {
        XCTAssertEqual(window(stall: 20), 30, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(window(stall: 1000), 30)
    }

    /// Full jitter: the draw covers the whole window, not just its upper half.
    /// A delay that is always ~the window is not jitter — the herd stays
    /// synchronised, which is the failure this exists to prevent.
    func testDrawSpansTheWholeWindow() {
        let samples = (0 ..< 400).map { _ in SegmentedTransfer.backoffSeconds(stall: 5) }
        let ceiling = window(stall: 5)

        XCTAssertTrue(samples.allSatisfy { $0 >= 0 && $0 <= ceiling })
        XCTAssertTrue(
            samples.contains { $0 < ceiling * 0.25 },
            "no sample landed in the bottom quarter — draw is not full jitter"
        )
        XCTAssertTrue(
            samples.contains { $0 > ceiling * 0.75 },
            "no sample landed in the top quarter — draw is not spanning the window"
        )
    }

    /// The whole point: two segments failing together must not wake together.
    func testConcurrentFailuresDoNotShareADelay() {
        let herd = (0 ..< 32).map { _ in SegmentedTransfer.backoffSeconds(stall: 4) }
        XCTAssertGreaterThan(
            Set(herd.map { Int($0 * 1000) }).count, 1,
            "a whole herd drew the same delay — retries will burst together"
        )
    }

    /// Never negative, never NaN, whatever the caller passes.
    func testDegenerateStallCountsStayValid() {
        for stall in [Int.min, -1, 0, 1, Int.max] {
            let delay = SegmentedTransfer.backoffSeconds(stall: stall)
            XCTAssertFalse(delay.isNaN, "stall=\(stall) produced NaN")
            XCTAssertGreaterThanOrEqual(delay, 0, "stall=\(stall) produced a negative delay")
            XCTAssertLessThanOrEqual(delay, 30, "stall=\(stall) exceeded the cap")
        }
    }
}
