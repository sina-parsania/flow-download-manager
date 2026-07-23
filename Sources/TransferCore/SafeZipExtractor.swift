// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import zlib

/// Bounded, path-validated ZIP extraction (FR-FS-005 start).
/// Rejects absolute paths, `..` traversal, and Unix symlink entries.
public enum SafeZipExtractor {
    public static let defaultMaxUncompressedBytes: Int64 = 512 * 1024 * 1024
    public static let defaultMaxEntryCount: Int = 10000

    public enum ExtractError: Error, Equatable, Sendable {
        case notAZip
        case truncated
        case unsupportedCompression(UInt16)
        case unsafePath(String)
        case symlinkRejected
        case entryCountExceeded(Int)
        case uncompressedSizeExceeded(Int64)
        case inflateFailed
        case writeFailed
    }

    public struct Limits: Sendable, Equatable {
        public var maxUncompressedBytes: Int64
        public var maxEntryCount: Int

        public init(
            maxUncompressedBytes: Int64 = SafeZipExtractor.defaultMaxUncompressedBytes,
            maxEntryCount: Int = SafeZipExtractor.defaultMaxEntryCount
        ) {
            self.maxUncompressedBytes = maxUncompressedBytes
            self.maxEntryCount = maxEntryCount
        }
    }

    /// Extracts validated file entries into `destinationDirectory`.
    /// Creates the destination directory if needed. Existing contents are not wiped.
    public static func extract(
        archiveURL: URL,
        destinationDirectory: URL,
        limits: Limits = Limits()
    ) throws {
        let data = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        try extract(archiveData: data, destinationDirectory: destinationDirectory, limits: limits)
    }

    public static func extract(
        archiveData data: Data,
        destinationDirectory: URL,
        limits: Limits = Limits()
    ) throws {
        let entries = try CentralDirectory.parse(data: data, limits: limits)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        var totalUncompressed: Int64 = 0
        for entry in entries {
            if entry.isDirectory {
                let dirURL = try validatedDestination(
                    relativePath: entry.name,
                    under: destinationDirectory
                )
                try FileManager.default.createDirectory(
                    at: dirURL,
                    withIntermediateDirectories: true
                )
                continue
            }

            totalUncompressed += Int64(entry.uncompressedSize)
            if totalUncompressed > limits.maxUncompressedBytes {
                throw ExtractError.uncompressedSizeExceeded(totalUncompressed)
            }

            let fileURL = try validatedDestination(
                relativePath: entry.name,
                under: destinationDirectory
            )
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

            let payload = try LocalFile.readPayload(data: data, entry: entry)
            let plain: Data
            switch entry.compressionMethod {
            case 0:
                plain = payload
            case 8:
                plain = try inflateRaw(payload, expectedSize: entry.uncompressedSize)
            default:
                throw ExtractError.unsupportedCompression(entry.compressionMethod)
            }
            guard plain.count == entry.uncompressedSize else {
                throw ExtractError.inflateFailed
            }
            do {
                try plain.write(to: fileURL, options: [.atomic])
            } catch {
                throw ExtractError.writeFailed
            }
        }
    }

    /// Validates a ZIP relative path: no absolute, no `..`, no empty / `.` segments abuse.
    public static func validateRelativePath(_ name: String) throws -> String {
        guard !name.isEmpty else { throw ExtractError.unsafePath(name) }
        if name.hasPrefix("/") || name.hasPrefix("\\") {
            throw ExtractError.unsafePath(name)
        }
        // Drive-letter absolute (Windows-style) or UNC.
        if name.count >= 2, name[name.index(name.startIndex, offsetBy: 1)] == ":" {
            throw ExtractError.unsafePath(name)
        }
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        for part in parts {
            if part == ".." {
                throw ExtractError.unsafePath(name)
            }
        }
        return normalized
    }

    private static func validatedDestination(relativePath: String, under root: URL) throws -> URL {
        let safe = try validateRelativePath(relativePath)
        let trimmed = safe.hasSuffix("/") ? String(safe.dropLast()) : safe
        let candidate = root.appendingPathComponent(trimmed, isDirectory: safe.hasSuffix("/"))
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw ExtractError.unsafePath(relativePath)
        }
        return candidate
    }

    private static func inflateRaw(_ source: Data, expectedSize: UInt32) throws -> Data {
        if source.isEmpty {
            return Data()
        }
        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else { throw ExtractError.inflateFailed }
        defer { inflateEnd(&stream) }

        var output = Data(count: Int(expectedSize))
        let status: Int32 = source.withUnsafeBytes { srcRaw in
            output.withUnsafeMutableBytes { dstRaw in
                guard let srcBase = srcRaw.bindMemory(to: Bytef.self).baseAddress,
                      let dstBase = dstRaw.bindMemory(to: Bytef.self).baseAddress
                else {
                    return Z_DATA_ERROR
                }
                stream.next_in = UnsafeMutablePointer(mutating: srcBase)
                stream.avail_in = uInt(source.count)
                stream.next_out = dstBase
                stream.avail_out = uInt(expectedSize)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END || status == Z_OK else {
            throw ExtractError.inflateFailed
        }
        let produced = Int(expectedSize) - Int(stream.avail_out)
        guard produced == Int(expectedSize) else {
            throw ExtractError.inflateFailed
        }
        return output
    }
}

// MARK: - Central directory / local file parsing

private enum CentralDirectory {
    struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
        let isDirectory: Bool
        let isSymlink: Bool
    }

    static func parse(data: Data, limits: SafeZipExtractor.Limits) throws -> [Entry] {
        guard data.count >= 22 else { throw SafeZipExtractor.ExtractError.notAZip }
        guard let eocdOffset = findEOCD(in: data) else {
            throw SafeZipExtractor.ExtractError.notAZip
        }

        let diskEntries = readUInt16(data, eocdOffset + 8)
        let totalEntries = readUInt16(data, eocdOffset + 10)
        let cdSize = Int(readUInt32(data, eocdOffset + 12))
        let cdOffset = Int(readUInt32(data, eocdOffset + 16))
        guard diskEntries == totalEntries else {
            // Split archives are out of scope.
            throw SafeZipExtractor.ExtractError.notAZip
        }
        let entryCount = Int(totalEntries)
        if entryCount > limits.maxEntryCount {
            throw SafeZipExtractor.ExtractError.entryCountExceeded(entryCount)
        }
        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= data.count else {
            throw SafeZipExtractor.ExtractError.truncated
        }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var cursor = cdOffset
        var totalUncompressed: Int64 = 0
        for _ in 0 ..< entryCount {
            guard cursor + 46 <= data.count else {
                throw SafeZipExtractor.ExtractError.truncated
            }
            let sig = readUInt32(data, cursor)
            guard sig == 0x0201_4B50 else {
                throw SafeZipExtractor.ExtractError.notAZip
            }
            let versionMadeBy = readUInt16(data, cursor + 4)
            let compressionMethod = readUInt16(data, cursor + 10)
            let compressedSize = readUInt32(data, cursor + 20)
            let uncompressedSize = readUInt32(data, cursor + 24)
            let nameLen = Int(readUInt16(data, cursor + 28))
            let extraLen = Int(readUInt16(data, cursor + 30))
            let commentLen = Int(readUInt16(data, cursor + 32))
            let externalAttrs = readUInt32(data, cursor + 38)
            let localOffset = readUInt32(data, cursor + 42)
            guard cursor + 46 + nameLen + extraLen + commentLen <= data.count else {
                throw SafeZipExtractor.ExtractError.truncated
            }
            let nameData = data.subdata(in: (cursor + 46) ..< (cursor + 46 + nameLen))
            guard let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
            else {
                throw SafeZipExtractor.ExtractError.unsafePath("")
            }
            _ = try SafeZipExtractor.validateRelativePath(name)

            let hostOS = versionMadeBy >> 8
            let isSymlink = isUnixSymlink(hostOS: hostOS, externalAttrs: externalAttrs)
            if isSymlink {
                throw SafeZipExtractor.ExtractError.symlinkRejected
            }

            let isDirectory = name.hasSuffix("/")
            if !isDirectory {
                totalUncompressed += Int64(uncompressedSize)
                if totalUncompressed > limits.maxUncompressedBytes {
                    throw SafeZipExtractor.ExtractError.uncompressedSizeExceeded(totalUncompressed)
                }
            }

            entries.append(
                Entry(
                    name: name,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localOffset,
                    isDirectory: isDirectory,
                    isSymlink: false
                )
            )
            cursor += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    private static func findEOCD(in data: Data) -> Int? {
        // EOCD is 22 bytes + optional comment (max 65535). Scan from the end.
        let maxScan = min(data.count, 22 + 65535)
        let start = data.count - maxScan
        var i = data.count - 22
        while i >= start {
            if readUInt32(data, i) == 0x0605_4B50 {
                return i
            }
            i -= 1
        }
        return nil
    }

    private static func isUnixSymlink(hostOS: UInt16, externalAttrs: UInt32) -> Bool {
        // Unix (3) / macOS (19): high 16 bits of external attrs are st_mode.
        guard hostOS == 3 || hostOS == 19 else { return false }
        let mode = (externalAttrs >> 16) & 0xFFFF
        let fileType = mode & 0xF000
        return fileType == 0xA000 // S_IFLNK
    }
}

private enum LocalFile {
    static func readPayload(data: Data, entry: CentralDirectory.Entry) throws -> Data {
        let offset = Int(entry.localHeaderOffset)
        guard offset + 30 <= data.count else {
            throw SafeZipExtractor.ExtractError.truncated
        }
        let sig = readUInt32(data, offset)
        guard sig == 0x0403_4B50 else {
            throw SafeZipExtractor.ExtractError.notAZip
        }
        let nameLen = Int(readUInt16(data, offset + 26))
        let extraLen = Int(readUInt16(data, offset + 28))
        let dataStart = offset + 30 + nameLen + extraLen
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= data.count else {
            throw SafeZipExtractor.ExtractError.truncated
        }
        return data.subdata(in: dataStart ..< dataEnd)
    }
}

private func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}
