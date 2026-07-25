// SPDX-License-Identifier: GPL-3.0-or-later

import TransferCore
import XCTest

final class TransferAbortFlagTests: XCTestCase {
    func testRequestResetRoundTrip() {
        let flag = TransferAbortFlag()
        XCTAssertFalse(flag.isSet)
        flag.requestAbort()
        XCTAssertTrue(flag.isSet)
        flag.reset()
        XCTAssertFalse(flag.isSet)
    }

    func testConcurrentAbortFlagAccess() {
        let flag = TransferAbortFlag()
        let iterations = 10000
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0 ..< iterations {
                flag.requestAbort()
                _ = flag.isSet
            }
        }
        XCTAssertTrue(flag.isSet)
    }
}
