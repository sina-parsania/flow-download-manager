// SPDX-License-Identifier: GPL-3.0-or-later

import EngineAgent
import XCTest

final class SleepAssertionHolderTests: XCTestCase {
    func testNoOpHolderTracksBeginAndEnd() {
        let holder = NoOpSleepAssertionHolder()
        let token = holder.beginTransferAssertion(reason: "DownloadManager transfer")
        XCTAssertNotNil(token)
        XCTAssertEqual(holder.beginCount, 1)
        holder.endTransferAssertion(token)
        XCTAssertEqual(holder.endCount, 1)
        holder.endTransferAssertion(nil)
        XCTAssertEqual(holder.endCount, 1)
    }
}
