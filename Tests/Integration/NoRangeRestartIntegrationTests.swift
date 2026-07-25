// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TestFaultService
import TransferCore
import XCTest

/// Safe restart of legacy contiguous partials on servers that ignore ranges.
final class NoRangeRestartIntegrationTests: XCTestCase {
    private func makePartial() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-no-range-\(UUID().uuidString).partial")
    }

    func testNoRangePartialRestartsAndCompletes() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let partial = makePartial()
        defer { try? FileManager.default.removeItem(at: partial) }

        let url = "http://127.0.0.1:\(port)/fixtures/no-range"
        let prefix = FaultHTTPServer.fixtureBody.prefix(2048)
        try Data(prefix).write(to: partial)

        let outcome = try TransferCore.resumeOrDownload(url: url, partialURL: partial)
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.fixtureBody.count))
        XCTAssertEqual(try Data(contentsOf: partial), FaultHTTPServer.fixtureBody)
    }

    func testNoRangePartialRestartsViaSegmentedTransfer() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let partial = makePartial()
        defer { try? FileManager.default.removeItem(at: partial) }

        let url = "http://127.0.0.1:\(port)/fixtures/no-range"
        try Data(FaultHTTPServer.fixtureBody.prefix(1024)).write(to: partial)

        let outcome = try SegmentedTransfer.downloadHTTP(url: url, partialURL: partial)
        XCTAssertEqual(outcome.segmentCount, 1)
        XCTAssertEqual(try Data(contentsOf: partial), FaultHTTPServer.fixtureBody)
    }

    func testCancellationDuringReplacementPreservesOriginal() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let partial = makePartial()
        defer { try? FileManager.default.removeItem(at: partial) }

        let url = "http://127.0.0.1:\(port)/fixtures/no-range-large"
        let prefix = FaultHTTPServer.largeBody.prefix(1024 * 1024)
        try Data(prefix).write(to: partial)
        let original = try Data(contentsOf: partial)

        let flag = TransferAbortFlag()
        flag.requestAbort()

        XCTAssertThrowsError(
            try TransferCore.resumeOrDownload(url: url, partialURL: partial, abortFlag: flag)
        ) { error in
            XCTAssertEqual(error as? TransferCore.TransferError, .aborted)
        }

        XCTAssertEqual(try Data(contentsOf: partial), original)
        let siblings = try FileManager.default.contentsOfDirectory(
            at: partial.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(siblings.contains { $0.lastPathComponent.contains(".repl-") })
    }

    func testTruncatedReplacementPreservesOriginal() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let partial = makePartial()
        defer { try? FileManager.default.removeItem(at: partial) }

        let url = "http://127.0.0.1:\(port)/fixtures/no-range-truncate"
        let prefix = FaultHTTPServer.fixtureBody.prefix(512)
        try Data(prefix).write(to: partial)
        let original = try Data(contentsOf: partial)

        XCTAssertThrowsError(
            try TransferCore.resumeOrDownload(url: url, partialURL: partial)
        )

        XCTAssertEqual(try Data(contentsOf: partial), original)
    }

    func testAmbiguousPreallocatedShellRemainsUntouched() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let partial = makePartial()
        defer { try? FileManager.default.removeItem(at: partial) }

        let total = Int64(FaultHTTPServer.largeBody.count)
        try Data(repeating: 0xA5, count: Int(total)).write(to: partial)
        let before = try Data(contentsOf: partial)

        XCTAssertThrowsError(
            try SegmentedTransfer.downloadHTTP(
                url: "http://127.0.0.1:\(port)/fixtures/large",
                partialURL: partial
            )
        ) { error in
            guard case TransferCore.TransferError.incompleteWrite = error else {
                XCTFail("expected incompleteWrite, got \(error)")
                return
            }
        }

        XCTAssertEqual(try Data(contentsOf: partial), before)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: SegmentedTransfer.segmentMapURL(for: partial).path)
        )
    }

    func testRangeCapablePartialStillResumesFromOffset() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let partial = makePartial()
        defer { try? FileManager.default.removeItem(at: partial) }

        let url = "http://127.0.0.1:\(port)/fixtures/large"
        try Data(FaultHTTPServer.largeBody.prefix(256 * 1024)).write(to: partial)

        let outcome = try TransferCore.resumeOrDownload(url: url, partialURL: partial)
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.largeBody.count))
        XCTAssertEqual(try Data(contentsOf: partial), FaultHTTPServer.largeBody)
    }
}
