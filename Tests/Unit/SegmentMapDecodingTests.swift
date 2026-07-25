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

    private func writeMap(
        baseOffset: Int64 = 0,
        entries: [[String: Any]],
        validator: [String: Any]? = nil
    ) throws -> URL {
        var map: [String: Any] = [
            "total": total,
            "baseOffset": baseOffset,
            "entries": entries
        ]
        if let validator { map["validator"] = validator }
        return try write(map)
    }

    private func assertLoadRejects(_ url: URL) throws {
        let before = try Data(contentsOf: url)
        XCTAssertNil(SegmentLedger.load(sidecarURL: url))
        XCTAssertEqual(try Data(contentsOf: url), before, "load must not rewrite the sidecar")
    }

    private func contiguousEntries(
        from start: Int64,
        through end: Int64,
        written: Int64? = nil
    ) -> [[String: Any]] {
        let span = end - start + 1
        return [["start": start, "end": end, "written": written ?? span]]
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

    func testRejectsGapBetweenEntries() throws {
        let half = total / 2
        let gapStart = half + 1024
        let url = try writeMap(entries: [
            ["start": 0, "end": half - 1, "written": half],
            ["start": gapStart, "end": total - 1, "written": total - gapStart]
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        try assertLoadRejects(url)
    }

    func testRejectsOverlappingEntries() throws {
        let half = total / 2
        let url = try writeMap(entries: [
            ["start": 0, "end": half, "written": half + 1],
            ["start": half, "end": total - 1, "written": 0]
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        try assertLoadRejects(url)
    }

    func testRejectsDuplicateInterval() throws {
        let half = total / 2
        let url = try writeMap(entries: [
            ["start": 0, "end": half - 1, "written": half],
            ["start": 0, "end": half - 1, "written": 0],
            ["start": half, "end": total - 1, "written": 0]
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        try assertLoadRejects(url)
    }

    func testRejectsUnsortedEntries() throws {
        let half = total / 2
        let url = try writeMap(entries: [
            ["start": half, "end": total - 1, "written": 0],
            ["start": 0, "end": half - 1, "written": half]
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        try assertLoadRejects(url)
    }

    func testRejectsFirstEntryBeforeBaseOffset() throws {
        let base: Int64 = 65536
        let url = try writeMap(
            baseOffset: base,
            entries: contiguousEntries(from: 0, through: total - 1)
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try assertLoadRejects(url)
    }

    func testRejectsFirstEntryAfterBaseOffset() throws {
        let base: Int64 = 65536
        let url = try writeMap(
            baseOffset: base,
            entries: contiguousEntries(from: base + 1, through: total - 1)
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try assertLoadRejects(url)
    }

    func testRejectsFinalEntryBeforeTotalMinusOne() throws {
        let url = try writeMap(entries: contiguousEntries(from: 0, through: total - 2))
        defer { try? FileManager.default.removeItem(at: url) }
        try assertLoadRejects(url)
    }

    func testRejectsBaseOffsetGreaterThanOrEqualToTotal() throws {
        let url = try writeMap(
            baseOffset: total,
            entries: contiguousEntries(from: total, through: total - 1)
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try assertLoadRejects(url)
    }

    func testAcceptsValidLegacyMapWithoutValidator() throws {
        let url = try writeMap(entries: entries(half: total / 2))
        defer { try? FileManager.default.removeItem(at: url) }

        let ledger = SegmentLedger.load(sidecarURL: url)
        XCTAssertNotNil(ledger, "valid legacy coverage must still resume")
        XCTAssertNil(ledger?.validator)
        XCTAssertEqual(ledger?.total, total)
        XCTAssertEqual(ledger?.baseOffset, 0)
    }
}
