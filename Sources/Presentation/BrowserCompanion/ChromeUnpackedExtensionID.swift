// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// Chrome’s unpacked-extension ID: SHA-256 of the absolute directory path,
/// first 16 bytes mapped from hex `0-f` onto `a-p`.
public enum ChromeUnpackedExtensionID {
    public static func make(directoryPath: String) -> String {
        let absolute = Self.normalizedAbsolutePath(directoryPath)
        let digest = SHA256.hash(data: Data(absolute.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let first32 = hex.prefix(32)
        var mapped = String()
        mapped.reserveCapacity(32)
        for character in first32 {
            let value = Int(String(character), radix: 16) ?? 0
            mapped.append(Character(UnicodeScalar(UInt8(ascii: "a") &+ UInt8(value))))
        }
        return mapped
    }

    /// Absolute + symlink-resolved spellings Chrome may canonicalize to.
    public static func candidates(for directory: URL) -> [String] {
        var paths: [String] = []
        let absolute = normalizedAbsolutePath(directory.path)
        if !absolute.isEmpty { paths.append(absolute) }
        let resolved = normalizedAbsolutePath(
            (directory.path as NSString).resolvingSymlinksInPath
        )
        if !resolved.isEmpty, !paths.contains(resolved) {
            paths.append(resolved)
        }
        return paths
    }

    static func normalizedAbsolutePath(_ path: String) -> String {
        var absolute = (path as NSString).standardizingPath
        while absolute.count > 1, absolute.hasSuffix("/") {
            absolute.removeLast()
        }
        return absolute
    }
}
