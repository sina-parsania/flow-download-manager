// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TransferCore
import XCTest

final class SegmentPolicyAndIntegrityTests: XCTestCase {
    func testPreferredSegmentCountScalesWithSize() {
        XCTAssertEqual(SegmentedTransfer.preferredSegmentCount(totalBytes: 100), 1)
        XCTAssertEqual(SegmentedTransfer.preferredSegmentCount(totalBytes: 4096), 1)
        XCTAssertEqual(SegmentedTransfer.preferredSegmentCount(totalBytes: 2_000_000), 2)
        XCTAssertEqual(SegmentedTransfer.preferredSegmentCount(totalBytes: 20_000_000), 4)
        XCTAssertGreaterThanOrEqual(SegmentedTransfer.preferredSegmentCount(totalBytes: 200_000_000), 8)
        XCTAssertLessThanOrEqual(SegmentedTransfer.preferredSegmentCount(totalBytes: 200_000_000), 32)
        XCTAssertEqual(SegmentedTransfer.preferredSegmentCount(totalBytes: 512_000_000), 32)
    }

    func testPreferredSegmentCountHonorsHostMaxHint() {
        XCTAssertEqual(
            SegmentedTransfer.preferredSegmentCount(totalBytes: 20_000_000, hostMaxSegments: 2),
            2
        )
        XCTAssertEqual(
            SegmentedTransfer.preferredSegmentCount(totalBytes: 100, hostMaxSegments: 8),
            1
        )
        XCTAssertEqual(
            SegmentedTransfer.preferredSegmentCount(totalBytes: 20_000_000, hostMaxSegments: nil),
            4
        )
    }

    func testSHA256RoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-hash-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = Data("download-manager-integrity".utf8)
        try payload.write(to: url)
        let hex = try IntegrityVerifier.sha256Hex(ofFile: url)
        XCTAssertEqual(hex.count, 64)
        try IntegrityVerifier.verifySHA256(ofFile: url, expectedHex: hex)
        XCTAssertThrowsError(try IntegrityVerifier.verifySHA256(
            ofFile: url,
            expectedHex: String(repeating: "0", count: 64)
        ))
    }

    func testAbortFlagStopsTransfer() {
        // Tiny local file path is not a network transfer; verify token mechanics.
        let flag = TransferAbortFlag()
        XCTAssertFalse(flag.isSet)
        flag.requestAbort()
        XCTAssertTrue(flag.isSet)
        flag.reset()
        XCTAssertFalse(flag.isSet)
    }
}
