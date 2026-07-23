// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// Default download-folder destination profile (agent sole writer).
public enum DestinationRepository {
    public struct Snapshot: Sendable, Equatable {
        public let pathDisplay: String
        public let folderName: String
        public let isDefaultDownloads: Bool
    }

    public static func defaultDownloadsDirectory() -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return downloads.appendingPathComponent("DownloadManager", isDirectory: true)
    }

    public static func fetchDefault(database: EngineDatabase) throws -> Snapshot {
        try database.pool.read { db in
            guard let profile = try DestinationProfileRecord.fetchOne(
                db,
                key: ProductionSeedIDs.destinationDownloads
            ) else {
                let fallback = defaultDownloadsDirectory()
                return Snapshot(
                    pathDisplay: fallback.path,
                    folderName: fallback.lastPathComponent,
                    isDefaultDownloads: true
                )
            }
            return snapshot(from: profile)
        }
    }

    /// Replace the default destination. `pathHint` comes from the app (NSOpenPanel)
    /// because security-scoped bookmarks often will not resolve inside the agent binary.
    public static func setDefaultBookmark(
        database: EngineDatabase,
        bookmarkData: Data,
        displayName: String?,
        pathHint: String?
    ) throws -> Snapshot {
        guard !bookmarkData.isEmpty else {
            throw DestinationRepositoryError.emptyBookmark
        }

        let resolvedURL = resolveBookmark(bookmarkData)
        let path: String
        if let hint = pathHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            path = hint
        } else if let resolvedURL {
            path = resolvedURL.path
        } else {
            throw DestinationRepositoryError.notADirectory
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw DestinationRepositoryError.notADirectory
        }

        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String = if let name, !name.isEmpty {
            name
        } else {
            URL(fileURLWithPath: path).lastPathComponent
        }

        // Prefer a plain bookmark the agent can re-resolve later; fall back to client bytes.
        let storeBookmark: Data = if let plain = try? URL(fileURLWithPath: path).bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            plain
        } else {
            bookmarkData
        }

        try database.pool.write { db in
            if try DestinationProfileRecord.fetchOne(db, key: ProductionSeedIDs.destinationDownloads) == nil {
                try DestinationProfileRecord(
                    id: ProductionSeedIDs.destinationDownloads,
                    name: resolvedName,
                    bookmarkData: storeBookmark,
                    volumeIdentity: nil,
                    conflictPolicy: "uniquify"
                ).insert(db)
            } else {
                try db.execute(
                    sql: """
                    UPDATE destination_profiles
                    SET bookmarkData = ?, name = ?, conflictPolicy = 'uniquify'
                    WHERE id = ?
                    """,
                    arguments: [storeBookmark, resolvedName, ProductionSeedIDs.destinationDownloads]
                )
            }
        }

        let defaultPath = defaultDownloadsDirectory().resolvingSymlinksInPath().path
        let normalized = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return Snapshot(
            pathDisplay: normalized,
            folderName: resolvedName,
            isDefaultDownloads: normalized == defaultPath
        )
    }

    /// Reset to ~/Downloads/DownloadManager (agent-local bookmark).
    public static func resetDefault(database: EngineDatabase) throws -> Snapshot {
        let directory = defaultDownloadsDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bookmark = try directory.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try database.pool.write { db in
            if try DestinationProfileRecord.fetchOne(db, key: ProductionSeedIDs.destinationDownloads) == nil {
                try DestinationProfileRecord(
                    id: ProductionSeedIDs.destinationDownloads,
                    name: "Downloads",
                    bookmarkData: bookmark,
                    volumeIdentity: nil,
                    conflictPolicy: "uniquify"
                ).insert(db)
            } else {
                try db.execute(
                    sql: """
                    UPDATE destination_profiles
                    SET bookmarkData = ?, name = 'Downloads', conflictPolicy = 'uniquify'
                    WHERE id = ?
                    """,
                    arguments: [bookmark, ProductionSeedIDs.destinationDownloads]
                )
            }
        }
        return try fetchDefault(database: database)
    }

    private static func snapshot(from profile: DestinationProfileRecord) -> Snapshot {
        let defaultPath = defaultDownloadsDirectory().resolvingSymlinksInPath().path
        if let url = resolveBookmark(profile.bookmarkData) {
            let resolvedPath = url.resolvingSymlinksInPath().path
            return Snapshot(
                pathDisplay: resolvedPath,
                folderName: profile.name,
                isDefaultDownloads: resolvedPath == defaultPath
            )
        }
        // Bookmark unreadable in this process — still return a usable name.
        return Snapshot(
            pathDisplay: profile.name,
            folderName: profile.name,
            isDefaultDownloads: false
        )
    }

    private static func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return url
        }
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return url
        }
        return nil
    }
}

public enum DestinationRepositoryError: Error, Sendable {
    case emptyBookmark
    case notADirectory
}
