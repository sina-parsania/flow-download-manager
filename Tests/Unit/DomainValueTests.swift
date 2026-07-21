// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import XCTest

/// A small deterministic RNG so UUIDv7 layout/ordering can be asserted without
/// system entropy (test-only).
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class ByteRangeTests: XCTestCase {
    func testRejectsNegativeAndInverted() {
        XCTAssertNil(ByteRange(lowerBound: -1, upperBoundExclusive: 10))
        XCTAssertNil(ByteRange(lowerBound: 10, upperBoundExclusive: 5))
        XCTAssertNotNil(ByteRange(lowerBound: 0, upperBoundExclusive: 0)) // empty is valid
        XCTAssertNotNil(ByteRange(lowerBound: 5, upperBoundExclusive: 10))
    }

    func testCount() {
        XCTAssertEqual(ByteRange(lowerBound: 5, upperBoundExclusive: 10)?.count, 5)
    }

    func testCommitInvariant() throws {
        let range = try XCTUnwrap(ByteRange(lowerBound: 100, upperBoundExclusive: 200))
        XCTAssertTrue(range.isValidCommit(100)) // == lowerBound
        XCTAssertTrue(range.isValidCommit(200)) // == upperBoundExclusive
        XCTAssertTrue(range.isValidCommit(150))
        XCTAssertFalse(range.isValidCommit(99))
        XCTAssertFalse(range.isValidCommit(201))
    }

    func testOverlap() throws {
        let a = try XCTUnwrap(ByteRange(lowerBound: 0, upperBoundExclusive: 100))
        let b = try XCTUnwrap(ByteRange(lowerBound: 100, upperBoundExclusive: 200)) // adjacent
        let c = try XCTUnwrap(ByteRange(lowerBound: 50, upperBoundExclusive: 150)) // overlaps both
        XCTAssertFalse(a.overlaps(b))
        XCTAssertTrue(a.overlaps(c))
        XCTAssertTrue(b.overlaps(c))
    }

    func testByteCountRejectsNegative() {
        XCTAssertNil(ByteCount(-1))
        XCTAssertEqual(ByteCount(0)?.value, 0)
        XCTAssertEqual(ByteCount.zero.value, 0)
    }
}

final class UUIDv7Tests: XCTestCase {
    func testVersionAndVariantBits() {
        var rng = SplitMix64(seed: 42)
        let uuid = UUIDv7.make(millisecondsSinceEpoch: 0x0123_4567_89AB, using: &rng)
        let bytes = uuid.uuid
        XCTAssertEqual(bytes.6 & 0xF0, 0x70, "version nibble must be 7")
        XCTAssertEqual(bytes.8 & 0xC0, 0x80, "variant bits must be 0b10")
    }

    func testTimestampIsBigEndianPrefix() {
        var rng = SplitMix64(seed: 1)
        let millis: UInt64 = 0x0000_0102_0304_0506 & 0xFFFF_FFFF_FFFF // 48-bit
        let uuid = UUIDv7.make(millisecondsSinceEpoch: millis, using: &rng)
        let b = uuid.uuid
        XCTAssertEqual([b.0, b.1, b.2, b.3, b.4, b.5], [0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
    }

    func testMonotonicByTimestamp() {
        var rng = SplitMix64(seed: 7)
        let earlier = UUIDv7.make(millisecondsSinceEpoch: 1000, using: &rng)
        let later = UUIDv7.make(millisecondsSinceEpoch: 2000, using: &rng)
        // Time-ordered: earlier sorts before later by UUID string.
        XCTAssertLessThan(earlier.uuidString, later.uuidString)
    }

    func testTypedIDsAreDistinctTypesButShareGeneration() {
        let job = JobID.generate()
        let resource = ResourceID.generate()
        XCTAssertNotEqual(job.rawValue, resource.rawValue)
    }
}

final class TerminalReasonTests: XCTestCase {
    func testUserCancelledMapsToCancelled() {
        XCTAssertEqual(TerminalReason.userCancelled.impliedState, .cancelled)
    }

    func testAllOtherReasonsMapToFailed() {
        for reason in TerminalReason.allCases where reason != .userCancelled {
            XCTAssertEqual(reason.impliedState, .failed, "\(reason) should imply failed")
        }
    }

    func testReasonCountMatchesContract() {
        // 22 stable reason codes are defined in the contract (§5).
        XCTAssertEqual(TerminalReason.allCases.count, 22)
    }
}
