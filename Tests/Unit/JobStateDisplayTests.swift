// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import XCTest

/// Guards the U4 contract: no screen may render a persistence token. Every check
/// runs over `JobState.allCases`, so a new case that forgets human wording fails
/// here (and fails to compile in `displayName`/`shortLabel`, which have no
/// `default:` clause).
final class JobStateDisplayTests: XCTestCase {
    func testDisplayNameIsNeverTheRawIdentifier() {
        for state in JobState.allCases {
            let name = state.displayName
            XCTAssertFalse(name.isEmpty, "\(state.rawValue) has an empty displayName")
            XCTAssertNotEqual(name, state.rawValue, "\(state.rawValue) leaks its raw identifier")
            XCTAssertNotEqual(
                name, state.rawValue.uppercased(),
                "\(state.rawValue) leaks its uppercased raw identifier"
            )
            XCTAssertTrue(
                name.contains(where: \.isLowercase),
                "displayName \"\(name)\" reads as an uppercase-only identifier"
            )
            XCTAssertEqual(
                name.first?.isUppercase, true,
                "displayName \"\(name)\" is not sentence case"
            )
            // A camelCase raw value is multi-word; squashing it into one token is the
            // exact defect (`retryWaiting` → `RETRYWAITING`) this suite exists to catch.
            if state.rawValue.contains(where: \.isUppercase) {
                XCTAssertNotEqual(
                    name.lowercased(), state.rawValue.lowercased(),
                    "displayName \"\(name)\" is the raw identifier with different casing"
                )
            }
        }
    }

    func testShortLabelIsACompactChipAndNeverTheRawIdentifier() {
        for state in JobState.allCases {
            let label = state.shortLabel
            XCTAssertFalse(label.isEmpty, "\(state.rawValue) has an empty shortLabel")
            XCTAssertNotEqual(label, state.rawValue, "\(state.rawValue) leaks its raw identifier")
            XCTAssertLessThanOrEqual(
                label.count, 6,
                "shortLabel \"\(label)\" exceeds the six-character chip budget"
            )
            XCTAssertEqual(label, label.uppercased(), "shortLabel \"\(label)\" is not all caps")
            XCTAssertTrue(
                label.allSatisfy(\.isLetter),
                "shortLabel \"\(label)\" contains non-letter characters"
            )
            if state.rawValue.contains(where: \.isUppercase) {
                XCTAssertNotEqual(
                    label.lowercased(), state.rawValue.lowercased(),
                    "shortLabel \"\(label)\" is the raw identifier with different casing"
                )
            }
        }
    }

    func testDisplayVocabularyIsUnambiguous() {
        let names = JobState.allCases.map(\.displayName)
        let labels = JobState.allCases.map(\.shortLabel)
        XCTAssertEqual(Set(names).count, JobState.allCases.count, "two states share a displayName")
        XCTAssertEqual(Set(labels).count, JobState.allCases.count, "two states share a shortLabel")
    }

    func testEstablishedBoardVocabularyIsPreserved() {
        XCTAssertEqual(JobState.downloading.shortLabel, "LIVE")
        XCTAssertEqual(JobState.paused.shortLabel, "PAUSED")
        XCTAssertEqual(JobState.queued.shortLabel, "QUEUE")
        XCTAssertEqual(JobState.completed.shortLabel, "DONE")
        XCTAssertEqual(JobState.failed.shortLabel, "FAIL")
        XCTAssertEqual(JobState.cancelled.shortLabel, "STOP")
    }
}
