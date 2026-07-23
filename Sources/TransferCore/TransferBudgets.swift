// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Central connection and rate budgets (FR-TRN-010/011, FR-QUE-001 foundation).
public actor TransferBudgetLedger {
    public struct Snapshot: Sendable, Equatable {
        public var activeJobs: Int
        public var openSockets: Int
        public var socketsByHost: [String: Int]
    }

    private let maxActiveJobs: Int
    private let maxTotalSockets: Int
    private let maxSocketsPerHost: Int

    private var activeJobs = 0
    private var openSockets = 0
    private var socketsByHost: [String: Int] = [:]

    public init(maxActiveJobs: Int = 5, maxTotalSockets: Int = 96, maxSocketsPerHost: Int = 32) {
        self.maxActiveJobs = maxActiveJobs
        self.maxTotalSockets = maxTotalSockets
        self.maxSocketsPerHost = maxSocketsPerHost
    }

    public func snapshot() -> Snapshot {
        Snapshot(activeJobs: activeJobs, openSockets: openSockets, socketsByHost: socketsByHost)
    }

    public func maxActiveJobsLimit() -> Int {
        maxActiveJobs
    }

    public func availableJobSlots() -> Int {
        max(0, maxActiveJobs - activeJobs)
    }

    public func tryBeginJob() -> Bool {
        guard activeJobs < maxActiveJobs else { return false }
        activeJobs += 1
        return true
    }

    public func endJob() {
        if activeJobs > 0 { activeJobs -= 1 }
    }

    public func tryAcquireSocket(host: String) -> Bool {
        let hostCount = socketsByHost[host, default: 0]
        guard openSockets < maxTotalSockets, hostCount < maxSocketsPerHost else { return false }
        openSockets += 1
        socketsByHost[host] = hostCount + 1
        return true
    }

    /// Reserve up to `requested` additional sockets for one job's segments.
    /// Returns the granted count (possibly 0) within total and per-host caps.
    public func reserveSockets(host: String, upTo requested: Int) -> Int {
        guard requested > 0 else { return 0 }
        let hostCount = socketsByHost[host, default: 0]
        let grant = min(requested, maxTotalSockets - openSockets, maxSocketsPerHost - hostCount)
        guard grant > 0 else { return 0 }
        openSockets += grant
        socketsByHost[host] = hostCount + grant
        return grant
    }

    public func releaseSockets(host: String, count: Int) {
        guard count > 0 else { return }
        openSockets = max(0, openSockets - count)
        let hostCount = socketsByHost[host, default: 0]
        let next = hostCount - count
        socketsByHost[host] = next > 0 ? next : nil
    }

    public func releaseSocket(host: String) {
        if openSockets > 0 { openSockets -= 1 }
        let hostCount = socketsByHost[host, default: 0]
        if hostCount <= 1 {
            socketsByHost[host] = nil
        } else {
            socketsByHost[host] = hostCount - 1
        }
    }
}

/// Monotonic-clock token bucket for bandwidth limits (FR-TRN-011).
public actor BandwidthGovernor {
    private let bytesPerSecond: Int64
    private var tokens: Double
    private var lastRefill: ContinuousClock.Instant

    public init(bytesPerSecond: Int64) {
        self.bytesPerSecond = max(0, bytesPerSecond)
        tokens = Double(max(0, bytesPerSecond))
        lastRefill = ContinuousClock.now
    }

    public func consume(bytes: Int64) async {
        guard bytesPerSecond > 0, bytes > 0 else { return }
        refill()
        let needed = Double(bytes)
        while tokens < needed {
            let deficit = needed - tokens
            let seconds = deficit / Double(bytesPerSecond)
            let ns = UInt64(min(max(seconds * 1_000_000_000, 1), 250_000_000))
            try? await Task.sleep(nanoseconds: ns)
            refill()
        }
        tokens -= needed
    }

    private func refill() {
        let now = ContinuousClock.now
        let elapsed = now - lastRefill
        lastRefill = now
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        tokens = min(Double(bytesPerSecond), tokens + seconds * Double(bytesPerSecond))
    }
}

/// Synchronous token bucket for the libcurl write/progress path (FR-TRN-011).
/// Downloads run on background threads; use `Thread.sleep` rather than async.
public final class SyncBandwidthGovernor: @unchecked Sendable {
    private let lock = NSLock()
    private let bytesPerSecond: Int64
    private var tokens: Double
    private var lastRefill: TimeInterval
    private var lastReportedWritten: Int64 = 0

    public init(bytesPerSecond: Int64) {
        self.bytesPerSecond = max(0, bytesPerSecond)
        tokens = Double(max(0, bytesPerSecond))
        lastRefill = ProcessInfo.processInfo.systemUptime
    }

    /// Consume an absolute byte delta (e.g. from a write callback chunk).
    public func consume(bytes: Int64) {
        guard bytesPerSecond > 0, bytes > 0 else { return }
        lock.lock()
        refillLocked()
        let needed = Double(bytes)
        if tokens >= needed {
            tokens -= needed
            lock.unlock()
            return
        }
        let deficit = needed - tokens
        tokens = 0
        let sleepSeconds = deficit / Double(bytesPerSecond)
        lastRefill = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        if sleepSeconds > 0 {
            Thread.sleep(forTimeInterval: min(sleepSeconds, 30))
        }
    }

    /// Progress callbacks report cumulative bytes; convert to deltas then consume.
    public func noteProgress(totalWritten: Int64) {
        guard bytesPerSecond > 0 else { return }
        lock.lock()
        guard totalWritten > lastReportedWritten else {
            lock.unlock()
            return
        }
        let delta = totalWritten - lastReportedWritten
        lastReportedWritten = totalWritten
        lock.unlock()
        consume(bytes: delta)
    }

    private func refillLocked() {
        let now = ProcessInfo.processInfo.systemUptime
        let seconds = max(0, now - lastRefill)
        lastRefill = now
        tokens = min(Double(bytesPerSecond), tokens + seconds * Double(bytesPerSecond))
    }
}
