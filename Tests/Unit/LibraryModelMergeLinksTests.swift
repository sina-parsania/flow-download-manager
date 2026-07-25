// SPDX-License-Identifier: GPL-3.0-or-later

import Presentation
import XCTest

final class LibraryModelMergeLinksTests: XCTestCase {
    func testMergeLinkBlocksDedupesAndPreservesOrder() {
        let merged = LibraryModel.mergeLinkBlocks(
            existing: "https://a.example/1\nhttps://b.example/2",
            incoming: "https://b.example/2\nhttps://c.example/3"
        )
        XCTAssertEqual(
            merged,
            "https://a.example/1\nhttps://b.example/2\nhttps://c.example/3"
        )
    }

    func testMergeLinkBlocksIgnoresBlankLines() {
        let merged = LibraryModel.mergeLinkBlocks(
            existing: "\nhttps://a.example/1\n",
            incoming: "  \nhttps://a.example/1\nhttps://b.example/2\n"
        )
        XCTAssertEqual(merged, "https://a.example/1\nhttps://b.example/2")
    }
}
