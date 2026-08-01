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

    /// A structurally invalid map must not let a preallocated shell reach the
    /// size-only completion path. The caller should surface a recoverable error
    /// and leave both the partial and the invalid sidecar on disk.
    func testInvalidSegmapCannotCompletePreallocatedShell() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let total = Int64(FaultHTTPServer.largeBody.count)
        let partial = root.appendingPathComponent("gap.partial")
        let half = total / 2
        let gapStart = half + 1024

        try Data(repeating: 0xA5, count: Int(total)).write(to: partial)

        let map: [String: Any] = [
            "total": total,
            "baseOffset": 0,
            "entries": [
                ["start": 0, "end": half - 1, "written": half],
                ["start": gapStart, "end": total - 1, "written": total - gapStart]
            ]
        ]
        let segmapURL = SegmentedTransfer.segmentMapURL(for: partial)
        try JSONSerialization.data(withJSONObject: map).write(to: segmapURL)
        let partialBefore = try Data(contentsOf: partial)
        let segmapBefore = try Data(contentsOf: segmapURL)

        XCTAssertNil(
            SegmentLedger.load(sidecarURL: segmapURL),
            "gap map must not load — old code treated it as complete"
        )

        XCTAssertThrowsError(
            try SegmentedTransfer.downloadHTTP(
                url: "http://127.0.0.1:\(port)/fixtures/large",
                partialURL: partial
            )
        ) { error in
            guard case TransferCore.TransferError.incompleteWrite = error else {
                XCTFail("expected incompleteWrite, got \(error)")
                return
            }
        }

        XCTAssertEqual(try Data(contentsOf: partial), partialBefore)
        XCTAssertEqual(try Data(contentsOf: segmapURL), segmapBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: segmapURL.path))
    }

    /// Range probe returns 403, plain GET returns 200.
    ///
    /// Before the fallback, `probeRangeSupport` threw and the job never tried a
    /// full GET — hosts that reject ranged probes looked permanently broken.
    func testRangeForbiddenProbeFallsBackToSingleStream() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-range-forbidden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = root.appendingPathComponent("range-forbidden.partial")
        let outcome = try SegmentedTransfer.downloadHTTP(
            url: "http://127.0.0.1:\(port)/fixtures/range-forbidden",
            partialURL: partial
        )
        XCTAssertEqual(outcome.segmentCount, 1)
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.fixtureBody.count))
        XCTAssertEqual(try Data(contentsOf: partial), FaultHTTPServer.fixtureBody)
    }

    /// One-shot signed URL: a Cookie-bearing job must not Range-probe first.
    ///
    /// The probe used to download the whole body (hosts that ignore Range), burn
    /// the token, then fail the real transfer with 403.
    func testCookieJobSkipsProbeOnOneShotURL() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-once-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var options = TransferCore.DownloadOptions()
        options.extraHeaders = [
            TransferCore.HTTPHeader(name: "Cookie", value: "session=test")
        ]
        let partial = root.appendingPathComponent("once.partial")
        let outcome = try SegmentedTransfer.downloadHTTP(
            url: "http://127.0.0.1:\(port)/fixtures/once",
            partialURL: partial,
            options: options
        )
        XCTAssertEqual(outcome.segmentCount, 1)
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.fixtureBody.count))
        XCTAssertEqual(try Data(contentsOf: partial), FaultHTTPServer.fixtureBody)
    }

    /// Fragile `sig=` query skips the probe entirely (no Range request at all).
    func testFragileSignedQuerySkipsProbeOnOneShotURL() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-sig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = root.appendingPathComponent("sig.partial")
        let outcome = try SegmentedTransfer.downloadHTTP(
            url: "http://127.0.0.1:\(port)/fixtures/once?sig=abc123&ts=1",
            partialURL: partial
        )
        XCTAssertEqual(outcome.segmentCount, 1)
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.fixtureBody.count))
        XCTAssertEqual(try Data(contentsOf: partial), FaultHTTPServer.fixtureBody)
    }

    /// One-shot without Cookie/`sig`: Range probe is rejected without consuming
    /// the token, then the plain GET succeeds.
    func testOneShotSurvivesRejectedRangeProbe() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-once-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = root.appendingPathComponent("once-fallback.partial")
        let outcome = try SegmentedTransfer.downloadHTTP(
            url: "http://127.0.0.1:\(port)/fixtures/once",
            partialURL: partial
        )
        XCTAssertEqual(outcome.segmentCount, 1)
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.fixtureBody.count))
        XCTAssertEqual(try Data(contentsOf: partial), FaultHTTPServer.fixtureBody)
    }

    /// AWS-shaped signed query must still multi-segment (speed path).
    func testAWSSignedQueryStillSegments() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-aws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = root.appendingPathComponent("aws.partial")
        let outcome = try SegmentedTransfer.downloadHTTP(
            url: "http://127.0.0.1:\(port)/fixtures/large?X-Amz-Signature=test&X-Amz-Algorithm=AWS4-HMAC-SHA256",
            partialURL: partial
        )
        XCTAssertEqual(outcome.segmentCount, 2)
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.largeBody.count))
        XCTAssertEqual(try Data(contentsOf: partial), FaultHTTPServer.largeBody)
    }

    /// A 200 answer to the `Range: 0-0` probe must not disable segmentation.
    ///
    /// CDNs ignore Range on a cache miss and honour it on a hit — measured on one
    /// Cloudflare URL seconds apart. Reading the probe's 200 as "no ranges" pinned
    /// the download to a single connection for its whole life, which on a
    /// high-latency link is ~1 MB/s instead of ~10 MB/s.
    func testProbe200StillSegmentsWhenRealRangesAreHonoured() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-probe200-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = root.appendingPathComponent("probe200.partial")
        let outcome = try SegmentedTransfer.downloadHTTP(
            url: "http://127.0.0.1:\(port)/fixtures/probe-200-ranges-ok",
            partialURL: partial
        )

        XCTAssertGreaterThan(
            outcome.segmentCount, 1,
            "a 200 probe on a range-capable host must still segment"
        )
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.largeBody.count))
        XCTAssertEqual(try Data(contentsOf: partial), FaultHTTPServer.largeBody)
    }

    /// The user-reported defect: an expiring-signature URL was pinned to one
    /// connection forever.
    ///
    /// `?expires=&sig=` makes `shouldSkipProbe` true, which used to mean
    /// `singleOutcome` unconditionally. The host honours ranges perfectly — an
    /// expiring signature is re-fetchable until it expires — so the opening chunk
    /// now doubles as the probe and the remainder runs in parallel.
    func testExpiringSignedURLStillSegments() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-signed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = "http://127.0.0.1:\(port)/fixtures/signed-ranged?expires=99999999999&sig=deadbeef"
        XCTAssertTrue(
            RangeProbePolicy.shouldSkipProbe(url: url, options: TransferCore.DownloadOptions()),
            "fixture must exercise the probe-skipping path"
        )

        let partial = root.appendingPathComponent("signed.partial")
        let outcome = try SegmentedTransfer.downloadHTTP(url: url, partialURL: partial)

        XCTAssertGreaterThan(
            outcome.segmentCount, 1,
            "an expiring signature is not a one-shot token — it must still segment"
        )
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.largeBody.count))
        XCTAssertEqual(try Data(contentsOf: partial), FaultHTTPServer.largeBody)
    }

    // MARK: resume for probe-skipping (expiring-signature) URLs

    private func signedURL(port: UInt16, path: String) -> String {
        "http://127.0.0.1:\(port)\(path)?expires=99999999999&sig=deadbeef"
    }

    /// An interrupted signed download must resume, not restart.
    ///
    /// These URLs used to restart from zero on every attempt — the probe-skipping
    /// branch sat ahead of the segment-map resume and `singleOutcome` truncates.
    /// On a multi-hundred-megabyte file over a lossy link that is eight full
    /// restarts before the job gives up.
    func testSignedURLResumesFromSegmentMap() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-signed-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let total = Int64(FaultHTTPServer.largeBody.count)
        let half = total / 2
        let partial = root.appendingPathComponent("signed-resume.partial")

        var seeded = FaultHTTPServer.largeBody.prefix(Int(half))
        seeded.append(Data(repeating: 0, count: Int(total - half)))
        try Data(seeded).write(to: partial)
        try writeSegmap(for: partial, total: total, half: half, validator: nil)

        let outcome = try SegmentedTransfer.downloadHTTP(
            url: signedURL(port: port, path: "/fixtures/signed-ranged"),
            partialURL: partial
        )

        XCTAssertEqual(outcome.bytesWritten, total)
        XCTAssertEqual(try Data(contentsOf: partial), FaultHTTPServer.largeBody)
        // Request count is what separates resume from restart here, since both
        // issue only ranged GETs and both end with correct bytes. The map has one
        // incomplete entry, so a resume fetches exactly it: **1** request. A
        // restart would spend one on the opening chunk and then re-tile the
        // remaining 1 MiB into two more: 3.
        XCTAssertEqual(
            server.logs().count, 1,
            "expected a single ranged GET for the one incomplete entry; more means it restarted"
        )
    }

    /// A signed URL whose resource changed must be discarded, not stitched.
    ///
    /// The validator arrives on the *first chunk the map still needs*, so the
    /// comparison happens after those bytes are on disk — the wipe therefore has
    /// to take the freshly written chunk with it.
    func testSignedURLResumeDiscardsPartialWhenValidatorContradictsServer() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-signed-etag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let total = Int64(FaultHTTPServer.largeBody.count)
        let half = total / 2
        let partial = root.appendingPathComponent("signed-etag.partial")

        // 0xFF appears nowhere in the fixture, so any surviving byte is visible.
        var seeded = Data(repeating: 0xFF, count: Int(half))
        seeded.append(Data(repeating: 0, count: Int(total - half)))
        try seeded.write(to: partial)
        try writeSegmap(
            for: partial, total: total, half: half,
            validator: ["etag": "\"stale-version\"", "totalBytes": total]
        )

        let outcome = try SegmentedTransfer.downloadHTTP(
            url: signedURL(port: port, path: "/fixtures/signed-ranged"),
            partialURL: partial
        )

        XCTAssertEqual(outcome.bytesWritten, total)
        XCTAssertEqual(
            try Data(contentsOf: partial), FaultHTTPServer.largeBody,
            "a contradicted partial must be discarded, not resumed into"
        )
    }

    /// A transient failure on the validating chunk must NOT wipe the partial.
    ///
    /// This is the rule the repo has been burned by: the network being down at
    /// relaunch is not evidence the bytes on disk are wrong. The error has to
    /// propagate so the job's retry path keeps them.
    func testSignedURLResumeKeepsPartialWhenValidatorRequestFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-signed-transient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let total = Int64(FaultHTTPServer.largeBody.count)
        let half = total / 2
        let partial = root.appendingPathComponent("signed-transient.partial")

        var seeded = FaultHTTPServer.largeBody.prefix(Int(half))
        seeded.append(Data(repeating: 0, count: Int(total - half)))
        try Data(seeded).write(to: partial)
        try writeSegmap(for: partial, total: total, half: half, validator: nil)

        let sidecar = SegmentedTransfer.segmentMapURL(for: partial)
        // Port 1 refuses immediately: a connection failure, not a verdict.
        XCTAssertThrowsError(
            try SegmentedTransfer.downloadHTTP(
                url: "http://127.0.0.1:1/fixtures/signed-ranged?expires=99999999999&sig=deadbeef",
                partialURL: partial
            )
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: partial.path),
            "a transient failure must never wipe the partial"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sidecar.path),
            "the segment map must survive with it — the partial is meaningless alone"
        )
        XCTAssertEqual(fileByteCount(partial), total)
    }

    private func fileByteCount(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? -1
    }

    /// A remainder that tiles to ONE connection is still a remainder.
    ///
    /// 1.5 MiB: the 1 MiB opening chunk leaves 0.5 MiB, which is below
    /// `preferredSegmentCount`'s 1 MiB floor and so tiles to a single connection.
    /// Treating that as "not worth segmenting" and returning early reported the
    /// file complete at 1 MiB — a silently truncated download that every
    /// downstream size check would then have accepted.
    func testOpeningChunkFinishesARemainderTooSmallToSplit() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-awkward-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = "http://127.0.0.1:\(port)/fixtures/signed-ranged-awkward?expires=99999999999&sig=deadbeef"
        let partial = root.appendingPathComponent("awkward.partial")
        let outcome = try SegmentedTransfer.downloadHTTP(url: url, partialURL: partial)

        XCTAssertEqual(
            outcome.bytesWritten, Int64(FaultHTTPServer.awkwardRemainderBody.count),
            "the sub-1 MiB tail must still be downloaded, not declared done"
        )
        XCTAssertEqual(try Data(contentsOf: partial), FaultHTTPServer.awkwardRemainderBody)
    }

    /// The safety half: a probe-skipping URL whose host ignores Range must keep the
    /// full body from that same first request — one request, no wasted token.
    func testProbeSkippingURLKeepsFullBodyWhenHostIgnoresRange() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-signed-norange-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = "http://127.0.0.1:\(port)/fixtures/no-range-large?expires=99999999999&sig=deadbeef"
        let partial = root.appendingPathComponent("signed-norange.partial")
        let outcome = try SegmentedTransfer.downloadHTTP(url: url, partialURL: partial)

        XCTAssertEqual(outcome.segmentCount, 1)
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.largeBody.count))
        XCTAssertEqual(try Data(contentsOf: partial), FaultHTTPServer.largeBody)
    }

    /// The other half of the same change: a host that ignores Range on the real
    /// GETs too must fall back to a single stream, deliver correct bytes, and
    /// leave no segment map behind for a later resume to trust.
    func testRangeIgnoringHostFallsBackCleanlyAfterSegmentAttempt() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-seg-norange-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = root.appendingPathComponent("norange.partial")
        let outcome = try SegmentedTransfer.downloadHTTP(
            url: "http://127.0.0.1:\(port)/fixtures/no-range-large",
            partialURL: partial
        )

        XCTAssertEqual(outcome.segmentCount, 1)
        XCTAssertEqual(outcome.bytesWritten, Int64(FaultHTTPServer.largeBody.count))
        XCTAssertEqual(try Data(contentsOf: partial), FaultHTTPServer.largeBody)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: SegmentedTransfer.segmentMapURL(for: partial).path
            ),
            "a preallocated shell's segment map must not survive the fallback"
        )
    }
}
