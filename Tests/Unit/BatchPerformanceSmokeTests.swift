// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import XCTest

/// NFR-PERF *smoke* only — not the full Phase 1 performance gate.
final class BatchPerformanceSmokeTests: XCTestCase {
    func testURLTextExtractorFiveThousandURLsUnderTwoSeconds_smoke() {
        let urls = (0 ..< 5000).map { "https://cdn.example.test/files/item-\($0).bin" }
        let text = urls.joined(separator: "\n")

        let clock = ContinuousClock()
        let started = clock.now
        let result = URLTextExtractor.extract(from: text)
        let elapsed = clock.now - started

        XCTAssertEqual(result.validCount, 5000)
        XCTAssertLessThan(
            elapsed,
            .seconds(2),
            "URLTextExtractor smoke: 5000 URLs should finish under 2s (elapsed \(elapsed))"
        )
    }

    func testClassificationEngineFiveThousandUnderOneSecond_smoke() {
        let clock = ContinuousClock()
        let started = clock.now
        var lastKey = ""
        for index in 0 ..< 5000 {
            let ext = switch index % 4 {
            case 0: "mp4"
            case 1: "zip"
            case 2: "pdf"
            default: "bin"
            }
            let result = ClassificationEngine.classify(
                filenameEvidence: "file-\(index).\(ext)",
                mimeEvidence: nil,
                urlPathExtension: ext
            )
            lastKey = result.stableKey
        }
        let elapsed = clock.now - started

        XCTAssertFalse(lastKey.isEmpty)
        XCTAssertLessThan(
            elapsed,
            .seconds(1),
            "ClassificationEngine smoke: 5000 classify calls should finish under 1s (elapsed \(elapsed))"
        )
    }
}
