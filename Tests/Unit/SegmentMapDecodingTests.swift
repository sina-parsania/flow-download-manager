// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import TransferCore

/// `.segmap` decoding.
///
/// `SegmentLedger.load` returns nil for anything it cannot decode, and the caller
/// treats nil as "no resume information" and silently starts over. That makes a
/// decoding regression invisible: no error, no log, just a download that quietly
/// restarts from zero. These pin the on-disk shape.
final class SegmentMapDecodingTests: XCTestCase {
    private let total: Int64 = 2_097_152

    private func write(_ map: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-map-\(UUID().uuidString).segmap")
        try JSONSerialization.data(withJSONObject: map).write(to: url)
        return url
    }

    private func entries(half: Int64) -> [[String: Any]] {
        [
            ["start": 0, "end": half - 1, "written": half],
            ["start": half, "end": total - 1, "written": 0]
        ]
    }

    /// A map written by an older build has no `validator` key at all.
    func testDecodesMapWithoutValidator() throws {
        let url = try write([
            "total": total,
            "baseOffset": 0,
            "entries": entries(half: total / 2)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let ledger = SegmentLedger.load(sidecarURL: url)
        XCTAssertNotNil(ledger, "a pre-validator map must still resume")
        XCTAssertNil(ledger?.validator)
        XCTAssertEqual(ledger?.total, total)
    }

    /// The shape the current build writes.
    func testDecodesMapWithFullValidator() throws {
        let url = try write([
            "total": total,
            "baseOffset": 0,
            "entries": entries(half: total / 2),
            "validator": [
                "etag": "\"abc\"",
                "lastModified": "Mon, 01 Jan 2024 00:00:00 GMT",
                "totalBytes": total
            ]
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let ledger = SegmentLedger.load(sidecarURL: url)
        XCTAssertNotNil(ledger)
        XCTAssertEqual(ledger?.validator?.etag, "\"abc\"")
        XCTAssertEqual(ledger?.validator?.totalBytes, total)
    }

    /// Servers commonly send an ETag and no `Last-Modified`, so the key is absent
    /// from the validator we persist. An optional field must decode from a missing
    /// key, not fail the whole map.
    func testDecodesValidatorWithMissingOptionalField() throws {
        let url = try write([
            "total": total,
            "baseOffset": 0,
            "entries": entries(half: total / 2),
            "validator": ["etag": "\"abc\"", "totalBytes": total]
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let ledger = SegmentLedger.load(sidecarURL: url)
        XCTAssertNotNil(ledger, "a validator without lastModified must still decode")
        XCTAssertEqual(ledger?.validator?.etag, "\"abc\"")
        XCTAssertNil(ledger?.validator?.lastModified)
    }

    /// Round-trips what the ledger itself writes, so the reader and writer cannot
    /// drift apart.
    func testRoundTripsWhatTheLedgerWrites() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-map-rt-\(UUID().uuidString).segmap")
        defer { try? FileManager.default.removeItem(at: url) }

        let written = SegmentLedger(
            total: total,
            baseOffset: 0,
            entries: [SegmentLedger.Entry(start: 0, end: total - 1, written: 128)],
            sidecarURL: url,
            validator: ResourceValidator(
                etag: "\"rt\"", lastModified: nil, totalBytes: total
            )
        )
        try written.saveNow()

        let reloaded = SegmentLedger.load(sidecarURL: url)
        XCTAssertEqual(reloaded?.total, total)
        XCTAssertEqual(reloaded?.validator?.etag, "\"rt\"")
        XCTAssertEqual(reloaded?.downloadedBytes(), 128)
    }
}
