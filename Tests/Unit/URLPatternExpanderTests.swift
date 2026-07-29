// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Foundation
import XCTest

final class URLPatternExpanderTests: XCTestCase {
    func testExpandsASimpleRange() {
        let result = URLPatternExpander.expand("https://host.test/img[1-3].jpg")
        XCTAssertEqual(
            result.text,
            """
            https://host.test/img1.jpg
            https://host.test/img2.jpg
            https://host.test/img3.jpg
            """
        )
        XCTAssertEqual(result.expandedCount, 3)
    }

    /// Zero padding is the common case for sequential media, and the width has
    /// to come from how the user wrote the first bound.
    func testPaddingWidthFollowsTheFirstBound() {
        let result = URLPatternExpander.expand("https://host.test/p[008-010].jpg")
        XCTAssertEqual(
            result.text,
            """
            https://host.test/p008.jpg
            https://host.test/p009.jpg
            https://host.test/p010.jpg
            """
        )
    }

    func testUnpaddedBoundStaysUnpadded() {
        let result = URLPatternExpander.expand("https://host.test/p[8-10].jpg")
        XCTAssertTrue(result.text.contains("p8.jpg"))
        XCTAssertTrue(result.text.contains("p10.jpg"))
        XCTAssertFalse(result.text.contains("p08.jpg"))
    }

    func testSingleValueRangeExpandsToOne() {
        let result = URLPatternExpander.expand("https://host.test/p[5-5].jpg")
        XCTAssertEqual(result.text, "https://host.test/p5.jpg")
        XCTAssertEqual(result.expandedCount, 1)
    }

    // MARK: - Pass-through

    func testTextWithNoPatternIsUntouched() {
        let input = "https://host.test/a.jpg\nhttps://host.test/b.jpg"
        let result = URLPatternExpander.expand(input)
        XCTAssertEqual(result.text, input)
        XCTAssertEqual(result.expandedCount, 0)
    }

    func testDescendingRangeIsLeftAlone() {
        let input = "https://host.test/p[10-1].jpg"
        XCTAssertEqual(URLPatternExpander.expand(input).text, input)
    }

    /// Brackets appear in ordinary URLs and in IPv6 literals. Only a
    /// digit-dash-digit form is a range, and anything else must survive intact.
    func testNonNumericBracketsAreLeftAlone() {
        for input in [
            "https://host.test/a[b-c].jpg",
            "https://[2001:db8::1]/file.bin",
            "https://host.test/name[draft].pdf",
            "https://host.test/p[].jpg"
        ] {
            XCTAssertEqual(
                URLPatternExpander.expand(input).text, input,
                "\(input) must not be treated as a range"
            )
        }
    }

    func testOtherLinesSurviveAnExpansion() {
        let result = URLPatternExpander.expand(
            """
            https://host.test/first.bin
            https://host.test/p[1-2].jpg
            https://host.test/last.bin
            """
        )
        XCTAssertEqual(
            result.text,
            """
            https://host.test/first.bin
            https://host.test/p1.jpg
            https://host.test/p2.jpg
            https://host.test/last.bin
            """
        )
    }

    // MARK: - Bounds

    /// A typo like [1-999999] must not enqueue a million jobs. Refusing the
    /// pattern whole and handing the line back beats silently truncating it,
    /// which would look like a successful partial expansion.
    func testOversizeRangeIsRefusedNotTruncated() {
        let input = "https://host.test/p[1-100000].jpg"
        let result = URLPatternExpander.expand(input)
        XCTAssertEqual(result.text, input, "the line must come back as the user wrote it")
        XCTAssertEqual(result.expandedCount, 0)
        XCTAssertEqual(result.refusedPatterns, ["[1-100000]"])
    }

    func testExactlyTheLimitIsAllowed() {
        let result = URLPatternExpander.expand("https://host.test/p[1-\(URLPatternExpander.maxExpansion)].jpg")
        XCTAssertEqual(result.expandedCount, URLPatternExpander.maxExpansion)
        XCTAssertTrue(result.refusedPatterns.isEmpty)
    }

    func testAbsurdlyLongBoundIsLeftAlone() {
        let input = "https://host.test/p[1-\(String(repeating: "9", count: 40))].jpg"
        XCTAssertEqual(URLPatternExpander.expand(input).text, input)
    }

    /// Two ranges on one line is a cross product — a much easier way to create
    /// thousands of jobs by accident, and a different feature. Only the first
    /// is expanded, and the second is left visible in the output.
    func testOnlyTheFirstRangeOnALineIsExpanded() {
        let result = URLPatternExpander.expand("https://host.test/[1-2]/p[1-2].jpg")
        XCTAssertEqual(result.expandedCount, 2)
        XCTAssertEqual(
            result.text,
            """
            https://host.test/1/p[1-2].jpg
            https://host.test/2/p[1-2].jpg
            """
        )
    }

    func testEmptyInputIsSafe() {
        XCTAssertEqual(URLPatternExpander.expand("").text, "")
    }

    /// The pre-pass runs before the candidate regex, so what it emits still has
    /// to be something the extractor accepts.
    func testExpandedLinksSurviveExtraction() {
        let expansion = URLPatternExpander.expand("https://host.test/img[1-4].jpg")
        let extracted = URLTextExtractor.extract(from: expansion.text)
        XCTAssertEqual(extracted.validCount, 4)
        XCTAssertEqual(extracted.duplicateCount, 0)
    }
}
