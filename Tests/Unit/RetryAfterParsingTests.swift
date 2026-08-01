// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import XCTest
@testable import TransferCore

/// `Retry-After` parsing.
///
/// Deliberately delta-seconds only. A wrong reading of this header is worse than
/// no reading: falling back to our own backoff costs a few seconds, while
/// misparsing an HTTP-date into a number could park a job for hours.
final class RetryAfterParsingTests: XCTestCase {
    func testPlainDeltaSecondsParses() {
        XCTAssertEqual(TransferCore.retryAfterSeconds("7"), 7)
        XCTAssertEqual(TransferCore.retryAfterSeconds("  30  "), 30)
        XCTAssertEqual(TransferCore.retryAfterSeconds("0"), 0)
    }

    func testHTTPDateFormIsIgnoredRatherThanGuessed() {
        XCTAssertNil(TransferCore.retryAfterSeconds("Wed, 21 Oct 2026 07:28:00 GMT"))
    }

    func testGarbageAndNegativesAreIgnored() {
        XCTAssertNil(TransferCore.retryAfterSeconds(nil))
        XCTAssertNil(TransferCore.retryAfterSeconds(""))
        XCTAssertNil(TransferCore.retryAfterSeconds("   "))
        XCTAssertNil(TransferCore.retryAfterSeconds("soon"))
        XCTAssertNil(TransferCore.retryAfterSeconds("-5"))
        XCTAssertNil(TransferCore.retryAfterSeconds("inf"))
        XCTAssertNil(TransferCore.retryAfterSeconds("nan"))
    }

    /// The whole point of parsing it: the delay actually used must be the
    /// server's, not our backoff curve.
    func testPolicyPrefersTheServersDelayOverItsOwnBackoff() {
        let policy = RetryPolicy()
        let honoured = policy.delayNanoseconds(attempt: 0, retryAfterSeconds: 7)
        XCTAssertEqual(honoured, 7_000_000_000)

        // And a hostile value cannot park a job indefinitely.
        let clamped = policy.delayNanoseconds(attempt: 0, retryAfterSeconds: 86400)
        XCTAssertLessThanOrEqual(clamped, RetryPolicy().maxDelayNanoseconds)
    }
}
