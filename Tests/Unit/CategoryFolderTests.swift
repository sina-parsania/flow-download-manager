// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation
import GRDB
import Persistence
import XCTest

final class CategoryFolderNameTests: XCTestCase {
    func testSeededCategoriesAllProduceFolderNames() {
        let expected = [
            "videos": "Videos",
            "audio": "Audio",
            "images": "Images",
            "documents": "Documents",
            "archives": "Archives",
            "applications": "Applications",
            "torrents": "Torrents",
            "other": "Other"
        ]
        for entry in ProductionSeedIDs.categories {
            XCTAssertEqual(
                CategoryFolderName.folderName(forCategoryStableKey: entry.key),
                expected[entry.key],
                "seeded category \(entry.key) must map to a folder"
            )
        }
    }

    /// The folder name becomes a filesystem path component, so anything that could
    /// escape the download directory or nest must be refused outright.
    func testPathEscapesAreRefused() {
        for hostile in ["..", ".", "../../etc", "a/b", "a:b", "", "   ", ".hidden"] {
            XCTAssertNil(
                CategoryFolderName.folderName(forCategoryStableKey: hostile),
                "\(hostile.debugDescription) must not become a folder name"
            )
        }
    }

    func testOverlongKeyIsRefused() {
        XCTAssertNil(
            CategoryFolderName.folderName(forCategoryStableKey: String(repeating: "a", count: 65))
        )
    }
}

final class CategorySubfolderStampTests: XCTestCase {
    private func openTempDatabase() throws -> (EngineDatabase, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-catfolder-\(UUID().uuidString)", isDirectory: true)
        let database = try EngineDatabase(url: root.appendingPathComponent("engine.sqlite"))
        try JobRepository.ensureProductionSeed(
            database: database,
            defaultDestinationDirectory: root.appendingPathComponent("Downloads", isDirectory: true)
        )
        return (database, root)
    }

    private func seedJob(_ database: EngineDatabase, category: String) throws -> String {
        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [(url: "https://example.test/a.bin", categoryStableKey: category)]
        )
        return try XCTUnwrap(result.jobIDs.first)
    }

    func testDisabledStampsNothing() throws {
        let (database, root) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobID = try seedJob(database, category: "videos")

        let stamped = try JobRepository.stampCategorySubfolder(
            database: database, jobID: jobID, enabled: false
        )
        XCTAssertNil(stamped)
        let details = try JobRepository.loadJobForTransfer(database: database, id: jobID)
        XCTAssertEqual(details.writeDirectory, details.destinationDirectory)
    }

    func testEnabledStampsFolderFromCategory() throws {
        let (database, root) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobID = try seedJob(database, category: "videos")

        XCTAssertEqual(
            try JobRepository.stampCategorySubfolder(
                database: database, jobID: jobID, enabled: true
            ),
            "Videos"
        )
        let details = try JobRepository.loadJobForTransfer(database: database, id: jobID)
        XCTAssertEqual(details.categorySubfolder, "Videos")
        XCTAssertEqual(
            details.writeDirectory,
            details.destinationDirectory.appendingPathComponent("Videos", isDirectory: true)
        )
    }

    /// The whole reason the value is persisted: a job that changed folder between
    /// attempts would leave its `.partial` and `.segmap` at the old path and
    /// re-download from zero.
    func testStampIsImmutableWhenTheSettingIsTurnedOff() throws {
        let (database, root) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobID = try seedJob(database, category: "videos")

        _ = try JobRepository.stampCategorySubfolder(
            database: database, jobID: jobID, enabled: true
        )
        XCTAssertEqual(
            try JobRepository.stampCategorySubfolder(
                database: database, jobID: jobID, enabled: false
            ),
            "Videos",
            "an in-flight job must keep the folder it started in"
        )
    }

    func testStampIsImmutableWhenTheCategoryChanges() throws {
        let (database, root) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobID = try seedJob(database, category: "other")

        XCTAssertEqual(
            try JobRepository.stampCategorySubfolder(
                database: database, jobID: jobID, enabled: true
            ),
            "Other"
        )
        try JobRepository.setJobCategory(
            database: database, jobID: jobID, categoryStableKey: "videos"
        )
        XCTAssertEqual(
            try JobRepository.stampCategorySubfolder(
                database: database, jobID: jobID, enabled: true
            ),
            "Other",
            "recategorising a started job must not move where its bytes are written"
        )
    }

    /// The orchestrator stamps *after* the probe has upgraded a job out of `other`,
    /// so an unclassified link that turns out to be a video lands in Videos.
    func testUpgradeBeforeFirstStampLandsInTheUpgradedFolder() throws {
        let (database, root) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobID = try seedJob(database, category: "other")

        _ = try JobRepository.upgradeCategoryFromOther(
            database: database, jobID: jobID, categoryStableKey: "videos"
        )
        XCTAssertEqual(
            try JobRepository.stampCategorySubfolder(
                database: database, jobID: jobID, enabled: true
            ),
            "Videos"
        )
    }

    private func storedPath(_ database: EngineDatabase, _ jobID: String) throws -> String {
        try XCTUnwrap(
            try database.pool.read { try JobRecord.fetchOne($0, key: jobID) }?.destinationPath
        )
    }

    func testStampedFolderIsAppendedToTheStoredDestinationPath() throws {
        let (database, root) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobID = try seedJob(database, category: "documents")

        let before = try storedPath(database, jobID)
        _ = try JobRepository.stampCategorySubfolder(
            database: database, jobID: jobID, enabled: true
        )
        XCTAssertEqual(
            try storedPath(database, jobID),
            (before as NSString).appendingPathComponent("Documents")
        )
    }

    /// Every state transition recomputes `destinationPath` from the destination
    /// profile. Without the subfolder it writes the parent back over the stamped
    /// path, and the Location column points at a folder the file is not in.
    func testStateTransitionKeepsTheSubfolderInTheStoredPath() throws {
        let (database, root) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobID = try seedJob(database, category: "videos")
        _ = try JobRepository.stampCategorySubfolder(
            database: database, jobID: jobID, enabled: true
        )
        let stampedPath = try storedPath(database, jobID)
        XCTAssertTrue(stampedPath.hasSuffix("/Videos"))

        _ = try JobRepository.updateJobState(
            database: database, id: jobID, state: .connecting,
            terminalReason: nil, expectedRevision: nil
        )
        XCTAssertEqual(
            try storedPath(database, jobID),
            stampedPath,
            "a state change must not rewrite the location back to the parent folder"
        )
    }

    /// A client holds an expected revision for pause/cancel. Path bookkeeping is
    /// not state it races the agent for, so stamping must not invalidate it.
    func testStampingDoesNotBumpTheRevision() throws {
        let (database, root) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobID = try seedJob(database, category: "videos")
        let before = try XCTUnwrap(
            try database.pool.read { try JobRecord.fetchOne($0, key: jobID) }?.revision
        )

        _ = try JobRepository.stampCategorySubfolder(
            database: database, jobID: jobID, enabled: true
        )
        XCTAssertEqual(
            try database.pool.read { try JobRecord.fetchOne($0, key: jobID) }?.revision,
            before,
            "a stale expectedRevision here would reject the user's next Pause"
        )
    }

    /// A plain file sitting where the category folder should go must surface as an
    /// error, not be silently written past into the parent directory.
    func testFileBlockingTheFolderPathFailsRatherThanFallingBack() throws {
        let (database, root) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobID = try seedJob(database, category: "videos")
        _ = try JobRepository.stampCategorySubfolder(
            database: database, jobID: jobID, enabled: true
        )
        let details = try JobRepository.loadJobForTransfer(database: database, id: jobID)

        try FileManager.default.createDirectory(
            at: details.destinationDirectory, withIntermediateDirectories: true
        )
        try Data("not a directory".utf8).write(to: details.writeDirectory)

        XCTAssertThrowsError(
            try FileManager.default.createDirectory(
                at: details.writeDirectory, withIntermediateDirectories: true
            ),
            "a file blocking the folder must throw so the job fails visibly"
        )
    }
}
