// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Jittered exponential backoff with Retry-After support (FR-TRN-012).
public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var baseDelayNanoseconds: UInt64
    public var maxDelayNanoseconds: UInt64

    public init(
        maxAttempts: Int = 8,
        baseDelayNanoseconds: UInt64 = 500_000_000,
        maxDelayNanoseconds: UInt64 = 60_000_000_000
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelayNanoseconds = baseDelayNanoseconds
        self.maxDelayNanoseconds = maxDelayNanoseconds
    }

    public func shouldRetry(attempt: Int, httpStatus: Int?) -> Bool {
        guard attempt < maxAttempts else { return false }
        guard let httpStatus else { return true }
        switch httpStatus {
        case 408, 425, 429, 500, 502, 503, 504:
            return true
        default:
            return false
        }
    }

    public func delayNanoseconds(attempt: Int, retryAfterSeconds: Double?) -> UInt64 {
        if let retryAfterSeconds, retryAfterSeconds > 0 {
            let ns = UInt64(min(retryAfterSeconds, 3600) * 1_000_000_000)
            return min(ns, maxDelayNanoseconds)
        }
        let shift = min(attempt, 16)
        let exp = baseDelayNanoseconds &<< UInt64(shift)
        let capped = min(exp == 0 ? maxDelayNanoseconds : exp, maxDelayNanoseconds)
        let jitter = UInt64.random(in: 0 ... max(capped / 5, 1))
        return min(capped + jitter, maxDelayNanoseconds)
    }
}
