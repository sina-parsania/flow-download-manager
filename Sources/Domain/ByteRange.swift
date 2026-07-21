// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A non-negative byte count. Byte counts and offsets are signed 64-bit with
/// non-negative validation (`04-domain-and-data-contracts.md` §1); this wrapper
/// makes an invalid (negative) count unrepresentable.
public struct ByteCount: Hashable, Sendable, Comparable, Codable {
    public let value: Int64

    public init?(_ value: Int64) {
        guard value >= 0 else { return nil }
        self.value = value
    }

    /// Non-failable zero.
    public static let zero = ByteCount(exactlyNonNegative: 0)

    /// Internal constructor for values proven non-negative at the call site.
    init(exactlyNonNegative value: Int64) {
        precondition(value >= 0, "ByteCount must be non-negative")
        self.value = value
    }

    public static func < (lhs: ByteCount, rhs: ByteCount) -> Bool {
        lhs.value < rhs.value
    }
}

/// A half-open byte interval `[lowerBound, upperBoundExclusive)` with the segment
/// invariant `lowerBound <= committedExclusive <= upperBoundExclusive`
/// (`04-domain-and-data-contracts.md` §4). Construction validates the invariant so
/// an inconsistent range is unrepresentable.
public struct ByteRange: Hashable, Sendable, Codable {
    public let lowerBound: Int64
    public let upperBoundExclusive: Int64

    public init?(lowerBound: Int64, upperBoundExclusive: Int64) {
        guard lowerBound >= 0, upperBoundExclusive >= lowerBound else { return nil }
        self.lowerBound = lowerBound
        self.upperBoundExclusive = upperBoundExclusive
    }

    /// Number of bytes in the interval.
    public var count: Int64 {
        upperBoundExclusive - lowerBound
    }

    /// Whether `committedExclusive` is a valid commit position for this range:
    /// `lowerBound <= committedExclusive <= upperBoundExclusive`.
    public func isValidCommit(_ committedExclusive: Int64) -> Bool {
        committedExclusive >= lowerBound && committedExclusive <= upperBoundExclusive
    }

    /// Whether two ranges overlap on any byte. Used to enforce that segments of one
    /// attempt do not overlap committed ranges.
    public func overlaps(_ other: ByteRange) -> Bool {
        lowerBound < other.upperBoundExclusive && other.lowerBound < upperBoundExclusive
    }
}
