// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Domain
import Foundation
import Persistence
import SharedSecurity
import XPCContracts

/// Runtime facts the engine reports over the control interface. Injected so tests
/// drive uptime, build and database status deterministically.
public struct EngineServices: Sendable {
    public let engineBuild: String
    public let databaseVersion: Int
    public let isDatabaseOpen: @Sendable () -> Bool
    public let startDate: Date
    public let now: @Sendable () -> Date
    public let database: EngineDatabase?
    public let orchestrator: TransferOrchestrator?
    public let progressLedger: JobProgressLedger?
    public let changeLedger: JobChangeLedger?
    public let secretStore: (any SecretStore)?

    public init(
        engineBuild: String,
        databaseVersion: Int,
        isDatabaseOpen: @escaping @Sendable () -> Bool,
        startDate: Date,
        now: @escaping @Sendable () -> Date = { Date() },
        database: EngineDatabase? = nil,
        orchestrator: TransferOrchestrator? = nil,
        progressLedger: JobProgressLedger? = nil,
        changeLedger: JobChangeLedger? = nil,
        secretStore: (any SecretStore)? = nil
    ) {
        self.engineBuild = engineBuild
        self.databaseVersion = databaseVersion
        self.isDatabaseOpen = isDatabaseOpen
        self.startDate = startDate
        self.now = now
        self.database = database
        self.orchestrator = orchestrator
        self.progressLedger = progressLedger
        self.changeLedger = changeLedger
        self.secretStore = secretStore
    }
}

/// Per-connection exported object implementing ``EngineControlProtocol``.
final class EngineControlExporter: NSObject, EngineControlProtocol, @unchecked Sendable {
    private let services: EngineServices
    private let lock = NSLock()
    private var didHandshake = false
    /// Single bounded idempotency store shared by every RPC on this connection,
    /// replacing the 24 unbounded per-RPC dictionaries this type used to keep.
    private let replayStore = RequestReplayStore()

    init(services: EngineServices) {
        self.services = services
    }

    /// Handshake + duplicate-replay gate shared by every read RPC. Replies and
    /// returns `true` when the caller must stop (handshake missing, or a
    /// cached response for `requestID` was replayed); returns `false` when the
    /// caller should proceed to compute a fresh response.
    private func gate<T: AnyObject>(
        requestID: String,
        reply: (T?, NSError?) -> Void
    ) -> Bool {
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return true
        }
        lock.unlock()
        if let cached: T = replayStore.lookup(requestID) {
            reply(cached, nil)
            return true
        }
        return false
    }

    /// Handshake + duplicate-replay gate for mutation RPCs. Behaves like
    /// ``gate(requestID:reply:)``, but additionally fails closed with
    /// ``XPCErrorCode/duplicateRequestID`` when `requestID` already executed
    /// this mutation and its replay receipt has since been evicted — the
    /// mutation must never be re-run in that case.
    private func gateMutation<T: AnyObject>(
        requestID: String,
        reply: (T?, NSError?) -> Void
    ) -> Bool {
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return true
        }
        lock.unlock()
        if let cached: T = replayStore.lookup(requestID) {
            reply(cached, nil)
            return true
        }
        if replayStore.wasExecutedMutation(requestID) {
            reply(nil, XPCErrorCode.duplicateRequestID.error(detail: "idempotency receipt expired"))
            return true
        }
        return false
    }

    /// Thrown from a ``handleMutation(requestID:reply:failure:body:)`` body when the
    /// failure needs its own error code rather than the handler's generic one —
    /// a malformed field is `invalidPayload`, not `internalError`.
    struct MutationFailure: Error {
        let code: XPCErrorCode
        let detail: String?

        init(_ code: XPCErrorCode, _ detail: String? = nil) {
            self.code = code
            self.detail = detail
        }
    }

    /// The whole ritual every mutation RPC performs, in one place: validate the
    /// request identifier, run the handshake/replay gate, unwrap the database,
    /// execute, **record the idempotency receipt**, and reply.
    ///
    /// Recording the receipt is why this exists. It was previously the last line
    /// of twenty hand-written handlers, and a handler that omitted it would let a
    /// retried `requestID` execute the mutation a second time — a double delete or
    /// a double upsert — with nothing failing to reveal it. Here it cannot be
    /// omitted, because `body` has no way to reply on its own.
    ///
    /// `body` runs only after the gate passes. Throwing ``MutationFailure``
    /// selects a specific error code; any other error becomes `failure`.
    private func handleMutation<Response: AnyObject>(
        requestID: String,
        reply: @escaping @Sendable (Response?, NSError?) -> Void,
        failure: String,
        body: (EngineDatabase) throws -> Response
    ) {
        guard isValidRequestID(requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gateMutation(requestID: requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let response = try body(database)
            remember(requestID, response, isMutation: true)
            reply(response, nil)
        } catch let mutation as MutationFailure {
            reply(nil, mutation.code.error(detail: mutation.detail))
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: failure))
        }
    }

    /// Record a successful response so a duplicate `requestID` replays it.
    /// Must be called only after a response has actually been produced (never
    /// on an error path), since `isMutation: true` marks the mutation as
    /// executed for the fail-closed check in ``gateMutation(requestID:reply:)``.
    private func remember(_ requestID: String, _ value: some AnyObject, isMutation: Bool) {
        replayStore.store(requestID, value, bytes: Self.estimatedByteSize(of: value), isMutation: isMutation)
    }

    /// O(1) size estimate feeding the store's byte budget.
    ///
    /// This deliberately does **not** archive the response. An earlier revision
    /// called `NSKeyedArchiver.archivedData(requiringSecureCoding:)` here, which
    /// meant `listJobs` serialized the entire job list a second time on every
    /// poll — purely to produce a number — on the same process that runs curl.
    /// The budget is a safety valve, not accounting, so a per-element constant
    /// is enough; the store's count and age limits do the real bounding.
    private static func estimatedByteSize(of value: AnyObject) -> Int {
        let perElement = 512
        switch value {
        case let snapshot as JobListSnapshot:
            return 256 + snapshot.jobs.count * perElement
        case let batch as JobChangeBatch:
            return 256 + (batch.upserts.count + batch.removedJobIDs.count) * perElement
        case let response as ListEventsResponse:
            return 256 + response.events.count * perElement
        default:
            return 1024
        }
    }

    func handshake(_ hello: ClientHello, reply: @escaping @Sendable (ServerHello?, NSError?) -> Void) {
        guard hello.protocolVersion == SchemaVersions.xpcProtocol else {
            reply(nil, XPCErrorCode.unsupportedProtocolVersion.error(
                detail: "client=\(hello.protocolVersion) engine=\(SchemaVersions.xpcProtocol)"
            ))
            return
        }
        lock.lock()
        didHandshake = true
        lock.unlock()

        reply(ServerHello(
            acceptedVersion: SchemaVersions.xpcProtocol,
            engineBuild: services.engineBuild,
            databaseVersion: services.databaseVersion,
            capabilities: [
                "health", "enqueueBatch", "listJobs", "controlJob",
                "upsertCredentialProfile", "upsertProxyProfile", "upsertCookieProfile",
                "listProfiles", "getDefaultDestination", "setDefaultDestination",
                "upsertBandwidthPolicy", "getBandwidthPolicy",
                "listOrganization", "upsertProject", "upsertTag", "setJobTags", "setJobProject",
                "setJobCategory", "setJobFilename",
                "getBoolSetting", "setBoolSetting",
                "listCategoryRules", "upsertCategoryRule", "listEvents", "clearEvents", "setJobPriority",
                "deleteJob", "getJobTransferSettings",
                "listHostSettings", "upsertHostSetting", "deleteHostSetting",
                EngineCapability.jobChanges
            ]
        ), nil)
    }

    func healthStatus(requestID: String, reply: @escaping @Sendable (EngineHealthSnapshot?, NSError?) -> Void) {
        guard isValidRequestID(requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gate(requestID: requestID, reply: reply) { return }

        let snapshot = EngineHealthSnapshot(
            requestID: requestID,
            engineBuild: services.engineBuild,
            databaseVersion: services.databaseVersion,
            databaseOpen: services.isDatabaseOpen(),
            uptimeSeconds: services.now().timeIntervalSince(services.startDate)
        )
        remember(requestID, snapshot, isMutation: false)
        reply(snapshot, nil)
    }

    func enqueueBatch(
        _ request: EnqueueBatchRequest,
        reply: @escaping @Sendable (EnqueueBatchResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "enqueue failed"
        ) { database in
            let items = request.items.map { ($0.url, $0.categoryStableKey) }
            var scheduleStartAt: Date?
            if let iso = request.scheduleStartAtISO8601 {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                guard let parsed = formatter.date(from: iso) else {
                    throw MutationFailure(.invalidPayload, "malformed scheduleStartAt")
                }
                scheduleStartAt = parsed
            }
            do {
                _ = try HeaderValidator.parseExtraHeadersJSON(request.customHeadersJSON)
            } catch {
                throw MutationFailure(.invalidPayload, "invalid customHeadersJSON")
            }
            // Re-checked here as well as in the decoder: an in-process caller
            // constructs the request directly and skips secure coding entirely.
            var expectedChecksum: String?
            if let raw = request.expectedChecksumSHA256 {
                guard let normalized = ChecksumFormat.normalizedSHA256(raw) else {
                    throw MutationFailure(
                        .invalidPayload, "expected checksum must be 64 hex characters"
                    )
                }
                // One digest cannot describe several different files: applying it
                // to the whole batch would fail every job but at most one.
                guard request.items.count == 1 else {
                    throw MutationFailure(
                        .invalidPayload, "expected checksum requires a single-item batch"
                    )
                }
                expectedChecksum = normalized
            }
            if let rate = request.maxBytesPerSecond,
               rate <= 0 || rate > EngineXPC.maxJobBytesPerSecond {
                throw MutationFailure(.invalidPayload, "invalid maxBytesPerSecond")
            }
            if let connections = request.preferredConnectionCount,
               connections < 1 || connections > EngineXPC.maxPreferredConnectionCount {
                throw MutationFailure(.invalidPayload, "invalid preferredConnectionCount")
            }
            let result = try JobRepository.insertBatch(
                database: database,
                source: request.source,
                displayName: request.displayName,
                items: items,
                credentialProfileID: request.credentialProfileID,
                proxyProfileID: request.proxyProfileID,
                cookieProfileID: request.cookieProfileID,
                customHeadersJSON: request.customHeadersJSON,
                projectID: request.projectID,
                scheduleStartAt: scheduleStartAt,
                expectedChecksumSHA256: expectedChecksum,
                maxBytesPerSecond: request.maxBytesPerSecond,
                preferredConnectionCount: request.preferredConnectionCount
            )
            for jobID in result.jobIDs {
                services.changeLedger?.noteUpsert(jobID)
            }
            Task { await services.orchestrator?.start() }
            return EnqueueBatchResponse(
                requestID: request.requestID,
                batchID: result.batchID,
                jobIDs: result.jobIDs,
                acceptedCount: result.jobIDs.count
            )
        }
    }

    func listJobs(
        requestID: String,
        reply: @escaping @Sendable (JobListSnapshot?, NSError?) -> Void
    ) {
        guard isValidRequestID(requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gate(requestID: requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let rows = try JobRepository.fetchJobRows(database: database)
            let progressMap = services.progressLedger?.all() ?? [:]
            let jobs = rows.map { row in
                Self.makeJobSnapshot(row: row, progressMap: progressMap)
            }
            let sequence = services.changeLedger?.checkpointFullSync() ?? 1
            let snapshot = JobListSnapshot(
                requestID: requestID,
                sequence: sequence,
                jobs: jobs
            )
            remember(requestID, snapshot, isMutation: false)
            reply(snapshot, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "list failed"))
        }
    }

    func pullJobChanges(
        _ request: PullJobChangesRequest,
        reply: @escaping @Sendable (JobChangeBatch?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gate(requestID: request.requestID, reply: reply) { return }

        guard let changeLedger = services.changeLedger else {
            reply(nil, XPCErrorCode.internalError.error(detail: "jobChanges unavailable"))
            return
        }
        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        let drain = changeLedger.drain(since: request.sinceSequence)
        if drain.hasGap {
            let batch = JobChangeBatch(
                requestID: request.requestID,
                sequence: drain.sequence,
                sinceSequence: request.sinceSequence,
                upserts: [],
                removedJobIDs: [],
                hasGap: true
            )
            remember(request.requestID, batch, isMutation: false)
            reply(batch, nil)
            return
        }
        if drain.idle {
            let batch = JobChangeBatch(
                requestID: request.requestID,
                sequence: drain.sequence,
                sinceSequence: request.sinceSequence,
                upserts: [],
                removedJobIDs: [],
                hasGap: false
            )
            remember(request.requestID, batch, isMutation: false)
            reply(batch, nil)
            return
        }

        do {
            let progressMap = services.progressLedger?.all() ?? [:]
            let rows = try JobRepository.fetchJobRows(
                database: database,
                jobIDs: Set(drain.upsertIDs)
            )
            let upserts = rows.map { row in
                Self.makeJobSnapshot(row: row, progressMap: progressMap)
            }
            let batch = JobChangeBatch(
                requestID: request.requestID,
                sequence: drain.sequence,
                sinceSequence: request.sinceSequence,
                upserts: upserts,
                removedJobIDs: drain.removedIDs,
                hasGap: false
            )
            remember(request.requestID, batch, isMutation: false)
            reply(batch, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "pullJobChanges failed"))
        }
    }

    private static func makeJobSnapshot(
        row: (
            job: JobRecord,
            resource: ResourceRecord,
            category: CategoryRecord,
            projectName: String?,
            tagNames: [String],
            tagIDs: [String]
        ),
        progressMap: [String: JobProgressSnapshot]
    ) -> JobSnapshot {
        let job = row.job
        let resource = row.resource
        let downloadURL = resource.finalURL ?? resource.canonicalURL
        let host = URL(string: downloadURL)?.host
            ?? URL(string: resource.canonicalURL)?.host
            ?? ""
        let derivedName = FilenameSanitizer.preferredFilename(
            contentDisposition: nil,
            urlString: downloadURL,
            existingEvidence: resource.filenameEvidence,
            contentType: resource.mimeEvidence
        )
        let name = job.finalFilename ?? derivedName
        let live = progressMap[job.id]
        let total = live?.totalBytes ?? resource.expectedSize
        let isLiveTransfer = job.state == "downloading"
            || job.state == "connecting"
            || job.state == "verifying"
            || job.state == "merging"
            || job.state == "postProcessing"
        let transferred: Int64 = if job.state == "completed" {
            // Prefer the known total once the live ledger is cleared after finish.
            total ?? live?.bytesTransferred ?? 0
        } else {
            live?.bytesTransferred ?? 0
        }
        let speed = isLiveTransfer ? (live?.speedBytesPerSecond ?? 0) : 0
        let fraction: Double? = if job.state == "completed" {
            live?.progressFraction ?? 1.0
        } else {
            live?.progressFraction
        }
        let destinationDirectoryPath = job.destinationPath
        let filePath = Self.resolvedFilePath(
            directoryPath: destinationDirectoryPath,
            filename: name,
            state: job.state
        )
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        return JobSnapshot(
            id: job.id,
            name: name,
            sourceHost: host,
            sourceURL: downloadURL,
            state: job.state,
            progressFraction: fraction,
            bytesTransferred: transferred,
            totalBytes: total,
            speedBytesPerSecond: speed,
            categoryKey: row.category.stableKey,
            projectID: job.projectID,
            projectName: row.projectName,
            tagIDs: row.tagIDs,
            tagNames: row.tagNames,
            priority: job.priority,
            startedAtISO8601: job.startedAt.map { dateFormatter.string(from: $0) },
            completedAtISO8601: job.completedAt.map { dateFormatter.string(from: $0) },
            destinationDirectoryPath: destinationDirectoryPath,
            filePath: filePath
        )
    }

    /// Prefer an existing final file, then `.partial`, else the expected final path
    /// when a destination directory is known.
    private static func resolvedFilePath(
        directoryPath: String?,
        filename: String,
        state: String
    ) -> String? {
        guard let directoryPath, !directoryPath.isEmpty, !filename.isEmpty else { return nil }
        let folder = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let finalURL = folder.appendingPathComponent(filename)
        let partialURL = folder.appendingPathComponent("\(filename).partial")
        if FileManager.default.fileExists(atPath: finalURL.path) {
            return finalURL.path
        }
        if FileManager.default.fileExists(atPath: partialURL.path) {
            return partialURL.path
        }
        if state == "completed" || state == "failed" || state == "cancelled" {
            return finalURL.path
        }
        return partialURL.path
    }

    func controlJob(
        _ request: JobCommandRequest,
        reply: @escaping @Sendable (JobCommandResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "control failed"
        ) { database in
            let newState: JobState
            let reason: String?
            switch request.command {
            case .pause:
                newState = .paused
                reason = nil
                Task { await services.orchestrator?.requestPause(jobID: request.jobID) }
            case .resume:
                newState = .queued
                reason = nil
                Task { await services.orchestrator?.requestResume(jobID: request.jobID) }
                Task { await services.orchestrator?.start() }
            case .cancel:
                newState = .cancelled
                reason = "userCancelled"
                Task { await services.orchestrator?.requestCancel(jobID: request.jobID) }
            case .retry:
                newState = .queued
                reason = nil
                Task { await services.orchestrator?.requestResume(jobID: request.jobID) }
                Task { await services.orchestrator?.start() }
            case .restart:
                // Wipe partial + clear identity size, then requeue (FR restart-from-scratch).
                if let details = try? JobRepository.loadJobForTransfer(
                    database: database,
                    id: request.jobID
                ) {
                    let filename = FilenameSanitizer.sanitize(details.suggestedFilename)
                    let partial = details.writeDirectory
                        .appendingPathComponent("\(filename).partial")
                    let accessed = details.destinationDirectory.startAccessingSecurityScopedResource()
                    defer {
                        if accessed {
                            details.destinationDirectory.stopAccessingSecurityScopedResource()
                        }
                    }
                    try? FileManager.default.removeItem(at: partial)
                    try? FileManager.default.removeItem(
                        at: URL(fileURLWithPath: partial.path + ".segmap")
                    )
                }
                try JobRepository.clearResourceIdentitySize(
                    database: database,
                    jobID: request.jobID
                )
                Task { await services.orchestrator?.clearProgress(jobID: request.jobID) }
                newState = .queued
                reason = nil
                Task { await services.orchestrator?.requestResume(jobID: request.jobID) }
                Task { await services.orchestrator?.start() }
            }
            let revision = try JobRepository.updateJobState(
                database: database,
                id: request.jobID,
                state: newState,
                terminalReason: reason,
                expectedRevision: request.expectedRevision > 0 ? request.expectedRevision : nil,
                resetTimelineForRestart: request.command == .restart
            )
            services.changeLedger?.noteUpsert(request.jobID)
            return JobCommandResponse(
                requestID: request.requestID,
                jobID: request.jobID,
                state: newState.rawValue,
                revision: revision
            )
        }
    }

    func setJobPriority(
        _ request: SetJobPriorityRequest,
        reply: @escaping @Sendable (SetJobPriorityResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "set job priority failed"
        ) { database in
            let revision = try JobRepository.setPriority(
                database: database,
                id: request.jobID,
                priority: request.priority
            )
            services.changeLedger?.noteUpsert(request.jobID)
            return SetJobPriorityResponse(
                requestID: request.requestID,
                jobID: request.jobID,
                priority: request.priority,
                revision: revision
            )
        }
    }

    func deleteJob(
        _ request: DeleteJobRequest,
        reply: @escaping @Sendable (DeleteJobResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "delete job failed"
        ) { database in
            // Abort any in-flight transfer before wiping files / dropping the row
            // so curl is not writing into a deleted path.
            if let orchestrator = services.orchestrator {
                let jobID = request.jobID
                let gate = DispatchSemaphore(value: 0)
                Task {
                    await orchestrator.requestCancel(jobID: jobID)
                    await orchestrator.clearProgress(jobID: jobID)
                    await orchestrator.clearControl(jobID: jobID)
                    gate.signal()
                }
                _ = gate.wait(timeout: .now() + .milliseconds(250))
            }

            if request.deleteFiles,
               let details = try? JobRepository.loadJobForTransfer(
                   database: database,
                   id: request.jobID
               ) {
                let filename = FilenameSanitizer.sanitize(details.suggestedFilename)
                let accessed = details.destinationDirectory.startAccessingSecurityScopedResource()
                defer {
                    if accessed { details.destinationDirectory.stopAccessingSecurityScopedResource() }
                }
                let partial = details.writeDirectory
                    .appendingPathComponent("\(filename).partial")
                let final = details.writeDirectory
                    .appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: partial)
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: partial.path + ".segmap")
                )
                try? FileManager.default.removeItem(at: final)
            }

            let previousState: String
            do {
                previousState = try JobRepository.deleteTerminalJob(
                    database: database,
                    id: request.jobID
                )
            } catch JobRepositoryError.jobNotFound {
                throw MutationFailure(.invalidPayload, "job not found")
            }
            services.changeLedger?.noteRemoval(request.jobID)
            return DeleteJobResponse(
                requestID: request.requestID,
                jobID: request.jobID,
                previousState: previousState
            )
        }
    }

    func upsertCredentialProfile(
        _ request: UpsertCredentialProfileRequest,
        reply: @escaping @Sendable (UpsertCredentialProfileResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "credential upsert failed"
        ) { database in
            // The password half of this profile lives in the secret store, so both
            // must be present; the helper only unwraps the database.
            guard let secretStore = services.secretStore else {
                throw MutationFailure(.internalError, "database unavailable")
            }
            try ProfileRepository.upsertCredentialProfile(
                database: database,
                id: request.profileID,
                metadata: CredentialProfileMetadata(
                    displayName: request.displayName,
                    username: request.username
                ),
                passwordUTF8: request.passwordUTF8,
                secretStore: secretStore
            )
            return UpsertCredentialProfileResponse(
                requestID: request.requestID,
                profileID: request.profileID
            )
        }
    }

    func upsertProxyProfile(
        _ request: UpsertProxyProfileRequest,
        reply: @escaping @Sendable (UpsertProxyProfileResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "proxy upsert failed"
        ) { database in
            try ProfileRepository.upsertProxyProfile(
                database: database,
                id: request.profileID,
                metadata: ProxyProfileMetadata(
                    displayName: request.displayName,
                    kind: request.kind,
                    host: request.host,
                    port: request.port
                )
            )
            return UpsertProxyProfileResponse(
                requestID: request.requestID,
                profileID: request.profileID
            )
        }
    }

    func listProfiles(
        requestID: String,
        reply: @escaping @Sendable (ListProfilesResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gate(requestID: requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let credentials = try ProfileRepository.listCredentialProfiles(database: database)
                .map { id, meta in
                    CredentialProfileSnapshot(
                        id: id,
                        displayName: meta.displayName,
                        username: meta.username
                    )
                }
            let proxies = try ProfileRepository.listProxyProfiles(database: database)
                .map { id, meta in
                    ProxyProfileSnapshot(
                        id: id,
                        displayName: meta.displayName,
                        kind: meta.kind,
                        host: meta.host,
                        port: meta.port
                    )
                }
            let cookies = try ProfileRepository.listCookieProfiles(database: database)
                .map { id, displayName, _ in
                    CookieProfileSnapshot(id: id, displayName: displayName)
                }
            let response = ListProfilesResponse(
                requestID: requestID,
                credentials: credentials,
                proxies: proxies,
                cookies: cookies
            )
            remember(requestID, response, isMutation: false)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "list profiles failed"))
        }
    }

    func getDefaultDestination(
        requestID: String,
        reply: @escaping @Sendable (GetDefaultDestinationResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gate(requestID: requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let snap = try DestinationRepository.fetchDefault(database: database)
            let response = GetDefaultDestinationResponse(
                requestID: requestID,
                destination: DefaultDestinationSnapshot(
                    pathDisplay: snap.pathDisplay,
                    folderName: snap.folderName,
                    isDefaultDownloads: snap.isDefaultDownloads
                )
            )
            remember(requestID, response, isMutation: false)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "get destination failed"))
        }
    }

    func setDefaultDestination(
        _ request: SetDefaultDestinationRequest,
        reply: @escaping @Sendable (SetDefaultDestinationResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "set destination failed"
        ) { database in
            let snap: DestinationRepository.Snapshot
            do {
                snap = if let bookmark = request.bookmarkData {
                    try DestinationRepository.setDefaultBookmark(
                        database: database,
                        bookmarkData: bookmark,
                        displayName: request.displayName,
                        pathHint: request.pathDisplay
                    )
                } else {
                    try DestinationRepository.resetDefault(database: database)
                }
            } catch {
                // A stale or foreign bookmark is bad input, not an engine fault, so
                // this stays `invalidPayload` rather than the helper's default.
                throw MutationFailure(.invalidPayload, "set destination failed")
            }
            return SetDefaultDestinationResponse(
                requestID: request.requestID,
                destination: DefaultDestinationSnapshot(
                    pathDisplay: snap.pathDisplay,
                    folderName: snap.folderName,
                    isDefaultDownloads: snap.isDefaultDownloads
                )
            )
        }
    }

    func upsertCookieProfile(
        _ request: UpsertCookieProfileRequest,
        reply: @escaping @Sendable (UpsertCookieProfileResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "cookie profile upsert failed"
        ) { database in
            try ProfileRepository.upsertCookieProfile(
                database: database,
                id: request.profileID,
                displayName: request.displayName
            )
            _ = try ProfileRepository.cookieJarPath(
                database: database,
                profileID: request.profileID,
                applicationSupportRoot: Self.applicationSupportRoot()
            )
            return UpsertCookieProfileResponse(
                requestID: request.requestID,
                profileID: request.profileID
            )
        }
    }

    func upsertBandwidthPolicy(
        _ request: UpsertBandwidthPolicyRequest,
        reply: @escaping @Sendable (UpsertBandwidthPolicyResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "bandwidth policy upsert failed"
        ) { database in
            do {
                _ = try BandwidthWindowEvaluator.parseWindowsJSON(request.windowsJSON)
            } catch is BandwidthWindowEvaluator.ParseError {
                throw MutationFailure(.invalidPayload, "invalid windowsJSON")
            }
            try ProfileRepository.upsertBandwidthPolicy(
                database: database,
                id: request.policyID,
                name: request.name,
                windowsJSON: request.windowsJSON,
                maxBytesPerSecond: request.maxBytesPerSecond
            )
            return UpsertBandwidthPolicyResponse(
                requestID: request.requestID,
                policyID: request.policyID
            )
        }
    }

    func getBandwidthPolicy(
        requestID: String,
        reply: @escaping @Sendable (GetBandwidthPolicyResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gate(requestID: requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let record = try ProfileRepository.fetchGlobalBandwidthPolicy(database: database)
            let snapshot = record.map {
                BandwidthPolicySnapshot(
                    id: $0.id,
                    name: $0.name,
                    windowsJSON: $0.windowsJSON,
                    maxBytesPerSecond: $0.maxBytesPerSecond
                )
            }
            let response = GetBandwidthPolicyResponse(requestID: requestID, policy: snapshot)
            remember(requestID, response, isMutation: false)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "get bandwidth policy failed"))
        }
    }

    func listOrganization(
        requestID: String,
        reply: @escaping @Sendable (ListOrganizationResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gate(requestID: requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let projects = try OrganizationRepository.listProjects(database: database)
                .map { ProjectSnapshot(id: $0.id, name: $0.name, colorRole: $0.colorRole) }
            let tags = try OrganizationRepository.listTags(database: database)
                .map { TagSnapshot(id: $0.id, name: $0.name) }
            let response = ListOrganizationResponse(
                requestID: requestID,
                projects: projects,
                tags: tags
            )
            remember(requestID, response, isMutation: false)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "list organization failed"))
        }
    }

    func upsertProject(
        _ request: UpsertProjectRequest,
        reply: @escaping @Sendable (UpsertProjectResponse?, NSError?) -> Void
    ) {
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "project upsert failed"
        ) { database in
            try OrganizationRepository.upsertProject(
                database: database,
                id: request.projectID,
                name: request.name,
                colorRole: request.colorRole
            )
            return UpsertProjectResponse(
                requestID: request.requestID,
                projectID: request.projectID
            )
        }
    }

    func upsertTag(
        _ request: UpsertTagRequest,
        reply: @escaping @Sendable (UpsertTagResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "tag upsert failed"
        ) { database in
            let resolvedTagID = try OrganizationRepository.upsertTag(
                database: database,
                id: request.tagID,
                name: request.name
            )
            return UpsertTagResponse(
                requestID: request.requestID,
                tagID: resolvedTagID
            )
        }
    }

    func setJobTags(
        _ request: SetJobTagsRequest,
        reply: @escaping @Sendable (SetJobTagsResponse?, NSError?) -> Void
    ) {
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "set job tags failed"
        ) { database in
            try OrganizationRepository.setJobTags(
                database: database,
                jobID: request.jobID,
                tagIDs: request.tagIDs
            )
            services.changeLedger?.noteUpsert(request.jobID)
            return SetJobTagsResponse(
                requestID: request.requestID,
                jobID: request.jobID
            )
        }
    }

    func setJobProject(
        _ request: SetJobProjectRequest,
        reply: @escaping @Sendable (SetJobProjectResponse?, NSError?) -> Void
    ) {
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "set job project failed"
        ) { database in
            try OrganizationRepository.setJobProject(
                database: database,
                jobID: request.jobID,
                projectID: request.projectID
            )
            services.changeLedger?.noteUpsert(request.jobID)
            return SetJobProjectResponse(
                requestID: request.requestID,
                jobID: request.jobID
            )
        }
    }

    func setJobCategory(
        _ request: SetJobCategoryRequest,
        reply: @escaping @Sendable (SetJobCategoryResponse?, NSError?) -> Void
    ) {
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "set job category failed"
        ) { database in
            do {
                try JobRepository.setJobCategory(
                    database: database,
                    jobID: request.jobID,
                    categoryStableKey: request.categoryStableKey
                )
            } catch JobRepositoryError.unknownCategory {
                throw MutationFailure(.invalidPayload, "unknown category")
            } catch JobRepositoryError.jobNotFound {
                throw MutationFailure(.invalidPayload, "job not found")
            }
            services.changeLedger?.noteUpsert(request.jobID)
            return SetJobCategoryResponse(
                requestID: request.requestID,
                jobID: request.jobID,
                categoryStableKey: request.categoryStableKey
            )
        }
    }

    func setJobFilename(
        _ request: SetJobFilenameRequest,
        reply: @escaping @Sendable (SetJobFilenameResponse?, NSError?) -> Void
    ) {
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "set job filename failed"
        ) { database in
            let filename: String
            do {
                filename = try JobRepository.setJobFilename(
                    database: database,
                    jobID: request.jobID,
                    filename: request.filename
                )
            } catch JobRepositoryError.renameWhileActive {
                throw MutationFailure(.invalidPayload, "pause the download before renaming")
            } catch JobRepositoryError.renameTargetExists {
                throw MutationFailure(.invalidPayload, "a file with that name already exists")
            } catch JobRepositoryError.invalidFilename {
                throw MutationFailure(.invalidPayload, "invalid filename")
            } catch JobRepositoryError.jobNotFound {
                throw MutationFailure(.invalidPayload, "job not found")
            }
            services.changeLedger?.noteUpsert(request.jobID)
            return SetJobFilenameResponse(
                requestID: request.requestID,
                jobID: request.jobID,
                filename: filename
            )
        }
    }

    func getBoolSetting(
        _ request: GetBoolSettingRequest,
        reply: @escaping @Sendable (GetBoolSettingResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gate(requestID: request.requestID, reply: reply) { return }

        guard AgentBoolSettings.allowlistedKeys.contains(request.key) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "unknown setting key"))
            return
        }
        let value = AgentBoolSettings.bool(forKey: request.key)
        let response = GetBoolSettingResponse(
            requestID: request.requestID,
            key: request.key,
            value: value
        )
        remember(request.requestID, response, isMutation: false)
        reply(response, nil)
    }

    /// Deliberately not routed through ``handleMutation(requestID:reply:failure:body:)``:
    /// this setting lives in user defaults, not the database, and the helper fails
    /// closed when the database is unavailable. Converting it would make the
    /// setting unwritable whenever the database is closed, which it is not today.
    func setBoolSetting(
        _ request: SetBoolSettingRequest,
        reply: @escaping @Sendable (SetBoolSettingResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard AgentBoolSettings.setBool(request.value, forKey: request.key) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "unknown setting key"))
            return
        }
        let response = SetBoolSettingResponse(
            requestID: request.requestID,
            key: request.key,
            value: request.value
        )
        remember(request.requestID, response, isMutation: true)
        reply(response, nil)
    }

    func listCategoryRules(
        requestID: String,
        reply: @escaping @Sendable (ListCategoryRulesResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gate(requestID: requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let rules = try CategoryRulesRepository.list(database: database)
                .map {
                    CategoryRuleSnapshot(
                        id: $0.id,
                        priority: $0.priority,
                        enabled: $0.enabled,
                        predicateJSON: $0.predicate,
                        categoryStableKey: $0.action
                    )
                }
            let response = ListCategoryRulesResponse(requestID: requestID, rules: rules)
            remember(requestID, response, isMutation: false)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "list category rules failed"))
        }
    }

    func upsertCategoryRule(
        _ request: UpsertCategoryRuleRequest,
        reply: @escaping @Sendable (UpsertCategoryRuleResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "category rule upsert failed"
        ) { database in
            try CategoryRulesRepository.upsert(
                database: database,
                id: request.ruleID,
                priority: request.priority,
                enabled: request.enabled,
                predicateJSON: request.predicateJSON,
                categoryStableKey: request.categoryStableKey
            )
            return UpsertCategoryRuleResponse(
                requestID: request.requestID,
                ruleID: request.ruleID
            )
        }
    }

    func listEvents(
        _ request: ListEventsRequest,
        reply: @escaping @Sendable (ListEventsResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if let jobID = request.jobID, UUID(uuidString: jobID) == nil {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed jobID"))
            return
        }
        guard request.limit > 0, request.limit <= EngineXPC.maxCollectionCount else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "invalid limit"))
            return
        }
        if gate(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let records = try JobRepository.listEvents(
                database: database,
                jobID: request.jobID,
                limit: request.limit
            )
            let events = records.compactMap { record -> EventSnapshot? in
                guard let sequence = record.sequence else { return nil }
                return EventSnapshot(
                    sequence: sequence,
                    jobID: record.jobID,
                    occurredAtISO8601: formatter.string(from: record.occurredAt),
                    type: record.type,
                    sanitizedPayload: record.sanitizedPayload
                )
            }
            let response = ListEventsResponse(requestID: request.requestID, events: events)
            remember(request.requestID, response, isMutation: false)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "list events failed"))
        }
    }

    func clearEvents(
        _ request: ClearEventsRequest,
        reply: @escaping @Sendable (ClearEventsResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        guard UUID(uuidString: request.jobID) != nil else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed jobID"))
            return
        }
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "clear events failed"
        ) { database in
            let deleted = try JobRepository.clearEvents(database: database, jobID: request.jobID)
            return ClearEventsResponse(requestID: request.requestID, deletedCount: deleted)
        }
    }

    func getJobTransferSettings(
        _ request: GetJobTransferSettingsRequest,
        reply: @escaping @Sendable (GetJobTransferSettingsResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        guard UUID(uuidString: request.jobID) != nil else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed jobID"))
            return
        }
        if gate(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let settings = try JobRepository.loadTransferSettings(
                database: database,
                jobID: request.jobID
            )
            var globalLimit: Int64?
            if let policy = try ProfileRepository.fetchGlobalBandwidthPolicy(database: database) {
                let windows = try BandwidthWindowEvaluator.parseWindowsJSON(policy.windowsJSON)
                if BandwidthWindowEvaluator.isActive(
                    now: services.now(),
                    calendar: .current,
                    windows: windows
                ) {
                    globalLimit = policy.maxBytesPerSecond
                }
            }
            let response = GetJobTransferSettingsResponse(
                requestID: request.requestID,
                jobID: settings.jobID,
                state: settings.state,
                terminalReason: settings.terminalReason,
                expectedChecksumSHA256: settings.expectedChecksum
                    .flatMap(ChecksumFormat.normalizedSHA256),
                maxBytesPerSecond: settings.maxBytesPerSecond,
                preferredConnectionCount: settings.preferredConnectionCount,
                globalMaxBytesPerSecond: globalLimit
            )
            remember(request.requestID, response, isMutation: false)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "job transfer settings unavailable"))
        }
    }

    func listHostSettings(
        requestID: String,
        reply: @escaping @Sendable (ListHostSettingsResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gate(requestID: requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let settings = try HostSettingRepository.list(database: database).map {
                HostSettingSnapshot(
                    host: $0.host,
                    maxConnections: $0.maxConnections,
                    maxBytesPerSecond: $0.maxBytesPerSecond,
                    userAgent: $0.userAgent,
                    credentialProfileID: $0.credentialProfileID
                )
            }
            let response = ListHostSettingsResponse(requestID: requestID, settings: settings)
            remember(requestID, response, isMutation: false)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "list host settings failed"))
        }
    }

    func upsertHostSetting(
        _ request: UpsertHostSettingRequest,
        reply: @escaping @Sendable (UpsertHostSettingResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "host setting upsert failed"
        ) { database in
            if let connections = request.maxConnections, !(1 ... 32).contains(connections) {
                throw MutationFailure(.invalidPayload, "invalid maxConnections")
            }
            if let rate = request.maxBytesPerSecond, rate <= 0 {
                throw MutationFailure(.invalidPayload, "invalid maxBytesPerSecond")
            }
            let stored: HostSettingRepository.Setting
            do {
                stored = try HostSettingRepository.upsert(
                    database: database,
                    setting: HostSettingRepository.Setting(
                        host: request.host,
                        maxConnections: request.maxConnections,
                        maxBytesPerSecond: request.maxBytesPerSecond,
                        userAgent: request.clearUserAgent ? nil : request.userAgent,
                        credentialProfileID: request.clearCredentialProfileID
                            ? nil
                            : request.credentialProfileID
                    )
                )
            } catch HostSettingRepositoryError.invalidHost {
                throw MutationFailure(.invalidPayload, "invalid host")
            } catch HostSettingRepositoryError.invalidMaxConnections {
                throw MutationFailure(.invalidPayload, "invalid maxConnections")
            } catch HostSettingRepositoryError.invalidMaxBytesPerSecond {
                throw MutationFailure(.invalidPayload, "invalid maxBytesPerSecond")
            } catch HostSettingRepositoryError.invalidUserAgent {
                throw MutationFailure(.invalidPayload, "invalid userAgent")
            } catch HostSettingRepositoryError.invalidCredentialProfileID,
                HostSettingRepositoryError.unknownCredentialProfileID {
                throw MutationFailure(.invalidPayload, "invalid credentialProfileID")
            }
            return UpsertHostSettingResponse(
                requestID: request.requestID,
                setting: HostSettingSnapshot(
                    host: stored.host,
                    maxConnections: stored.maxConnections,
                    maxBytesPerSecond: stored.maxBytesPerSecond,
                    userAgent: stored.userAgent,
                    credentialProfileID: stored.credentialProfileID
                )
            )
        }
    }

    func deleteHostSetting(
        _ request: DeleteHostSettingRequest,
        reply: @escaping @Sendable (DeleteHostSettingResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        handleMutation(
            requestID: request.requestID,
            reply: reply,
            failure: "host setting delete failed"
        ) { database in
            let deleted: Bool
            do {
                deleted = try HostSettingRepository.delete(database: database, host: request.host)
            } catch HostSettingRepositoryError.invalidHost {
                throw MutationFailure(.invalidPayload, "invalid host")
            }
            return DeleteHostSettingResponse(
                requestID: request.requestID,
                host: HostSettingRepository.normalizeHost(request.host) ?? request.host.lowercased(),
                deleted: deleted
            )
        }
    }

    private func isValidRequestID(_ requestID: String) -> Bool {
        requestID.count <= EngineXPC.maxPayloadStringLength && UUID(uuidString: requestID) != nil
    }

    private static func applicationSupportRoot() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(EngineXPC.machServiceName, isDirectory: true)
    }
}

/// `NSXPCListenerDelegate` that authorizes and configures new connections.
public final class EngineServiceListener: NSObject, NSXPCListenerDelegate {
    private let validator: any ClientIdentityValidator
    private let services: EngineServices

    public init(validator: any ClientIdentityValidator, services: EngineServices) {
        self.validator = validator
        self.services = services
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard validator.isAuthorized(newConnection) else {
            return false
        }
        newConnection.exportedInterface = EngineControlInterface.make()
        newConnection.exportedObject = EngineControlExporter(services: services)
        newConnection.resume()
        return true
    }
}
