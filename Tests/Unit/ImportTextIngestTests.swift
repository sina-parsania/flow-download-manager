// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import XCTest

final class ImportTextIngestTests: XCTestCase {
    func testIsImportableAcceptsTxtCsvAndExtensionless() throws {
        let txt = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-import-\(UUID().uuidString).txt")
        let csv = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-import-\(UUID().uuidString).csv")
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-import-\(UUID().uuidString)")
        let bin = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-import-\(UUID().uuidString).bin")
        defer {
            try? FileManager.default.removeItem(at: txt)
            try? FileManager.default.removeItem(at: csv)
            try? FileManager.default.removeItem(at: bare)
            try? FileManager.default.removeItem(at: bin)
        }

        XCTAssertTrue(ImportTextIngest.isImportableFile(txt))
        XCTAssertTrue(ImportTextIngest.isImportableFile(csv))
        XCTAssertTrue(ImportTextIngest.isImportableFile(bare))
        XCTAssertFalse(ImportTextIngest.isImportableFile(bin))

        let remote = try XCTUnwrap(URL(string: "https://example.test/list.txt"))
        XCTAssertFalse(ImportTextIngest.isImportableFile(remote))
    }

    func testReadTextDecodesUTF8AndRejectsOversized() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-import-read-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = "https://cdn.example.test/a.bin\nhttps://cdn.example.test/b.bin\n"
        try Data(payload.utf8).write(to: url)
        XCTAssertEqual(try ImportTextIngest.readText(from: url), payload)

        XCTAssertThrowsError(
            try ImportTextIngest.readText(from: url, maxBytes: 8)
        ) { error in
            XCTAssertEqual(error as? ImportTextIngest.ReadError, .exceedsSizeLimit)
        }
    }
}
