// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pure deterministic Phase 1 classifier (FR-CAT-001, FR-CAT-005 simplified).
///
/// Precedence: Content-Disposition-ish filename > non-generic MIME > URL-path
/// extension > `other`. Generic MIME types (`application/octet-stream`,
/// `text/plain`, and similar weak types) never win on their own. Torrents are
/// classified only from a `.torrent` extension (magnet links are unsupported
/// upstream).
public enum ClassificationEngine {
    public enum Confidence: String, Sendable, Equatable {
        case high
        case medium
        case low
    }

    public struct ClassificationResult: Sendable, Equatable {
        public let stableKey: String
        public let confidence: Confidence
        public let evidence: String

        public init(stableKey: String, confidence: Confidence, evidence: String) {
            self.stableKey = stableKey
            self.confidence = confidence
            self.evidence = evidence
        }
    }

    /// Built-in category stable keys shipped in Phase 1.
    public static let builtInStableKeys: [String] = [
        "videos", "audio", "images", "documents", "archives", "applications", "torrents", "other"
    ]

    /// - Parameters:
    ///   - filenameEvidence: Preferred filename (e.g. Content-Disposition).
    ///   - mimeEvidence: Response Content-Type when known.
    ///   - urlPathExtension: Extension derived from the URL path (no leading dot),
    ///     or a path/filename from which the extension is taken.
    ///   - rules: Optional user rules; first match overrides the built-in maps.
    public static func classify(
        filenameEvidence: String?,
        mimeEvidence: String?,
        urlPathExtension: String?,
        rules: [CategoryRulesEngine.Rule]? = nil
    ) -> ClassificationResult {
        if let rules, !rules.isEmpty,
           let match = CategoryRulesEngine.evaluate(
               rules: rules,
               filenameEvidence: filenameEvidence,
               mimeEvidence: mimeEvidence,
               urlPathExtension: urlPathExtension
           ) {
            return ClassificationResult(
                stableKey: match.categoryStableKey,
                confidence: .high,
                evidence: match.evidence
            )
        }

        if let filename = filenameEvidence?.trimmingCharacters(in: .whitespacesAndNewlines),
           !filename.isEmpty,
           let ext = pathExtension(of: filename),
           let key = category(forExtension: ext) {
            return ClassificationResult(
                stableKey: key,
                confidence: .high,
                evidence: "filename:\(ext)"
            )
        }

        if let mime = normalizedMIME(mimeEvidence),
           !isGenericMIME(mime),
           let key = category(forMIME: mime) {
            return ClassificationResult(
                stableKey: key,
                confidence: .medium,
                evidence: "mime:\(mime)"
            )
        }

        if let ext = normalizedExtension(urlPathExtension),
           let key = category(forExtension: ext) {
            return ClassificationResult(
                stableKey: key,
                confidence: .medium,
                evidence: "extension:\(ext)"
            )
        }

        // Allow callers to pass a full URL path; take its pathExtension.
        if let path = urlPathExtension?.trimmingCharacters(in: .whitespacesAndNewlines),
           path.contains("/"),
           let ext = pathExtension(of: path),
           let key = category(forExtension: ext) {
            return ClassificationResult(
                stableKey: key,
                confidence: .medium,
                evidence: "extension:\(ext)"
            )
        }

        return ClassificationResult(
            stableKey: "other",
            confidence: .low,
            evidence: "fallback"
        )
    }

    /// Compatibility alias used by UI callers that pass a URL path string.
    public static func classify(
        filenameEvidence: String?,
        mimeEvidence: String?,
        urlPath: String?,
        rules: [CategoryRulesEngine.Rule]? = nil
    ) -> ClassificationResult {
        classify(
            filenameEvidence: filenameEvidence,
            mimeEvidence: mimeEvidence,
            urlPathExtension: urlPath,
            rules: rules
        )
    }

    // MARK: - Extension → category

    private static func category(forExtension ext: String) -> String? {
        switch ext {
        case "mp4", "m4v", "mkv", "mov", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "ts", "m2ts", "3gp":
            return "videos"
        case "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma", "aiff", "aif", "oga":
            return "audio"
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "svg", "ico", "raw":
            return "images"
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "odt", "ods", "odp",
             "csv", "md", "epub", "pages", "numbers", "key":
            return "documents"
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "cab":
            return "archives"
        case "dmg", "pkg", "app", "exe", "msi", "deb", "rpm", "apk", "ipa", "appimage", "iso":
            return "applications"
        case "torrent":
            return "torrents"
        default:
            return nil
        }
    }

    // MARK: - MIME → category (never torrents — extension only)

    private static func category(forMIME mime: String) -> String? {
        if mime.hasPrefix("video/") { return "videos" }
        if mime.hasPrefix("audio/") { return "audio" }
        if mime.hasPrefix("image/") { return "images" }

        switch mime {
        case "application/pdf",
             "application/msword",
             "application/vnd.ms-excel",
             "application/vnd.ms-powerpoint",
             "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
             "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
             "application/vnd.openxmlformats-officedocument.presentationml.presentation",
             "application/rtf",
             "application/epub+zip",
             "text/csv",
             "text/markdown",
             "text/xml",
             "application/json":
            return "documents"
        case "application/zip",
             "application/x-zip-compressed",
             "application/x-rar-compressed",
             "application/vnd.rar",
             "application/x-7z-compressed",
             "application/x-tar",
             "application/gzip",
             "application/x-gzip",
             "application/x-bzip2",
             "application/x-xz":
            return "archives"
        case "application/x-apple-diskimage",
             "application/vnd.apple.installer+xml",
             "application/vnd.debian.binary-package",
             "application/x-rpm",
             "application/vnd.android.package-archive",
             "application/x-iso9660-image",
             "application/x-msdownload",
             "application/vnd.microsoft.portable-executable":
            return "applications"
        default:
            return nil
        }
    }

    private static let genericMIMETypes: Set<String> = [
        "application/octet-stream",
        "application/binary",
        "binary/octet-stream",
        "text/plain",
        "application/force-download",
        "application/x-download"
    ]

    private static func isGenericMIME(_ mime: String) -> Bool {
        genericMIMETypes.contains(mime)
    }

    private static func normalizedMIME(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let withoutParams = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? raw
        return withoutParams.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func pathExtension(of filename: String) -> String? {
        let name = (filename as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        return normalizedExtension(ext)
    }

    private static func normalizedExtension(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        var ext = raw.lowercased()
        if ext.hasPrefix(".") {
            ext.removeFirst()
        }
        // If a path slipped through without "/", still try pathExtension.
        if ext.contains("/") {
            return pathExtension(of: ext)
        }
        return ext.isEmpty ? nil : ext
    }
}
