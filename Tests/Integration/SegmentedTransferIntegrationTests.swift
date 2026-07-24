// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TestFaultService
import TransferCore
import XCTest

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
}
