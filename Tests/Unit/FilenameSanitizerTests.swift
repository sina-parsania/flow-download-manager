// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import XCTest

final class FilenameSanitizerTests: XCTestCase {
    func testGenericDownloadPathUsesHostFallback() {
        let name = FilenameSanitizer.filename(
            fromURLString: "https://nineanime.ir/download"
        )
        XCTAssertFalse(FilenameSanitizer.isWeakFilename(name))
        XCTAssertTrue(name.lowercased().contains("nineanime"))
        XCTAssertNotEqual(name.lowercased(), "download")
    }

    func testEpisodePathSegmentPreferredOverDownload() {
        let name = FilenameSanitizer.filename(
            fromURLString: "https://nineanime.ir/watch/one-piece-episode-101/download"
        )
        XCTAssertEqual(name, "one-piece-episode-101")
    }

    func testQueryTitleUsedWhenPathIsWeak() {
        let name = FilenameSanitizer.filename(
            fromURLString: "https://cdn.example.com/download?title=One+Piece+Ep+12"
        )
        XCTAssertEqual(name, "One Piece Ep 12")
    }

    func testQueryFilenameWithExtension() {
        let name = FilenameSanitizer.filename(
            fromURLString: "https://cdn.example.com/get?filename=clip.mp4&token=abc"
        )
        XCTAssertEqual(name, "clip.mp4")
    }

    func testContentDispositionFilenameStar() {
        let parsed = FilenameSanitizer.filenameFromContentDisposition(
            "attachment; filename*=UTF-8''One%20Piece%20Ep%2001.mp4"
        )
        XCTAssertEqual(parsed, "One Piece Ep 01.mp4")
    }

    func testPreferredFilenamePrefersDispositionOverWeakEvidence() {
        let name = FilenameSanitizer.preferredFilename(
            contentDisposition: "attachment; filename=\"real-video.mkv\"",
            urlString: "https://nineanime.ir/download",
            existingEvidence: "download"
        )
        XCTAssertEqual(name, "real-video.mkv")
    }

    func testPreferredFilenameUpgradesWeakEvidenceFromURL() {
        let name = FilenameSanitizer.preferredFilename(
            contentDisposition: nil,
            urlString: "https://nineanime.ir/anime/bleach-episode-42",
            existingEvidence: "download"
        )
        XCTAssertEqual(name, "bleach-episode-42")
    }

    func testBase64URLPathIsNotUsedAsDisplayName() {
        let encoded = Data("https://cdn.example.com/files/one-piece-101.mp4".utf8)
            .base64EncodedString()
        XCTAssertTrue(FilenameSanitizer.isWeakFilename(encoded))

        // Existing evidence that is a base64 URL blob must be upgraded from the real URL.
        let name = FilenameSanitizer.preferredFilename(
            contentDisposition: nil,
            urlString: "https://cdn.example.com/files/one-piece-101.mp4",
            existingEvidence: encoded
        )
        XCTAssertEqual(name, "one-piece-101.mp4")

        // Direct decode of a base64 path segment (URL-safe, no `=`).
        let raw = "https://cdn.example.com/watch/bleach-ep-09.mkv"
        var token = Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while token.hasSuffix("=") {
            token.removeLast()
        }
        let fromToken = FilenameSanitizer.filename(
            fromURLString: "https://nineanime.ir/\(token)"
        )
        XCTAssertEqual(fromToken, "bleach-ep-09.mkv")
    }
}
