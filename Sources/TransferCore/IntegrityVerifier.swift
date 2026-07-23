// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// Integrity helpers used before final-file promotion (FR-TRN-014).
public enum IntegrityVerifier {
    public enum VerifyError: Error, Equatable, Sendable {
        case checksumMismatch(expected: String, actual: String)
        case unreadableFile
    }

    public static func sha256Hex(ofFile url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw VerifyError.unreadableFile
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func verifySHA256(ofFile url: URL, expectedHex: String) throws {
        let actual = try sha256Hex(ofFile: url)
        let expected = expectedHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard actual == expected else {
            throw VerifyError.checksumMismatch(expected: expected, actual: actual)
        }
    }
}
