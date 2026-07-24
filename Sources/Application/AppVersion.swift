// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Numeric `major.minor.patch` for update comparison (ignores a leading `v`).
public struct AppVersion: Comparable, Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `1.2.3`, `v1.2.3`, or `1.2` (patch defaults to 0). Extra pre-release
    /// suffixes after `-` or `+` are ignored for ordering.
    public static func parse(_ raw: String) -> AppVersion? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") {
            text = String(text.dropFirst())
        }
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            text = String(text[..<cut])
        }
        let parts = text.split(separator: ".").map(String.init)
        guard parts.count >= 2, parts.count <= 3,
              let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0
        else { return nil }
        let patch: Int
        if parts.count == 3 {
            guard let value = Int(parts[2]), value >= 0 else { return nil }
            patch = value
        } else {
            patch = 0
        }
        return AppVersion(major: major, minor: minor, patch: patch)
    }

    public var displayString: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
