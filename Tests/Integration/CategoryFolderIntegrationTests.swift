// SPDX-License-Identifier: GPL-3.0-or-later

import EngineAgent
import Foundation
import Persistence
import SharedSecurity
import TestFaultService
import XCTest

/// End-to-end proof that the bytes land in the category folder.
///
/// The unit tests cover the stamping decision; this covers the thing a user would
/// actually notice — that the promoted file is inside `Videos/` and not next to it.
/// Without this, the whole feature could be wired to a `writeDirectory` nobody
/// reads and every other lane would still pass, because the setting is off by
/// default and no existing test turns it on.
final class CategoryFolderIntegrationTests: XCTestCase {
    /// `AgentBoolSettings` reads `UserDefaults.standard`, so the flag is restored
    /// after each test to keep the rest of the lane on the default (off) path.
    private var previousValue: Any?

    override func setUp() {
        super.setUp()
        previousValue = UserDefaults.standard.object(
            forKey: AgentBoolSettings.categoryFoldersEnabledKey
        )
    }

    override func tearDown() {
        if let previousValue {
            UserDefaults.standard.set(previousValue, forKey: AgentBoolSettings.categoryFoldersEnabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AgentBoolSettings.categoryFoldersEnabledKey)
        }
        super.tearDown()
    }

    private func runToCompletion(
        categoryFolders: Bool,
        categoryStableKey: String
    ) async throws -> (destination: URL, state: String) {
        _ = AgentBoolSettings.setBool(
            categoryFolders,
            forKey: AgentBoolSettings.categoryFoldersEnabledKey
        )

        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-catfolder-\(UUID().uuidString).sqlite")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-catfolder-dest-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dest)
        }

        let database = try EngineDatabase(url: dbURL)
        try JobRepository.ensureProductionSeed(database: database, defaultDestinationDirectory: dest)
        _ = try JobRepository.insertBatch(
            database: database,
            source: "test",
            displayName: nil,
            items: [(
                url: "http://127.0.0.1:\(port)/fixtures/ok",
                categoryStableKey: categoryStableKey
            )]
        )

        let orchestrator = TransferOrchestrator(
            database: database,
            secretStore: InMemorySecretStore()
        )
        await orchestrator.start()

        let deadline = Date().addingTimeInterval(15)
        var state = "queued"
        while Date() < deadline {
            let rows = try JobRepository.fetchJobRows(database: database)
            if let row = rows.first {
                state = row.job.state
                if state == "completed" || state == "failed" || state == "cancelled" { break }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await orchestrator.stop()
        // Allow the pump task to exit before unlinking the database file.
        try await Task.sleep(nanoseconds: 300_000_000)
        return (dest, state)
    }

    /// Promoted *files* only — the category folder itself is a directory entry of
    /// the destination and must not be counted as a stray download.
    private func promotedFiles(in directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true }
            .map(\.lastPathComponent)
            .filter { !$0.hasSuffix(".partial") && !$0.hasSuffix(".segmap") }
            .sorted()
    }

    func testCompletedFileLandsInsideTheCategoryFolder() async throws {
        let (dest, state) = try await runToCompletion(
            categoryFolders: true,
            categoryStableKey: "videos"
        )
        XCTAssertEqual(state, "completed")
        guard state == "completed" else { return }

        let folder = dest.appendingPathComponent("Videos", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
            "expected a Videos folder in \(dest.path)"
        )
        XCTAssertTrue(isDirectory.boolValue)

        let inFolder = try promotedFiles(in: folder)
        XCTAssertEqual(inFolder.count, 1, "expected the promoted file inside Videos, got \(inFolder)")
        XCTAssertEqual(
            try Data(contentsOf: folder.appendingPathComponent(XCTUnwrap(inFolder.first))),
            FaultHTTPServer.fixtureBody
        )
        XCTAssertTrue(
            try promotedFiles(in: dest).isEmpty,
            "nothing may be left in the parent directory when the folder is used"
        )
    }

    func testFileStaysInTheDestinationWhenTheSettingIsOff() async throws {
        let (dest, state) = try await runToCompletion(
            categoryFolders: false,
            categoryStableKey: "videos"
        )
        XCTAssertEqual(state, "completed")
        guard state == "completed" else { return }

        XCTAssertEqual(try promotedFiles(in: dest).count, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dest.appendingPathComponent("Videos").path
            ),
            "the feature is off, so no folder may be created"
        )
    }

    /// A plain file already occupying the folder path must fail the job visibly
    /// rather than silently writing into the parent — and must not be clobbered.
    func testFileBlockingTheCategoryFolderFailsTheJob() async throws {
        _ = AgentBoolSettings.setBool(true, forKey: AgentBoolSettings.categoryFoldersEnabledKey)

        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-catblock-\(UUID().uuidString).sqlite")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-catblock-dest-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dest)
        }

        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let blocker = dest.appendingPathComponent("Videos")
        let blockerBody = Data("occupied".utf8)
        try blockerBody.write(to: blocker)

        let database = try EngineDatabase(url: dbURL)
        try JobRepository.ensureProductionSeed(database: database, defaultDestinationDirectory: dest)
        _ = try JobRepository.insertBatch(
            database: database,
            source: "test",
            displayName: nil,
            items: [(url: "http://127.0.0.1:\(port)/fixtures/ok", categoryStableKey: "videos")]
        )

        let orchestrator = TransferOrchestrator(
            database: database,
            secretStore: InMemorySecretStore()
        )
        await orchestrator.start()
        let deadline = Date().addingTimeInterval(15)
        var state = "queued"
        while Date() < deadline {
            let rows = try JobRepository.fetchJobRows(database: database)
            if let row = rows.first {
                state = row.job.state
                if state == "completed" || state == "failed" || state == "cancelled" { break }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await orchestrator.stop()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(state, "failed", "a blocked folder must fail the job, not fall back")
        XCTAssertEqual(
            try Data(contentsOf: blocker),
            blockerBody,
            "the file occupying the folder name must be left untouched"
        )
    }
}
