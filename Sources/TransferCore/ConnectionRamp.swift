// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How many connections a live transfer should be running right now.
///
/// Written by the orchestrator (which owns the ramp, because raising the number
/// means reserving another socket from a budget only it can see) and read by the
/// multi loop's drive thread. Different threads, hence the lock — same shape as
/// `LiveByteCounter`.
///
/// The value is only ever raised after the sockets behind it have actually been
/// granted, so the transport can treat it as permission, not a wish.
public final class ConcurrencyTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    public init(_ value: Int) {
        self.value = max(1, value)
    }

    public func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Never lowers: a live connection cannot be taken back without abandoning
    /// the tile it is mid-way through.
    public func raise(to newValue: Int) {
        lock.lock()
        value = max(value, newValue)
        lock.unlock()
    }
}

/// Decides how many connections a live transfer should be running.
///
/// The right number is a property of the **host**, not a constant. Measured on
/// two hosts with the same client and the same file sizes:
///
/// | connections | CDN mirror | the reported host |
/// | --- | --- | --- |
/// | 4 | 5.03 MB/s | 7.00 MB/s |
/// | 8 | 7.27 MB/s | 7.55 MB/s |
/// | 16 | 7.51 MB/s | 8.23 MB/s |
/// | 24 | — | 9.33 MB/s |
/// | 32 | — | 8.03 MB/s, erratic |
///
/// One flattens at 8, the other keeps climbing to 24 and then gets *worse* at
/// 32. A fixed default cannot be right for both, which is the whole reason this
/// exists.
///
/// **Climbs, then stops. Never oscillates.** A controller that also steps back
/// down would chase noise: repeated runs at one setting varied by ±1.5 MB/s on
/// the same host, and an A/B during development was swamped by 3x swings in link
/// conditions. So the only feedback acted on is "did the last step up help", and
/// once the answer is no the ramp is done for this transfer. The worst case is
/// sitting at a level a fixed configuration would have used anyway.
public struct ConnectionRamp {
    /// Concurrency the transfer should be running right now.
    public private(set) var current: Int
    /// Hard bound from the orchestrator's socket reservation.
    public let ceiling: Int
    private let step: Int
    /// How long a level must run before its throughput is trusted. Shorter than
    /// this and the sample is mostly noise.
    private let dwell: Double
    /// Fractional gain required to justify another step up.
    private let minimumGain: Double

    private var levelStartedAt: Double?
    private var levelStartBytes: Int64 = 0
    private var bestThroughput: Double = 0
    /// Set once a step fails to pay: the ramp stops for the rest of the transfer.
    public private(set) var settled = false

    public init(
        start: Int,
        ceiling: Int,
        step: Int = 4,
        dwellSeconds: Double = 10,
        minimumGain: Double = 0.10
    ) {
        self.ceiling = max(1, ceiling)
        current = min(max(1, start), self.ceiling)
        self.step = max(1, step)
        dwell = max(1, dwellSeconds)
        self.minimumGain = max(0, minimumGain)
        if current >= self.ceiling { settled = true }
    }

    /// Feed cumulative bytes and a monotonic timestamp; returns the concurrency
    /// to run from now on.
    ///
    /// `bytes` must be cumulative for the whole transfer — the ramp differences
    /// it itself, so a caller that resets its counter would fabricate a stall.
    public mutating func record(totalBytes: Int64, at now: Double) -> Int {
        guard !settled else { return current }

        guard let started = levelStartedAt else {
            levelStartedAt = now
            levelStartBytes = totalBytes
            return current
        }

        let elapsed = now - started
        guard elapsed >= dwell else { return current }

        let throughput = Double(totalBytes - levelStartBytes) / elapsed
        defer {
            levelStartedAt = now
            levelStartBytes = totalBytes
        }

        // First measured level is the baseline: nothing to compare it against
        // yet, so take the step and judge the *next* one.
        guard bestThroughput > 0 else {
            bestThroughput = throughput
            current = min(current + step, ceiling)
            if current >= ceiling { settled = true }
            return current
        }

        guard throughput >= bestThroughput * (1 + minimumGain) else {
            // The last step up did not pay. Stop here rather than stepping back:
            // the level is already known to be workable, and reducing on a noisy
            // sample is how a controller starts oscillating.
            settled = true
            return current
        }

        bestThroughput = throughput
        current = min(current + step, ceiling)
        if current >= ceiling { settled = true }
        return current
    }
}
