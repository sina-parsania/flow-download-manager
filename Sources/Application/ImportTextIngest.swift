// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pure helpers for txt/csv (and extensionless text) import used by Finder/dock
/// open-URL, window drop, and the Add sheet file importer (FR-ING).
/// Never starts transfers — callers only prefill the Add sheet.
public enum ImportTextIngest {
    public static let maxBytes = 8_000_000

    public enum ReadError: Error, Equatable, Sendable {
        case notAFileURL
        case unsupportedExtension
        case exceedsSizeLimit
        case undecodable
    }

    /// `txt`, `csv`, or extensionless paths are accepted.
    public static func isImportableFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        return ext == "txt" || ext == "csv" || ext.isEmpty
    }

    /// Reads UTF-8 (falling back to ISO Latin-1) text from an importable file URL.
    public static func readText(from url: URL, maxBytes: Int = maxBytes) throws -> String {
        guard url.isFileURL else { throw ReadError.notAFileURL }
        guard isImportableFile(url) else { throw ReadError.unsupportedExtension }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maxBytes else { throw ReadError.exceedsSizeLimit }
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else {
            throw ReadError.undecodable
        }
        return text
    }
}
