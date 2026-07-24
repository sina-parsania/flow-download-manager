// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Process-wide change journal for Library delivery (PERF-003 / P3).
///
/// Mutations and live progress mark job IDs dirty; ``drain(since:)`` publishes a
/// coalesced batch and advances the monotonic sequence. Overflow forces a gap so
/// the client falls back to ``listJobs``.
public final class JobChangeLedger: @unchecked Sendable {
    public static let overflowThreshold = 2000

    public struct Drain: Sendable, Equatable {
        public let sequence: Int64
        public let upsertIDs: [String]
        public let removedIDs: [String]
        public let hasGap: Bool
        public let idle: Bool

        public init(
            sequence: Int64,
            upsertIDs: [String],
            removedIDs: [String],
            hasGap: Bool,
            idle: Bool
        ) {
            self.sequence = sequence
            self.upsertIDs = upsertIDs
            self.removedIDs = removedIDs
            self.hasGap = hasGap
            self.idle = idle
        }
    }

    private let lock = NSLock()
    private var publishedSequence: Int64 = 0
    private var dirtyUpserts: Set<String> = []
    private var dirtyRemovals: Set<String> = []
    private var forceGap = false

    public init() {}

    public func currentSequence() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return publishedSequence
    }

    public func noteUpsert(_ jobID: String) {
        lock.lock()
        dirtyRemovals.remove(jobID)
        dirtyUpserts.insert(jobID)
        if dirtyUpserts.count + dirtyRemovals.count > Self.overflowThreshold {
            forceGap = true
            dirtyUpserts.removeAll(keepingCapacity: true)
            dirtyRemovals.removeAll(keepingCapacity: true)
        }
        lock.unlock()
    }

    public func noteRemoval(_ jobID: String) {
        lock.lock()
        dirtyUpserts.remove(jobID)
        dirtyRemovals.insert(jobID)
        if dirtyUpserts.count + dirtyRemovals.count > Self.overflowThreshold {
            forceGap = true
            dirtyUpserts.removeAll(keepingCapacity: true)
            dirtyRemovals.removeAll(keepingCapacity: true)
        }
        lock.unlock()
    }

    /// Full-list baseline: clear pending deltas and bump the published sequence.
    @discardableResult
    public func checkpointFullSync() -> Int64 {
        lock.lock()
        dirtyUpserts.removeAll(keepingCapacity: true)
        dirtyRemovals.removeAll(keepingCapacity: true)
        forceGap = false
        publishedSequence += 1
        let sequence = publishedSequence
        lock.unlock()
        return sequence
    }

    /// Coalesce and publish dirty IDs since the client's last sequence.
    public func drain(since: Int64) -> Drain {
        lock.lock()
        defer { lock.unlock() }

        if forceGap || since < 0 || since > publishedSequence {
            forceGap = false
            dirtyUpserts.removeAll(keepingCapacity: true)
            dirtyRemovals.removeAll(keepingCapacity: true)
            publishedSequence += 1
            return Drain(
                sequence: publishedSequence,
                upsertIDs: [],
                removedIDs: [],
                hasGap: true,
                idle: false
            )
        }

        if dirtyUpserts.isEmpty, dirtyRemovals.isEmpty {
            return Drain(
                sequence: publishedSequence,
                upsertIDs: [],
                removedIDs: [],
                hasGap: false,
                idle: true
            )
        }

        let upsertIDs = dirtyUpserts.sorted()
        let removedIDs = dirtyRemovals.sorted()
        dirtyUpserts.removeAll(keepingCapacity: true)
        dirtyRemovals.removeAll(keepingCapacity: true)
        publishedSequence += 1
        return Drain(
            sequence: publishedSequence,
            upsertIDs: upsertIDs,
            removedIDs: removedIDs,
            hasGap: false,
            idle: false
        )
    }
}
