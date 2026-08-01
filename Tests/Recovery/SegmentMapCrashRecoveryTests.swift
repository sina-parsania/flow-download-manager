// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TestFaultService
import XCTest
@testable import TransferCore

/// Crash boundaries around the segment map, for downloads that skip the range
/// probe (expiring-signature URLs).
///
/// A finished transfer is not atomic: `markCompleted` persists a map with every
/// entry full, then a **full-file `fsync`** runs, then the size is checked, and
/// only then is the sidecar deleted. On a large file on external storage that
/// `fsync` is seconds wide, and anything that kills the process inside it leaves
/// a complete map next to a complete file.
final class SegmentMapCrashRecoveryTests: XCTestCase {
    /// A complete map plus a complete file must be recognised as done — never
    /// deleted and downloaded again.
    ///
    /// The resume path for probe-skipping URLs returns `nil` when there is no
    /// remaining work, and `nil` means "start fresh", which removes the partial.
    /// For this state that would destroy a finished multi-hundred-megabyte
    /// download and re-fetch it in full.
    func testCompletedMapLeftBySuddenExitIsFinishedNotRestarted() throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-rec-segmap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let body = FaultHTTPServer.largeBody
        let total = Int64(body.count)
        let partial = root.appendingPathComponent("done.partial")
        try body.write(to: partial)

        // Exactly the state `markCompleted` persists: every entry full, sidecar
        // not yet deleted.
        let map: [String: Any] = [
            "total": total,
            "baseOffset": 0,
            "entries": [
                ["start": 0, "end": total / 2 - 1, "written": total / 2],
                ["start": total / 2, "end": total - 1, "written": total - total / 2]
            ]
        ]
        let sidecar = SegmentedTransfer.segmentMapURL(for: partial)
        try JSONSerialization.data(withJSONObject: map).write(to: sidecar)

        let outcome = try SegmentedTransfer.downloadHTTP(
            url: "http://127.0.0.1:\(port)/fixtures/signed-ranged?expires=99999999999&sig=deadbeef",
            partialURL: partial
        )

        XCTAssertEqual(outcome.bytesWritten, total)
        XCTAssertEqual(try Data(contentsOf: partial), body)
        XCTAssertEqual(
            server.logs().count, 0,
            "a finished download must not send a single request — any request means it restarted"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sidecar.path),
            "the sidecar must be dropped once completion is confirmed"
        )
    }
}
