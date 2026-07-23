// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import XCTest

final class URLTextExtractorTests: XCTestCase {
    func testExtractsOrderedURLsAndDedupes() {
        let text = """
        See https://a.example/one and also https://A.example/one
        ftp://files.example/x.bin.
        magnet:?xt=urn:btih:abc
        not-a-url
        https://b.example/two
        """
        let result = URLTextExtractor.extract(from: text)
        XCTAssertEqual(result.validCount, 3)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(result.unsupportedCount, 1)
        XCTAssertEqual(result.items.map(\.status), [
            .valid, .duplicate, .valid, .unsupported, .valid
        ])
        XCTAssertEqual(result.items[0].scheme, "https")
        XCTAssertEqual(result.items[1].duplicateOfIndex, 0)
        XCTAssertEqual(result.items[2].scheme, "ftp")
        XCTAssertEqual(result.items[3].scheme, "magnet")
        XCTAssertEqual(result.items[4].host, "b.example")
    }

    func testRespectsMaxURLCount() {
        let text = (0 ..< 20).map { "https://example.com/\($0)" }.joined(separator: " ")
        let result = URLTextExtractor.extract(
            from: text,
            limits: .init(maxInputBytes: 1_000_000, maxURLCount: 5)
        )
        XCTAssertEqual(result.items.count, 5)
        XCTAssertEqual(result.validCount, 5)
    }
}
