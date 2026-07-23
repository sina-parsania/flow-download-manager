// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import XCTest

final class RetryPolicyTests: XCTestCase {
    func testRetriesTransientStatusesOnly() {
        let policy = RetryPolicy(maxAttempts: 5)
        XCTAssertTrue(policy.shouldRetry(attempt: 0, httpStatus: 503))
        XCTAssertTrue(policy.shouldRetry(attempt: 1, httpStatus: 429))
        XCTAssertFalse(policy.shouldRetry(attempt: 0, httpStatus: 404))
        XCTAssertFalse(policy.shouldRetry(attempt: 5, httpStatus: 503))
    }

    func testRetryAfterHonored() {
        let policy = RetryPolicy(maxAttempts: 5, maxDelayNanoseconds: 10_000_000_000)
        let delay = policy.delayNanoseconds(attempt: 0, retryAfterSeconds: 2)
        XCTAssertEqual(delay, 2_000_000_000)
    }
}

final class HeaderValidatorTests: XCTestCase {
    func testRejectsBannedAndCRLF() {
        XCTAssertTrue(HeaderValidator.validate(name: "User-Agent", value: "DM/1"))
        XCTAssertFalse(HeaderValidator.validate(name: "Host", value: "evil.test"))
        XCTAssertFalse(HeaderValidator.validate(name: "X-Test", value: "a\nb"))
    }
}
