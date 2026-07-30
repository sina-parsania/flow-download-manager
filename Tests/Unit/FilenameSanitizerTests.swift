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

    func testBinaryPathIsWeakAndMIMEAddsVideoExtension() {
        XCTAssertTrue(FilenameSanitizer.isWeakFilename("binary"))
        let name = FilenameSanitizer.preferredFilename(
            contentDisposition: nil,
            urlString: "https://media-cdn.example.com/cdn/client/abc/file/def/binary?dl=true",
            existingEvidence: "binary",
            contentType: "video/mp4"
        )
        XCTAssertTrue(name.hasSuffix(".mp4"), name)
        XCTAssertFalse(name.lowercased().contains("true"))
    }

    func testHTMLMIMEAddsHtmlExtension() {
        let name = FilenameSanitizer.preferredFilename(
            contentDisposition: nil,
            urlString: "https://example.com/article/about-us",
            existingEvidence: nil,
            contentType: "text/html; charset=utf-8"
        )
        XCTAssertTrue(name.hasSuffix(".html"), name)
    }

    func testGenericBinExtensionReplacedByMIME() {
        let name = FilenameSanitizer.ensuringExtension(
            "media-cdn.example.com.bin",
            contentType: "video/webm"
        )
        XCTAssertEqual(name, "media-cdn.example.com.webm")
    }

    func testDownloadTrueQueryIgnored() {
        let name = FilenameSanitizer.filename(
            fromURLString: "https://cdn.example.com/binary?dl=true&download=true"
        )
        XCTAssertNotEqual(name.lowercased(), "true")
        XCTAssertNotEqual(name.lowercased(), "binary")
    }

    func testAtlassianStyleContentDispositionTitle() {
        let header =
            "attachment; filename=\"Cooked count is not updated after marking a recipe as cooked from View Recipe.MP4\""
        let parsed = FilenameSanitizer.filenameFromContentDisposition(header)
        XCTAssertEqual(
            parsed,
            "Cooked count is not updated after marking a recipe as cooked from View Recipe.MP4"
        )
        let preferred = FilenameSanitizer.preferredFilename(
            contentDisposition: header,
            urlString: "https://media-cdn.example.com/cdn/client/3994a9d9-a8f2-475e-934e-3cbb90a0f872/file/554c4bda-135e-463c-92f2-ea815c24c172/binary?dl=true",
            existingEvidence: "binary",
            contentType: "video/mp4"
        )
        XCTAssertEqual(
            preferred,
            "Cooked count is not updated after marking a recipe as cooked from View Recipe.MP4"
        )
    }

    // MARK: - Server-script endpoints

    /// The reported bug, from a real download: EnterpriseDB serves its installer
    /// from `getfile.jsp?fileid=…` as application/x-apple-diskimage. The file
    /// landed as "getfile.jsp" and Finder refused to open a valid disk image.
    func testDiskImageFromAServerScriptEndpointGetsDmg() {
        XCTAssertEqual(
            FilenameSanitizer.preferredFilename(
                contentDisposition: nil,
                urlString: "https://sbp.enterprisedb.com/getfile.jsp?fileid=1260323",
                contentType: "application/x-apple-diskimage"
            ),
            "getfile.dmg"
        )
    }

    func testServerScriptExtensionsAreReplacedByTheDeclaredType() {
        for ext in ["jsp", "php", "asp", "aspx", "cgi", "do", "action", "ashx"] {
            XCTAssertEqual(
                FilenameSanitizer.ensuringExtension("download.\(ext)", contentType: "application/pdf"),
                "download.pdf",
                ".\(ext) names the script, not the bytes it returned"
            )
        }
    }

    /// The replacement only fires when the server declared a type that maps to a
    /// known extension — an unknown or absent type must leave the name alone
    /// rather than guessing.
    func testUnknownContentTypeLeavesAServerScriptNameAlone() {
        XCTAssertEqual(
            FilenameSanitizer.ensuringExtension("getfile.jsp", contentType: "application/octet-stream"),
            "getfile.jsp"
        )
        XCTAssertEqual(
            FilenameSanitizer.ensuringExtension("getfile.jsp", contentType: nil),
            "getfile.jsp"
        )
    }

    /// A real `.php` page served as HTML must not be renamed to `.html` — the
    /// extension already agrees with the content.
    func testServerScriptServingItsOwnPageIsUntouchedWhenTypesAgree() {
        XCTAssertEqual(
            FilenameSanitizer.ensuringExtension("index.html", contentType: "text/html"),
            "index.html"
        )
    }

    /// A genuine extension the server disagrees with is NOT overridden: only the
    /// generic and script-endpoint set is replaceable, or a `.pdf` served with a
    /// sloppy `text/html` would be renamed and broken.
    func testGenuineExtensionSurvivesAMismatchedContentType() {
        XCTAssertEqual(
            FilenameSanitizer.ensuringExtension("paper.pdf", contentType: "text/html"),
            "paper.pdf"
        )
    }

    // MARK: - Installer and archive types

    func testCommonInstallerAndArchiveTypesMapToExtensions() {
        let cases: [(String, String)] = [
            ("application/x-apple-diskimage", "dmg"),
            ("application/x-xar", "pkg"),
            ("application/x-7z-compressed", "7z"),
            ("application/vnd.rar", "rar"),
            ("application/x-tar", "tar"),
            ("application/x-iso9660-image", "iso"),
            ("application/epub+zip", "epub"),
            ("application/vnd.android.package-archive", "apk"),
            ("application/vnd.debian.binary-package", "deb"),
            ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx"),
            ("application/msword", "doc"),
            ("text/plain", "txt")
        ]
        for (mime, expected) in cases {
            XCTAssertEqual(FilenameSanitizer.extension(forMIME: mime), expected, mime)
        }
    }

    /// The point of asking the system instead of keeping a table: types nobody
    /// wrote down still resolve. None of these were in the hand-written map.
    func testSystemDatabaseCoversTypesNobodyListed() {
        let cases: [(String, String)] = [
            ("image/webp", "webp"),
            ("image/avif", "avif"),
            ("image/heic", "heic"),
            ("application/x-bittorrent", "torrent"),
            ("text/x-python-script", "py")
        ]
        for (mime, expected) in cases {
            XCTAssertEqual(FilenameSanitizer.extension(forMIME: mime), expected, mime)
        }
    }

    /// The system database is broad but not total — `application/x-sh` and
    /// `text/yaml` are genuinely absent. Returning nil is the right answer: the
    /// name keeps whatever extension the URL or Content-Disposition gave it
    /// rather than having one invented. Recorded so the boundary is documented
    /// instead of rediscovered.
    func testTypesTheSystemDoesNotKnowReturnNil() {
        XCTAssertNil(FilenameSanitizer.extension(forMIME: "application/x-sh"))
        XCTAssertNil(FilenameSanitizer.extension(forMIME: "text/yaml"))
        XCTAssertEqual(
            FilenameSanitizer.ensuringExtension("setup.sh", contentType: "application/x-sh"),
            "setup.sh",
            "an unknown type must never cost a name its real extension"
        )
    }

    /// `octet-stream` means "I don't know". UTType maps it to `.data`, and
    /// appending that would bury a good filename under a meaningless suffix.
    func testOctetStreamIsTreatedAsNoInformation() {
        XCTAssertNil(FilenameSanitizer.extension(forMIME: "application/octet-stream"))
        XCTAssertNil(FilenameSanitizer.extension(forMIME: "binary/octet-stream"))
        XCTAssertEqual(
            FilenameSanitizer.ensuringExtension("installer.dmg", contentType: "application/octet-stream"),
            "installer.dmg",
            "a real extension must survive a server that declares nothing useful"
        )
    }

    /// RFC 6839: an unknown `+zip` type still behaves like a zip.
    func testStructuredSuffixFallsBackToItsBaseType() {
        XCTAssertEqual(FilenameSanitizer.extension(forMIME: "application/vnd.acme.thing+zip"), "zip")
    }

    /// Media the system has never heard of still gets a usable extension rather
    /// than none — this is what the previous implementation did for all media.
    func testUnknownMediaSubtypeStillYieldsAnExtension() {
        XCTAssertEqual(FilenameSanitizer.extension(forMIME: "video/x-flv"), "flv")
        XCTAssertNil(FilenameSanitizer.extension(forMIME: "video/*"))
    }

    /// Overrides must beat the system, or `image/jpeg` drifts to `.jpeg`.
    func testOverridesBeatTheSystemAnswer() {
        XCTAssertEqual(FilenameSanitizer.extension(forMIME: "image/jpeg"), "jpg")
        XCTAssertEqual(FilenameSanitizer.extension(forMIME: "video/mpeg"), "mpg")
    }

    /// Content-Type carries parameters in the wild; the map must see past them.
    func testContentTypeParametersDoNotDefeatTheMap() {
        XCTAssertEqual(
            FilenameSanitizer.extension(forMIME: "application/x-apple-diskimage; charset=binary"),
            "dmg"
        )
    }

    func testExtensionlessNameStillGainsTheMimeExtension() {
        XCTAssertEqual(
            FilenameSanitizer.ensuringExtension("installer", contentType: "application/x-apple-diskimage"),
            "installer.dmg"
        )
    }

    func testCDNUUIDPathTokensAreWeak() {
        XCTAssertTrue(
            FilenameSanitizer.isWeakFilename("554c4bda-135e-463c-92f2-ea815c24c172")
        )
        let name = FilenameSanitizer.filename(
            fromURLString:
            "https://media-cdn.example.com/cdn/client/3994a9d9-a8f2-475e-934e-3cbb90a0f872/file/554c4bda-135e-463c-92f2-ea815c24c172/binary"
        )
        XCTAssertFalse(name.lowercased().contains("554c4bda"))
        XCTAssertNotEqual(name.lowercased(), "binary")
    }
}
