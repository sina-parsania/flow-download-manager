// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MediaIsolation
import XCTest

final class MediaIsolationTests: XCTestCase {
    func testDRMRejection() {
        XCTAssertEqual(MediaPolicy.evaluate(urlString: "https://cdn.example/video", formatID: "hls-drm"), .rejectedDRM)
        XCTAssertEqual(MediaPolicy.evaluate(urlString: "https://cdn.example/video", formatID: "140"), .allowed)
    }

    func testYtdlpArgvHasNoShell() {
        let args = MediaProcessLauncher.ytdlpMetadataArguments(url: "https://example.com/w")
        XCTAssertEqual(args.first, "--dump-json")
        XCTAssertEqual(args.last, "https://example.com/w")
        XCTAssertFalse(args.contains(where: { $0.contains(";") || $0.contains("|") }))
    }

    func testMissingExecutableFailsClosed() {
        let launcher = MediaProcessLauncher(
            executableURL: URL(fileURLWithPath: "/tmp/dm-missing-ytdlp-\(UUID().uuidString)")
        )
        XCTAssertThrowsError(try launcher.run(arguments: ["--version"])) { error in
            XCTAssertEqual(error as? MediaProcessLauncher.LaunchError, .executableMissing)
        }
    }

    func testYtdlpProbeParsesDRM() throws {
        let json = Data(#"{"id":"v1","title":"t","format_id":"hls-drm","_has_drm":true}"#.utf8)
        let probe = try YtdlpJSONProbe.parse(stdout: json)
        XCTAssertEqual(probe.mediaDecision, .rejectedDRM)
    }

    func testYtdlpProbeAllowsCleanFormat() throws {
        let json = Data(#"{"id":"v1","title":"t","format_id":"140","is_live":false}"#.utf8)
        let probe = try YtdlpJSONProbe.parse(stdout: json)
        XCTAssertEqual(probe.mediaDecision, .allowed)
        XCTAssertEqual(probe.formatID, "140")
    }

    func testProbePrefersLargestProgressiveFormat() throws {
        let json = Data(#"""
        {"id":"v1","title":"t","formats":[
          {"format_id":"18","url":"https://cdn.test/small.mp4","vcodec":"avc1","acodec":"mp4a","filesize":1000},
          {"format_id":"22","url":"https://cdn.test/big.mp4","vcodec":"avc1","acodec":"mp4a","filesize":9000},
          {"format_id":"137","url":"https://cdn.test/videoonly.mp4","vcodec":"avc1","acodec":"none","filesize":99000}
        ]}
        """#.utf8)
        let probe = try YtdlpJSONProbe.parse(stdout: json)
        // The video-only rendition is the largest but needs a muxer, so it loses.
        XCTAssertEqual(probe.downloadableFormat?.url, "https://cdn.test/big.mp4")
        XCTAssertEqual(probe.formats.filter(\.isProgressive).count, 2)
    }

    func testProbeRejectsAdaptiveOnlyPage() throws {
        let json = Data(#"""
        {"id":"v1","title":"t","formats":[
          {"format_id":"137","url":"https://cdn.test/v.mp4","vcodec":"avc1","acodec":"none"},
          {"format_id":"140","url":"https://cdn.test/a.m4a","vcodec":"none","acodec":"mp4a"}
        ]}
        """#.utf8)
        let probe = try YtdlpJSONProbe.parse(stdout: json)
        XCTAssertNil(probe.downloadableFormat)
    }

    func testProbeSkipsNonHTTPFormatURLs() throws {
        let json = Data(#"""
        {"id":"v1","title":"t","formats":[
          {"format_id":"hls","url":"m3u8://cdn.test/live.m3u8","vcodec":"avc1","acodec":"mp4a"}
        ]}
        """#.utf8)
        let probe = try YtdlpJSONProbe.parse(stdout: json)
        XCTAssertTrue(probe.formats.isEmpty)
        XCTAssertNil(probe.downloadableFormat)
    }

    func testProbeFallsBackToTopLevelURLWhenNoFormats() throws {
        let json = Data(#"""
        {"id":"v1","title":"t","format_id":"http","url":"https://cdn.test/direct.mp4",
         "http_headers":{"User-Agent":"yt-dlp/2026","Referer":"https://page.test/"}}
        """#.utf8)
        let probe = try YtdlpJSONProbe.parse(stdout: json)
        XCTAssertEqual(probe.downloadableFormat?.url, "https://cdn.test/direct.mp4")
        XCTAssertEqual(probe.downloadableFormat?.httpHeaders["Referer"], "https://page.test/")
    }

    func testFormatInheritsTopLevelHeadersWhenItHasNone() throws {
        let json = Data(#"""
        {"id":"v1","title":"t","http_headers":{"User-Agent":"yt-dlp/2026"},
         "formats":[{"format_id":"22","url":"https://cdn.test/big.mp4","vcodec":"avc1","acodec":"mp4a"}]}
        """#.utf8)
        let probe = try YtdlpJSONProbe.parse(stdout: json)
        XCTAssertEqual(probe.downloadableFormat?.httpHeaders["User-Agent"], "yt-dlp/2026")
    }

    func testMediaSiteProbeRecognizesKnownHosts() {
        XCTAssertTrue(MediaSiteProbe.looksLikeMediaPage(urlString: "https://www.youtube.com/watch?v=abc"))
        XCTAssertTrue(MediaSiteProbe.looksLikeMediaPage(urlString: "https://youtu.be/abc"))
        XCTAssertFalse(MediaSiteProbe.looksLikeMediaPage(urlString: "https://cdn.example.test/file.mp4"))
        XCTAssertFalse(MediaSiteProbe.looksLikeMediaPage(urlString: "magnet:?xt=urn:btih:abc"))
    }

    func testMediaSiteProbeFailsClosedWithoutBinary() {
        XCTAssertThrowsError(
            try MediaSiteProbe.probeMetadata(
                urlString: "https://www.youtube.com/watch?v=abc",
                executableURL: URL(fileURLWithPath: "/tmp/dm-missing-ytdlp-\(UUID().uuidString)")
            )
        ) { error in
            XCTAssertEqual(error as? MediaSiteProbe.AvailabilityError, .executableMissing)
        }
    }
}
