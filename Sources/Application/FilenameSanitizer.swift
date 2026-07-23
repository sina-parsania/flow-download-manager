// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Sanitize remote filenames for APFS/macOS without silent data loss (FR-FS-002).
public enum FilenameSanitizer {
    public static func sanitize(_ raw: String, fallback: String = "download.bin") -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return fallback }
        // Strip path components if a remote disposition smuggled separators.
        if let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last {
            name = String(last)
        }
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

    public static func filename(fromURLString urlString: String) -> String {
        guard let url = URL(string: urlString) else { return sanitize("download.bin") }
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" {
            return sanitize(url.host.map { "\($0).bin" } ?? "download.bin")
        }
        return sanitize(last)
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
