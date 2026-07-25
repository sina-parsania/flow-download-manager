// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import XCTest

final class ClassificationEngineTests: XCTestCase {
    func testMP4MapsToVideos() {
        let result = ClassificationEngine.classify(
            filenameEvidence: nil,
            mimeEvidence: nil,
            urlPathExtension: "mp4"
        )
        XCTAssertEqual(result.stableKey, "videos")
        XCTAssertEqual(result.confidence, .medium)
        XCTAssertEqual(result.evidence, "extension:mp4")
    }

    func testZipMapsToArchives() {
        let result = ClassificationEngine.classify(
            filenameEvidence: "archive.zip",
            mimeEvidence: nil,
            urlPathExtension: nil
        )
        XCTAssertEqual(result.stableKey, "archives")
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.evidence, "filename:zip")
    }

    func testApplicationPDFMapsToDocuments() {
        let result = ClassificationEngine.classify(
            filenameEvidence: nil,
            mimeEvidence: "application/pdf",
            urlPathExtension: nil
        )
        XCTAssertEqual(result.stableKey, "documents")
        XCTAssertEqual(result.confidence, .medium)
        XCTAssertEqual(result.evidence, "mime:application/pdf")
    }

    func testOctetStreamBinMapsToOther() {
        let result = ClassificationEngine.classify(
            filenameEvidence: "payload.bin",
            mimeEvidence: "application/octet-stream",
            urlPathExtension: "bin"
        )
        XCTAssertEqual(result.stableKey, "other")
        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(result.evidence, "fallback")
    }

    func testDMGMapsToApplications() {
        let result = ClassificationEngine.classify(
            filenameEvidence: nil,
            mimeEvidence: nil,
            urlPathExtension: "dmg"
        )
        XCTAssertEqual(result.stableKey, "applications")
        XCTAssertEqual(result.confidence, .medium)
    }

    func testUnknownMapsToOther() {
        let result = ClassificationEngine.classify(
            filenameEvidence: nil,
            mimeEvidence: "application/octet-stream",
            urlPathExtension: "unknownxyz"
        )
        XCTAssertEqual(result.stableKey, "other")
        XCTAssertEqual(result.confidence, .low)
    }

    func testFilenameOutranksGenericMIMEAndExtension() {
        let result = ClassificationEngine.classify(
            filenameEvidence: "clip.mp4",
            mimeEvidence: "application/octet-stream",
            urlPathExtension: "zip"
        )
        XCTAssertEqual(result.stableKey, "videos")
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.evidence, "filename:mp4")
    }

    func testTorrentOnlyFromExtension() {
        let byExtension = ClassificationEngine.classify(
            filenameEvidence: nil,
            mimeEvidence: nil,
            urlPathExtension: "torrent"
        )
        XCTAssertEqual(byExtension.stableKey, "torrents")

        let mimeAlone = ClassificationEngine.classify(
            filenameEvidence: nil,
            mimeEvidence: "application/x-bittorrent",
            urlPathExtension: nil
        )
        XCTAssertEqual(mimeAlone.stableKey, "other")
    }

    func testSignedCDNURLWithQueryMapsToVideos() {
        let result = ClassificationEngine.classify(
            filenameEvidence: nil,
            mimeEvidence: nil,
            urlPath: "https://cdn.example.com/hls/ep01.mp4?token=abc&exp=99"
        )
        XCTAssertEqual(result.stableKey, "videos")
    }

    func testAnimePathHintMapsToVideos() {
        let result = ClassificationEngine.classify(
            filenameEvidence: nil,
            mimeEvidence: nil,
            urlPath: "https://nirvanime.example/stream/onepiece/episode/101"
        )
        XCTAssertEqual(result.stableKey, "videos")
        XCTAssertEqual(result.confidence, .medium)
    }

    func testM3U8TokenInURLMapsToVideos() {
        let result = ClassificationEngine.classify(
            filenameEvidence: "segment",
            mimeEvidence: "application/octet-stream",
            urlPath: "https://media.example.com/play/master.m3u8"
        )
        XCTAssertEqual(result.stableKey, "videos")
    }

    func testVideoHostHintMapsToVideos() {
        let result = ClassificationEngine.classify(
            filenameEvidence: nil,
            mimeEvidence: nil,
            urlPath: "https://www.twitch.tv/somechannel/clip/AbCdEf"
        )
        XCTAssertEqual(result.stableKey, "videos")
        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(result.evidence, "host-hint:videos")
    }

    func testTextHTMLMapsToDocuments() {
        let byMIME = ClassificationEngine.classify(
            filenameEvidence: nil,
            mimeEvidence: "text/html; charset=utf-8",
            urlPathExtension: nil
        )
        XCTAssertEqual(byMIME.stableKey, "documents")
        XCTAssertEqual(byMIME.confidence, .medium)

        let byExt = ClassificationEngine.classify(
            filenameEvidence: "about.html",
            mimeEvidence: nil,
            urlPathExtension: nil
        )
        XCTAssertEqual(byExt.stableKey, "documents")
        XCTAssertEqual(byExt.confidence, .high)
    }

    func testMediaCDNHostHintMapsToVideos() {
        let result = ClassificationEngine.classify(
            filenameEvidence: "binary",
            mimeEvidence: nil,
            urlPath: "https://media-cdn.atlassian.com/us-west-2/v2/cdn/client/x/file/y/binary?dl=true"
        )
        XCTAssertEqual(result.stableKey, "videos")
    }

    func testVideoMIMEMapsExtensionlessNameToVideos() {
        let result = ClassificationEngine.classify(
            filenameEvidence: "media-cdn.example.com-client",
            mimeEvidence: "video/mp4",
            urlPathExtension: nil
        )
        XCTAssertEqual(result.stableKey, "videos")
        XCTAssertEqual(result.confidence, .medium)
    }
}
