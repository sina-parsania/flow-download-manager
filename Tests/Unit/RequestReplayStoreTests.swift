// SPDX-License-Identifier: GPL-3.0-or-later

import EngineAgent
import Foundation
import XCTest

/// Minimal reference-type payload standing in for an XPC response DTO.
private final class StubResponse: NSObject {
    let tag: String
    init(_ tag: String) {
        self.tag = tag
    }
}

/// A second, unrelated payload type used to prove that a stored value is only
/// ever replayed as the type it was stored with.
private final class OtherResponse: NSObject {
    let tag: String
    init(_ tag: String) {
        self.tag = tag
    }
}

/// Mutable, test-controlled clock so age-based eviction is deterministic.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date = Date()) {
        current = date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

final class RequestReplayStoreTests: XCTestCase {
    // MARK: replay hit

    func testStoredResponseReplaysOnLookup() {
        let store = RequestReplayStore()
        let id = UUID().uuidString
        let response = StubResponse("first")

        store.store(id, response, bytes: 64, isMutation: false)
        let replayed: StubResponse? = store.lookup(id)

        XCTAssertTrue(replayed === response)
    }

    func testLookupMissForUnknownRequestID() {
        let store = RequestReplayStore()
        let replayed: StubResponse? = store.lookup(UUID().uuidString)
        XCTAssertNil(replayed)
    }

    func testLookupMissWhenTypeDoesNotMatchStoredValue() {
        let store = RequestReplayStore()
        let id = UUID().uuidString
        store.store(id, StubResponse("mismatched"), bytes: 16, isMutation: false)

        let replayed: OtherResponse? = store.lookup(id)
        XCTAssertNil(replayed)
    }

    // MARK: eviction by count

    func testEvictionByCountDropsOldestFirst() {
        let store = RequestReplayStore(maxCount: 3, maxAge: 0, maxBytes: .max)
        let ids = (0 ..< 3).map { _ in UUID().uuidString }
        for id in ids {
            store.store(id, StubResponse(id), bytes: 8, isMutation: false)
        }

        // Pushes the store over its count budget; the least-recently-used
        // entry (ids[0]) must be evicted first.
        let newest = UUID().uuidString
        store.store(newest, StubResponse(newest), bytes: 8, isMutation: false)

        let evicted: StubResponse? = store.lookup(ids[0])
        XCTAssertNil(evicted)
        let survivors: [StubResponse?] = [ids[1], ids[2], newest].map { store.lookup($0) }
        XCTAssertTrue(survivors.allSatisfy { $0 != nil })
    }

    func testLookupRefreshesLRUOrderAndProtectsFromEviction() {
        let store = RequestReplayStore(maxCount: 2, maxAge: 0, maxBytes: .max)
        let first = UUID().uuidString
        let second = UUID().uuidString
        store.store(first, StubResponse(first), bytes: 8, isMutation: false)
        store.store(second, StubResponse(second), bytes: 8, isMutation: false)

        // Touch `first` so it becomes the most-recently-used entry.
        _ = store.lookup(first) as StubResponse?

        let third = UUID().uuidString
        store.store(third, StubResponse(third), bytes: 8, isMutation: false)

        // `second` was least-recently-used at the time of the third insert.
        let secondStillCached: StubResponse? = store.lookup(second)
        XCTAssertNil(secondStillCached)
        let firstStillCached: StubResponse? = store.lookup(first)
        XCTAssertNotNil(firstStillCached)
    }

    // MARK: eviction by bytes

    func testEvictionByByteBudgetDropsOldestFirst() {
        let store = RequestReplayStore(maxCount: 1000, maxAge: 0, maxBytes: 100)
        let first = UUID().uuidString
        let second = UUID().uuidString
        store.store(first, StubResponse(first), bytes: 60, isMutation: false)
        store.store(second, StubResponse(second), bytes: 60, isMutation: false)

        let evicted: StubResponse? = store.lookup(first)
        XCTAssertNil(evicted, "total bytes (120) exceeded the 100 byte budget, oldest must be evicted")
        let survivor: StubResponse? = store.lookup(second)
        XCTAssertNotNil(survivor)
    }

    // MARK: age eviction

    func testAgeEvictionDropsExpiredEntries() {
        let clock = MutableClock()
        let store = RequestReplayStore(maxCount: 1000, maxAge: 60, maxBytes: .max, now: clock.now)
        let id = UUID().uuidString
        store.store(id, StubResponse(id), bytes: 8, isMutation: false)

        XCTAssertNotNil(store.lookup(id) as StubResponse?)

        clock.advance(by: 61)

        let expired: StubResponse? = store.lookup(id)
        XCTAssertNil(expired)
    }

    // MARK: mutation fail-closed after response eviction

    func testMutationReceiptSurvivesResponseEviction() {
        let store = RequestReplayStore(maxCount: 1, maxAge: 0, maxBytes: .max)
        let id = UUID().uuidString
        store.store(id, StubResponse(id), bytes: 8, isMutation: true)

        // Force the entry out of the bounded response cache.
        let other = UUID().uuidString
        store.store(other, StubResponse(other), bytes: 8, isMutation: false)

        XCTAssertNil(store.lookup(id) as StubResponse?, "response entry must have been evicted")
        XCTAssertTrue(
            store.wasExecutedMutation(id),
            "mutation receipt must outlive the evicted response so the mutation is not re-run"
        )
    }

    func testNonMutationMissDoesNotReportAsExecutedMutation() {
        let store = RequestReplayStore()
        let id = UUID().uuidString
        store.store(id, StubResponse(id), bytes: 8, isMutation: false)
        XCTAssertFalse(store.wasExecutedMutation(id))
    }

    func testUnknownRequestIDIsNotAnExecutedMutation() {
        let store = RequestReplayStore()
        XCTAssertFalse(store.wasExecutedMutation(UUID().uuidString))
    }

    func testMutationReceiptRingIsBounded() {
        let store = RequestReplayStore(maxCount: 10000, maxAge: 0, maxBytes: .max, maxMutationReceipts: 4)
        let ids = (0 ..< 6).map { _ in UUID().uuidString }
        for id in ids {
            store.store(id, StubResponse(id), bytes: 8, isMutation: true)
        }

        // Only the most recent `maxMutationReceipts` (4) receipts survive.
        XCTAssertFalse(store.wasExecutedMutation(ids[0]))
        XCTAssertFalse(store.wasExecutedMutation(ids[1]))
        for id in ids[2...] {
            XCTAssertTrue(store.wasExecutedMutation(id))
        }
    }
}
