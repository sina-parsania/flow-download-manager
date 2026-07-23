// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import XCTest

final class OpenURLIngestTests: XCTestCase {
    func testParseQueryURL() throws {
        let url = try XCTUnwrap(URL(string: "downloadmanager://open?url=https%3A%2F%2Fcdn.example.test%2Fa.bin"))
        XCTAssertEqual(OpenURLIngest.parse(url), ["https://cdn.example.test/a.bin"])
    }

    func testParseRepeatedQueryURLsPreservesOrderAndDedupes() throws {
        let url = try XCTUnwrap(URL(string:
            "downloadmanager://add?url=https://a.example.test/1&url=https://b.example.test/2&url=https://a.example.test/1"
        ))
        XCTAssertEqual(OpenURLIngest.parse(url), [
            "https://a.example.test/1",
            "https://b.example.test/2"
        ])
    }

    func testParsePathAsHTTPURL() throws {
        let url = try XCTUnwrap(URL(string: "downloadmanager:///https://files.example.test/x.zip"))
        XCTAssertEqual(OpenURLIngest.parse(url), ["https://files.example.test/x.zip"])
    }

    func testIgnoresForeignSchemesAndEmptyPayloads() throws {
        let http = try XCTUnwrap(URL(string: "https://example.test/file"))
        XCTAssertEqual(OpenURLIngest.parse(http), [])

        let bare = try XCTUnwrap(URL(string: "downloadmanager://open"))
        XCTAssertEqual(OpenURLIngest.parse(bare), [])

        let badPath = try XCTUnwrap(URL(string: "downloadmanager:///not-a-url"))
        XCTAssertEqual(OpenURLIngest.parse(badPath), [])

        let fileURL = URL(fileURLWithPath: "/tmp/links.txt")
        XCTAssertEqual(OpenURLIngest.parse(fileURL), [])
    }
}
