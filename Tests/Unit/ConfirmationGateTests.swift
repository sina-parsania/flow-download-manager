// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import XCTest

final class ConfirmationGateTests: XCTestCase {
    func testShouldConfirmWhenAnyLowConfidence() {
        let results = [
            ClassificationEngine.ClassificationResult(
                stableKey: "videos", confidence: .high, evidence: "filename:mp4"
            ),
            ClassificationEngine.ClassificationResult(
                stableKey: "documents", confidence: .low, evidence: "fallback"
            )
        ]
        XCTAssertTrue(ConfirmationGate.shouldConfirm(results: results))
    }

    func testShouldConfirmWhenCategoryIsOther() {
        let results = [
            ClassificationEngine.ClassificationResult(
                stableKey: "other", confidence: .medium, evidence: "mime:application/octet-stream"
            )
        ]
        XCTAssertTrue(ConfirmationGate.shouldConfirm(results: results))
    }

    func testShouldNotConfirmWhenAllConfidentNonOther() {
        let results = [
            ClassificationEngine.ClassificationResult(
                stableKey: "videos", confidence: .high, evidence: "filename:mp4"
            ),
            ClassificationEngine.ClassificationResult(
                stableKey: "audio", confidence: .medium, evidence: "mime:audio/mpeg"
            )
        ]
        XCTAssertFalse(ConfirmationGate.shouldConfirm(results: results))
    }

    func testShouldNotConfirmEmpty() {
        XCTAssertFalse(ConfirmationGate.shouldConfirm(results: []))
    }

    func testCategoryCountsSorted() {
        let results = [
            ClassificationEngine.ClassificationResult(
                stableKey: "videos", confidence: .high, evidence: "a"
            ),
            ClassificationEngine.ClassificationResult(
                stableKey: "other", confidence: .low, evidence: "b"
            ),
            ClassificationEngine.ClassificationResult(
                stableKey: "videos", confidence: .high, evidence: "c"
            )
        ]
        let counts = ConfirmationGate.categoryCounts(results: results)
        XCTAssertEqual(counts.map(\.stableKey), ["other", "videos"])
        XCTAssertEqual(counts.map(\.count), [1, 2])
    }
}
