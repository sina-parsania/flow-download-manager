// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MediaIsolation
import XCTest
@testable import Presentation

final class MediaResolutionTests: XCTestCase {
    private func probe(
        title: String? = "Clip",
        isLive: Bool = false,
        formatID: String? = "22",
        formats: [YtdlpFormat] = [],
        headers: [String: String] = [:]
    ) -> YtdlpProbeResult {
        YtdlpProbeResult(
            id: "v1",
            title: title,
            extractor: "test",
            formatID: formatID,
            isLive: isLive,
            drmFlag: false,
            directURL: nil,
            httpHeaders: headers,
            formats: formats
        )
    }

    private func format(
        url: String = "https://cdn.test/clip.mp4",
        video: String? = "avc1",
        audio: String? = "mp4a",
        headers: [String: String] = [:]
    ) -> YtdlpFormat {
        YtdlpFormat(
            formatID: "22",
            url: url,
            ext: "mp4",
            videoCodec: video,
            audioCodec: audio,
            filesizeBytes: 100,
            httpHeaders: headers
        )
    }

    func testDRMPageIsBlockedBeforeResolving() {
        let drm = YtdlpProbeResult(
            id: "v1", title: "Clip", extractor: "test", formatID: "hls-drm",
            isLive: false, drmFlag: true, directURL: "https://cdn.test/clip.mp4",
            httpHeaders: [:], formats: [format()]
        )
        guard case let .blocked(_, _, reason) = MediaResolution.resolve(
            sourceURL: "https://page.test/v", probe: drm
        ) else {
            return XCTFail("DRM page must never resolve to a queueable link")
        }
        XCTAssertTrue(reason.contains("protected"))
    }

    func testLiveStreamIsBlocked() {
        let outcome = MediaResolution.resolve(
            sourceURL: "https://page.test/v",
            probe: probe(isLive: true, formats: [format()])
        )
        guard case .blocked = outcome else {
            return XCTFail("a live stream has no finished file to queue")
        }
    }

    func testAdaptiveOnlyPageIsBlocked() {
        let outcome = MediaResolution.resolve(
            sourceURL: "https://page.test/v",
            probe: probe(formats: [
                format(url: "https://cdn.test/v.mp4", audio: "none"),
                format(url: "https://cdn.test/a.m4a", video: "none")
            ])
        )
        guard case .blocked = outcome else {
            return XCTFail("Flow has no muxer, so split streams cannot be queued")
        }
    }

    func testProgressiveFormatResolves() {
        let outcome = MediaResolution.resolve(
            sourceURL: "https://page.test/v",
            probe: probe(formats: [format()])
        )
        guard case let .resolved(resolved) = outcome else {
            return XCTFail("a progressive format is queueable")
        }
        XCTAssertEqual(resolved.downloadURL, "https://cdn.test/clip.mp4")
        XCTAssertEqual(resolved.title, "Clip")
        XCTAssertFalse(resolved.isSingleConnection)
    }

    /// A server honouring `Accept-Encoding` answers a Range request with compressed
    /// bytes, which makes every segment offset wrong. It must never be forwarded.
    func testAcceptEncodingIsDroppedFromResolvedHeaders() {
        let outcome = MediaResolution.resolve(
            sourceURL: "https://page.test/v",
            probe: probe(formats: [format(headers: [
                "Accept-Encoding": "gzip, deflate",
                "User-Agent": "yt-dlp/2026",
                "Referer": "https://page.test/"
            ])])
        )
        guard case let .resolved(resolved) = outcome, let json = resolved.headersJSON else {
            return XCTFail("expected resolved link with headers")
        }
        XCTAssertFalse(json.lowercased().contains("accept-encoding"))
        XCTAssertTrue(json.contains("User-Agent"))
        XCTAssertTrue(json.contains("Referer"))
    }

    func testHopByHopHeaderIsDroppedRatherThanFailingTheWholeSet() {
        let outcome = MediaResolution.resolve(
            sourceURL: "https://page.test/v",
            probe: probe(formats: [format(headers: [
                "Host": "cdn.test",
                "User-Agent": "yt-dlp/2026"
            ])])
        )
        guard case let .resolved(resolved) = outcome, let json = resolved.headersJSON else {
            return XCTFail("one bad header must not lose the whole download")
        }
        XCTAssertFalse(json.contains("Host"))
        XCTAssertTrue(json.contains("User-Agent"))
    }

    func testCookieBoundLinkIsFlaggedSingleConnection() {
        let outcome = MediaResolution.resolve(
            sourceURL: "https://page.test/v",
            probe: probe(formats: [format(headers: ["Cookie": "session=abc"])])
        )
        guard case let .resolved(resolved) = outcome else {
            return XCTFail("expected resolved link")
        }
        XCTAssertTrue(
            resolved.isSingleConnection,
            "cookie-bound links skip the range probe, so the sheet must say so"
        )
    }

    func testNoHeadersMeansNilJSONRatherThanEmptyArray() {
        let outcome = MediaResolution.resolve(
            sourceURL: "https://page.test/v",
            probe: probe(formats: [format()])
        )
        guard case let .resolved(resolved) = outcome else {
            return XCTFail("expected resolved link")
        }
        XCTAssertNil(resolved.headersJSON)
    }
}
