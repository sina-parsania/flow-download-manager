// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TransferCore
import XCTest

final class SafeZipExtractorTests: XCTestCase {
    func testExtractsStoredZipEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = root.appendingPathComponent("sample.zip")
        let payload = Data("hello-zip".utf8)
        try ZipFixture.writeStoredArchive(
            to: archive,
            entries: [("readme.txt", payload, isSymlink: false)]
        )

        let dest = root.appendingPathComponent("out", isDirectory: true)
        try SafeZipExtractor.extract(archiveURL: archive, destinationDirectory: dest)
        let extracted = try Data(contentsOf: dest.appendingPathComponent("readme.txt"))
        XCTAssertEqual(extracted, payload)
    }

    func testRejectsPathTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-zip-trav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = root.appendingPathComponent("evil.zip")
        try ZipFixture.writeStoredArchive(
            to: archive,
            entries: [("../escape.txt", Data("x".utf8), isSymlink: false)]
        )
        let dest = root.appendingPathComponent("out", isDirectory: true)
        XCTAssertThrowsError(
            try SafeZipExtractor.extract(archiveURL: archive, destinationDirectory: dest)
        ) { error in
            guard case SafeZipExtractor.ExtractError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }
    }

    func testRejectsAbsolutePath() throws {
        XCTAssertThrowsError(try SafeZipExtractor.validateRelativePath("/etc/passwd")) { error in
            guard case SafeZipExtractor.ExtractError.unsafePath = error else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }
    }

    func testRejectsUnixSymlinkEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-zip-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = root.appendingPathComponent("link.zip")
        try ZipFixture.writeStoredArchive(
            to: archive,
            entries: [("link-name", Data("/tmp/target".utf8), isSymlink: true)]
        )
        let dest = root.appendingPathComponent("out", isDirectory: true)
        XCTAssertThrowsError(
            try SafeZipExtractor.extract(archiveURL: archive, destinationDirectory: dest)
        ) { error in
            XCTAssertEqual(error as? SafeZipExtractor.ExtractError, .symlinkRejected)
        }
    }

    func testEntryCountLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-zip-count-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = root.appendingPathComponent("many.zip")
        let entries: [(String, Data, Bool)] = (0 ..< 3).map { i in
            ("f\(i).txt", Data("\(i)".utf8), false)
        }
        try ZipFixture.writeStoredArchive(to: archive, entries: entries)
        let dest = root.appendingPathComponent("out", isDirectory: true)
        XCTAssertThrowsError(
            try SafeZipExtractor.extract(
                archiveURL: archive,
                destinationDirectory: dest,
                limits: SafeZipExtractor.Limits(maxUncompressedBytes: 1024, maxEntryCount: 2)
            )
        ) { error in
            guard case SafeZipExtractor.ExtractError.entryCountExceeded = error else {
                return XCTFail("expected entryCountExceeded, got \(error)")
            }
        }
    }
}

/// Minimal STORED-method ZIP writer for fixtures (no external deps).
private enum ZipFixture {
    static func writeStoredArchive(
        to url: URL,
        entries: [(name: String, data: Data, isSymlink: Bool)]
    ) throws {
        var localChunks: [Data] = []
        var centralChunks: [Data] = []
        var offset: UInt32 = 0

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            var local = Data()
            appendUInt32(&local, 0x0403_4B50) // local file header
            appendUInt16(&local, 20) // version needed
            appendUInt16(&local, 0) // flags
            appendUInt16(&local, 0) // stored
            appendUInt16(&local, 0) // time
            appendUInt16(&local, 0) // date
            let crc = crc32(entry.data)
            appendUInt32(&local, crc)
            appendUInt32(&local, UInt32(entry.data.count))
            appendUInt32(&local, UInt32(entry.data.count))
            appendUInt16(&local, UInt16(nameData.count))
            appendUInt16(&local, 0) // extra
            local.append(nameData)
            local.append(entry.data)
            localChunks.append(local)

            var central = Data()
            appendUInt32(&central, 0x0201_4B50)
            // version made by: Unix (3) << 8 | 20
            appendUInt16(&central, (3 << 8) | 20)
            appendUInt16(&central, 20) // version needed
            appendUInt16(&central, 0) // flags
            appendUInt16(&central, 0) // stored
            appendUInt16(&central, 0)
            appendUInt16(&central, 0)
            appendUInt32(&central, crc)
            appendUInt32(&central, UInt32(entry.data.count))
            appendUInt32(&central, UInt32(entry.data.count))
            appendUInt16(&central, UInt16(nameData.count))
            appendUInt16(&central, 0) // extra
            appendUInt16(&central, 0) // comment
            appendUInt16(&central, 0) // disk start
            appendUInt16(&central, 0) // internal attrs
            let mode: UInt32 = entry.isSymlink ? 0xA000 : 0x8000 // S_IFLNK : S_IFREG
            let external = (mode | 0o644) << 16
            appendUInt32(&central, external)
            appendUInt32(&central, offset)
            central.append(nameData)
            centralChunks.append(central)

            offset += UInt32(local.count)
        }

        var archive = Data()
        for chunk in localChunks {
            archive.append(chunk)
        }
        let cdOffset = UInt32(archive.count)
        var cdSize: UInt32 = 0
        for chunk in centralChunks {
            archive.append(chunk)
            cdSize += UInt32(chunk.count)
        }
        // EOCD
        appendUInt32(&archive, 0x0605_4B50)
        appendUInt16(&archive, 0)
        appendUInt16(&archive, 0)
        appendUInt16(&archive, UInt16(entries.count))
        appendUInt16(&archive, UInt16(entries.count))
        appendUInt32(&archive, cdSize)
        appendUInt32(&archive, cdOffset)
        appendUInt16(&archive, 0) // comment length
        try archive.write(to: url)
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return ~crc
    }
}
