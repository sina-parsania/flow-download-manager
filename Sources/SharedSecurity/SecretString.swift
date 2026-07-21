// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A string value that never prints its contents. Interpolating or describing a
/// `SecretString` yields `"<redacted>"`; the real value is available only via the
/// explicit `reveal()` call site, which is auditable (`06-licensing-security-privacy.md`
/// §4). Use for passwords, tokens and cookie material held transiently in memory.
public struct SecretString: CustomStringConvertible, CustomDebugStringConvertible, Sendable, Equatable {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    /// The only path to the underlying value. Grep for `.reveal()` to audit uses.
    public func reveal() -> String {
        value
    }

    public var description: String {
        "<redacted>"
    }

    public var debugDescription: String {
        "<redacted>"
    }

    /// Equality that compares content in constant time for equal-length inputs
    /// (accumulates XOR without early exit). Length is compared up front; the only
    /// thing that reveals is the secret's length, via an in-process comparison with
    /// no network/timing oracle.
    public static func == (lhs: SecretString, rhs: SecretString) -> Bool {
        let a = Array(lhs.value.utf8)
        let b = Array(rhs.value.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }
}
