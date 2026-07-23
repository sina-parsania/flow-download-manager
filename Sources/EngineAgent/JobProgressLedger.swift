// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Live progress snapshot coalesced for listJobs (≤1 Hz durable UI path).
public struct JobProgressSnapshot: Sendable, Equatable {
    public var bytesTransferred: Int64
    public var totalBytes: Int64?
    public var speedBytesPerSecond: Int64

    public init(bytesTransferred: Int64, totalBytes: Int64?, speedBytesPerSecond: Int64) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.speedBytesPerSecond = speedBytesPerSecond
    }

    public var progressFraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1.0, Double(bytesTransferred) / Double(totalBytes))
    }
}

/// Thread-safe progress map readable from the XPC reply path without awaiting.
public final class JobProgressLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: JobProgressSnapshot] = [:]

    public init() {}

    public func set(_ snapshot: JobProgressSnapshot, for jobID: String) {
        lock.lock()
        values[jobID] = snapshot
        lock.unlock()
    }

    public func remove(_ jobID: String) {
        lock.lock()
        values[jobID] = nil
        lock.unlock()
    }

    public func snapshot(for jobID: String) -> JobProgressSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return values[jobID]
    }

    public func all() -> [String: JobProgressSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
