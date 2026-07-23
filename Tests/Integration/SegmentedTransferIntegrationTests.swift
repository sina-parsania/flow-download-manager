// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TestFaultService
import TransferCore
import XCTest

final class SegmentedTransferIntegrationTests: XCTestCase {
    func testTwoSegmentDownloadMatchesFixture() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = root.appendingPathComponent("seg.partial")
        let url = "http://127.0.0.1:\(port)/fixtures/ok"
        let outcome = try SegmentedTransfer.downloadHTTP(url: url, partialURL: partial)
        XCTAssertEqual(outcome.segmentCount, 2)
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.fixtureBody.count))
        let data = try Data(contentsOf: partial)
        XCTAssertEqual(data, FaultHTTPServer.fixtureBody)
    }
}
