// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Presentation

@MainActor
final class JobRowFormattingTests: XCTestCase {
    func testEtaSecondsFromSpeedAndRemaining() {
        XCTAssertEqual(
            JobRowFormatting.etaSeconds(transferred: 50, total: 150, speedBytesPerSecond: 50),
            2
        )
        XCTAssertNil(JobRowFormatting.etaSeconds(transferred: 50, total: 150, speedBytesPerSecond: 0))
        XCTAssertNil(JobRowFormatting.etaSeconds(transferred: 150, total: 150, speedBytesPerSecond: 50))
        XCTAssertNil(JobRowFormatting.etaSeconds(transferred: 10, total: nil, speedBytesPerSecond: 50))
    }

    func testEtaDisplayStrings() {
        XCTAssertEqual(JobRowFormatting.eta(nil), "—")
        XCTAssertEqual(JobRowFormatting.eta(0), "—")
        XCTAssertEqual(JobRowFormatting.eta(45), "45s")
        XCTAssertEqual(JobRowFormatting.eta(125), "2m 5s")
        XCTAssertEqual(JobRowFormatting.eta(3725), "1h 2m")
    }
}
