// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Minimal bencode decoder for `.torrent` metadata inspection (Phase 4 start).
/// Does not speak BitTorrent wire protocol; magnets remain unsupported until
/// libtorrent lands.
public enum TorrentBencode {
    public enum DecodeError: Error, Equatable, Sendable {
        case truncated
        case invalidInteger
        case invalidStringLength
        case unexpectedToken
        case missingInfo
    }

    public enum Value: Sendable, Equatable {
        case integer(Int64)
        case string(Data)
        case list([Value])
        case dict([String: Value])
    }

    public struct TorrentFileEntry: Sendable, Equatable {
        public let path: String
        public let length: Int64
    }

    public struct TorrentMetadata: Sendable, Equatable {
        public let name: String?
        public let pieceLength: Int64?
        public let files: [TorrentFileEntry]
        public let totalLength: Int64
    }

    public static func decode(_ data: Data) throws -> Value {
        var index = data.startIndex
        let value = try parseValue(data, index: &index)
        guard index == data.endIndex else { throw DecodeError.unexpectedToken }
        return value
    }

    public static func metadata(fromTorrentFile data: Data) throws -> TorrentMetadata {
        let root = try decode(data)
        guard case let .dict(top) = root else { throw DecodeError.missingInfo }
        guard case let .dict(info) = top["info"] else { throw DecodeError.missingInfo }

        let name: String? = {
            guard case let .string(raw) = info["name"] else { return nil }
            return String(data: raw, encoding: .utf8)
        }()
        let pieceLength: Int64? = {
            guard case let .integer(value) = info["piece length"] else { return nil }
            return value
        }()

        if case let .integer(length) = info["length"] {
            return TorrentMetadata(
                name: name,
                pieceLength: pieceLength,
                files: [TorrentFileEntry(path: name ?? "download", length: length)],
                totalLength: length
            )
        }

        var files: [TorrentFileEntry] = []
        if case let .list(entries) = info["files"] {
            for entry in entries {
                guard case let .dict(fileDict) = entry,
                      case let .integer(length) = fileDict["length"]
                else { continue }
                let path: String
                if case let .list(parts) = fileDict["path"] {
                    let names = parts.compactMap { part -> String? in
                        guard case let .string(raw) = part else { return nil }
                        return String(data: raw, encoding: .utf8)
                    }
                    path = names.joined(separator: "/")
                } else {
                    path = "file"
                }
                guard isSafeRelativePath(path) else { continue }
                files.append(TorrentFileEntry(path: path, length: length))
            }
        }
        // Reject case-folding collisions on Apple filesystems (FR-P2P-007).
        var seenFolded: Set<String> = []
        var uniqueFiles: [TorrentFileEntry] = []
        for entry in files {
            let folded = entry.path.lowercased()
            guard seenFolded.insert(folded).inserted else { continue }
            uniqueFiles.append(entry)
        }
        let total = uniqueFiles.reduce(Int64(0)) { $0 + $1.length }
        return TorrentMetadata(name: name, pieceLength: pieceLength, files: uniqueFiles, totalLength: total)
    }

    /// Relative POSIX-style paths only: no absolute, no `..`, no empty segments, no NUL.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        return true
    }

    private static func parseValue(_ data: Data, index: inout Data.Index) throws -> Value {
        guard index < data.endIndex else { throw DecodeError.truncated }
        let marker = data[index]
        switch marker {
        case UInt8(ascii: "i"):
            index = data.index(after: index)
            return try .integer(parseInteger(data, index: &index))
        case UInt8(ascii: "l"):
            index = data.index(after: index)
            var items: [Value] = []
            while index < data.endIndex, data[index] != UInt8(ascii: "e") {
                try items.append(parseValue(data, index: &index))
            }
            guard index < data.endIndex else { throw DecodeError.truncated }
            index = data.index(after: index)
            return .list(items)
        case UInt8(ascii: "d"):
            index = data.index(after: index)
            var dict: [String: Value] = [:]
            while index < data.endIndex, data[index] != UInt8(ascii: "e") {
                guard case let .string(keyData) = try parseValue(data, index: &index),
                      let key = String(data: keyData, encoding: .utf8)
                else { throw DecodeError.unexpectedToken }
                dict[key] = try parseValue(data, index: &index)
            }
            guard index < data.endIndex else { throw DecodeError.truncated }
            index = data.index(after: index)
            return .dict(dict)
        case UInt8(ascii: "0") ... UInt8(ascii: "9"):
            return try .string(parseString(data, index: &index))
        default:
            throw DecodeError.unexpectedToken
        }
    }

    private static func parseInteger(_ data: Data, index: inout Data.Index) throws -> Int64 {
        let start = index
        while index < data.endIndex, data[index] != UInt8(ascii: "e") {
            index = data.index(after: index)
        }
        guard index < data.endIndex else { throw DecodeError.truncated }
        let slice = data[start ..< index]
        index = data.index(after: index)
        guard let text = String(data: slice, encoding: .ascii),
              let value = Int64(text)
        else { throw DecodeError.invalidInteger }
        return value
    }

    private static func parseString(_ data: Data, index: inout Data.Index) throws -> Data {
        let start = index
        while index < data.endIndex, data[index] != UInt8(ascii: ":") {
            index = data.index(after: index)
        }
        guard index < data.endIndex else { throw DecodeError.truncated }
        let lengthSlice = data[start ..< index]
        index = data.index(after: index)
        guard let lengthText = String(data: lengthSlice, encoding: .ascii),
              let length = Int(lengthText), length >= 0
        else { throw DecodeError.invalidStringLength }
        let end = data.index(index, offsetBy: length, limitedBy: data.endIndex)
        guard let end else { throw DecodeError.truncated }
        let value = data[index ..< end]
        index = end
        return Data(value)
    }
}
