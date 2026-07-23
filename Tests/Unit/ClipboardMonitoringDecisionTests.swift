// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import XCTest

final class ClipboardMonitoringDecisionTests: XCTestCase {
    func testSameTextDoesNotNotify() {
        let text = "https://example.test/a.bin"
        XCTAssertFalse(ClipboardMonitoringDecision.shouldNotify(previousText: text, newText: text))
    }

    func testNewValidLinksNotify() {
        XCTAssertTrue(
            ClipboardMonitoringDecision.shouldNotify(
                previousText: "hello",
                newText: "see https://cdn.example/file.zip"
            )
        )
    }

    func testNoValidLinksDoesNotNotify() {
        XCTAssertFalse(
            ClipboardMonitoringDecision.shouldNotify(
                previousText: nil,
                newText: "magnet:?xt=urn:btih:abcdef"
            )
        )
        XCTAssertFalse(
            ClipboardMonitoringDecision.shouldNotify(
                previousText: "a",
                newText: "no links here"
            )
        )
    }

    func testNilPreviousWithValidLinksNotifies() {
        XCTAssertTrue(
            ClipboardMonitoringDecision.shouldNotify(
                previousText: nil,
                newText: "https://example.test/one.bin"
            )
        )
    }
}
