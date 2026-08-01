// SPDX-License-Identifier: GPL-3.0-or-later

import TestFaultService
import TransferCore
import XCTest

/// `Retry-After` has to survive the whole journey — libcurl's header callback,
/// `DMCurlHeaderCtx`, `DMCurlDownloadResult`, the Swift bridge, and finally the
/// error the orchestrator pattern-matches on.
///
/// The unit tests prove the parser is right, which is worth nothing on its own:
/// before this, `RetryPolicy` documented "Retry-After support" while the header
/// was never captured from a response anywhere in the tree, so the feature did
/// not exist end to end.
final class RetryAfterIntegrationTests: XCTestCase {
    private func partialURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-retry-after-\(label)-\(UUID().uuidString).partial")
    }

    func testDeltaSecondsReachesTheThrownError() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let partial = partialURL("delta")
        defer { try? FileManager.default.removeItem(at: partial) }

        do {
            _ = try TransferCore.downloadSingleStream(
                url: "http://127.0.0.1:\(port)/fixtures/rate-limited",
                partialURL: partial
            )
            XCTFail("a 429 must not be reported as success")
        } catch let TransferCore.TransferError.httpStatus(status, retryAfter) {
            XCTAssertEqual(status, 429)
            XCTAssertEqual(
                retryAfter, 7,
                "the server asked for 7 s and the engine must be told that"
            )
        }
    }

    /// An unparseable header must leave the caller on its own backoff rather than
    /// inventing a number.
    func testHTTPDateFormLeavesTheDelayUnset() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let partial = partialURL("date")
        defer { try? FileManager.default.removeItem(at: partial) }

        do {
            _ = try TransferCore.downloadSingleStream(
                url: "http://127.0.0.1:\(port)/fixtures/rate-limited-http-date",
                partialURL: partial
            )
            XCTFail("a 429 must not be reported as success")
        } catch let TransferCore.TransferError.httpStatus(status, retryAfter) {
            XCTAssertEqual(status, 429)
            XCTAssertNil(retryAfter, "an HTTP-date must not be guessed at")
        }
    }

    /// A response without the header must not fabricate one.
    func testAbsentHeaderStaysNil() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let partial = partialURL("absent")
        defer { try? FileManager.default.removeItem(at: partial) }

        do {
            _ = try TransferCore.downloadSingleStream(
                url: "http://127.0.0.1:\(port)/status/503",
                partialURL: partial
            )
            XCTFail("a 503 must not be reported as success")
        } catch let TransferCore.TransferError.httpStatus(status, retryAfter) {
            XCTAssertEqual(status, 503)
            XCTAssertNil(retryAfter)
        }
    }
}
