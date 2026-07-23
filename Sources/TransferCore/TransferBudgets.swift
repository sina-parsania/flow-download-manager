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

    public init(maxActiveJobs: Int = 3, maxTotalSockets: Int = 32, maxSocketsPerHost: Int = 8) {
        self.maxActiveJobs = maxActiveJobs
        self.maxTotalSockets = maxTotalSockets
        self.maxSocketsPerHost = maxSocketsPerHost
    }

    public func snapshot() -> Snapshot {
        Snapshot(activeJobs: activeJobs, openSockets: openSockets, socketsByHost: socketsByHost)
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
