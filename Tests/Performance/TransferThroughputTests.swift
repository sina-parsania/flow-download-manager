// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TestFaultService
import TransferCore
import TransferCurlBridge
import XCTest

/// Throughput acceptance tests for the segmented transfer path (FR-TRN-009).
///
/// These are the measurements the v0.3 speed work is judged against. They do
/// not assert wall-clock numbers from a machine profile — they assert the
/// *relationships* that must hold if segmentation and the refill loop work:
///
///   1. N connections against a per-connection rate cap must beat 1 connection
///      by roughly N (scaling).
///   2. One slow connection must not dominate the total (tail behaviour). This
///      is the acceptance test for the work-refill loop: because the ledger
///      tiles finer than the connection count, a straggler only ever holds one
///      small tile instead of a full 1/N share.
///
/// The per-connection cap is what makes any of this measurable — an uncapped
/// loopback transfer finishes instantly and parallelism is invisible.
final class TransferThroughputTests: XCTestCase {
    /// Small enough to keep the suite fast, large enough that the rate cap
    /// dominates connection setup noise.
    private static let payloadBytes = 4 * 1024 * 1024
    private static let perConnectionKBps = 2048

    private func throughputURL(
        port: UInt16,
        slowFirst: Int = 0,
        slowKBps: Int = 0
    ) -> String {
        var url = "http://127.0.0.1:\(port)/fixtures/throughput"
        url += "?size=\(Self.payloadBytes)&kbps=\(Self.perConnectionKBps)"
        if slowFirst > 0 {
            url += "&slowFirst=\(slowFirst)&slowKbps=\(slowKBps)"
        }
        return url
    }

    /// Downloads the fixture with `connections` parallel ranges and returns the
    /// elapsed seconds. Ranges are tiled evenly; `maxConcurrent` bounds how many
    /// are live, matching what `SegmentedTransfer` does in production.
    private func measureRangedDownload(
        url: String,
        connections: Int,
        tiles: Int
    ) throws -> Double {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-throughput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = root.appendingPathComponent("bench.partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        try handle.truncate(atOffset: UInt64(Self.payloadBytes))
        try handle.close()

        let total = Int64(Self.payloadBytes)
        let span = total / Int64(tiles)
        var ranges: [CurlMultiLoop.RangeRequest] = []
        for index in 0 ..< tiles {
            let start = Int64(index) * span
            let end = index == tiles - 1 ? total - 1 : start + span - 1
            ranges.append(
                CurlMultiLoop.RangeRequest(
                    rangeHeader: "\(start)-\(end)",
                    fileOffset: start,
                    expectedBytes: end - start + 1
                )
            )
        }

        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            _ = try TransferCore.downloadRangesViaMulti(
                url: url,
                partialURL: partial,
                ranges: ranges,
                maxConcurrent: connections
            )
        }

        let written = try Data(contentsOf: partial)
        XCTAssertEqual(written.count, Self.payloadBytes, "short transfer")
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }

    /// Four connections against a per-connection cap must be substantially
    /// faster than one. The bar is deliberately loose (2x, not 4x) so the test
    /// measures the property, not the machine.
    func testParallelConnectionsScaleAgainstAPerConnectionCap() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }
        let url = throughputURL(port: port)

        let single = try measureRangedDownload(url: url, connections: 1, tiles: 1)
        server.reset()
        let parallel = try measureRangedDownload(url: url, connections: 4, tiles: 4)

        XCTAssertGreaterThan(
            single / max(parallel, 0.001), 2.0,
            "4 connections (\(parallel)s) should beat 1 (\(single)s) by >2x under a per-connection cap"
        )
    }

    /// The tail test, and the acceptance test for the refill loop.
    ///
    /// Both runs face the *same* straggler — one connection capped eight times
    /// slower than its peers. The only difference is tiling:
    ///
    ///   - coarse (`tiles == connections`): the straggler owns a full 1/N share
    ///     of the file and nothing can take it away. Total time degrades toward
    ///     the straggler's rate.
    ///   - fine (`tiles >> connections`): the straggler only ever holds one
    ///     small tile; every tile it does not take is refilled onto a fast
    ///     connection as soon as one frees up.
    ///
    /// Fine tiling must therefore be materially faster. Comparing the two under
    /// identical conditions is what makes this falsifiable: if the refill loop
    /// in `CurlMultiLoop` stops reusing freed slots, fine tiling collapses to
    /// coarse behaviour and this fails.
    func testFineTilingBeatsCoarseTilingWhenOneConnectionIsSlow() throws {
        let connections = 4

        func measureWithStraggler(tiles: Int) throws -> Double {
            let server = FaultHTTPServer()
            let port = try server.start()
            defer { server.stop() }
            return try measureRangedDownload(
                url: throughputURL(
                    port: port,
                    slowFirst: 1,
                    slowKBps: Self.perConnectionKBps / 8
                ),
                connections: connections,
                tiles: tiles
            )
        }

        let coarse = try measureWithStraggler(tiles: connections)
        let fine = try measureWithStraggler(tiles: connections * 8)
        let speedup = coarse / max(fine, 0.001)

        print("[throughput] straggler tail: coarse=\(coarse)s fine=\(fine)s speedup=\(speedup)x")

        XCTAssertGreaterThan(
            speedup, 1.5,
            """
            fine tiling (\(fine)s) should clearly beat coarse tiling (\(coarse)s) \
            when one connection is slow — the refill loop is not reusing freed slots
            """
        )
    }
}
