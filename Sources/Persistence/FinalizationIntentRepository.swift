// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation
import GRDB

public enum FinalizationRecoveryAction: Equatable, Sendable {
    case completed
    case failed(reason: TerminalReason)
    case needsResumePromotion
    case needsPostProcessing
}

public struct FinalizationRecoveryOutcome: Equatable, Sendable {
    public let jobID: String
    public let action: FinalizationRecoveryAction

    public init(jobID: String, action: FinalizationRecoveryAction) {
        self.jobID = jobID
        self.action = action
    }
}

public enum FinalizationIntentRepositoryError: Error, Equatable, Sendable {
    case jobNotFound(String)
    case intentNotFound(String)
    case unknownPersistedState(String)
    case invalidTransition(from: JobState, to: JobState)
    case destinationUnavailable(String)
}

/// Durable finalization intent and crash recovery for interrupted verifying /
/// post-processing jobs.
public enum FinalizationIntentRepository {
    /// Atomically transitions a job to `verifying` and records a `prepared`
    /// intent before any filesystem promotion.
    public static func beginVerification(
        database: EngineDatabase,
        jobID: String,
        finalFilename: String,
        partialFilename: String,
        expectedByteSize: Int64,
        expectedChecksum: String?,
        zipAutoExtract: Bool
    ) throws -> Int {
        try database.pool.write { db in
            guard var job = try JobRecord.fetchOne(db, key: jobID) else {
                throw FinalizationIntentRepositoryError.jobNotFound(jobID)
            }
            try transitionJob(
                &job,
                to: .verifying,
                terminalReason: nil,
                in: db
            )

            if let profile = try DestinationProfileRecord.fetchOne(db, key: job.destinationProfileID) {
                job.finalFilename = finalFilename
                JobLocationTimeline.refreshDestinationPath(&job, profile: profile)
                try job.update(db)
            } else {
                job.finalFilename = finalFilename
                try job.update(db)
            }

            let now = Date()
            let intent = FinalizationIntentRecord(
                jobID: jobID,
                destinationProfileID: job.destinationProfileID,
                finalFilename: finalFilename,
                partialFilename: partialFilename,
                expectedByteSize: expectedByteSize,
                expectedChecksum: expectedChecksum,
                stage: FinalizationIntentStage.prepared.rawValue,
                zipAutoExtract: zipAutoExtract,
                revision: 1,
                createdAt: now,
                updatedAt: now
            )
            try intent.insert(db)

            try appendIntentEvent(
                db,
                jobID: jobID,
                type: "finalization.prepared",
                revision: job.revision,
                stage: FinalizationIntentStage.prepared.rawValue
            )
            return job.revision
        }
    }

    /// Durably records promotion completion and transitions the job to
    /// `postProcessing`.
    public static func markPromoted(database: EngineDatabase, jobID: String) throws -> Int {
        try database.pool.write { db in
            guard var job = try JobRecord.fetchOne(db, key: jobID) else {
                throw FinalizationIntentRepositoryError.jobNotFound(jobID)
            }
            guard var intent = try FinalizationIntentRecord.fetchOne(db, key: jobID) else {
                throw FinalizationIntentRepositoryError.intentNotFound(jobID)
            }
            try transitionJob(
                &job,
                to: .postProcessing,
                terminalReason: nil,
                in: db
            )

            intent.stage = FinalizationIntentStage.promoted.rawValue
            intent.revision += 1
            intent.updatedAt = job.updatedAt
            try intent.update(db)

            try appendIntentEvent(
                db,
                jobID: jobID,
                type: "finalization.promoted",
                revision: job.revision,
                stage: FinalizationIntentStage.promoted.rawValue
            )
            return job.revision
        }
    }

    /// Completes finalization: transitions to `completed` and deletes the intent.
    public static func completeFinalization(database: EngineDatabase, jobID: String) throws -> Int {
        try database.pool.write { db in
            guard var job = try JobRecord.fetchOne(db, key: jobID) else {
                throw FinalizationIntentRepositoryError.jobNotFound(jobID)
            }
            if JobState(rawValue: job.state) == .verifying {
                try transitionJob(
                    &job,
                    to: .postProcessing,
                    terminalReason: nil,
                    in: db
                )
            }
            try transitionJob(
                &job,
                to: .completed,
                terminalReason: nil,
                in: db
            )
            try FinalizationIntentRecord.deleteOne(db, key: jobID)
            try appendIntentEvent(
                db,
                jobID: jobID,
                type: "finalization.completed",
                revision: job.revision,
                stage: nil
            )
            return job.revision
        }
    }

    public static func fetchIntent(
        database: EngineDatabase,
        jobID: String
    ) throws -> FinalizationIntentRecord? {
        try database.pool.read { db in
            try FinalizationIntentRecord.fetchOne(db, key: jobID)
        }
    }

    /// Jobs still in verifying/post-processing with a durable intent that need
    /// orchestrator-side promotion or post-processing.
    public static func fetchJobsNeedingFinalizationResume(
        database: EngineDatabase,
        limit: Int
    ) throws -> [String] {
        let capped = min(max(limit, 1), 256)
        let states = [JobState.verifying.rawValue, JobState.postProcessing.rawValue]
        return try database.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT j.id FROM jobs j
                INNER JOIN finalization_intents fi ON fi.jobID = j.id
                WHERE j.state IN (?, ?)
                ORDER BY j.queuePosition ASC, j.createdAt ASC
                LIMIT ?
                """,
                arguments: [states[0], states[1], capped]
            )
        }
    }

    /// Reconciles interrupted verifying/post-processing jobs using durable
    /// intents and on-disk artifacts. Never deletes partial or final files.
    public static func reconcileInterruptedFinalizations(
        database: EngineDatabase
    ) throws -> [FinalizationRecoveryOutcome] {
        try database.pool.write { db in
            var outcomes: [FinalizationRecoveryOutcome] = []
            let interrupted = try JobRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM jobs
                WHERE state IN (?, ?)
                ORDER BY queuePosition ASC, createdAt ASC
                """,
                arguments: [JobState.verifying.rawValue, JobState.postProcessing.rawValue]
            )
            for var job in interrupted {
                guard let state = JobState(rawValue: job.state) else {
                    throw FinalizationIntentRepositoryError.unknownPersistedState(job.state)
                }
                guard var intent = try FinalizationIntentRecord.fetchOne(db, key: job.id) else {
                    try outcomes.append(
                        failJob(
                            &job,
                            reason: .databaseRecoveryRequired,
                            in: db,
                            eventType: "recovery.finalizationMissingIntent"
                        )
                    )
                    continue
                }

                let destination = try resolveDestinationDirectory(
                    db: db,
                    profileID: intent.destinationProfileID
                )
                let partialURL = destination.appendingPathComponent(intent.partialFilename)
                let finalURL = destination.appendingPathComponent(intent.finalFilename)
                let snapshot = FinalizationReconciler.filesystemSnapshot(
                    partialURL: partialURL,
                    finalURL: finalURL
                )
                let plan = FinalizationReconciler.plan(
                    intent: FinalizationIntentSnapshot(
                        stage: FinalizationIntentStage(rawValue: intent.stage)
                            ?? .prepared,
                        expectedByteSize: intent.expectedByteSize,
                        zipAutoExtract: intent.zipAutoExtract
                    ),
                    snapshot: snapshot
                )
                try outcomes.append(
                    applyPlan(
                        plan,
                        job: &job,
                        state: state,
                        intent: &intent,
                        in: db
                    )
                )
            }

            let completedWithIntent = try FinalizationIntentRecord.fetchAll(db)
            for intent in completedWithIntent {
                guard let job = try JobRecord.fetchOne(db, key: intent.jobID),
                      job.state == JobState.completed.rawValue
                else {
                    continue
                }
                try FinalizationIntentRecord.deleteOne(db, key: intent.jobID)
                try appendIntentEvent(
                    db,
                    jobID: intent.jobID,
                    type: "recovery.finalizationIntentCleaned",
                    revision: job.revision,
                    stage: nil
                )
                outcomes.append(
                    FinalizationRecoveryOutcome(jobID: intent.jobID, action: .completed)
                )
            }
            return outcomes
        }
    }

    // MARK: - Private

    private static func applyPlan(
        _ plan: FinalizationReconciliationPlan,
        job: inout JobRecord,
        state: JobState,
        intent: inout FinalizationIntentRecord,
        in db: Database
    ) throws -> FinalizationRecoveryOutcome {
        switch plan {
        case .resumePromotion:
            try appendIntentEvent(
                db,
                jobID: job.id,
                type: "recovery.finalizationResumePromotion",
                revision: job.revision,
                stage: intent.stage
            )
            return FinalizationRecoveryOutcome(
                jobID: job.id,
                action: .needsResumePromotion
            )

        case .advanceToPostProcessing:
            if state == .verifying {
                try transitionJob(
                    &job,
                    to: .postProcessing,
                    terminalReason: nil,
                    in: db
                )
            }
            intent.stage = FinalizationIntentStage.promoted.rawValue
            intent.revision += 1
            intent.updatedAt = job.updatedAt
            try intent.update(db)
            return try finishPostProcessingIfNeeded(
                job: &job,
                intent: &intent,
                in: db
            )

        case .completeWithoutPostProcessing:
            return try completeDuringRecovery(job: &job, intent: &intent, in: db)

        case .runPostProcessing:
            if state == .verifying {
                try transitionJob(
                    &job,
                    to: .postProcessing,
                    terminalReason: nil,
                    in: db
                )
                intent.stage = FinalizationIntentStage.promoted.rawValue
                intent.revision += 1
                intent.updatedAt = job.updatedAt
                try intent.update(db)
            }
            try appendIntentEvent(
                db,
                jobID: job.id,
                type: "recovery.finalizationResumePostProcessing",
                revision: job.revision,
                stage: intent.stage
            )
            return FinalizationRecoveryOutcome(
                jobID: job.id,
                action: .needsPostProcessing
            )

        case .failMissingArtifacts:
            return try failJob(
                &job,
                reason: .destinationUnavailable,
                in: db,
                eventType: "recovery.finalizationMissingArtifacts"
            )

        case .failAmbiguousFiles:
            return try failJob(
                &job,
                reason: .destinationUnavailable,
                in: db,
                eventType: "recovery.finalizationAmbiguousArtifacts"
            )

        case let .failSizeMismatch(expected, actual):
            _ = expected
            _ = actual
            return try failJob(
                &job,
                reason: .rangeProtocolViolation,
                in: db,
                eventType: "recovery.finalizationSizeMismatch"
            )

        case .cleanupIntentOnly:
            try FinalizationIntentRecord.deleteOne(db, key: job.id)
            return FinalizationRecoveryOutcome(jobID: job.id, action: .completed)
        }
    }

    private static func finishPostProcessingIfNeeded(
        job: inout JobRecord,
        intent: inout FinalizationIntentRecord,
        in db: Database
    ) throws -> FinalizationRecoveryOutcome {
        if intent.zipAutoExtract {
            try appendIntentEvent(
                db,
                jobID: job.id,
                type: "recovery.finalizationResumePostProcessing",
                revision: job.revision,
                stage: intent.stage
            )
            return FinalizationRecoveryOutcome(
                jobID: job.id,
                action: .needsPostProcessing
            )
        }
        return try completeDuringRecovery(job: &job, intent: &intent, in: db)
    }

    private static func completeDuringRecovery(
        job: inout JobRecord,
        intent: inout FinalizationIntentRecord,
        in db: Database
    ) throws -> FinalizationRecoveryOutcome {
        if JobState(rawValue: job.state) != .postProcessing {
            try transitionJob(
                &job,
                to: .postProcessing,
                terminalReason: nil,
                in: db
            )
        }
        try transitionJob(
            &job,
            to: .completed,
            terminalReason: nil,
            in: db
        )
        try FinalizationIntentRecord.deleteOne(db, key: job.id)
        try appendIntentEvent(
            db,
            jobID: job.id,
            type: "recovery.finalizationCompleted",
            revision: job.revision,
            stage: nil
        )
        return FinalizationRecoveryOutcome(jobID: job.id, action: .completed)
    }

    private static func failJob(
        _ job: inout JobRecord,
        reason: TerminalReason,
        in db: Database,
        eventType: String
    ) throws -> FinalizationRecoveryOutcome {
        try transitionJob(
            &job,
            to: reason.impliedState,
            terminalReason: reason.rawValue,
            in: db
        )
        try FinalizationIntentRecord.deleteOne(db, key: job.id)
        try appendIntentEvent(
            db,
            jobID: job.id,
            type: eventType,
            revision: job.revision,
            stage: nil
        )
        return FinalizationRecoveryOutcome(
            jobID: job.id,
            action: .failed(reason: reason)
        )
    }

    private static func transitionJob(
        _ job: inout JobRecord,
        to target: JobState,
        terminalReason: String?,
        in db: Database
    ) throws {
        guard let current = JobState(rawValue: job.state) else {
            throw FinalizationIntentRepositoryError.unknownPersistedState(job.state)
        }
        guard current.canTransition(to: target) else {
            throw FinalizationIntentRepositoryError.invalidTransition(from: current, to: target)
        }
        try validateTerminalReason(state: target, terminalReason: terminalReason)
        job.state = target.rawValue
        job.terminalReason = terminalReason
        let now = Date()
        job.updatedAt = now
        JobLocationTimeline.applyStateTransition(&job, from: current, to: target, at: now)
        job.revision += 1
        try job.update(db)

        let payload = sanitizedStatePayload(
            state: target.rawValue,
            terminalReason: terminalReason,
            revision: job.revision
        )
        try EventRecord(
            jobID: job.id,
            occurredAt: job.updatedAt,
            type: "state.changed",
            sanitizedPayload: payload
        ).insert(db)
    }

    private static func resolveDestinationDirectory(
        db: Database,
        profileID: String
    ) throws -> URL {
        guard let profile = try DestinationProfileRecord.fetchOne(db, key: profileID) else {
            throw FinalizationIntentRepositoryError.destinationUnavailable(profileID)
        }
        return try DestinationBookmark.resolveDirectory(bookmarkData: profile.bookmarkData)
    }

    private static func validateTerminalReason(
        state: JobState,
        terminalReason: String?
    ) throws {
        if JobState.terminalReasonRequiring.contains(state) {
            guard let terminalReason,
                  let reason = TerminalReason(rawValue: terminalReason)
            else {
                throw JobRepositoryError.missingTerminalReason(state: state)
            }
            guard reason.impliedState == state else {
                throw JobRepositoryError.terminalReasonMismatch(
                    state: state,
                    reason: terminalReason
                )
            }
            return
        }
        guard terminalReason == nil else {
            throw JobRepositoryError.unexpectedTerminalReason(state: state)
        }
    }

    private static func sanitizedStatePayload(
        state: String,
        terminalReason: String?,
        revision: Int
    ) -> String {
        var object: [String: Any] = [
            "state": state,
            "revision": revision
        ]
        if let terminalReason {
            object["terminalReason"] = terminalReason
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{\"state\":\"\(state)\",\"revision\":\(revision)}"
        }
        return string
    }

    private static func appendIntentEvent(
        _ db: Database,
        jobID: String,
        type: String,
        revision: Int,
        stage: String?
    ) throws {
        var object: [String: Any] = ["revision": revision]
        if let stage {
            object["stage"] = stage
        }
        let payload: String = if let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ), let string = String(data: data, encoding: .utf8) {
            string
        } else if let stage {
            "{\"revision\":\(revision),\"stage\":\"\(stage)\"}"
        } else {
            "{\"revision\":\(revision)}"
        }
        try EventRecord(
            jobID: jobID,
            occurredAt: Date(),
            type: type,
            sanitizedPayload: payload
        ).insert(db)
    }
}
