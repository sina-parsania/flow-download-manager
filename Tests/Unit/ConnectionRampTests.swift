// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import TransferCore

/// The ramp is pure arithmetic over (bytes, time), so it can be driven through
/// exact scenarios rather than raced against a real download.
final class ConnectionRampTests: XCTestCase {
    /// Feeds a constant rate for `seconds` and returns the concurrency the ramp
    /// asks for at the end.
    @discardableResult
    private func drive(
        _ ramp: inout ConnectionRamp,
        bytesPerSecond: Double,
        seconds: Double,
        from clock: inout Double,
        bytes: inout Int64
    ) -> Int {
        var result = ramp.current
        let tick = 1.0
        for _ in 0 ..< Int(seconds / tick) {
            clock += tick
            bytes += Int64(bytesPerSecond * tick)
            result = ramp.record(totalBytes: bytes, at: clock)
        }
        return result
    }

    /// A host that keeps rewarding connections gets ramped to the ceiling.
    func testKeepsClimbingWhileThroughputImproves() {
        var ramp = ConnectionRamp(start: 8, ceiling: 24, step: 4, dwellSeconds: 10)
        var clock = 0.0
        var bytes: Int64 = 0

        // Each level genuinely faster than the last.
        drive(&ramp, bytesPerSecond: 7_000_000, seconds: 11, from: &clock, bytes: &bytes)
        XCTAssertEqual(ramp.current, 12, "first measured level is the baseline; take a step")
        drive(&ramp, bytesPerSecond: 9_000_000, seconds: 11, from: &clock, bytes: &bytes)
        XCTAssertEqual(ramp.current, 16)
        drive(&ramp, bytesPerSecond: 12_000_000, seconds: 11, from: &clock, bytes: &bytes)
        XCTAssertEqual(ramp.current, 20)
    }

    /// A host that flattens — the CDN mirror's real shape — must stop, not keep
    /// opening sockets for nothing.
    func testStopsWhenAStepStopsPaying() {
        var ramp = ConnectionRamp(start: 8, ceiling: 32, step: 4, dwellSeconds: 10)
        var clock = 0.0
        var bytes: Int64 = 0

        drive(&ramp, bytesPerSecond: 7_270_000, seconds: 11, from: &clock, bytes: &bytes)
        XCTAssertEqual(ramp.current, 12)
        // 7.51 vs 7.27 is under the 10% bar — the flat CDN case.
        drive(&ramp, bytesPerSecond: 7_510_000, seconds: 11, from: &clock, bytes: &bytes)

        XCTAssertTrue(ramp.settled)
        XCTAssertEqual(ramp.current, 12, "must hold, not climb further")
    }

    /// Never step back down: a level that measures worse still stops the ramp
    /// rather than starting an oscillation on a noisy sample.
    func testARegressionStopsTheRampWithoutReducing() {
        var ramp = ConnectionRamp(start: 8, ceiling: 32, step: 4, dwellSeconds: 10)
        var clock = 0.0
        var bytes: Int64 = 0

        drive(&ramp, bytesPerSecond: 9_000_000, seconds: 11, from: &clock, bytes: &bytes)
        XCTAssertEqual(ramp.current, 12)
        drive(&ramp, bytesPerSecond: 4_000_000, seconds: 11, from: &clock, bytes: &bytes)

        XCTAssertTrue(ramp.settled)
        XCTAssertEqual(ramp.current, 12)
    }

    /// Once settled it stays settled, however good a later sample looks — that
    /// is what stops a noisy link from restarting the climb repeatedly.
    func testSettledIsPermanentForTheTransfer() {
        var ramp = ConnectionRamp(start: 8, ceiling: 32, step: 4, dwellSeconds: 10)
        var clock = 0.0
        var bytes: Int64 = 0

        drive(&ramp, bytesPerSecond: 9_000_000, seconds: 11, from: &clock, bytes: &bytes)
        drive(&ramp, bytesPerSecond: 1_000_000, seconds: 11, from: &clock, bytes: &bytes)
        XCTAssertTrue(ramp.settled)
        let held = ramp.current

        drive(&ramp, bytesPerSecond: 50_000_000, seconds: 30, from: &clock, bytes: &bytes)
        XCTAssertEqual(ramp.current, held)
    }

    /// Samples shorter than the dwell are not acted on at all — this is the
    /// noise guard, and it is the whole reason the controller is trustworthy.
    func testShortSamplesAreIgnored() {
        var ramp = ConnectionRamp(start: 8, ceiling: 32, step: 4, dwellSeconds: 10)
        var clock = 0.0
        var bytes: Int64 = 0

        drive(&ramp, bytesPerSecond: 50_000_000, seconds: 9, from: &clock, bytes: &bytes)
        XCTAssertEqual(ramp.current, 8, "9 s is under the dwell; no decision yet")
        XCTAssertFalse(ramp.settled)
    }

    func testNeverExceedsTheSocketCeiling() {
        var ramp = ConnectionRamp(start: 8, ceiling: 10, step: 4, dwellSeconds: 10)
        var clock = 0.0
        var bytes: Int64 = 0

        for _ in 0 ..< 6 {
            drive(&ramp, bytesPerSecond: 50_000_000, seconds: 11, from: &clock, bytes: &bytes)
        }
        XCTAssertEqual(ramp.current, 10)
    }

    /// Starting at the ceiling means there is nothing to learn — settle at once
    /// so no dwell is spent pretending otherwise.
    func testStartingAtTheCeilingSettlesImmediately() {
        let ramp = ConnectionRamp(start: 32, ceiling: 32)
        XCTAssertTrue(ramp.settled)
        XCTAssertEqual(ramp.current, 32)
    }
}
