// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TestFaultService
import TransferCore
import XCTest

final class RedirectIntegrationTests: XCTestCase {
    private func sensitiveHeaders() -> [TransferCore.HTTPHeader] {
        [
            TransferCore.HTTPHeader(name: "Cookie", value: "sid=fixture"),
            TransferCore.HTTPHeader(name: "Authorization", value: "Bearer fixture-token"),
            TransferCore.HTTPHeader(name: "Referer", value: "https://origin.example/private?token=secret"),
            TransferCore.HTTPHeader(name: "Accept", value: "application/octet-stream"),
            TransferCore.HTTPHeader(name: "Accept-Language", value: "en-US")
        ]
    }

    func testSingleHopRedirectKeepsOnlyTerminalMetadata() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        var options = TransferCore.DownloadOptions()
        options.maxRedirects = 5
        let url = "http://127.0.0.1:\(port)/fixtures/redirect/metadata-hop"
        let outcome = try TransferCore.downloadSingleStream(
            url: url,
            partialURL: temporaryPartial(),
            options: options
        )

        XCTAssertEqual(outcome.identity.etag, "\"terminal-only\"")
        XCTAssertEqual(outcome.identity.contentType, "application/octet-stream")
        XCTAssertNil(outcome.identity.contentDisposition)
        XCTAssertTrue(outcome.identity.advertisesByteRanges)
        XCTAssertTrue(outcome.identity.finalURL.hasSuffix("/fixtures/redirect/metadata-terminal"))
    }

    func testMultiHopRedirectKeepsOnlyTerminalMetadata() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        var options = TransferCore.DownloadOptions()
        options.maxRedirects = 5
        let url = "http://127.0.0.1:\(port)/fixtures/redirect/metadata-chain"
        let outcome = try TransferCore.downloadSingleStream(
            url: url,
            partialURL: temporaryPartial(),
            options: options
        )

        XCTAssertEqual(outcome.identity.etag, "\"terminal-only\"")
        XCTAssertNil(outcome.identity.lastModified)
        XCTAssertNil(outcome.identity.contentDisposition)
    }

    func testSegmentedRedirectKeepsOnlyTerminalMetadata() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let partial = temporaryPartial()
        let url = "http://127.0.0.1:\(port)/fixtures/redirect/metadata-hop"
        let outcome = try SegmentedTransfer.downloadHTTP(url: url, partialURL: partial)
        XCTAssertGreaterThanOrEqual(outcome.segmentCount, 1)
        XCTAssertEqual(outcome.identity.etag, "\"terminal-only\"")
        XCTAssertNil(outcome.identity.contentDisposition)
    }

    func testSameOriginRedirectForwardsSensitiveHeaders() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        var options = TransferCore.DownloadOptions()
        options.maxRedirects = 5
        options.extraHeaders = sensitiveHeaders()
        let url = "http://127.0.0.1:\(port)/fixtures/redirect/same-origin"
        _ = try TransferCore.downloadSingleStream(
            url: url,
            partialURL: temporaryPartial(),
            options: options
        )

        let names = Set(server.recordedHeaderNames(on: "/fixtures/redirect/capture"))
        XCTAssertTrue(names.contains("Cookie"))
        XCTAssertTrue(names.contains("Authorization"))
        XCTAssertTrue(names.contains("Referer"))
        XCTAssertTrue(names.contains("Accept"))
    }

    func testCrossOriginRedirectDropsSensitiveHeaders() throws {
        let origin = FaultHTTPServer()
        let target = FaultHTTPServer()
        let originPort = try origin.start()
        let targetPort = try target.start()
        defer {
            origin.stop()
            target.stop()
        }

        var options = TransferCore.DownloadOptions()
        options.maxRedirects = 5
        options.extraHeaders = sensitiveHeaders()
        let url = "http://127.0.0.1:\(originPort)/fixtures/redirect/cross?port=\(targetPort)"
        _ = try TransferCore.downloadSingleStream(
            url: url,
            partialURL: temporaryPartial(),
            options: options
        )

        let names = Set(target.recordedHeaderNames(on: "/fixtures/redirect/capture"))
        XCTAssertFalse(names.contains("Cookie"))
        XCTAssertFalse(names.contains("Authorization"))
        XCTAssertFalse(names.contains("Referer"))
        XCTAssertTrue(names.contains("Accept"))
        XCTAssertTrue(names.contains("Accept-Language"))
    }

    func testRedirectLimitFailsClosed() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        var options = TransferCore.DownloadOptions()
        options.maxRedirects = 0
        let url = "http://127.0.0.1:\(port)/fixtures/redirect/metadata-hop"
        XCTAssertThrowsError(
            try TransferCore.downloadSingleStream(
                url: url,
                partialURL: temporaryPartial(),
                options: options
            )
        ) { error in
            guard case let TransferCore.TransferError.httpStatus(status, _) = error else {
                return XCTFail("expected redirect status, got \(error)")
            }
            XCTAssertEqual(status, 302)
        }
    }

    private func temporaryPartial() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-redirect-\(UUID().uuidString).partial")
    }
}
