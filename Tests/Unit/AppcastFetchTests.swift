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

    /// Sparkle refuses any feed URL that is not http/https:
    ///
    ///   "The download request URL must use http or https (file:///…)"
    ///
    /// 0.3.5 downloaded the feed itself, wrote it to Application Support, and
    /// handed Sparkle a `file://` URL to defeat HTTP caching. Every Check for
    /// Updates then failed with "An error occurred in retrieving update
    /// information" — the feature the file hand-off was added to fix.
    ///
    /// Caching is handled by the cache-busting query in `fetchLatest` instead.
    @MainActor
    func testFeedURLGivenToSparkleUsesHTTPS() {
        let feed = UpdateCheckController.remoteFeedURLString
        XCTAssertTrue(
            feed.hasPrefix("https://"),
            "Sparkle rejects any scheme other than http/https; got \(feed)"
        )
        XCTAssertFalse(feed.hasPrefix("file://"))
    }
}
