// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TestFaultService
import TransferCurlBridge
import XCTest
@testable import TransferCore

final class RangeResponseValidationIntegrationTests: XCTestCase {
    private let rangeByteCount = 256
    private let fileOffset: Int64 = 1024

    func testRangedProbeRejectsHTTP200WithZeroBytes() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let url = "http://127.0.0.1:\(port)/fixtures/range-ignored-200"
        XCTAssertThrowsError(try TransferCore.observeRangeProbe(url: url)) { error in
            XCTAssertEqual(
                error as? TransferCore.TransferError,
                .invalidRangeResponse(httpStatus: 200)
            )
        }
    }

    func testValid206RangeProbeWritesOneByte() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let probe = try TransferCore.observeRangeProbe(url: "http://127.0.0.1:\(port)/fixtures/ok")
        XCTAssertEqual(probe.identity.httpStatus, 206)
        XCTAssertNotNil(probe.identity.contentRange)
        XCTAssertEqual(probe.bytesWritten, 1)
    }

    func testInvalidRangedResponsesCommitZeroBytes() throws {
        let adversarialPaths = [
            "/fixtures/range-ignored-200",
            "/fixtures/range-shifted",
            "/fixtures/range-malformed-cr",
            "/fixtures/range-wrong-total",
            "/fixtures/range-error-body"
        ]

        for path in adversarialPaths {
            let server = FaultHTTPServer()
            let port = try server.start()
            defer { server.stop() }

            let partial = FileManager.default.temporaryDirectory
                .appendingPathComponent("dm-range-invalid-\(UUID().uuidString).partial")
            FileManager.default.createFile(atPath: partial.path, contents: Data(repeating: 0xAB, count: 2048))
            defer { try? FileManager.default.removeItem(at: partial) }

            let before = try Data(contentsOf: partial)
            let url = "http://127.0.0.1:\(port)\(path)"

            XCTAssertThrowsError(
                try TransferCore.downloadSingleStream(
                    url: url,
                    partialURL: partial,
                    rangeHeader: "0-\(rangeByteCount - 1)",
                    fileOffset: fileOffset
                )
            )
            XCTAssertEqual(
                try Data(contentsOf: partial),
                before,
                "invalid ranged response must not mutate partial for \(path)"
            )
        }
    }

    func testCurlMultiRejectsInvalidRangeResponse() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let partial = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-range-multi-\(UUID().uuidString).partial")
        FileManager.default.createFile(atPath: partial.path, contents: Data(repeating: 0xCD, count: 4096))
        defer { try? FileManager.default.removeItem(at: partial) }

        let before = try Data(contentsOf: partial)
        let url = "http://127.0.0.1:\(port)/fixtures/range-shifted"

        XCTAssertThrowsError(
            try CurlMultiLoop.downloadRangesToFile(
                url: url,
                partialURL: partial,
                ranges: [
                    CurlMultiLoop.RangeRequest(
                        rangeHeader: "0-\(rangeByteCount - 1)",
                        fileOffset: fileOffset,
                        expectedBytes: Int64(rangeByteCount)
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? CurlMultiLoop.MultiError,
                .invalidRangeResponse(httpStatus: 206)
            )
        }

        XCTAssertEqual(try Data(contentsOf: partial), before)
    }

    func testProbeFailureDoesNotWipeSegmapPartial() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-range-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = root.appendingPathComponent("resume.partial")
        let sidecar = SegmentedTransfer.segmentMapURL(for: partial)
        let total = Int64(FaultHTTPServer.fixtureBody.count)
        try Data(repeating: 0x5A, count: Int(total)).write(to: partial)

        let map: [String: Any] = [
            "total": total,
            "baseOffset": 0,
            "validator": [
                "etag": FaultHTTPServer.strongETag,
                "lastModified": NSNull(),
                "totalBytes": total
            ],
            "entries": [
                ["start": 0, "end": 511, "written": 512],
                ["start": 512, "end": total - 1, "written": 0]
            ]
        ]
        let mapData = try JSONSerialization.data(withJSONObject: map)
        try mapData.write(to: sidecar)

        let url = "http://127.0.0.1:\(port)/fixtures/range-ignored-200"
        XCTAssertThrowsError(
            try SegmentedTransfer.downloadHTTP(url: url, partialURL: partial, preferResume: true)
        ) { error in
            XCTAssertEqual(
                error as? TransferCore.TransferError,
                .invalidRangeResponse(httpStatus: 200)
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(try Data(contentsOf: partial).count, Int(total))
    }
}
