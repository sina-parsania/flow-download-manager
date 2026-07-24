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
