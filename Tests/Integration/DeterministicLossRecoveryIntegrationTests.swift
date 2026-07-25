// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TestFaultService
import TransferCore
import XCTest

/// Correctness gate for deterministic mid-stream connection loss on the throughput
/// fixture. Exploratory `loss=` curves live in the performance lane.
final class DeterministicLossRecoveryIntegrationTests: XCTestCase {
    private func body(size: Int) -> Data {
        Data((0 ..< size).map { UInt8($0 % 251) })
    }

    private func runDeterministicLossRecovery(
        server: FaultHTTPServer,
        port: UInt16,
        size: Int,
        dropFirst: Int
    ) throws -> (attempts: Int, dropped: Int) {
        server.reset()
        let partial = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-det-loss-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: partial) }

        let url = "http://127.0.0.1:\(port)/fixtures/throughput?size=\(size)&kbps=4096&dropFirst=\(dropFirst)"
        let outcome = try SegmentedTransfer.downloadHTTP(
            url: url,
            partialURL: partial,
            hostMaxSegments: 8
        )

        XCTAssertEqual(outcome.bytesWritten, Int64(size))
        XCTAssertEqual(try Data(contentsOf: partial), body(size: size))

        let attempts = server.throughputConnectionAttemptCount()
        let dropped = server.throughputConnectionsDroppedCount()
        XCTAssertGreaterThanOrEqual(dropped, dropFirst, "fixture did not drop scheduled connections")
        XCTAssertGreaterThan(attempts, dropFirst, "retries did not open replacement connections")
        return (attempts, dropped)
    }

    func testDeterministicLossRecoveryCompletesWithExactCounters() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let size = 1 * 1024 * 1024
        let dropFirst = 3
        var referenceAttempts: Int?
        var referenceDropped: Int?

        for run in 0 ..< 5 {
            let counters = try runDeterministicLossRecovery(
                server: server,
                port: port,
                size: size,
                dropFirst: dropFirst
            )
            if let referenceAttempts, let referenceDropped {
                XCTAssertEqual(counters.attempts, referenceAttempts, "attempt drift on repeat run \(run)")
                XCTAssertEqual(counters.dropped, referenceDropped, "drop drift on repeat run \(run)")
            } else {
                referenceAttempts = counters.attempts
                referenceDropped = counters.dropped
            }
        }
    }
}
