// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Origin-scoped custom header policy for HTTP(S) redirects.
///
/// Pinned libcurl withholds `Authorization` and explicit `Cookie` on cross-host
/// redirects, but forwards other custom headers (notably `Referer`). Flow applies
/// this policy on every redirect hop so sensitive representation headers never
/// leave the origin that supplied them.
public enum RedirectHeaderPolicy: Sendable {
    public struct Origin: Equatable, Sendable {
        public let scheme: String
        public let host: String
        public let port: Int

        public init(scheme: String, host: String, port: Int) {
            self.scheme = scheme.lowercased()
            self.host = host.lowercased()
            self.port = port
        }
    }

    public enum Outcome: Equatable, Sendable {
        case forward(headers: [TransferCore.HTTPHeader])
        case rejectSchemeDowngrade
    }

    /// Header names dropped on cross-origin HTTP(S) redirects.
    public static let crossOriginSensitiveNames: Set<String> = [
        "Cookie", "Authorization", "Referer"
    ]

    /// Non-sensitive headers that may follow a cross-origin redirect.
    public static let crossOriginSafeNames: Set<String> = [
        "User-Agent", "Accept", "Accept-Language"
    ]

    /// Parses scheme, host, and effective port from an HTTP(S) URL.
    public static func origin(from urlString: String) -> Origin? {
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        return Origin(scheme: scheme, host: host, port: port)
    }

    public static func originsEqual(_ lhs: Origin, _ rhs: Origin) -> Bool {
        lhs.scheme == rhs.scheme && lhs.host == rhs.host && lhs.port == rhs.port
    }

    /// Applies redirect forwarding rules between two HTTP(S) origins.
    public static func filterHeaders(
        _ headers: [TransferCore.HTTPHeader],
        from source: Origin,
        to destination: Origin
    ) -> Outcome {
        if source.scheme == "https", destination.scheme == "http" {
            return .rejectSchemeDowngrade
        }
        if originsEqual(source, destination) {
            return .forward(headers: headers)
        }
        let kept = headers.filter { header in
            let canonical = canonicalHeaderName(header.name)
            guard !header.value.isEmpty else { return false }
            if crossOriginSensitiveNames.contains(canonical) { return false }
            return crossOriginSafeNames.contains(canonical)
        }
        return .forward(headers: kept)
    }

    /// Filters newline-separated `Name: Value` header lines (curl payload form).
    public static func filterCurlPayload(
        _ payload: String?,
        from sourceURL: String,
        to destinationURL: String
    ) -> Outcome {
        guard let payload, !payload.isEmpty else { return .forward(headers: []) }
        guard let source = origin(from: sourceURL), let destination = origin(from: destinationURL) else {
            return .forward(headers: [])
        }
        var headers: [TransferCore.HTTPHeader] = []
        for line in payload.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            headers.append(TransferCore.HTTPHeader(name: name, value: value))
        }
        return filterHeaders(headers, from: source, to: destination)
    }

    private static func canonicalHeaderName(_ name: String) -> String {
        let lowered = name.lowercased()
        if let match = crossOriginSensitiveNames.union(crossOriginSafeNames)
            .first(where: { $0.lowercased() == lowered }) {
            return match
        }
        return name
    }
}
