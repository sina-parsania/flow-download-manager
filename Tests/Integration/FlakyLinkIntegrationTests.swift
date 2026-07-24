// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TestFaultService
import XCTest
@testable import TransferCore

/// Behaviour on a link that drops mid-transfer.
///
/// This is the acceptance suite for the resilience work. The engine previously
/// allowed three failures for an *entire job*, so a multi-gigabyte download over
/// a link that hiccups every few minutes could never finish. Budget is now spent
/// on stalls rather than errors: a pass that moved bytes proves the link works,
/// however many individual ranges dropped.
final class FlakyLinkIntegrationTests: XCTestCase {
    private func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func body(size: Int) -> Data {
        Data((0 ..< size).map { UInt8($0 % 251) })
    }

    /// The headline case: several connections hang up mid-body, and the download
    /// still completes with byte-exact content.
    func testDownloadCompletesDespiteRepeatedMidTransferDrops() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = try makeRoot("flaky")
        defer { try? FileManager.default.removeItem(at: root) }

        let size = 2 * 1024 * 1024
        let partial = root.appendingPathComponent("flaky.partial")
        let outcome = try SegmentedTransfer.downloadHTTP(
            url: "http://127.0.0.1:\(port)/fixtures/flaky?size=\(size)&drops=6",
            partialURL: partial
        )

        XCTAssertEqual(outcome.bytesWritten, Int64(size))
        XCTAssertEqual(
            try Data(contentsOf: partial), body(size: size),
            "content differs — dropped connections corrupted the assembled file"
        )
    }

    /// Bytes that arrived before a drop must survive it. If every drop restarted
    /// its range from zero, a link that drops often would make no net progress —
    /// the classic "download resets to 0%" failure.
    func testBytesSurviveDropsRatherThanRestartingFromZero() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = try makeRoot("flaky-progress")
        defer { try? FileManager.default.removeItem(at: root) }

        let size = 2 * 1024 * 1024
        let partial = root.appendingPathComponent("progress.partial")

        // Progress is reported as a cumulative total. It must never go backwards
        // across a drop, and it must reach the full size.
        let observed = ProgressRecorder()
        _ = try SegmentedTransfer.downloadHTTP(
            url: "http://127.0.0.1:\(port)/fixtures/flaky?size=\(size)&drops=4",
            partialURL: partial,
            onProgress: { bytes, _ in observed.record(bytes) }
        )

        XCTAssertFalse(observed.wentBackwards, "reported progress regressed after a drop")
        XCTAssertEqual(observed.peak, Int64(size))
        XCTAssertEqual(try Data(contentsOf: partial), body(size: size))
    }

    /// A resume after a drop must still refuse a partial whose validator no
    /// longer matches — resilience must not weaken the identity check, since a
    /// flaky link is exactly where resumes are most frequent.
    func testResilienceDoesNotWeakenTheValidatorCheck() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = try makeRoot("flaky-validator")
        defer { try? FileManager.default.removeItem(at: root) }

        let size = 2 * 1024 * 1024
        let partial = root.appendingPathComponent("validator.partial")
        try Data(repeating: 0xFF, count: size).write(to: partial)

        let half = Int64(size / 2)
        let map: [String: Any] = [
            "total": Int64(size),
            "baseOffset": 0,
            "entries": [
                ["start": 0, "end": half - 1, "written": half],
                ["start": half, "end": Int64(size) - 1, "written": 0]
            ],
            "validator": ["etag": "\"gone\"", "totalBytes": Int64(size)]
        ]
        try JSONSerialization.data(withJSONObject: map)
            .write(to: SegmentedTransfer.segmentMapURL(for: partial))

        _ = try SegmentedTransfer.downloadHTTP(
            url: "http://127.0.0.1:\(port)/fixtures/flaky?size=\(size)&drops=3",
            partialURL: partial
        )

        let written = try Data(contentsOf: partial)
        XCTAssertEqual(written, body(size: size))
        XCTAssertFalse(
            written.prefix(Int(half)).contains(0xFF),
            "stale bytes survived a resume that also had to survive drops"
        )
    }
}

/// Records cumulative progress from the transfer's callback thread.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = 0
    private(set) var wentBackwards = false
    private(set) var peak: Int64 = 0

    func record(_ bytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if bytes < last { wentBackwards = true }
        last = bytes
        peak = max(peak, bytes)
    }
}
