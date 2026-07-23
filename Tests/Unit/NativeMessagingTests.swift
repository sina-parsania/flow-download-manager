// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NativeMessaging
import XCTest

final class NativeMessagingTests: XCTestCase {
    func testFramingRoundTrip() throws {
        let body = Data(#"{"command":"ping"}"#.utf8)
        let packet = try NativeMessagingFraming.encodeJSONData(body)
        var buffer = packet
        let decoded = try XCTUnwrap(try NativeMessagingFraming.decodeNext(from: &buffer))
        XCTAssertEqual(decoded, body)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testRejectsOversizedMessage() {
        let huge = Data(repeating: 0x41, count: NativeMessagingFraming.maxMessageBytes + 1)
        XCTAssertThrowsError(try NativeMessagingFraming.encodeJSONData(huge)) { error in
            XCTAssertEqual(error as? NativeMessagingFraming.FramingError, .messageTooLarge)
        }
    }

    func testProtocolPingRoundTrip() throws {
        let request = NativeMessagingProtocol.Request(
            requestID: "r1",
            command: .ping
        )
        let body = try JSONEncoder().encode(request)
        let decoded = try NativeMessagingProtocol.decodeRequest(from: body)
        XCTAssertEqual(decoded.command, .ping)
        XCTAssertEqual(decoded.requestID, "r1")
    }

    func testUnsupportedProtocolVersion() throws {
        let body = Data(#"{"protocolVersion":99,"requestID":"x","command":"ping"}"#.utf8)
        XCTAssertThrowsError(try NativeMessagingProtocol.decodeRequest(from: body)) { error in
            XCTAssertEqual(
                error as? NativeMessagingProtocol.DecodeError,
                .unsupportedProtocolVersion(99)
            )
        }
    }

    func testRouterPing() async throws {
        struct StubEngine: NativeMessagingEngineBridge {
            func enqueueURLs(
                _ urls: [String],
                displayName: String?
            ) async throws -> (acceptedCount: Int, jobIDs: [String]) {
                (0, [])
            }

            func listJobCount() async throws -> Int {
                0
            }
        }
        let router = NativeMessagingRouter(engine: StubEngine())
        let request = NativeMessagingProtocol.Request(requestID: "p1", command: .ping)
        let body = try JSONEncoder().encode(request)
        let responseData = await router.handle(body: body)
        let response = try JSONDecoder().decode(NativeMessagingProtocol.Response.self, from: responseData)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.message, "pong")
    }

    func testRouterEnqueueFiltersInvalidURLs() async throws {
        struct StubEngine: NativeMessagingEngineBridge {
            func enqueueURLs(
                _ urls: [String],
                displayName: String?
            ) async throws -> (acceptedCount: Int, jobIDs: [String]) {
                (urls.count, urls.map { _ in UUID().uuidString })
            }

            func listJobCount() async throws -> Int {
                0
            }
        }
        let router = NativeMessagingRouter(engine: StubEngine())
        let request = NativeMessagingProtocol.Request(
            requestID: "e1",
            command: .enqueueURLs,
            urls: ["not-a-url", "https://example.com/a.bin"]
        )
        let body = try JSONEncoder().encode(request)
        let responseData = await router.handle(body: body)
        let response = try JSONDecoder().decode(NativeMessagingProtocol.Response.self, from: responseData)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.acceptedCount, 1)
        XCTAssertEqual(response.jobIDs?.count, 1)
    }
}
