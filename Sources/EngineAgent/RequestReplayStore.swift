// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Bounded, thread-safe replay store backing XPC request idempotency.
///
/// A duplicate `requestID` on the same connection must replay the prior
/// response rather than re-executing (`EngineControlProtocol` doc comments,
/// `04-domain-and-data-contracts.md` §9). Earlier revisions kept one unbounded
/// `[String: Response]` dictionary per RPC, which could grow without bound for
/// the lifetime of a connection. This type replaces all of them with a single
/// store shared by every RPC on the exporter, enforcing one count/age/byte
/// budget in total.
///
/// Evicting a cached response must not let a mutation silently re-execute:
/// callers store mutation responses with `isMutation: true`, and the store
/// separately remembers those request IDs — in a small, bounded, ID-only set —
/// even after the response entry itself has been evicted. Callers use
/// ``wasExecutedMutation(_:)`` to fail closed instead of re-running a mutation
/// whose replay receipt has aged out.
///
/// Reads are not remembered this way: a cache miss for a read is always safe
/// to recompute.
public final class RequestReplayStore: @unchecked Sendable {
    /// Injectable clock so tests can drive age-based eviction deterministically.
    public typealias Clock = @Sendable () -> Date

    private struct Entry {
        let value: AnyObject
        let bytes: Int
        let storedAt: Date
    }

    private let maxCount: Int
    private let maxAge: TimeInterval
    private let maxBytes: Int
    private let maxMutationReceipts: Int
    private let now: Clock

    private let lock = NSLock()

    private var entries: [String: Entry] = [:]
    /// Least-recently-used order for `entries`, oldest first. Kept in sync with
    /// `entries` under `lock`.
    private var accessOrder: [String] = []
    private var totalBytes = 0

    /// Request IDs of mutations that have executed successfully, retained even
    /// after their response entry is evicted. Bounded by `maxMutationReceipts`
    /// via FIFO eviction, since this only needs to outlive plausible client
    /// retry windows, not the connection's full lifetime.
    private var mutationReceipts: Set<String> = []
    private var mutationReceiptOrder: [String] = []

    public init(
        maxCount: Int = 256,
        maxAge: TimeInterval = 15 * 60,
        maxBytes: Int = 32 * 1024 * 1024,
        maxMutationReceipts: Int = 4096,
        now: @escaping Clock = { Date() }
    ) {
        self.maxCount = maxCount
        self.maxAge = maxAge
        self.maxBytes = maxBytes
        self.maxMutationReceipts = maxMutationReceipts
        self.now = now
    }

    /// Replay a prior response for `id`, if one is cached and of the expected
    /// type. Returns `nil` on a miss (never stored, evicted, aged out, or
    /// stored under a different response type). A hit refreshes LRU order.
    public func lookup<T: AnyObject>(_ id: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        evictExpiredLocked()
        guard let entry = entries[id], let value = entry.value as? T else {
            return nil
        }
        touchLocked(id)
        return value
    }

    /// Record a completed response so a duplicate `requestID` replays it.
    /// `bytes` is a caller-computed size estimate used to enforce the byte
    /// budget. `isMutation` additionally records `id` in the fail-closed
    /// mutation-receipt set so the caller can refuse to re-execute the
    /// mutation later, even once this response entry itself is evicted.
    public func store(_ id: String, _ value: AnyObject, bytes: Int, isMutation: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let old = entries[id] {
            totalBytes -= old.bytes
        } else {
            accessOrder.append(id)
        }
        entries[id] = Entry(value: value, bytes: bytes, storedAt: now())
        totalBytes += bytes
        touchLocked(id)

        if isMutation {
            rememberMutationLocked(id)
        }

        evictExpiredLocked()
        evictToLimitsLocked()
    }

    /// Whether a mutation `requestID` has already executed on this connection,
    /// independent of whether its response entry is still cached. Callers
    /// must consult this after a `lookup` miss on a mutation RPC and fail
    /// closed (never re-run the mutation) when it returns `true`.
    public func wasExecutedMutation(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return mutationReceipts.contains(id)
    }

    // MARK: - Locked helpers (caller must hold `lock`)

    private func touchLocked(_ id: String) {
        if let index = accessOrder.firstIndex(of: id) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(id)
    }

    private func rememberMutationLocked(_ id: String) {
        guard !mutationReceipts.contains(id) else { return }
        mutationReceipts.insert(id)
        mutationReceiptOrder.append(id)
        while mutationReceiptOrder.count > maxMutationReceipts {
            let oldest = mutationReceiptOrder.removeFirst()
            mutationReceipts.remove(oldest)
        }
    }

    private func evictExpiredLocked() {
        guard maxAge > 0, !entries.isEmpty else { return }
        let cutoff = now().addingTimeInterval(-maxAge)
        let expired = entries.filter { $0.value.storedAt < cutoff }.map(\.key)
        for id in expired {
            removeEntryLocked(id)
        }
    }

    private func evictToLimitsLocked() {
        while entries.count > maxCount || totalBytes > maxBytes, let oldest = accessOrder.first {
            removeEntryLocked(oldest)
        }
    }

    private func removeEntryLocked(_ id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        totalBytes -= entry.bytes
        if let index = accessOrder.firstIndex(of: id) {
            accessOrder.remove(at: index)
        }
    }
}
