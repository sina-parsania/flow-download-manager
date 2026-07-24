// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Foundation
import NativeMessaging
import XCTest
import XPCContracts

/// Records what the router forwarded and answers with a configurable route.
private actor StubEngine: NativeMessagingEngineBridge {
    private let route: NativeMessagingProtocol.Route
    private(set) var lastURLs: [String] = []
    private(set) var lastDisplayName: String?
    private(set) var lastCustomHeadersJSON: String?

    init(route: NativeMessagingProtocol.Route = .engine) {
        self.route = route
    }

    func enqueue(
        urls: [String],
        displayName: String?,
        customHeadersJSON: String?
    ) async throws -> NativeMessagingEnqueueOutcome {
        lastURLs = urls
        lastDisplayName = displayName
        lastCustomHeadersJSON = customHeadersJSON
        return NativeMessagingEnqueueOutcome(
            route: route,
            acceptedCount: urls.count,
            jobIDs: route == .engine ? urls.map { _ in UUID().uuidString } : []
        )
    }

    func listJobCount() async throws -> Int {
        0
    }
}

private struct FailingEngine: NativeMessagingEngineBridge {
    let error: NativeMessagingBridgeError

    func enqueue(
        urls _: [String],
        displayName _: String?,
        customHeadersJSON _: String?
    ) async throws -> NativeMessagingEnqueueOutcome {
        throw error
    }

    func listJobCount() async throws -> Int {
        throw error
    }
}

final class NativeMessagingTests: XCTestCase {
    // MARK: - Framing

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

    // MARK: - Envelope versioning

    func testProtocolPingRoundTrip() throws {
        let request = NativeMessagingProtocol.Request(
            requestID: "r1",
            command: .ping
        )
        XCTAssertEqual(request.protocolVersion, NativeMessagingProtocol.currentVersion)
        let body = try JSONEncoder().encode(request)
        let decoded = try NativeMessagingProtocol.decodeRequest(from: body)
        XCTAssertEqual(decoded.command, .ping)
        XCTAssertEqual(decoded.requestID, "r1")
    }

    func testVersionTwoRequestCarriesHeaders() throws {
        let body = Data(#"""
        {"protocolVersion":2,"requestID":"h1","command":"enqueueURLs",
         "urls":["https://example.com/a.bin"],
         "headers":[{"name":"Referer","value":"https://example.com/page"}]}
        """#.utf8)
        let decoded = try NativeMessagingProtocol.decodeRequest(from: body)
        XCTAssertEqual(decoded.headers?.count, 1)
        XCTAssertEqual(decoded.headers?.first?.name, "Referer")
    }

    func testVersionOneRequestStillDecodes() throws {
        let body = Data(#"""
        {"protocolVersion":1,"requestID":"v1","command":"enqueueURLs",
         "urls":["https://example.com/a.bin"]}
        """#.utf8)
        let decoded = try NativeMessagingProtocol.decodeRequest(from: body)
        XCTAssertEqual(decoded.protocolVersion, 1)
        XCTAssertEqual(decoded.urls, ["https://example.com/a.bin"])
        XCTAssertNil(decoded.headers)
    }

    func testVersionOneRequestCannotSmuggleHeaders() throws {
        let body = Data(#"""
        {"protocolVersion":1,"requestID":"v1h","command":"enqueueURLs",
         "urls":["https://example.com/a.bin"],
         "headers":[{"name":"Cookie","value":"session=abc"}]}
        """#.utf8)
        let decoded = try NativeMessagingProtocol.decodeRequest(from: body)
        XCTAssertNil(decoded.headers, "a version 1 envelope has no header channel")
    }

    func testUnsupportedProtocolVersion() {
        for version in [0, 99] {
            let body = Data(#"{"protocolVersion":\#(version),"requestID":"x","command":"ping"}"#.utf8)
            XCTAssertThrowsError(try NativeMessagingProtocol.decodeRequest(from: body)) { error in
                XCTAssertEqual(
                    error as? NativeMessagingProtocol.DecodeError,
                    .unsupportedProtocolVersion(version)
                )
            }
        }
    }

    // MARK: - Header policy

    func testHeaderPolicyForwardsAllowlistInCanonicalOrder() throws {
        let result = NativeMessagingHeaderPolicy.sanitize(
            [
                .init(name: "user-agent", value: "TestAgent/1.0"),
                .init(name: "COOKIE", value: "session=abc"),
                .init(name: "Referer", value: "https://example.com/page")
            ],
            urlCount: 1
        )
        XCTAssertEqual(result.forwardedNames, ["Cookie", "Referer", "User-Agent"])
        XCTAssertTrue(result.droppedNames.isEmpty)
        let parsed = try HeaderValidator.parseExtraHeadersJSON(result.customHeadersJSON)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed.first?.name, "Cookie")
        XCTAssertEqual(parsed.first?.value, "session=abc")
        XCTAssertEqual(parsed.last?.name, "User-Agent")
    }

    func testHeaderPolicyDropsNamesOutsideTheAllowlist() {
        let result = NativeMessagingHeaderPolicy.sanitize(
            [
                .init(name: "Authorization", value: "Bearer abc"),
                .init(name: "Host", value: "evil.example"),
                .init(name: "X-Forwarded-For", value: "10.0.0.1"),
                .init(name: "Referer", value: "https://example.com/page")
            ],
            urlCount: 1
        )
        XCTAssertEqual(result.forwardedNames, ["Referer"])
        XCTAssertFalse(result.droppedNames.contains("Authorization"))
        XCTAssertFalse(result.customHeadersJSON?.contains("Bearer") ?? false)
    }

    func testHeaderPolicyRejectsHeaderInjection() {
        let result = NativeMessagingHeaderPolicy.sanitize(
            [.init(name: "Referer", value: "https://a.example\r\nX-Evil: 1")],
            urlCount: 1
        )
        XCTAssertNil(result.customHeadersJSON)
        XCTAssertEqual(result.droppedNames, ["Referer"])
    }

    func testHeaderPolicyDropsCookieForMultiURLBatch() {
        let result = NativeMessagingHeaderPolicy.sanitize(
            [
                .init(name: "Cookie", value: "session=abc"),
                .init(name: "Referer", value: "https://example.com/page")
            ],
            urlCount: 3
        )
        XCTAssertEqual(result.forwardedNames, ["Referer"])
        XCTAssertEqual(result.droppedNames, ["Cookie"])
        XCTAssertFalse(result.customHeadersJSON?.contains("session=abc") ?? false)
    }

    func testHeaderPolicyKeepsFirstOfARepeatedName() throws {
        let result = NativeMessagingHeaderPolicy.sanitize(
            [
                .init(name: "Referer", value: "https://first.example/"),
                .init(name: "referer", value: "https://second.example/")
            ],
            urlCount: 1
        )
        let parsed = try HeaderValidator.parseExtraHeadersJSON(result.customHeadersJSON)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.value, "https://first.example/")
    }

    func testHeaderPolicyTrimsToThePayloadLimitKeepingTheCookie() throws {
        let cookie = "session=" + String(repeating: "a", count: 4000)
        let result = NativeMessagingHeaderPolicy.sanitize(
            [
                .init(name: "Cookie", value: cookie),
                .init(name: "Referer", value: "https://example.com/a"),
                .init(name: "User-Agent", value: "TestAgent/1.0")
            ],
            urlCount: 1
        )
        let encoded = try XCTUnwrap(result.customHeadersJSON)
        XCTAssertLessThanOrEqual(encoded.utf16.count, NativeMessagingHeaderPolicy.maxEncodedLength)
        XCTAssertEqual(result.forwardedNames.first, "Cookie")
        XCTAssertTrue(result.droppedNames.contains("User-Agent"))
    }

    func testHeaderPolicyDropsACookieThatCannotFitAtAll() {
        let cookie = "session=" + String(repeating: "a", count: 6000)
        let result = NativeMessagingHeaderPolicy.sanitize(
            [.init(name: "Cookie", value: cookie)],
            urlCount: 1
        )
        XCTAssertNil(result.customHeadersJSON)
        XCTAssertEqual(result.droppedNames, ["Cookie"])
    }

    func testHeaderPolicyIgnoresAnAbsentHeaderSet() {
        let result = NativeMessagingHeaderPolicy.sanitize(nil, urlCount: 1)
        XCTAssertNil(result.customHeadersJSON)
        XCTAssertTrue(result.forwardedNames.isEmpty)
        XCTAssertTrue(result.droppedNames.isEmpty)
    }

    // MARK: - Router

    func testRouterPing() async throws {
        let router = NativeMessagingRouter(engine: StubEngine())
        let request = NativeMessagingProtocol.Request(requestID: "p1", command: .ping)
        let response = try await roundTrip(router, request)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.message, "pong")
        XCTAssertEqual(response.protocolVersion, NativeMessagingProtocol.currentVersion)
    }

    func testRouterEnqueueFiltersInvalidURLs() async throws {
        let router = NativeMessagingRouter(engine: StubEngine())
        let request = NativeMessagingProtocol.Request(
            requestID: "e1",
            command: .enqueueURLs,
            urls: ["not-a-url", "https://example.com/a.bin"]
        )
        let response = try await roundTrip(router, request)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.acceptedCount, 1)
        XCTAssertEqual(response.jobIDs?.count, 1)
        XCTAssertEqual(response.route, .engine)
    }

    func testRouterAnswersAtTheRequestedProtocolVersion() async throws {
        let router = NativeMessagingRouter(engine: StubEngine())
        let request = NativeMessagingProtocol.Request(
            protocolVersion: 1,
            requestID: "legacy",
            command: .enqueueURLs,
            urls: ["https://example.com/a.bin"]
        )
        let response = try await roundTrip(router, request)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.protocolVersion, 1)
    }

    func testRouterForwardsSanitizedHeadersToTheEngine() async throws {
        let engine = StubEngine()
        let router = NativeMessagingRouter(engine: engine)
        let request = NativeMessagingProtocol.Request(
            requestID: "e2",
            command: .enqueueURLs,
            urls: ["https://example.com/a.bin"],
            headers: [
                .init(name: "Cookie", value: "session=abc"),
                .init(name: "Authorization", value: "Bearer secret")
            ]
        )
        let response = try await roundTrip(router, request)
        XCTAssertTrue(response.ok)
        let recorded = await engine.lastCustomHeadersJSON
        let forwarded = try XCTUnwrap(recorded)
        XCTAssertTrue(forwarded.contains("session=abc"))
        XCTAssertFalse(forwarded.contains("Bearer"))
    }

    func testRouterReportsAppHandoffAndTheHeadersItCouldNotCarry() async throws {
        let router = NativeMessagingRouter(engine: StubEngine(route: .appHandoff))
        let request = NativeMessagingProtocol.Request(
            requestID: "e3",
            command: .enqueueURLs,
            urls: ["https://example.com/a.bin"],
            headers: [.init(name: "Cookie", value: "session=abc")]
        )
        let response = try await roundTrip(router, request)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.route, .appHandoff)
        XCTAssertEqual(response.warningCode, "openedInAppWithoutHeaders")
        XCTAssertEqual(response.droppedHeaderNames, ["Cookie"])
        let message = try XCTUnwrap(response.message)
        XCTAssertFalse(message.contains("session=abc"), "a header value must never be echoed")
    }

    func testRouterRejectsAnUnsupportedVersionAtItsOwnVersion() async throws {
        let router = NativeMessagingRouter(engine: StubEngine())
        let body = Data(#"{"protocolVersion":99,"requestID":"x","command":"ping"}"#.utf8)
        let answer = await router.handle(body: body)
        let response = try JSONDecoder().decode(NativeMessagingProtocol.Response.self, from: answer)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.errorCode, "unsupportedProtocolVersion")
        XCTAssertEqual(response.protocolVersion, NativeMessagingProtocol.currentVersion)
    }

    func testRouterSurfacesAnUnreachableApp() async throws {
        let router = NativeMessagingRouter(engine: FailingEngine(error: .appUnavailable))
        let request = NativeMessagingProtocol.Request(
            requestID: "e4",
            command: .enqueueURLs,
            urls: ["https://example.com/a.bin"]
        )
        let response = try await roundTrip(router, request)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.errorCode, "appUnavailable")
    }

    // MARK: - App hand-off

    func testHandoffURLRoundTripsThroughOpenURLIngest() throws {
        let urls = [
            "https://example.com/a.bin",
            "https://example.com/dir/file.zip?token=1&next=2"
        ]
        let url = try XCTUnwrap(AppHandoffURL.make(urls: urls))
        XCTAssertEqual(url.scheme, OpenURLIngest.scheme)
        XCTAssertEqual(OpenURLIngest.parse(url), urls)
    }

    func testHandoffURLIsNilWithoutURLs() {
        XCTAssertNil(AppHandoffURL.make(urls: []))
    }

    func testHandoffURLCapsTheBatch() throws {
        let urls = (0 ..< (AppHandoffURL.maxURLCount + 10)).map { "https://example.com/\($0).bin" }
        let url = try XCTUnwrap(AppHandoffURL.make(urls: urls))
        XCTAssertEqual(OpenURLIngest.parse(url).count, AppHandoffURL.maxURLCount)
    }

    // MARK: - Transport classification

    func testEngineRejectionIsNotTreatedAsAnUnreachableEngine() {
        let rejection = NativeHostEngineClient.ClientError.remote(
            XPCErrorCode.invalidPayload.error(detail: "bad batch")
        )
        XCTAssertFalse(NativeHostEngineClient.isTransportFailure(rejection))
    }

    func testMissingMachServiceIsTreatedAsAnUnreachableEngine() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: 4097)
        XCTAssertTrue(
            NativeHostEngineClient.isTransportFailure(
                NativeHostEngineClient.ClientError.remote(cocoa)
            )
        )
        XCTAssertTrue(
            NativeHostEngineClient.isTransportFailure(NativeHostEngineClient.ClientError.timedOut)
        )
    }

    // MARK: - Helpers

    private func roundTrip(
        _ router: NativeMessagingRouter,
        _ request: NativeMessagingProtocol.Request
    ) async throws -> NativeMessagingProtocol.Response {
        let body = try JSONEncoder().encode(request)
        let answer = await router.handle(body: body)
        return try JSONDecoder().decode(NativeMessagingProtocol.Response.self, from: answer)
    }
}
