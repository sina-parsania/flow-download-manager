// SPDX-License-Identifier: GPL-3.0-or-later

import TestFaultService
import XCTest

/// End-to-end checks of the deterministic loopback fault service — the harness
/// Phase 1 transfer tests depend on (`05-quality-testing-release-gates.md` §3).
final class FaultServiceIntegrationTests: XCTestCase {
    private func startServer() throws -> (FaultHTTPServer, UInt16) {
        let server = FaultHTTPServer()
        let port = try server.start()
        return (server, port)
    }

    func testHealthAndLifecycle() throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let response = try FaultHTTPClient.get(port: port, path: "/health")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "ok")
        XCTAssertGreaterThan(port, 0)
    }

    func testFixtureAdvertisesRangeAndEtag() throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let response = try FaultHTTPClient.get(port: port, path: "/fixtures/ok")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.header("ETag"), FaultHTTPServer.strongETag)
        XCTAssertEqual(response.header("Accept-Ranges"), "bytes")
        XCTAssertEqual(response.body, FaultHTTPServer.fixtureBody)
    }

    func testRangeRequestReturns206WithContentRange() throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let response = try FaultHTTPClient.get(port: port, path: "/fixtures/ok", rangeHeader: "Range: bytes=0-99")
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.header("Content-Range"), "bytes 0-99/\(FaultHTTPServer.fixtureBody.count)")
        XCTAssertEqual(response.body.count, 100)
        XCTAssertEqual(response.body, FaultHTTPServer.fixtureBody.prefix(100))
    }

    func testNoRangeEndpointIgnoresRange() throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let response = try FaultHTTPClient.get(port: port, path: "/fixtures/no-range", rangeHeader: "Range: bytes=0-99")
        XCTAssertEqual(response.statusCode, 200, "server that ignores Range returns full 200")
        XCTAssertEqual(response.body.count, FaultHTTPServer.fixtureBody.count)
    }

    func testStatusCodeInjection() throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        for code in [401, 403, 404, 429, 503] {
            let response = try FaultHTTPClient.get(port: port, path: "/status/\(code)")
            XCTAssertEqual(response.statusCode, code)
        }
    }

    func testChangingEtagChangesBetweenRequests() throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let first = try FaultHTTPClient.get(port: port, path: "/fixtures/changing-etag")
        let second = try FaultHTTPClient.get(port: port, path: "/fixtures/changing-etag")
        XCTAssertNotNil(first.header("ETag"))
        XCTAssertNotEqual(first.header("ETag"), second.header("ETag"))
    }

    func testTruncatedBodyUnderreportsContentLength() throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let response = try FaultHTTPClient.get(port: port, path: "/fixtures/truncated")
        XCTAssertEqual(response.header("Content-Length"), "\(FaultHTTPServer.fixtureBody.count)")
        XCTAssertLessThan(
            response.body.count,
            FaultHTTPServer.fixtureBody.count,
            "body is truncated vs declared length"
        )
    }

    func testMaximalRangeDoesNotCrash() throws {
        // An Int.max upper bound in the untrusted Range header must not overflow-trap;
        // the server clamps to the resource size.
        let (server, port) = try startServer()
        defer { server.stop() }
        let response = try FaultHTTPClient.get(
            port: port, path: "/fixtures/ok", rangeHeader: "Range: bytes=0-9223372036854775807"
        )
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.body.count, FaultHTTPServer.fixtureBody.count)
    }

    func testControlResetAndLogs() throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        _ = try FaultHTTPClient.get(port: port, path: "/fixtures/ok")
        XCTAssertTrue(server.logs().contains { $0.contains("/fixtures/ok") })
        server.reset()
        XCTAssertFalse(server.logs().contains { $0.contains("/fixtures/ok") })
    }
}
