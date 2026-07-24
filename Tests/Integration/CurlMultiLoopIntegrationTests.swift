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
            onProgress: { written, _ in
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

    /// FR-TRN-009 S1 (work-stealing / connection saturation): with 4 ranges and
    /// `maxConcurrent: 2`, only 2 easies are ever live at once, but the pending
    /// queue refills a freed slot immediately so all 4 ranges still complete,
    /// byte-correct, and outcomes come back in original range order.
    func testFourRangeDownloadsViaMultiWithMaxConcurrentTwo() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-multi-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let total = Int64(FaultHTTPServer.fixtureBody.count)
        let partial = root.appendingPathComponent("multi-cap.partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let fd = partial.path.withCString { path in
            open(path, O_RDWR)
        }
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { close(fd) } }
        XCTAssertEqual(ftruncate(fd, off_t(total)), 0)

        // Deliberately uneven range sizes so outcome order can be verified
        // against input order even though all ranges hit the same fixture.
        let sizes: [Int64] = [300, 700, 1000, total - 300 - 700 - 1000]
        var ranges: [CurlMultiLoop.RangeRequest] = []
        var offset: Int64 = 0
        for size in sizes {
            ranges.append(
                CurlMultiLoop.RangeRequest(
                    rangeHeader: "\(offset)-\(offset + size - 1)",
                    fileOffset: offset,
                    expectedBytes: size
                )
            )
            offset += size
        }

        let url = "http://127.0.0.1:\(port)/fixtures/ok"
        let outcomes = try TransferCore.downloadRangesViaMulti(
            url: url,
            partialURL: partial,
            ranges: ranges,
            maxConcurrent: 2
        )

        XCTAssertEqual(outcomes.count, 4)
        for (index, outcome) in outcomes.enumerated() {
            XCTAssertEqual(outcome.httpStatus, 206)
            XCTAssertEqual(outcome.bytesWritten, sizes[index], "outcome \(index) out of order or short")
        }

        let data = try Data(contentsOf: partial)
        XCTAssertEqual(data, FaultHTTPServer.fixtureBody)
    }

    /// A range failure surfaces as that range's own error, and must NOT stop the
    /// rest of the work.
    ///
    /// The contract here deliberately changed. Stopping the pending queue on the
    /// first error is right for a clean link — fail fast, don't pile on — and
    /// wrong for a bad one, where the common case is a single range dropping
    /// while the others are healthy. Draining the queue on every blip turned one
    /// hiccup into a stalled pass, so on a link that drops regularly the download
    /// made almost no net progress. Refilling now continues; the error is still
    /// reported once everything settles.
    func testFailedRangeStillSurfacesWhileOtherRangesKeepRunning() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-multi-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let total = Int64(FaultHTTPServer.fixtureBody.count)
        let partial = root.appendingPathComponent("multi-fail.partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let fd = partial.path.withCString { path in
            open(path, O_RDWR)
        }
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { close(fd) } }
        XCTAssertEqual(ftruncate(fd, off_t(total)), 0)

        let third = total / 3
        // Range 0 declares one byte fewer than the server will send, so it fails
        // its expected-bytes check. Ranges 1 and 2 are correct and must still be
        // served — a sibling failing is not a reason to abandon them.
        let ranges = [
            CurlMultiLoop.RangeRequest(
                rangeHeader: "0-\(third - 1)", fileOffset: 0, expectedBytes: third - 1
            ),
            CurlMultiLoop.RangeRequest(
                rangeHeader: "\(third)-\(2 * third - 1)", fileOffset: third, expectedBytes: third
            ),
            CurlMultiLoop.RangeRequest(
                rangeHeader: "\(2 * third)-\(total - 1)",
                fileOffset: 2 * third,
                expectedBytes: total - 2 * third
            )
        ]

        let url = "http://127.0.0.1:\(port)/fixtures/ok"
        XCTAssertThrowsError(
            try TransferCore.downloadRangesViaMulti(
                url: url,
                partialURL: partial,
                ranges: ranges,
                maxConcurrent: 1
            )
        ) { error in
            // The range's own failure, not a blanket abort of the loop.
            guard case TransferCore.TransferError.incompleteWrite = error else {
                return XCTFail("expected incompleteWrite, got \(error)")
            }
        }

        // The healthy ranges were still served despite range 0 failing: their
        // bytes are on disk. This is the property that keeps a flaky link making
        // forward progress instead of restarting the same pass forever.
        let data = try Data(contentsOf: partial)
        XCTAssertEqual(data.count, Int(total))
        let healthy = data.suffix(from: Int(third))
        XCTAssertFalse(
            healthy.allSatisfy { $0 == 0 },
            "healthy ranges were abandoned because a sibling failed"
        )
        XCTAssertEqual(
            Array(healthy), Array(FaultHTTPServer.fixtureBody.suffix(from: Int(third))),
            "healthy ranges wrote the wrong bytes"
        )
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
        // 4 KiB always tiles to one range; the 2 MiB fixture exercises the real
        // multi path with more than one connection.
        let url = "http://127.0.0.1:\(port)/fixtures/large"
        let outcome = try SegmentedTransfer.downloadHTTP(
            url: url,
            partialURL: partial
        )
        XCTAssertEqual(outcome.segmentCount, 2)
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.largeBody.count))
        let data = try Data(contentsOf: partial)
        XCTAssertEqual(data, FaultHTTPServer.largeBody)
    }

    /// When two easies race the same byte range, the first to finish asks the
    /// other to stop. The loser reports `stoppedByRequest` with a short read —
    /// never an error — and the file stays byte-exact. Without this cancel the
    /// loser would download the whole chunk twice.
    func testHedgeLoserStopsAfterWinnerCompletes() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-hedge-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Cap one connection so the race is visible: the fast peer wins, the
        // slow one is still mid-chunk when RequestStop fires.
        let size = 512 * 1024
        let url = "http://127.0.0.1:\(port)/fixtures/throughput?size=\(size)&kbps=800&slowFirst=1&slowKbps=40"
        let expected = Int64(size)
        let partial = root.appendingPathComponent("hedge.partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let fd = partial.path.withCString { path in open(path, O_RDWR) }
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { close(fd) } }
        XCTAssertEqual(ftruncate(fd, off_t(expected)), 0)

        let range = CurlMultiLoop.RangeRequest(
            rangeHeader: "0-\(expected - 1)",
            fileOffset: 0,
            expectedBytes: expected
        )
        let outcomes = try TransferCore.downloadRangesViaMulti(
            url: url,
            partialURL: partial,
            ranges: [range, range],
            maxConcurrent: 2,
            replicaGroupByRangeIndex: [0, 0]
        )

        XCTAssertEqual(outcomes.count, 2)
        let winners = outcomes.filter { !$0.stoppedByRequest }
        let losers = outcomes.filter(\.stoppedByRequest)
        XCTAssertEqual(winners.count, 1, "exactly one full winner")
        XCTAssertEqual(losers.count, 1, "exactly one stopped replica")
        XCTAssertEqual(winners[0].bytesWritten, expected)
        XCTAssertLessThan(
            losers[0].bytesWritten,
            expected,
            "loser transferred a full chunk — RequestStop never fired"
        )

        // Deterministic body from FaultHTTPServer.throughputBodies formula.
        let expectedBody = Data((0 ..< size).map { UInt8($0 % 251) })
        let data = try Data(contentsOf: partial)
        XCTAssertEqual(data, expectedBody)
    }
}
