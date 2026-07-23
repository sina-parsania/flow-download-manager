// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Foundation
import Persistence
import XCTest

final class CategoryRulesEngineTests: XCTestCase {
    func testExtensionRuleOverridesBuiltInMap() {
        let rule = CategoryRulesEngine.Rule(
            id: UUID().uuidString.lowercased(),
            priority: 0,
            enabled: true,
            predicateJSON: #"{"extension":"mp4"}"#,
            categoryStableKey: "documents"
        )
        let result = ClassificationEngine.classify(
            filenameEvidence: nil,
            mimeEvidence: nil,
            urlPathExtension: "mp4",
            rules: [rule]
        )
        XCTAssertEqual(result.stableKey, "documents")
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.evidence, "rule:extension:mp4")
    }

    func testDisabledRuleFallsThroughToBuiltIn() {
        let rule = CategoryRulesEngine.Rule(
            id: UUID().uuidString.lowercased(),
            priority: 0,
            enabled: false,
            predicateJSON: #"{"extension":"mp4"}"#,
            categoryStableKey: "documents"
        )
        let result = ClassificationEngine.classify(
            filenameEvidence: nil,
            mimeEvidence: nil,
            urlPathExtension: "mp4",
            rules: [rule]
        )
        XCTAssertEqual(result.stableKey, "videos")
        XCTAssertEqual(result.evidence, "extension:mp4")
    }

    func testPriorityOrderingFirstWins() {
        let low = CategoryRulesEngine.Rule(
            id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            priority: 10,
            enabled: true,
            predicateJSON: #"{"extension":"mp4"}"#,
            categoryStableKey: "archives"
        )
        let high = CategoryRulesEngine.Rule(
            id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            priority: 1,
            enabled: true,
            predicateJSON: #"{"extension":"mp4"}"#,
            categoryStableKey: "documents"
        )
        let match = CategoryRulesEngine.evaluate(
            rules: [low, high],
            filenameEvidence: "clip.mp4",
            mimeEvidence: nil,
            urlPathExtension: nil
        )
        XCTAssertEqual(match?.categoryStableKey, "documents")
        XCTAssertEqual(match?.ruleID, high.id)
    }

    func testMimePrefixRule() {
        let rule = CategoryRulesEngine.Rule(
            id: UUID().uuidString.lowercased(),
            priority: 0,
            enabled: true,
            predicateJSON: #"{"mimePrefix":"video/"}"#,
            categoryStableKey: "other"
        )
        let result = ClassificationEngine.classify(
            filenameEvidence: nil,
            mimeEvidence: "video/mp4",
            urlPathExtension: nil,
            rules: [rule]
        )
        XCTAssertEqual(result.stableKey, "other")
        XCTAssertTrue(result.evidence.hasPrefix("rule:mimePrefix:"))
    }

    func testRepositoryRoundTrip() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-catrules-\(UUID().uuidString).sqlite")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-catrules-dest-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dest)
        }
        let database = try EngineDatabase(url: dbURL)
        try JobRepository.ensureProductionSeed(database: database, defaultDestinationDirectory: dest)

        let empty = try CategoryRulesRepository.list(database: database)
        XCTAssertTrue(empty.isEmpty)

        let id = UUID().uuidString.lowercased()
        let predicate = try XCTUnwrap(CategoryRulesEngine.extensionPredicateJSON("mp4"))
        try CategoryRulesRepository.upsert(
            database: database,
            id: id,
            priority: 0,
            predicateJSON: predicate,
            categoryStableKey: "documents"
        )
        let listed = try CategoryRulesRepository.list(database: database)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].action, "documents")
        XCTAssertEqual(listed[0].predicate, predicate)
    }
}
