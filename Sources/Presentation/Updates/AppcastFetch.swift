// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Minimal appcast reader for manual update checks (first `<item>` wins).
enum AppcastFetch {
    struct LatestRelease: Sendable {
        let shortVersion: String
        let build: Int
        let rawXML: Data
    }

    enum Error: Swift.Error {
        case badURL
        case httpStatus(Int)
        case emptyBody
        case notRSS
        case missingVersion
    }

    /// Download the published feed bypassing HTTP caches.
    static func fetchLatest(from remoteURLString: String) async throws -> LatestRelease {
        guard var components = URLComponents(string: remoteURLString) else {
            throw Error.badURL
        }
        // Bust CDN/proxy caches without changing the canonical feed path on GitHub.
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
        components.queryItems = query.queryItems

        guard let url = components.url else { throw Error.badURL }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 20
        )
        request.setValue("Flow-UpdateCheck/1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.emptyBody }
        guard (200 ..< 300).contains(http.statusCode) else { throw Error.httpStatus(http.statusCode) }
        guard !data.isEmpty else { throw Error.emptyBody }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard text.contains("<rss"), text.contains("sparkle") else { throw Error.notRSS }
        guard let latest = parseLatestBuild(from: text) else { throw Error.missingVersion }
        return LatestRelease(shortVersion: latest.short, build: latest.build, rawXML: data)
    }

    static func installedBuild() -> Int {
        let raw = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return Int(raw) ?? 0
    }

    static func installedShortVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func parseLatestBuild(from xml: String) -> (short: String, build: Int)? {
        guard let itemRange = xml.range(of: "<item>") else { return nil }
        let tail = String(xml[itemRange.lowerBound...])
        guard let short = firstTag("sparkle:shortVersionString", in: tail),
              let buildString = firstTag("sparkle:version", in: tail),
              let build = Int(buildString)
        else { return nil }
        return (short, build)
    }

    private static func firstTag(_ name: String, in xml: String) -> String? {
        let open = "<\(name)>"
        let close = "</\(name)>"
        guard let start = xml.range(of: open)?.upperBound,
              let end = xml.range(of: close, range: start ..< xml.endIndex)?.lowerBound
        else { return nil }
        return String(xml[start ..< end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
