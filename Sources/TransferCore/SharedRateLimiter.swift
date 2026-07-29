// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Process-wide byte-rate limiter shared by every concurrent transfer.
///
/// This exists because a per-transfer token bucket cannot enforce a global or a
/// per-host ceiling. `SyncBandwidthGovernor` was constructed once per job, so
/// with five concurrent downloads each one was allowed the full configured rate
/// and real throughput reached five times the number the user typed. The per-host
/// limit had the same defect.
///
/// **Deadline reservation, not a token bucket.** Each charge advances a shared
/// "next free instant" by `bytes / rate` and sleeps until the instant it was
/// handed. Because the reservation is taken while the lock is held and the sleep
/// happens after it is released, N concurrent callers serialise into a queue
/// whose drain rate is exactly `rate`. A shared token bucket would not do this:
/// each waiter would independently observe a refilled bucket and take its own
/// full allowance, which is the bug being fixed.
///
/// **Sleeps take the maximum of the deadlines, never the sum.** A byte is charged
/// against the global limiter and the host limiter in one call, and the caller
/// waits for whichever finishes later. Charging them as two separate sleeping
/// calls would add the durations, so a user who asked for 10 MB/s would silently
/// get less — with nothing anywhere reporting an error.
public final class SharedRateLimiter: @unchecked Sendable {
    private let lock = NSLock()

    /// `0` means unlimited. Mutable because the orchestrator re-reads the policy
    /// as calendar windows open and close.
    private var globalBytesPerSecond: Int64 = 0
    private var hostBytesPerSecond: [String: Int64] = [:]

    /// Monotonic instants (`ProcessInfo.systemUptime`) at which each queue next
    /// has capacity. `systemUptime` is used rather than `Date` for the same
    /// reason the rest of this file does: it does not jump when the wall clock
    /// is corrected.
    private var globalNextFree: TimeInterval = 0
    private var hostNextFree: [String: TimeInterval] = [:]

    /// Longest single sleep. A charge is never allowed to park a curl thread
    /// indefinitely — the abort flag has to stay observable, and a very large
    /// chunk against a very small rate would otherwise compute minutes.
    private static let maxSleepSeconds: TimeInterval = 30

    /// How far ahead of "now" a queue is allowed to be reserved. Without this a
    /// burst of charges against an idle limiter pushes the deadline arbitrarily
    /// far into the future and later arrivals inherit a debt they did not create.
    private static let maxReservationAheadSeconds: TimeInterval = 5

    public init() {}

    public func setGlobalLimit(bytesPerSecond: Int64) {
        lock.lock()
        defer { lock.unlock() }
        globalBytesPerSecond = max(0, bytesPerSecond)
        if globalBytesPerSecond == 0 { globalNextFree = 0 }
    }

    public func setHostLimit(host: String, bytesPerSecond: Int64) {
        let key = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        let rate = max(0, bytesPerSecond)
        if rate == 0 {
            hostBytesPerSecond[key] = nil
            hostNextFree[key] = nil
        } else {
            hostBytesPerSecond[key] = rate
        }
    }

    /// Drop a host's accounting once no transfer references it, so a long-running
    /// agent does not accumulate one entry per host ever downloaded from.
    public func forgetHost(_ host: String) {
        let key = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        hostBytesPerSecond[key] = nil
        hostNextFree[key] = nil
    }

    /// Whether any limit at all applies to `host`. Callers use this to skip the
    /// charge entirely on the unlimited path.
    public func isLimited(host: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if globalBytesPerSecond > 0 { return true }
        guard let host else { return false }
        return (hostBytesPerSecond[host.lowercased()] ?? 0) > 0
    }

    /// Charge `bytes` against the global and per-host queues and block until both
    /// reservations are satisfied.
    ///
    /// Runs on curl's write/progress thread, so it sleeps rather than suspending.
    /// The lock is never held across the sleep.
    public func charge(bytes: Int64, host: String?) {
        guard bytes > 0 else { return }
        let key = host?.lowercased()

        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        var deadline: TimeInterval = 0

        if globalBytesPerSecond > 0 {
            deadline = max(
                deadline,
                reserveLocked(
                    nextFree: &globalNextFree,
                    rate: globalBytesPerSecond,
                    bytes: bytes,
                    now: now
                )
            )
        }
        if let key, let rate = hostBytesPerSecond[key], rate > 0 {
            var next = hostNextFree[key] ?? 0
            // max, not +=: the two queues are charged in parallel and the caller
            // waits for the later one. Summing would over-throttle silently.
            deadline = max(
                deadline,
                reserveLocked(nextFree: &next, rate: rate, bytes: bytes, now: now)
            )
            hostNextFree[key] = next
        }
        lock.unlock()

        let wait = deadline - now
        guard wait > 0 else { return }
        Thread.sleep(forTimeInterval: min(wait, Self.maxSleepSeconds))
    }

    /// Advances one queue's cursor by the time `bytes` costs at `rate` and
    /// returns the instant the caller may proceed. Must be called with the lock
    /// held; it mutates the cursor in place.
    private func reserveLocked(
        nextFree: inout TimeInterval,
        rate: Int64,
        bytes: Int64,
        now: TimeInterval
    ) -> TimeInterval {
        // An idle queue starts from now rather than from a stale cursor,
        // otherwise the first charge after a pause is billed for the gap.
        let start = max(nextFree, now)
        // Clamp how far ahead the queue may run so a burst cannot mortgage the
        // future; the excess is simply not charged rather than deferred forever.
        let ceiling = now + Self.maxReservationAheadSeconds
        let cost = Double(bytes) / Double(rate)
        let granted = min(start, ceiling)
        nextFree = min(granted + cost, ceiling + cost)
        return granted
    }
}

/// Converts curl's cumulative progress counter into deltas for a
/// ``SharedRateLimiter``.
///
/// Progress callbacks report bytes-so-far, not bytes-since-last-call, and there
/// is one of these per transfer while the limiter behind it is shared. Keeping
/// the running total here rather than in the limiter is what lets many transfers
/// share one set of rate queues.
public final class RateLimitedProgressMeter: @unchecked Sendable {
    private let limiter: SharedRateLimiter
    private let host: String?
    private let lock = NSLock()
    private var lastReportedWritten: Int64 = 0

    public init(limiter: SharedRateLimiter, host: String?) {
        self.limiter = limiter
        self.host = host
    }

    public func noteProgress(totalWritten: Int64) {
        lock.lock()
        // Progress is monotonic per transfer; a lower value means a restarted
        // counter, so rebase rather than charging a negative delta.
        guard totalWritten > lastReportedWritten else {
            if totalWritten < lastReportedWritten { lastReportedWritten = totalWritten }
            lock.unlock()
            return
        }
        let delta = totalWritten - lastReportedWritten
        lastReportedWritten = totalWritten
        lock.unlock()
        limiter.charge(bytes: delta, host: host)
    }
}
