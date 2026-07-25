// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TestFaultService
import TransferCore
import XCTest

final class TransferAbortFlagIntegrationTests: XCTestCase {
    func testConcurrentAbortDuringSlowDownload() async throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let url = "http://127.0.0.1:\(port)/fixtures/throughput?size=1048576&kbps=32"
        let partial = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-concurrent-abort-\(UUID().uuidString).partial")

        for attempt in 0 ..< 8 {
            let flag = TransferAbortFlag()
            defer { try? FileManager.default.removeItem(at: partial) }

            let abortTask = Task.detached {
                try await Task.sleep(nanoseconds: 5_000_000)
                flag.requestAbort()
            }

            XCTAssertThrowsError(
                try TransferCore.downloadSingleStream(
                    url: url,
                    partialURL: partial,
                    abortFlag: flag
                )
            ) { error in
                XCTAssertEqual(error as? TransferCore.TransferError, .aborted, "attempt \(attempt)")
            }

            abortTask.cancel()
            _ = try? await abortTask.value
        }
    }
}
