// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Sanitize remote filenames for APFS/macOS without silent data loss (FR-FS-002).
public enum FilenameSanitizer {
    /// Path/query tokens that are never useful display names (CDN “download” endpoints).
    private static let weakBasenames: Set<String> = [
        "download", "download.bin", "dl", "get", "file", "files", "index",
        "watch", "stream", "embed", "play", "api", "video", "videos",
        "media", "asset", "assets", "raw", "source", "redirect", "r",
        "default", "untitled", "unknown"
    ]

    public static func sanitize(_ raw: String, fallback: String = "download.bin") -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return fallback }
        // Strip path components if a remote disposition smuggled separators.
        if let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last {
            name = String(last)
        }
        // Decode common URL encoding once.
        name = name.removingPercentEncoding ?? name
        name = name.replacingOccurrences(of: "+", with: " ")
        let illegal = CharacterSet(charactersIn: ":/\0")
            .union(.newlines)
            .union(.controlCharacters)
        name = name.components(separatedBy: illegal).joined(separator: "_")
        while name.hasPrefix(".") {
            name = String(name.dropFirst())
        }
        let reserved = Set([".", "..", "CON", "PRN", "AUX", "NUL"])
        if reserved.contains(name.uppercased()) || name.isEmpty {
            return fallback
        }
        if name.utf8.count > 255 {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            let kept = truncateUTF8(base, maxBytes: 240)
            name = ext.isEmpty ? kept : "\(kept).\(ext)"
        }
        return name
    }

    /// True when a stored name is a useless placeholder (e.g. path ended in `/download`).
    public static func isWeakFilename(_ raw: String?) -> Bool {
        guard let raw else { return true }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let base = (trimmed as NSString).lastPathComponent.lowercased()
        let noQuery: String = if let q = base.firstIndex(of: "?") {
            String(base[..<q])
        } else {
            base
        }
        if weakBasenames.contains(noQuery) { return true }
        if weakBasenames.contains((noQuery as NSString).deletingPathExtension) { return true }
        // Pure numeric / hash-like tokens without extension are weak for UI.
        if (noQuery as NSString).pathExtension.isEmpty,
           noQuery.count <= 2 || noQuery.allSatisfy({ $0.isNumber || $0 == "-" }) {
            return true
        }
        // Base64-encoded URL blobs (common CDN path tokens) are not display names.
        if looksLikeBase64URLToken(noQuery) { return true }
        return false
    }

    /// Best-effort display / destination name from a remote URL (query, path, host).
    public static func filename(fromURLString urlString: String) -> String {
        guard let url = URL(string: urlString) else { return sanitize("download.bin") }

        if let fromQuery = filenameFromQuery(url) {
            return sanitize(fromQuery)
        }

        if let fromPath = filenameFromPath(url) {
            return sanitize(fromPath)
        }

        // Path may be a base64(https://…) token — decode and re-derive.
        let last = url.lastPathComponent
        if let nested = decodeBase64URLString(last) {
            return filename(fromURLString: nested)
        }

        if let host = url.host, !host.isEmpty {
            let slug = pathSlug(from: url)
            if let slug, !slug.isEmpty {
                return sanitize("\(host)-\(slug)")
            }
            return sanitize("\(host).bin")
        }
        return sanitize("download.bin")
    }

    /// Prefer Content-Disposition, then URL heuristics.
    public static func preferredFilename(
        contentDisposition: String?,
        urlString: String?,
        existingEvidence: String? = nil
    ) -> String {
        if let disposition = contentDisposition,
           let fromCD = filenameFromContentDisposition(disposition) {
            return sanitize(fromCD)
        }
        if let existing = existingEvidence, !isWeakFilename(existing) {
            return sanitize(existing)
        }
        if let urlString {
            return filename(fromURLString: urlString)
        }
        if let existing = existingEvidence {
            return sanitize(existing)
        }
        return sanitize("download.bin")
    }

    /// RFC 6266-ish: `attachment; filename="x.mp4"` / `filename*=UTF-8''x.mp4`
    public static func filenameFromContentDisposition(_ header: String) -> String? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // filename*=charset'lang'value (RFC 5987)
        if let star = matchDispositionParameter(trimmed, name: "filename*") {
            var value = star
            if let tick = value.firstIndex(of: "'"),
               let tick2 = value[value.index(after: tick)...].firstIndex(of: "'") {
                value = String(value[value.index(after: tick2)...])
            }
            let decoded = value.removingPercentEncoding ?? value
            if !decoded.isEmpty { return decoded }
        }

        if let plain = matchDispositionParameter(trimmed, name: "filename") {
            var value = plain
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Private helpers

    private static func matchDispositionParameter(_ header: String, name: String) -> String? {
        let lower = header.lowercased()
        let needle = name.lowercased() + "="
        guard let range = lower.range(of: needle) else { return nil }
        var rest = String(header[range.upperBound...])
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\"") {
            rest = String(rest.dropFirst())
            if let end = rest.firstIndex(of: "\"") {
                return String(rest[..<end])
            }
            return rest
        }
        // Unquoted: stop at `;` or end.
        if let semi = rest.firstIndex(of: ";") {
            return String(rest[..<semi]).trimmingCharacters(in: .whitespaces)
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let queryNameKeys: [String] = [
        "filename", "file_name", "file", "name", "title", "download",
        "fn", "fname", "media", "media_name", "videoname", "episode"
    ]

    private static func filenameFromQuery(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty
        else { return nil }

        let map = Dictionary(
            items.compactMap { item -> (String, String)? in
                guard let value = item.value, !value.isEmpty else { return nil }
                return (item.name.lowercased(), value)
            },
            uniquingKeysWith: { first, _ in first }
        )

        for key in queryNameKeys {
            if let value = map[key], !isWeakFilename(value) {
                // Prefer values that look like filenames (have extension) when key is vague.
                if key == "download" || key == "title" || key == "name" || key == "episode" {
                    return ensureExtensionHint(value, url: url)
                }
                return value
            }
        }

        // Any query value that looks like a media file.
        for item in items {
            guard let value = item.value, looksLikeMediaFilename(value) else { continue }
            return value
        }
        return nil
    }

    private static func filenameFromPath(_ url: URL) -> String? {
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard !segments.isEmpty else { return nil }

        // Prefer last segment that looks like a real file.
        for segment in segments.reversed() {
            let cleaned = stripQueryFragment(segment)
            if looksLikeMediaFilename(cleaned) {
                return cleaned
            }
        }

        // Otherwise last non-weak segment.
        for segment in segments.reversed() {
            let cleaned = stripQueryFragment(segment)
            if !isWeakFilename(cleaned) {
                return ensureExtensionHint(cleaned, url: url)
            }
        }
        return nil
    }

    private static func pathSlug(from url: URL) -> String? {
        let segments = url.pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
            .map(stripQueryFragment)
            .filter { !isWeakFilename($0) }
        guard let last = segments.last else { return nil }
        return last
    }

    private static func stripQueryFragment(_ segment: String) -> String {
        var s = segment
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        if let h = s.firstIndex(of: "#") { s = String(s[..<h]) }
        return s.removingPercentEncoding ?? s
    }

    private static func looksLikeMediaFilename(_ value: String) -> Bool {
        let ext = (stripQueryFragment(value) as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        let media: Set<String> = [
            "mp4", "m4v", "mkv", "mov", "webm", "avi", "ts", "m3u8",
            "mp3", "m4a", "flac", "aac", "ogg",
            "jpg", "jpeg", "png", "gif", "webp",
            "zip", "rar", "7z", "pdf", "dmg", "pkg"
        ]
        return media.contains(ext)
    }

    private static func ensureExtensionHint(_ value: String, url: URL) -> String {
        let cleaned = stripQueryFragment(value)
        if !(cleaned as NSString).pathExtension.isEmpty {
            return cleaned
        }
        // Keep title-like names; destination layer may still uniquify.
        _ = url
        return cleaned
    }

    private static func looksLikeBase64URLToken(_ token: String) -> Bool {
        guard token.count >= 24 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=_-"))
        guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // `aHR0` / `ahr0` is base64 for `htt` — common for encoded https URLs.
        let lower = token.lowercased()
        return lower.hasPrefix("ahr0")
    }

    private static func decodeBase64URLString(_ token: String) -> String? {
        guard looksLikeBase64URLToken(token) else { return nil }
        var padded = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = padded.count % 4
        if rem > 0 {
            padded.append(String(repeating: "=", count: 4 - rem))
        }
        guard let data = Data(base64Encoded: padded),
              let decoded = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              decoded.hasPrefix("http://") || decoded.hasPrefix("https://")
        else { return nil }
        return decoded
    }

    private static func truncateUTF8(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var end = text.startIndex
        var count = 0
        while end < text.endIndex {
            let next = text.index(after: end)
            let byteCount = text[end ..< next].utf8.count
            if count + byteCount > maxBytes { break }
            count += byteCount
            end = next
        }
        return String(text[..<end])
    }
}
