// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import TransferCore

/// Ledger tiling arithmetic.
///
/// Tile size is what bounds a straggler: a slow connection holds exactly one
/// chunk, so the tail costs `chunkSize / slowRate` no matter how many
/// connections are running. The throughput benchmark proves the *mechanism* on a
/// small payload; these assert the *arithmetic* holds at sizes a test suite
/// cannot download. A cap regression only shows up on multi-GB files, where
/// nobody is watching.
final class SegmentTilingTests: XCTestCase {
    private let minChunk: Int64 = 4 * 1024 * 1024
    private let gib: Int64 = 1024 * 1024 * 1024

    private func chunkSize(total: Int64, connections: Int) -> Int64 {
        let count = SegmentedTransfer.chunkCount(from: 0, total: total, connectionCount: connections)
        XCTAssertGreaterThan(count, 0)
        return total / Int64(count)
    }

    /// Out to 4 GiB every chunk should still be at the ~4 MiB floor. Under the
    /// old 128 cap a 4 GiB file tiled into 32 MiB chunks — eight times the
    /// straggler cost.
    func testChunksStayAtTheFloorUpToFourGiB() {
        for total in [512 * 1024 * 1024, Int(gib), Int(2 * gib), Int(4 * gib)] {
            let size = chunkSize(total: Int64(total), connections: 8)
            XCTAssertLessThanOrEqual(
                size, minChunk,
                "\(total / (1024 * 1024)) MiB tiled into \(size / (1024 * 1024)) MiB chunks — straggler cost is \(size / minChunk)x the floor"
            )
        }
    }

    /// Beyond the cap chunks necessarily grow, but they must stay far below the
    /// quarter-gigabyte tiles the old cap produced at this size.
    func testVeryLargeFilesDegradeGracefully() {
        let size = chunkSize(total: 40 * gib, connections: 8)
        XCTAssertLessThan(
            size, 64 * 1024 * 1024,
            "40 GiB tiled into \(size / (1024 * 1024)) MiB chunks — one slow connection owns all of it"
        )
    }

    /// Tiling must never hand out fewer chunks than there are connections, or
    /// connections sit idle with work outstanding.
    func testNeverFewerChunksThanConnections() {
        for connections in [1, 2, 8, 32] {
            for total in [Int64(1), minChunk, 100 * minChunk, 8 * gib] {
                let count = SegmentedTransfer.chunkCount(
                    from: 0, total: total, connectionCount: connections
                )
                XCTAssertGreaterThanOrEqual(
                    count, connections,
                    "total=\(total) connections=\(connections) produced \(count) chunks"
                )
            }
        }
    }

    /// Resume tiles the remaining span, not the whole file.
    func testTilingIsRelativeToTheResumeOffset() {
        let almostDone = SegmentedTransfer.chunkCount(
            from: 8 * gib - minChunk, total: 8 * gib, connectionCount: 4
        )
        let fromScratch = SegmentedTransfer.chunkCount(
            from: 0, total: 8 * gib, connectionCount: 4
        )
        XCTAssertLessThan(almostDone, fromScratch)
        XCTAssertGreaterThanOrEqual(almostDone, 4)
    }

    /// A fully-downloaded or zero-length span must still yield usable work
    /// rather than zero chunks.
    func testDegenerateSpansStayValid() {
        XCTAssertGreaterThanOrEqual(
            SegmentedTransfer.chunkCount(from: 100, total: 100, connectionCount: 4), 4
        )
        XCTAssertGreaterThanOrEqual(
            SegmentedTransfer.chunkCount(from: 200, total: 100, connectionCount: 1), 1
        )
    }
}
