// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Presentation

final class AppcastFetchTests: XCTestCase {
    func testParsesFirstItemBuildAndShortVersion() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel>
        <item>
            <sparkle:version>7</sparkle:version>
            <sparkle:shortVersionString>0.3.4</sparkle:shortVersionString>
        </item>
        <item>
            <sparkle:version>6</sparkle:version>
            <sparkle:shortVersionString>0.3.3</sparkle:shortVersionString>
        </item>
        </channel>
        </rss>
        """
        let latest = AppcastFetch.parseLatestBuild(from: xml)
        XCTAssertEqual(latest?.short, "0.3.4")
        XCTAssertEqual(latest?.build, 7)
    }
}
