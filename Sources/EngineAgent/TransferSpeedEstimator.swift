// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Time-based download speed estimator with light EMA smoothing.
/// Progress callbacks report cumulative bytes; this converts deltas over wall
/// time into bytes/second (unlike treating each chunk size as a rate).
public struct TransferSpeedEstimator: Sendable, Equatable {
    public private(set) var speedBytesPerSecond: Int64
    private var lastBytes: Int64?
    private var lastSampleAt: ContinuousClock.Instant?
    private let minSampleSeconds: Double
    private let priorWeight: Double

    public init(
        speedBytesPerSecond: Int64 = 0,
        minSampleSeconds: Double = 0.45,
        priorWeight: Double = 0.78
    ) {
        self.speedBytesPerSecond = max(0, speedBytesPerSecond)
        self.minSampleSeconds = max(0.05, minSampleSeconds)
        self.priorWeight = min(0.95, max(0, priorWeight))
    }

    /// Record a cumulative byte total. Returns the updated bytes/second estimate.
    @discardableResult
    public mutating func record(bytes: Int64, at now: ContinuousClock.Instant = .now) -> Int64 {
        guard let lastBytes, let lastSampleAt else {
            self.lastBytes = bytes
            self.lastSampleAt = now
            return speedBytesPerSecond
        }

        let elapsed = now - lastSampleAt
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        guard seconds >= minSampleSeconds else {
            return speedBytesPerSecond
        }

        let delta = bytes - lastBytes
        self.lastBytes = bytes
        self.lastSampleAt = now

        guard delta >= 0, seconds > 0 else {
            return speedBytesPerSecond
        }

        let instant = Double(delta) / seconds
        let prior = Double(speedBytesPerSecond)
        let smoothed = prior > 0
            ? (prior * priorWeight + instant * (1 - priorWeight))
            : instant
        speedBytesPerSecond = Int64(max(0, smoothed.rounded()))
        return speedBytesPerSecond
    }

    public mutating func reset() {
        speedBytesPerSecond = 0
        lastBytes = nil
        lastSampleAt = nil
    }
}
