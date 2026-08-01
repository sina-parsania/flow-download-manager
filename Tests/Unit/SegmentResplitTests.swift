// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import TransferCore

/// `resplit` runs on the recovery path — a stalled pass halves the connection
/// limit and re-splits the tail so the leftover bytes regain parallelism. It also
/// persists the map it produces, so whatever it builds has to survive a reload:
/// `SegmentLedger.load` rejects any map whose entries are not contiguous and
/// ascending, and a rejected map means the resume is skipped entirely.
final class SegmentResplitTests: XCTestCase {
    private func tempSidecar() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-resplit-\(UUID().uuidString).partial.segmap")
    }

    /// Splitting a middle entry must keep the map reloadable.
    ///
    /// This is the shape a stall actually produces: connections finish out of
    /// order, so the one big incomplete entry left at the tail is rarely the last
    /// one in the array.
    func testResplitOfAMiddleEntryProducesAReloadableMap() {
        let sidecar = tempSidecar()
        defer { try? FileManager.default.removeItem(at: sidecar) }

        let chunk: Int64 = 16 * 1024 * 1024
        let total = chunk * 3
        // Middle entry untouched and large; first and last already complete.
        let ledger = SegmentLedger(
            total: total,
            baseOffset: 0,
            entries: [
                SegmentLedger.Entry(start: 0, end: chunk - 1, written: chunk),
                SegmentLedger.Entry(start: chunk, end: 2 * chunk - 1, written: 0),
                SegmentLedger.Entry(start: 2 * chunk, end: total - 1, written: chunk)
            ],
            sidecarURL: sidecar,
            validator: nil
        )

        ledger.resplit(targetCount: 4)

        XCTAssertNotNil(
            SegmentLedger.load(sidecarURL: sidecar),
            "resplit persisted a map that load() rejects — the next run silently "
                + "loses the resume and restarts from zero"
        )
    }

    /// The bytes must still add up after a split: same total, same completed
    /// count, and full coverage of the range.
    func testResplitPreservesCoverageAndProgress() throws {
        let sidecar = tempSidecar()
        defer { try? FileManager.default.removeItem(at: sidecar) }

        let chunk: Int64 = 16 * 1024 * 1024
        let total = chunk * 3
        let ledger = SegmentLedger(
            total: total,
            baseOffset: 0,
            entries: [
                SegmentLedger.Entry(start: 0, end: chunk - 1, written: chunk),
                SegmentLedger.Entry(start: chunk, end: 2 * chunk - 1, written: 0),
                SegmentLedger.Entry(start: 2 * chunk, end: total - 1, written: chunk)
            ],
            sidecarURL: sidecar,
            validator: nil
        )
        let doneBefore = ledger.downloadedBytes()

        ledger.resplit(targetCount: 4)

        XCTAssertEqual(ledger.downloadedBytes(), doneBefore, "a split must not change progress")
        XCTAssertEqual(
            ledger.remainingBytes(), total - doneBefore,
            "a split must not change how much is left"
        )

        let reloaded = try XCTUnwrap(SegmentLedger.load(sidecarURL: sidecar))
        XCTAssertEqual(reloaded.total, total)
        XCTAssertEqual(reloaded.downloadedBytes(), doneBefore)
    }
}
