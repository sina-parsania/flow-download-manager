// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// Deterministic fixture data for previews and tests ONLY (`bootstrap prompt §3`).
/// Never used in production paths. Inserts a coherent, FK-valid graph so previews
/// and constraint tests have realistic rows.
public enum DatabaseSeed {
    /// Inserts one destination profile, one category, one resource and one queued
    /// job inside the given database, returning the job id. Must be called within
    /// a write transaction.
    @discardableResult
    public static func insertFixtureJob(
        _ db: Database,
        jobID: String = "00000000-0000-7000-8000-000000000001",
        state: String = "queued"
    ) throws -> String {
        let profileID = "00000000-0000-7000-8000-0000000000d1"
        let categoryID = "00000000-0000-7000-8000-0000000000c1"
        let resourceID = "00000000-0000-7000-8000-0000000000a1"
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try DestinationProfileRecord(
            id: profileID, name: "Downloads",
            bookmarkData: Data([0x00]), volumeIdentity: nil, conflictPolicy: "rename"
        ).insert(db)

        try CategoryRecord(
            id: categoryID, stableKey: "documents", displayNameKey: "category.documents",
            systemSymbol: "doc", destinationProfileID: profileID
        ).insert(db)

        try ResourceRecord(
            id: resourceID, originalURL: "https://example.test/file.bin",
            canonicalURL: "https://example.test/file.bin", finalURL: nil,
            protocolKind: "https", filenameEvidence: "file.bin", mimeEvidence: "application/octet-stream",
            expectedSize: 1024, strongETag: nil, lastModified: nil, checksum: nil, identityRevision: 1
        ).insert(db)

        try JobRecord(
            id: jobID, batchID: nil, resourceID: resourceID, state: state, priority: 0,
            queuePosition: 0, categoryID: categoryID, projectID: nil,
            destinationProfileID: profileID, scheduleID: nil,
            createdAt: now, updatedAt: now, revision: 1, terminalReason: nil
        ).insert(db)

        return jobID
    }
}
