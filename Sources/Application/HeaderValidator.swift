// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Validate user-supplied HTTP headers (FR-TRN-005). Rejects injection and hop-by-hop names.
public enum HeaderValidator {
    private static let bannedNames: Set<String> = [
        "host", "content-length", "transfer-encoding", "connection", "keep-alive",
        "proxy-connection", "upgrade", "te", "trailer", "proxy-authorization"
    ]

    public static func validate(name: String, value: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.utf8.count <= 256 else { return false }
        guard value.utf8.count <= 8192 else { return false }
        if trimmedName.utf8
            .contains(where: {
                $0 == 0 || $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r")
            }) {
            return false
        }
        if value.utf8.contains(where: { $0 == 0 || $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") }) {
            return false
        }
        if bannedNames.contains(trimmedName.lowercased()) { return false }
        return true
    }
}

/// Proxy profile kinds claimed by the UI must match runtime capability (FR-TRN-004).
public enum ProxyKind: String, Sendable, Codable, CaseIterable {
    case http
    case https
    case socks5
}
