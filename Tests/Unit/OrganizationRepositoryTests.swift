// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Persistence
import XCTest

final class OrganizationRepositoryTests: XCTestCase {
    func testCreateProjectTagAttachAndList() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-org-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let database = try EngineDatabase(url: dbURL)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-org-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        try JobRepository.ensureProductionSeed(database: database, defaultDestinationDirectory: dest)

        let projectID = try OrganizationRepository.createProject(
            database: database,
            name: "Alpha"
        )
        let tagA = try OrganizationRepository.createTag(database: database, name: "urgent")
        let tagB = try OrganizationRepository.createTag(database: database, name: "nightly")

        let batch = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [("https://example.test/file.bin", "other")]
        )
        let jobID = try XCTUnwrap(batch.jobIDs.first)

        try OrganizationRepository.setJobProject(database: database, jobID: jobID, projectID: projectID)
        try OrganizationRepository.attachTagToJob(database: database, jobID: jobID, tagID: tagA)
        try OrganizationRepository.setJobTags(database: database, jobID: jobID, tagIDs: [tagA, tagB])

        let projects = try OrganizationRepository.listProjects(database: database)
        XCTAssertEqual(projects.map(\.name), ["Alpha"])
        let tags = try OrganizationRepository.listTags(database: database)
        XCTAssertEqual(tags.map(\.name).sorted(), ["nightly", "urgent"])

        let rows = try JobRepository.fetchJobRows(database: database)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.projectName, "Alpha")
        XCTAssertEqual(row.tagNames, ["nightly", "urgent"])
        XCTAssertEqual(row.tagIDs.count, 2)
        XCTAssertEqual(row.job.projectID, projectID)
    }

    func testSetJobCategory() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-org-cat-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let database = try EngineDatabase(url: dbURL)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-org-cat-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        try JobRepository.ensureProductionSeed(database: database, defaultDestinationDirectory: dest)

        let batch = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [("https://example.test/clip.mp4", "other")]
        )
        let jobID = try XCTUnwrap(batch.jobIDs.first)
        try JobRepository.setJobCategory(
            database: database,
            jobID: jobID,
            categoryStableKey: "videos"
        )
        let rows = try JobRepository.fetchJobRows(database: database)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.category.stableKey, "videos")

        XCTAssertThrowsError(
            try JobRepository.setJobCategory(
                database: database,
                jobID: jobID,
                categoryStableKey: "not-a-real-category"
            )
        )
    }

    func testUpsertTagNameFoldUniqueness() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-org-fold-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let database = try EngineDatabase(url: dbURL)
        let id = UUID().uuidString.lowercased()
        try OrganizationRepository.upsertTag(database: database, id: id, name: "Release")
        XCTAssertThrowsError(
            try OrganizationRepository.createTag(database: database, name: "release")
        )
        let reused = try OrganizationRepository.upsertTag(
            database: database,
            id: UUID().uuidString.lowercased(),
            name: "RELEASE"
        )
        XCTAssertEqual(reused, id)
    }
}
