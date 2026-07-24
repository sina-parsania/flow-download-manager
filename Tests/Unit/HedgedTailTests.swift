// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import TransferCore
@testable import TransferCurlBridge

/// Tail hedging policy.
///
/// Fine tiling bounds what a slow connection costs, but it cannot take work back
/// once assigned — at the tail the job waits on whichever connection is slowest
/// while other slots sit idle. Hedging spends those idle slots racing the same
/// byte range. The cost is duplicate bytes, so the policy has to be strict about
/// when it fires.
final class HedgedTailTests: XCTestCase {
    private func work(entry: Int, bytes: Int64) -> SegmentLedger.Work {
        SegmentLedger.Work(
            entryIndex: entry,
            baseWritten: 0,
            request: CurlMultiLoop.RangeRequest(
                rangeHeader: "0-\(bytes - 1)",
                fileOffset: 0,
                expectedBytes: bytes
            )
        )
    }

    private let big: Int64 = 4 * 1024 * 1024

    /// Slots idle and chunks worth racing — the case hedging exists for.
    func testHedgesLargestChunksWhenSlotsAreIdle() {
        let remaining = [work(entry: 0, bytes: big), work(entry: 1, bytes: big * 2)]
        let hedged = SegmentedTransfer.hedged(remaining, connectionLimit: 8)

        XCTAssertEqual(hedged.count, 4, "two idle slots should carry two replicas")
        // Largest first: entry 1 is twice the size, so it is raced before entry 0.
        XCTAssertEqual(hedged[2].entryIndex, 1)
        XCTAssertEqual(hedged[3].entryIndex, 0)
        // Replicas must target the same entry and the same bytes as the original.
        XCTAssertEqual(hedged[2].request, remaining[1].request)
    }

    /// No idle slot means every connection is already carrying real work.
    /// Duplicating here would displace it.
    func testNoHedgeWhenAllSlotsAreBusy() {
        let remaining = (0 ..< 8).map { work(entry: $0, bytes: big) }
        XCTAssertEqual(SegmentedTransfer.hedged(remaining, connectionLimit: 8), remaining)
        XCTAssertEqual(SegmentedTransfer.hedged(remaining, connectionLimit: 4), remaining)
    }

    /// Racing the only remaining chunk still leaves the job waiting on it — the
    /// replica cannot finish sooner than the original started.
    func testNoHedgeForASingleRemainingChunk() {
        let remaining = [work(entry: 0, bytes: big)]
        XCTAssertEqual(SegmentedTransfer.hedged(remaining, connectionLimit: 8), remaining)
    }

    /// A tiny chunk finishes before a second connection can even be established,
    /// so racing it is pure waste.
    func testSkipsChunksTooSmallToBeWorthAConnection() {
        let remaining = [work(entry: 0, bytes: 64 * 1024), work(entry: 1, bytes: 128 * 1024)]
        XCTAssertEqual(SegmentedTransfer.hedged(remaining, connectionLimit: 8), remaining)
    }

    /// Without a cancel the loser downloads its chunk in full, so the waste has
    /// to be bounded no matter how many slots are free.
    func testHedgeCountIsCapped() {
        let remaining = (0 ..< 6).map { work(entry: $0, bytes: big) }
        let hedged = SegmentedTransfer.hedged(remaining, connectionLimit: 64)
        XCTAssertEqual(hedged.count - remaining.count, 2, "hedges exceeded the cap")
    }

    /// Originals must always survive intact and in order — hedging adds work, it
    /// never replaces or reorders it.
    func testOriginalWorkIsPreservedInOrder() {
        let remaining = (0 ..< 3).map { work(entry: $0, bytes: big) }
        let hedged = SegmentedTransfer.hedged(remaining, connectionLimit: 8)
        XCTAssertEqual(Array(hedged.prefix(3)), remaining)
        XCTAssertEqual(Set(hedged.map(\.entryIndex)), Set(remaining.map(\.entryIndex)))
    }

    /// CurlMultiLoop stops losers by replica *group id*, which SegmentedTransfer
    /// sets to `entryIndex`. Replicas of the same entry must share that id —
    /// inferring from byte ranges would silently mis-group distinct entries that
    /// happen to have the same size.
    func testReplicaGroupIdsAreEntryIndices() {
        let remaining = [work(entry: 7, bytes: big), work(entry: 3, bytes: big)]
        let hedged = SegmentedTransfer.hedged(remaining, connectionLimit: 8)
        let groups = hedged.map(\.entryIndex)
        XCTAssertEqual(groups.prefix(2), [7, 3])
        // Appended hedges target the largest entry first (3 is same size as 7,
        // but sort is stable on equal size — both ≥ min; order among equals is
        // sort-dependent). Every group id must already appear as an original.
        XCTAssertEqual(Set(groups), Set([7, 3]))
        XCTAssertGreaterThan(groups.count, 2)
    }

    /// A replica reports progress for the same ledger entry as its original. The
    /// ledger keeps a monotonic maximum per entry, so double reporting must not
    /// inflate the total — that is what makes duplicate work safe.
    func testDuplicateReportingCannotInflateProgress() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-hedge-\(UUID().uuidString).segmap")
        defer { try? FileManager.default.removeItem(at: url) }

        let ledger = SegmentLedger(
            total: big,
            baseOffset: 0,
            entries: [SegmentLedger.Entry(start: 0, end: big - 1, written: 0)],
            sidecarURL: url
        )

        // Two racers reporting the same range, interleaved and out of order.
        _ = ledger.record(entry: 0, written: 1000)
        _ = ledger.record(entry: 0, written: 2500)
        _ = ledger.record(entry: 0, written: 1800)
        let done = ledger.record(entry: 0, written: 2500)

        XCTAssertEqual(done, 2500, "duplicate reports summed instead of taking the max")
        XCTAssertEqual(ledger.downloadedBytes(), 2500)
    }
}
