// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TestFaultService
import XCTest
@testable import TransferCore

final class SegmentedTransferIntegrationTests: XCTestCase {
    func testTwoSegmentDownloadMatchesFixture() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = root.appendingPathComponent("seg.partial")
        // `/fixtures/ok` is 4 KiB, which `preferredSegmentCount` always tiles to
        // a single range — use the 2 MiB fixture so this really is two segments.
        let url = "http://127.0.0.1:\(port)/fixtures/large"
        let outcome = try SegmentedTransfer.downloadHTTP(url: url, partialURL: partial)
        XCTAssertEqual(outcome.segmentCount, 2)
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.largeBody.count))
        let data = try Data(contentsOf: partial)
        XCTAssertEqual(data, FaultHTTPServer.largeBody)
    }

    /// The global speed limit must actually cap a *segmented* transfer.
    ///
    /// It previously did not cap it at all: the only `SyncBandwidthGovernor` was
    /// built inside `downloadSingleStream`, which the curl_multi transport never
    /// calls — so every download ≥1 MiB ran unthrottled while Settings claimed a
    /// limit was in force. The Dispatch fallback was wrong in the other
    /// direction, building one full-rate bucket per segment.
    func testGlobalSpeedLimitCapsSegmentedTransfer() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The token bucket starts full by design, so the first `cap` bytes are a
        // free burst. Budget for that: payload ≈ 4× cap ⇒ ~3 s of throttled time.
        let total = Int64(FaultHTTPServer.largeBody.count)
        let cap = total / 4
        var options = TransferCore.DownloadOptions()
        options.maxBytesPerSecond = cap

        let partial = root.appendingPathComponent("cap.partial")
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            let outcome = try SegmentedTransfer.downloadHTTP(
                url: "http://127.0.0.1:\(port)/fixtures/large",
                partialURL: partial,
                options: options
            )
            XCTAssertGreaterThan(outcome.segmentCount, 1, "must exercise the segmented path")
        }

        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        // Unthrottled this completes over loopback in well under 0.1 s.
        XCTAssertGreaterThan(
            seconds, 1.0,
            "segmented transfer finished in \(seconds)s — the global speed limit is not being applied"
        )
        XCTAssertEqual(try Data(contentsOf: partial), FaultHTTPServer.largeBody)
    }

    /// Writes a `.segmap` whose first entry is complete and second is untouched.
    ///
    /// Built through `JSONSerialization` rather than string interpolation: an
    /// ETag contains quotes, and a hand-escaped map that fails to decode makes
    /// `SegmentLedger.load` return nil, which silently skips the resume path
    /// entirely — the test would then pass or fail for the wrong reason.
    private func writeSegmap(
        for partial: URL,
        total: Int64,
        half: Int64,
        validator: [String: Any]?
    ) throws {
        var map: [String: Any] = [
            "total": total,
            "baseOffset": 0,
            "entries": [
                ["start": 0, "end": half - 1, "written": half],
                ["start": half, "end": total - 1, "written": 0]
            ]
        ]
        if let validator { map["validator"] = validator }
        let data = try JSONSerialization.data(withJSONObject: map)
        try data.write(to: SegmentedTransfer.segmentMapURL(for: partial))
    }

    /// A partial whose stored validator contradicts the server must be discarded,
    /// not resumed into.
    ///
    /// This is the corruption path that mattered most: before validators were
    /// stored, the only resume check was byte count. A resource that changed but
    /// kept its length was resumed into, so the finished file was half old bytes
    /// and half new ones — exactly the right size, passing every later check, and
    /// wrong. On a link that drops often, resumes are the common case.
    ///
    /// The partial here is filled with `0xFF`, which appears nowhere in the
    /// fixture, so any surviving byte of it is detectable in the result.
    func testResumeDiscardsPartialWhenValidatorContradictsServer() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let total = Int64(FaultHTTPServer.largeBody.count)
        let partial = root.appendingPathComponent("stale.partial")
        let half = total / 2

        // A full-size partial of bytes that are definitely not the fixture.
        try Data(repeating: 0xFF, count: Int(total)).write(to: partial)

        // A map claiming the first half is already downloaded, stamped with an
        // ETag the server will not agree with.
        try writeSegmap(
            for: partial,
            total: total,
            half: half,
            validator: ["etag": "\"stale-not-the-server-tag\"", "totalBytes": total]
        )
        // Prove the map is loadable before relying on the resume path at all: a
        // map that fails to decode makes load() return nil, which silently skips
        // resume entirely and would make this test pass for the wrong reason.
        let staged = SegmentLedger.load(sidecarURL: SegmentedTransfer.segmentMapURL(for: partial))
        XCTAssertNotNil(staged, "staged segmap did not decode")
        XCTAssertEqual(staged?.validator?.etag, "\"stale-not-the-server-tag\"")

        let outcome = try SegmentedTransfer.downloadHTTP(
            url: "http://127.0.0.1:\(port)/fixtures/large",
            partialURL: partial
        )

        XCTAssertEqual(outcome.bytesWritten, total)
        let written = try Data(contentsOf: partial)
        XCTAssertEqual(
            written, FaultHTTPServer.largeBody,
            "stale partial was stitched into the result instead of being discarded"
        )
        XCTAssertFalse(
            written.prefix(Int(half)).contains(0xFF),
            "bytes from the discarded partial survived into the finished file"
        )
    }

    /// A map written before validators existed has none. Absence is not
    /// contradiction — refusing to resume those would throw away every partial
    /// left by an older build.
    func testResumeStillWorksForAMapWithNoValidator() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let total = Int64(FaultHTTPServer.largeBody.count)
        let partial = root.appendingPathComponent("legacy.partial")
        let half = Int(total / 2)

        // First half genuinely correct, rest not yet fetched.
        var seeded = FaultHTTPServer.largeBody.prefix(half)
        seeded.append(Data(repeating: 0, count: Int(total) - half))
        try Data(seeded).write(to: partial)

        try writeSegmap(for: partial, total: total, half: Int64(half), validator: nil)

        let outcome = try SegmentedTransfer.downloadHTTP(
            url: "http://127.0.0.1:\(port)/fixtures/large",
            partialURL: partial
        )

        XCTAssertEqual(outcome.bytesWritten, total)
        XCTAssertEqual(try Data(contentsOf: partial), FaultHTTPServer.largeBody)
    }
}
