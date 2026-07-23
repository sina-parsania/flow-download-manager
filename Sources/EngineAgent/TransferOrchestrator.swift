// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Foundation
import Persistence
import SharedObservability
import TransferCore

/// Runs queued jobs through TransferCore and finalization. Agent-owned.
public actor TransferOrchestrator {
    private let database: EngineDatabase
    private let budget: TransferBudgetLedger
    private let retryPolicy: RetryPolicy
    private let progressLedger: JobProgressLedger
    private let log = EngineLog.agent
    private var isRunning = false
    private var cancelledJobIDs: Set<String> = []
    private var pausedJobIDs: Set<String> = []
    private var abortFlags: [String: TransferAbortFlag] = [:]
    private var attemptByJob: [String: Int] = [:]

    public init(
        database: EngineDatabase,
        budget: TransferBudgetLedger = TransferBudgetLedger(),
        retryPolicy: RetryPolicy = RetryPolicy(),
        progressLedger: JobProgressLedger = JobProgressLedger()
    ) {
        self.database = database
        self.budget = budget
        self.retryPolicy = retryPolicy
        self.progressLedger = progressLedger
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { await self.pump() }
    }

    public func stop() {
        isRunning = false
    }

    public func requestCancel(jobID: String) {
        cancelledJobIDs.insert(jobID)
        pausedJobIDs.remove(jobID)
        abortFlags[jobID]?.requestAbort()
    }

    public func requestPause(jobID: String) {
        pausedJobIDs.insert(jobID)
        abortFlags[jobID]?.requestAbort()
    }

    public func clearControl(jobID: String) {
        cancelledJobIDs.remove(jobID)
        pausedJobIDs.remove(jobID)
        abortFlags[jobID]?.reset()
    }

    private func pump() async {
        while isRunning {
            do {
                _ = try ProfileRepository.promoteDueScheduledJobs(database: database)
                let ids = try JobRepository.fetchQueuedJobIDs(database: database, limit: 1)
                if let jobID = ids.first {
                    await runJob(jobID)
                } else {
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            } catch {
                log.error("orchestrator pump error: \(EngineLog.redacted(error), privacy: .public)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func runJob(_ jobID: String) async {
        guard await budget.tryBeginJob() else {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return
        }
        defer {
            Task { await budget.endJob() }
            abortFlags[jobID] = nil
        }

        let abort = TransferAbortFlag()
        abortFlags[jobID] = abort

        do {
            let details = try JobRepository.loadJobForTransfer(database: database, id: jobID)
            guard details.state == "queued" else { return }
            if cancelledJobIDs.contains(jobID) {
                _ = try JobRepository.updateJobState(
                    database: database, id: jobID, state: "cancelled",
                    terminalReason: "userCancelled", expectedRevision: nil
                )
                cancelledJobIDs.remove(jobID)
                progressLedger.remove(jobID)
                return
            }
            if pausedJobIDs.contains(jobID) {
                _ = try JobRepository.updateJobState(
                    database: database, id: jobID, state: "paused",
                    terminalReason: nil, expectedRevision: nil
                )
                pausedJobIDs.remove(jobID)
                return
            }

            _ = try JobRepository.updateJobState(
                database: database, id: jobID, state: "connecting",
                terminalReason: nil, expectedRevision: nil
            )
            _ = try JobRepository.updateJobState(
                database: database, id: jobID, state: "downloading",
                terminalReason: nil, expectedRevision: nil
            )

            let accessed = details.destinationDirectory.startAccessingSecurityScopedResource()
            defer {
                if accessed { details.destinationDirectory.stopAccessingSecurityScopedResource() }
            }

            let filename = FilenameSanitizer.sanitize(details.suggestedFilename)
            let partial = details.destinationDirectory.appendingPathComponent("\(filename).partial")
            let final = uniquifiedURL(
                details.destinationDirectory.appendingPathComponent(filename)
            )

            let host = URL(string: details.canonicalURL)?.host ?? "unknown"
            guard await budget.tryAcquireSocket(host: host) else {
                _ = try JobRepository.updateJobState(
                    database: database, id: jobID, state: "queued",
                    terminalReason: nil, expectedRevision: nil
                )
                try await Task.sleep(nanoseconds: 200_000_000)
                return
            }
            defer { Task { await budget.releaseSocket(host: host) } }

            let outcome = try SegmentedTransfer.downloadHTTP(
                url: details.canonicalURL,
                partialURL: partial,
                abortFlag: abort,
                onProgress: { bytes in
                    Task { await self.recordProgress(jobID: jobID, bytes: bytes, total: nil) }
                },
                preferResume: true
            )

            if cancelledJobIDs.contains(jobID) || abort.isSet && cancelledJobIDs.contains(jobID) {
                _ = try JobRepository.updateJobState(
                    database: database, id: jobID, state: "cancelled",
                    terminalReason: "userCancelled", expectedRevision: nil
                )
                cancelledJobIDs.remove(jobID)
                progressLedger.remove(jobID)
                return
            }
            if pausedJobIDs.contains(jobID) {
                _ = try JobRepository.updateJobState(
                    database: database, id: jobID, state: "paused",
                    terminalReason: nil, expectedRevision: nil
                )
                pausedJobIDs.remove(jobID)
                progressLedger.set(
                    JobProgressSnapshot(
                        bytesTransferred: outcome.bytesWritten,
                        totalBytes: outcome.identity.contentLength,
                        speedBytesPerSecond: 0
                    ),
                    for: jobID
                )
                return
            }

            try JobRepository.updateResourceIdentity(
                database: database,
                jobID: jobID,
                finalURL: outcome.identity.finalURL,
                expectedSize: outcome.bytesWritten,
                etag: outcome.identity.etag,
                mime: outcome.identity.contentType
            )

            _ = try JobRepository.updateJobState(
                database: database, id: jobID, state: "verifying",
                terminalReason: nil, expectedRevision: nil
            )
            if let checksum = details.expectedChecksum, !checksum.isEmpty {
                try IntegrityVerifier.verifySHA256(ofFile: partial, expectedHex: checksum)
            }
            try TransferFinalizer.promote(
                partialURL: partial,
                finalURL: final,
                expectedSize: outcome.bytesWritten
            )
            _ = try JobRepository.updateJobState(
                database: database, id: jobID, state: "postProcessing",
                terminalReason: nil, expectedRevision: nil
            )
            _ = try JobRepository.updateJobState(
                database: database, id: jobID, state: "completed",
                terminalReason: nil, expectedRevision: nil
            )
            progressLedger.set(
                JobProgressSnapshot(
                    bytesTransferred: outcome.bytesWritten,
                    totalBytes: outcome.bytesWritten,
                    speedBytesPerSecond: 0
                ),
                for: jobID
            )
            attemptByJob[jobID] = nil
            log.info("job completed id=\(jobID, privacy: .public)")
        } catch TransferCore.TransferError.aborted {
            await handleAbort(jobID: jobID)
        } catch {
            await handleFailure(jobID: jobID, error: error)
        }
    }

    private func recordProgress(jobID: String, bytes: Int64, total: Int64?) {
        let previous = progressLedger.snapshot(for: jobID)
        var snap = previous ?? JobProgressSnapshot(
            bytesTransferred: 0, totalBytes: total, speedBytesPerSecond: 0
        )
        let priorBytes = snap.bytesTransferred
        snap.bytesTransferred = bytes
        if let total { snap.totalBytes = total }
        let delta = max(0, bytes - priorBytes)
        if delta > 0 {
            snap.speedBytesPerSecond = max(delta, snap.speedBytesPerSecond / 2)
        }
        progressLedger.set(snap, for: jobID)
    }

    private func handleAbort(jobID: String) async {
        if cancelledJobIDs.contains(jobID) {
            _ = try? JobRepository.updateJobState(
                database: database, id: jobID, state: "cancelled",
                terminalReason: "userCancelled", expectedRevision: nil
            )
            cancelledJobIDs.remove(jobID)
            progressLedger.remove(jobID)
            return
        }
        _ = try? JobRepository.updateJobState(
            database: database, id: jobID, state: "paused",
            terminalReason: nil, expectedRevision: nil
        )
        pausedJobIDs.remove(jobID)
        log.info("job paused id=\(jobID, privacy: .public)")
    }

    private func handleFailure(jobID: String, error: Error) async {
        log.error("job failed id=\(jobID, privacy: .public) err=\(EngineLog.redacted(error), privacy: .public)")
        let attempt = (attemptByJob[jobID] ?? 0) + 1
        attemptByJob[jobID] = attempt

        let httpStatus: Int? = {
            if case let TransferCore.TransferError.httpStatus(code) = error { return code }
            return nil
        }()

        if retryPolicy.shouldRetry(attempt: attempt, httpStatus: httpStatus) {
            let delay = retryPolicy.delayNanoseconds(attempt: attempt - 1, retryAfterSeconds: nil)
            _ = try? JobRepository.updateJobState(
                database: database, id: jobID, state: "retryWaiting",
                terminalReason: nil, expectedRevision: nil
            )
            try? await Task.sleep(nanoseconds: delay)
            if cancelledJobIDs.contains(jobID) {
                _ = try? JobRepository.updateJobState(
                    database: database, id: jobID, state: "cancelled",
                    terminalReason: "userCancelled", expectedRevision: nil
                )
                cancelledJobIDs.remove(jobID)
                return
            }
            if pausedJobIDs.contains(jobID) {
                _ = try? JobRepository.updateJobState(
                    database: database, id: jobID, state: "paused",
                    terminalReason: nil, expectedRevision: nil
                )
                pausedJobIDs.remove(jobID)
                return
            }
            _ = try? JobRepository.updateJobState(
                database: database, id: jobID, state: "queued",
                terminalReason: nil, expectedRevision: nil
            )
            return
        }

        let reason = if case let TransferCore.TransferError.httpStatus(code) = error {
            switch code {
            case 401, 403: "authenticationRejected"
            case 404, 410: "notFound"
            case 429: "serverRateLimited"
            case 500 ... 599: "serverUnavailable"
            default: "networkUnavailable"
            }
        } else if case TransferFinalizer.FinalizerError.sizeMismatch = error {
            "rangeProtocolViolation"
        } else if case IntegrityVerifier.VerifyError.checksumMismatch = error {
            "checksumMismatch"
        } else {
            "networkUnavailable"
        }
        _ = try? JobRepository.updateJobState(
            database: database, id: jobID, state: "failed",
            terminalReason: reason, expectedRevision: nil
        )
        attemptByJob[jobID] = nil
    }

    private func uniquifiedURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        for i in 2 ..< 10000 {
            let candidate = ext.isEmpty
                ? dir.appendingPathComponent("\(base) (\(i))")
                : dir.appendingPathComponent("\(base) (\(i)).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return dir.appendingPathComponent("\(base)-\(UUID().uuidString).\(ext)")
    }
}
