// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TestFaultService
import TransferCore
import XCTest

final class TransferCoreIntegrationTests: XCTestCase {
    func testSingleStreamDownloadAndPromote() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = root.appendingPathComponent("fixture.partial")
        let final = root.appendingPathComponent("fixture.bin")
        let url = "http://127.0.0.1:\(port)/fixtures/ok"

        let outcome = try TransferCore.downloadSingleStream(url: url, partialURL: partial)
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.fixtureBody.count))
        XCTAssertEqual(outcome.identity.httpStatus, 200)
        XCTAssertEqual(outcome.identity.etag, FaultHTTPServer.strongETag)
        XCTAssertTrue(outcome.identity.advertisesByteRanges)

        try TransferFinalizer.promote(
            partialURL: partial,
            finalURL: final,
            expectedSize: Int64(FaultHTTPServer.fixtureBody.count)
        )
        let data = try Data(contentsOf: final)
        XCTAssertEqual(data, FaultHTTPServer.fixtureBody)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testRangeProbeReturns206() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let url = "http://127.0.0.1:\(port)/fixtures/ok"
        let identity = try TransferCore.probeRangeSupport(url: url)
        XCTAssertEqual(identity.httpStatus, 206)
        XCTAssertNotNil(identity.contentRange)
    }
}
