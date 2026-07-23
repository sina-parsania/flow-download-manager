// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pure parser for the local-dev `downloadmanager` URL scheme (FR-ING dock / URL handoff).
/// Never starts transfers — callers only prefill the Add sheet.
public enum OpenURLIngest {
    public static let scheme = "downloadmanager"

    /// Extracts download URL strings from a custom-scheme open-URL.
    /// Accepts `?url=` / repeated `url` query items, and a path that itself looks like
    /// an `http(s)` / `ftp(s)` / `sftp` URL (leading slash stripped).
    public static func parse(_ url: URL) -> [String] {
        guard url.scheme?.lowercased() == scheme else { return [] }

        var collected: [String] = []
        var seen: Set<String> = []

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = components.queryItems {
            for item in items where item.name.lowercased() == "url" {
                guard let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty
                else { continue }
                append(value, into: &collected, seen: &seen)
            }
        }

        let pathCandidate = pathAsURLString(url)
        if let pathCandidate {
            append(pathCandidate, into: &collected, seen: &seen)
        }

        return collected
    }

    private static func append(_ value: String, into collected: inout [String], seen: inout Set<String>) {
        guard seen.insert(value).inserted else { return }
        collected.append(value)
    }

    private static func pathAsURLString(_ url: URL) -> String? {
        var path = url.path
        if path.hasPrefix("/") {
            path = String(path.dropFirst())
        }
        // Percent-decode once so `downloadmanager:///https%3A%2F%2F…` works.
        if let decoded = path.removingPercentEncoding {
            path = decoded
        }
        path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        let lower = path.lowercased()
        let allowedPrefixes = ["http://", "https://", "ftp://", "ftps://", "sftp://"]
        guard allowedPrefixes.contains(where: { lower.hasPrefix($0) }) else { return nil }
        return path
    }
}
