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

        var curve: [(connections: Int, seconds: Double, speedup: Double)] = []
        var baseline = 0.0
        for connections in [1, 2, 4, 8, 16] {
            server.reset()
            let seconds = try measureRangedDownload(
                url: url, connections: connections, tiles: connections
            )
            if connections == 1 { baseline = seconds }
            curve.append((connections, seconds, baseline / max(seconds, 0.001)))
        }

        let rendered = curve
            .map { "\($0.connections)c=\(String(format: "%.2f", $0.seconds))s(\(String(format: "%.1f", $0.speedup))x)" }
            .joined(separator: " ")
        print("[throughput] scaling under a per-connection cap: \(rendered)")

        // The mechanism behind every "download 5x faster" claim: when a server
        // shapes each connection, N connections get N shares. What it cannot do
        // is exceed the client's own pipe — which is why the honest form of the
        // claim is always "up to".
        let best = curve.map(\.speedup).max() ?? 0
        XCTAssertGreaterThan(
            best, 2.0,
            "parallel connections did not scale against a per-connection cap: \(rendered)"
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

    /// High-RTT / lossy link curve — the case where multi-connection actually
    /// multiplies on a real network (Mathis: ~MSS/(RTT·√p) per TCP flow).
    ///
    /// Asserts relationships only: under RTT, more connections beat fewer; under
    /// loss, the transfer still completes with byte-exact content when the
    /// SegmentedTransfer retry path can recover from mid-stream drops.
    func testConnectionScalingUnderRTTAndLoss() throws {
        let size = 1 * 1024 * 1024
        let kbps = 4096

        func url(port: UInt16, rtt: Int, loss: Double) -> String {
            "http://127.0.0.1:\(port)/fixtures/throughput?size=\(size)&kbps=\(kbps)&rtt=\(rtt)&loss=\(loss)"
        }

        func measureMulti(port: UInt16, rtt: Int, connections: Int) throws -> Double {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("dm-rtt-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let partial = root.appendingPathComponent("bench.partial")
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            let handle = try FileHandle(forWritingTo: partial)
            try handle.truncate(atOffset: UInt64(size))
            try handle.close()

            let total = Int64(size)
            let tiles = max(connections, 4)
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
                    url: url(port: port, rtt: rtt, loss: 0),
                    partialURL: partial,
                    ranges: ranges,
                    maxConcurrent: connections
                )
            }
            let written = try Data(contentsOf: partial)
            XCTAssertEqual(written.count, size)
            return Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
        }

        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        // Print RTT 0 / 100 / 300 ms curves (no loss). Assert the relationship
        // only on RTT=100 — enough latency that connection setup dominates a
        // single flow, without making the suite wall-clock heavy.
        for rtt in [0, 100, 300] {
            var curve: [(Int, Double)] = []
            for connections in [1, 2, 4, 8] {
                server.reset()
                let seconds = try measureMulti(port: port, rtt: rtt, connections: connections)
                curve.append((connections, seconds))
            }
            let rendered = curve
                .map { "\($0.0)c=\(String(format: "%.2f", $0.1))s" }
                .joined(separator: " ")
            print("[throughput] scaling under RTT=\(rtt)ms: \(rendered)")

            if rtt == 100 {
                let one = curve.first { $0.0 == 1 }?.1 ?? 0
                let eight = curve.first { $0.0 == 8 }?.1 ?? one
                XCTAssertGreaterThan(
                    one / max(eight, 0.001), 1.3,
                    "under RTT=100ms, 8 connections should beat 1: \(rendered)"
                )
            }
        }

        // Exploratory loss curves (seeded per connection index). Correctness is
        // gated by DeterministicLossRecoveryIntegrationTests and `dropFirst=`.
        for loss in [0.1, 1.0] {
            server.reset()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("dm-loss-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let partial = root.appendingPathComponent("loss.partial")
            let clock = ContinuousClock()
            let elapsed = try clock.measure {
                _ = try SegmentedTransfer.downloadHTTP(
                    url: url(port: port, rtt: 0, loss: loss),
                    partialURL: partial,
                    hostMaxSegments: 8
                )
            }
            let written = try Data(contentsOf: partial)
            XCTAssertEqual(written.count, size, "lossy transfer left wrong length at loss=\(loss)%")
            let expected = Data((0 ..< size).map { UInt8($0 % 251) })
            XCTAssertEqual(written, expected, "lossy transfer corrupted bytes at loss=\(loss)%")
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            let dropped = server.throughputConnectionsDroppedCount()
            print(
                "[throughput] loss=\(loss)% complete in \(String(format: "%.2f", seconds))s "
                    + "(dropped=\(dropped), attempts=\(server.throughputConnectionAttemptCount()))"
            )
        }

        // Deterministic correctness gate for the same fixture.
        server.reset()
        let dropFirst = 3
        let deterministicRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-loss-det-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: deterministicRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: deterministicRoot) }
        let deterministicPartial = deterministicRoot.appendingPathComponent("loss-det.partial")
        _ = try SegmentedTransfer.downloadHTTP(
            url: "http://127.0.0.1:\(port)/fixtures/throughput?size=\(size)&kbps=\(kbps)&dropFirst=\(dropFirst)",
            partialURL: deterministicPartial,
            hostMaxSegments: 8
        )
        XCTAssertGreaterThanOrEqual(server.throughputConnectionsDroppedCount(), dropFirst)
        XCTAssertGreaterThan(server.throughputConnectionAttemptCount(), dropFirst)
        XCTAssertEqual(try Data(contentsOf: deterministicPartial).count, size)
    }
}
