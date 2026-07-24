// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Presentation

final class ChromeUnpackedExtensionIDTests: XCTestCase {
    func testMatchesChromePathHashMapping() {
        // Same algorithm as Scripts/lib/write_native_host_manifest.py.
        let path = "/Volumes/T7 Shield/Projects/flow-download-manager/BrowserExtension/chrome"
        XCTAssertEqual(
            ChromeUnpackedExtensionID.make(directoryPath: path),
            "dpkpandlfgaoblffeeamcefohdahhinf"
        )
    }

    func testStripsTrailingSlash() {
        let withSlash = "/tmp/flow-chrome-companion/"
        let without = "/tmp/flow-chrome-companion"
        XCTAssertEqual(
            ChromeUnpackedExtensionID.make(directoryPath: withSlash),
            ChromeUnpackedExtensionID.make(directoryPath: without)
        )
    }
}
