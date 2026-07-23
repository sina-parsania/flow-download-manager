// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import TestFaultService
import TransferCore
import TransferCurlBridge
import XCTest

final class CurlMultiLoopIntegrationTests: XCTestCase {
    func testTwoRangeDownloadsViaMultiMatchFixture() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-multi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let total = Int64(FaultHTTPServer.fixtureBody.count)
        let mid = total / 2
        let partial = root.appendingPathComponent("multi.partial")
        // Pre-size the file so ranged pwrite does not leave holes of unknown size.
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let fd = partial.path.withCString { path in
            open(path, O_RDWR)
        }
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { close(fd) } }
        XCTAssertEqual(ftruncate(fd, off_t(total)), 0)

        let url = "http://127.0.0.1:\(port)/fixtures/ok"
        final class ProgressSamples: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Int64] = []

            func append(_ written: Int64) {
                lock.lock()
                values.append(written)
                lock.unlock()
            }

            func snapshot() -> [Int64] {
                lock.lock()
                defer { lock.unlock() }
                return values
            }
        }
        let progressSamples = ProgressSamples()
        let outcomes = try TransferCore.downloadRangesViaMulti(
            url: url,
            partialURL: partial,
            ranges: [
                CurlMultiLoop.RangeRequest(
                    rangeHeader: "0-\(mid - 1)",
                    fileOffset: 0,
                    expectedBytes: mid
                ),
                CurlMultiLoop.RangeRequest(
                    rangeHeader: "\(mid)-\(total - 1)",
                    fileOffset: mid,
                    expectedBytes: total - mid
                )
            ],
            onProgress: { written in
                progressSamples.append(written)
            }
        )
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(outcomes[0].httpStatus, 206)
        XCTAssertEqual(outcomes[1].httpStatus, 206)
        let samples = progressSamples.snapshot()
        XCTAssertGreaterThan(samples.count, 0)
        XCTAssertEqual(samples.last, total)
        for index in 1 ..< samples.count {
            XCTAssertGreaterThanOrEqual(samples[index], samples[index - 1])
        }

        let data = try Data(contentsOf: partial)
        XCTAssertEqual(data, FaultHTTPServer.fixtureBody)
    }

    func testSegmentedTransferOptionalCurlMultiPath() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-multi-seg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = root.appendingPathComponent("seg-multi.partial")
        let url = "http://127.0.0.1:\(port)/fixtures/ok"
        let outcome = try SegmentedTransfer.downloadHTTP(
            url: url,
            partialURL: partial
        )
        XCTAssertEqual(outcome.segmentCount, 2)
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.fixtureBody.count))
        let data = try Data(contentsOf: partial)
        XCTAssertEqual(data, FaultHTTPServer.fixtureBody)
    }
}
