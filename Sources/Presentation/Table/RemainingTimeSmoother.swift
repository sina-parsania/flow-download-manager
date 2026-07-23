// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Smooths remaining-time so the UI does not thrash when speed spikes
/// (20m → 3m). Pattern used by desktop download managers:
/// 1. countdown by wall clock between samples
/// 2. ease slowly toward the new remaining/speed estimate
/// 3. clamp per-update jump so one bad sample cannot rewrite the display
public struct RemainingTimeSmoother: Sendable, Equatable {
    private var displayedSeconds: Double?

    public init(displayedSeconds: Double? = nil) {
        self.displayedSeconds = displayedSeconds
    }

    public mutating func reset() {
        displayedSeconds = nil
    }

    /// - Parameters:
    ///   - remainingBytes: bytes still to download
    ///   - speedBytesPerSecond: already-smoothed speed
    ///   - elapsedSeconds: wall time since the previous UI refresh for this job
    @discardableResult
    public mutating func update(
        remainingBytes: Int64,
        speedBytesPerSecond: Int64,
        elapsedSeconds: Double
    ) -> Int? {
        guard speedBytesPerSecond > 0, remainingBytes > 0 else {
            displayedSeconds = nil
            return nil
        }

        let instant = Double(remainingBytes) / Double(speedBytesPerSecond)
        let elapsed = max(0, elapsedSeconds)

        guard var current = displayedSeconds else {
            displayedSeconds = instant
            return Self.display(instant)
        }

        // Natural countdown while we wait for the next speed sample.
        if elapsed > 0 {
            current = max(1, current - elapsed)
        }

        // Ease toward the fresh estimate (~20%/s of the gap).
        let alpha = min(0.55, 0.20 * max(elapsed, 0.35))
        var blended = current * (1 - alpha) + instant * alpha

        // Cap relative jump so a speed spike cannot collapse 20m to 3m in one tick.
        let maxJump = max(6.0, current * 0.15)
        let delta = blended - current
        if abs(delta) > maxJump {
            blended = current + (delta >= 0 ? maxJump : -maxJump)
        }

        displayedSeconds = blended
        return Self.display(blended)
    }

    private static func display(_ seconds: Double) -> Int {
        max(1, min(Int(seconds.rounded()), 99 * 3600))
    }
}
