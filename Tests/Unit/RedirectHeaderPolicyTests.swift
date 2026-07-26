// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import TransferCore

final class RedirectHeaderPolicyTests: XCTestCase {
    func testSameOriginPreservesCustomHeaders() {
        let source = RedirectHeaderPolicy.Origin(scheme: "https", host: "cdn.example", port: 443)
        let headers = [
            TransferCore.HTTPHeader(name: "Referer", value: "https://cdn.example/page"),
            TransferCore.HTTPHeader(name: "Accept", value: "*/*")
        ]
        let outcome = RedirectHeaderPolicy.filterHeaders(headers, from: source, to: source)
        XCTAssertEqual(outcome, .forward(headers: headers))
    }

    func testCrossOriginDropsCookieAuthorizationRefererOrigin() {
        let source = RedirectHeaderPolicy.Origin(scheme: "https", host: "a.example", port: 443)
        let destination = RedirectHeaderPolicy.Origin(scheme: "https", host: "b.example", port: 443)
        let headers = [
            TransferCore.HTTPHeader(name: "Cookie", value: "a=b"),
            TransferCore.HTTPHeader(name: "Authorization", value: "Bearer x"),
            TransferCore.HTTPHeader(name: "Referer", value: "https://a.example/private?token=secret"),
            TransferCore.HTTPHeader(name: "Origin", value: "https://a.example"),
            TransferCore.HTTPHeader(name: "Accept", value: "application/octet-stream"),
            TransferCore.HTTPHeader(name: "Accept-Language", value: "en-US"),
            TransferCore.HTTPHeader(name: "X-Custom", value: "drop-me")
        ]
        let outcome = RedirectHeaderPolicy.filterHeaders(headers, from: source, to: destination)
        XCTAssertEqual(
            outcome,
            .forward(headers: [
                TransferCore.HTTPHeader(name: "Accept", value: "application/octet-stream"),
                TransferCore.HTTPHeader(name: "Accept-Language", value: "en-US")
            ])
        )
    }

    func testHTTPSToHTTPDowngradeRejected() {
        let source = RedirectHeaderPolicy.Origin(scheme: "https", host: "secure.example", port: 443)
        let destination = RedirectHeaderPolicy.Origin(scheme: "http", host: "secure.example", port: 80)
        let outcome = RedirectHeaderPolicy.filterHeaders(
            [TransferCore.HTTPHeader(name: "Accept", value: "*/*")],
            from: source,
            to: destination
        )
        XCTAssertEqual(outcome, .rejectSchemeDowngrade)
    }

    func testHTTPToHTTPSUpgradeUsesCrossOriginRules() {
        let outcome = RedirectHeaderPolicy.filterCurlPayload(
            "Referer: https://a.example/page\nAccept: */*",
            from: "http://a.example/file",
            to: "https://b.example/file"
        )
        XCTAssertEqual(outcome, .forward(headers: [TransferCore.HTTPHeader(name: "Accept", value: "*/*")]))
    }

    func testOriginParserUsesEffectivePorts() {
        XCTAssertEqual(
            RedirectHeaderPolicy.origin(from: "https://cdn.example/asset"),
            RedirectHeaderPolicy.Origin(scheme: "https", host: "cdn.example", port: 443)
        )
        XCTAssertEqual(
            RedirectHeaderPolicy.origin(from: "http://127.0.0.1:8080/x"),
            RedirectHeaderPolicy.Origin(scheme: "http", host: "127.0.0.1", port: 8080)
        )
    }
}
