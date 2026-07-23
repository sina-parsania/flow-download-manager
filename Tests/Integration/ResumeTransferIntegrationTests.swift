// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TestFaultService
import TransferCore
import XCTest

final class ResumeTransferIntegrationTests: XCTestCase {
    func testResumeContinuesPartialFile() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let partial = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-resume-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: partial) }

        let url = "http://127.0.0.1:\(port)/fixtures/ok"
        let firstHalf = FaultHTTPServer.fixtureBody.prefix(2048)
        try Data(firstHalf).write(to: partial)

        let outcome = try TransferCore.resumeOrDownload(url: url, partialURL: partial)
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.fixtureBody.count))
        let data = try Data(contentsOf: partial)
        XCTAssertEqual(data, FaultHTTPServer.fixtureBody)
    }

    func testAbortDuringDownloadThrows() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let partial = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-abort-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: partial) }

        let flag = TransferAbortFlag()
        flag.requestAbort()
        XCTAssertThrowsError(
            try TransferCore.downloadSingleStream(
                url: "http://127.0.0.1:\(port)/fixtures/ok",
                partialURL: partial,
                abortFlag: flag
            )
        ) { error in
            XCTAssertEqual(error as? TransferCore.TransferError, .aborted)
        }
    }
}
