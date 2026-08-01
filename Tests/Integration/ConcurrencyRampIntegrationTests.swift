// SPDX-License-Identifier: GPL-3.0-or-later

import TestFaultService
import TransferCore
import TransferCurlBridge
import XCTest

/// The transport now takes a live concurrency target instead of a fixed count.
/// That is a change to the loop that moves bytes, so what matters is not that the
/// ramp is clever but that **nothing the controller says can break correctness**.
final class ConcurrencyRampIntegrationTests: XCTestCase {
    private func ranges(count: Int, total: Int) -> [CurlMultiLoop.RangeRequest] {
        let span = total / count
        return (0 ..< count).map { index in
            let start = index * span
            let end = index == count - 1 ? total - 1 : start + span - 1
            return CurlMultiLoop.RangeRequest(
                rangeHeader: "\(start)-\(end)",
                fileOffset: Int64(start),
                expectedBytes: Int64(end - start + 1)
            )
        }
    }

    private func run(
        port: UInt16,
        label: String,
        maxConcurrent: Int,
        desired: (@Sendable () -> Int)?
    ) throws -> Data {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-ramp-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appendingPathComponent("out.partial")

        let body = FaultHTTPServer.largeBody
        _ = try TransferCore.downloadRangesViaMulti(
            url: "http://127.0.0.1:\(port)/fixtures/large",
            partialURL: partial,
            ranges: ranges(count: 16, total: body.count),
            maxConcurrent: maxConcurrent,
            desiredConcurrency: desired
        )
        return try Data(contentsOf: partial)
    }

    /// A controller pinned to one connection must still produce the whole file —
    /// the refill path has to drain every pending tile, not just the ones opened
    /// at the start.
    func testPinnedToOneConnectionStillCompletes() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let data = try run(port: port, label: "one", maxConcurrent: 8, desired: { 1 })
        XCTAssertEqual(data, FaultHTTPServer.largeBody)
    }

    /// A controller asking for far more than the reservation must be clamped to
    /// it. `maxConcurrent` is the orchestrator's socket grant and is not
    /// negotiable — exceeding it is how a job starves its siblings.
    func testControllerCannotExceedTheReservation() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let data = try run(port: port, label: "greedy", maxConcurrent: 4, desired: { 999 })
        XCTAssertEqual(data, FaultHTTPServer.largeBody)
    }

    /// Nonsense from the controller must not wedge the loop or drop tiles.
    func testNonPositiveTargetIsTreatedAsOne() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let data = try run(port: port, label: "zero", maxConcurrent: 8, desired: { 0 })
        XCTAssertEqual(data, FaultHTTPServer.largeBody)
    }

    /// A target that grows mid-transfer — the actual ramp shape — still produces
    /// exactly the right bytes.
    func testGrowingTargetProducesTheSameBytes() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let calls = Counter()
        let data = try run(port: port, label: "growing", maxConcurrent: 8, desired: {
            min(1 + calls.next() / 2, 8)
        })
        XCTAssertEqual(data, FaultHTTPServer.largeBody)
    }

    /// Omitting the controller must behave exactly as before it existed.
    func testNoControllerMatchesLegacyBehaviour() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let data = try run(port: port, label: "legacy", maxConcurrent: 8, desired: nil)
        XCTAssertEqual(data, FaultHTTPServer.largeBody)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer {
            value += 1
            lock.unlock()
        }
        return value
    }
}
