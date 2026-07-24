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
        self.secretStore = secretStore
    }
}

/// Per-connection exported object implementing ``EngineControlProtocol``.
final class EngineControlExporter: NSObject, EngineControlProtocol, @unchecked Sendable {
    private let services: EngineServices
    private let lock = NSLock()
    private var didHandshake = false
    private var snapshotSequence: Int64 = 0
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
                "deleteJob", "getJobTransferSettings"
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
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let items = request.items.map { ($0.url, $0.categoryStableKey) }
            var scheduleStartAt: Date?
            if let iso = request.scheduleStartAtISO8601 {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                guard let parsed = formatter.date(from: iso) else {
                    reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed scheduleStartAt"))
                    return
                }
                scheduleStartAt = parsed
            }
            do {
                _ = try HeaderValidator.parseExtraHeadersJSON(request.customHeadersJSON)
            } catch {
                reply(nil, XPCErrorCode.invalidPayload.error(detail: "invalid customHeadersJSON"))
                return
            }
            // Re-checked here as well as in the decoder: an in-process caller
            // constructs the request directly and skips secure coding entirely.
            var expectedChecksum: String?
            if let raw = request.expectedChecksumSHA256 {
                guard let normalized = ChecksumFormat.normalizedSHA256(raw) else {
                    reply(nil, XPCErrorCode.invalidPayload.error(
                        detail: "expected checksum must be 64 hex characters"
                    ))
                    return
                }
                // One digest cannot describe several different files: applying it
                // to the whole batch would fail every job but at most one.
                guard request.items.count == 1 else {
                    reply(nil, XPCErrorCode.invalidPayload.error(
                        detail: "expected checksum requires a single-item batch"
                    ))
                    return
                }
                expectedChecksum = normalized
            }
            if let rate = request.maxBytesPerSecond,
               rate <= 0 || rate > EngineXPC.maxJobBytesPerSecond {
                reply(nil, XPCErrorCode.invalidPayload.error(detail: "invalid maxBytesPerSecond"))
                return
            }
            if let connections = request.preferredConnectionCount,
               connections < 1 || connections > EngineXPC.maxPreferredConnectionCount {
                reply(nil, XPCErrorCode.invalidPayload.error(detail: "invalid preferredConnectionCount"))
                return
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
            let response = EnqueueBatchResponse(
                requestID: request.requestID,
                batchID: result.batchID,
                jobIDs: result.jobIDs,
                acceptedCount: result.jobIDs.count
            )
            remember(request.requestID, response, isMutation: true)
            Task { await services.orchestrator?.start() }
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "enqueue failed"))
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
            let jobs = rows.map { job, resource, category, projectName, tagNames, tagIDs -> JobSnapshot in
                let downloadURL = resource.finalURL ?? resource.canonicalURL
                let host = URL(string: downloadURL)?.host
                    ?? URL(string: resource.canonicalURL)?.host
                    ?? ""
                let name = FilenameSanitizer.preferredFilename(
                    contentDisposition: nil,
                    urlString: downloadURL,
                    existingEvidence: resource.filenameEvidence
                )
                let live = progressMap[job.id]
                let total = live?.totalBytes ?? resource.expectedSize
                let transferred = live?.bytesTransferred ?? 0
                let isLiveTransfer = job.state == "downloading"
                    || job.state == "connecting"
                    || job.state == "verifying"
                    || job.state == "merging"
                    || job.state == "postProcessing"
                // Stale ledger rates must not show on paused/queued/failed rows.
                let speed = isLiveTransfer ? (live?.speedBytesPerSecond ?? 0) : 0
                let fraction: Double? = if job.state == "completed" {
                    live?.progressFraction ?? 1.0
                } else {
                    live?.progressFraction
                }
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
                    categoryKey: category.stableKey,
                    projectID: job.projectID,
                    projectName: projectName,
                    tagIDs: tagIDs,
                    tagNames: tagNames,
                    priority: job.priority
                )
            }
            lock.lock()
            snapshotSequence += 1
            let sequence = snapshotSequence
            lock.unlock()
            let snapshot = JobListSnapshot(requestID: requestID, sequence: sequence, jobs: jobs)
            remember(requestID, snapshot, isMutation: false)
            reply(snapshot, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "list failed"))
        }
    }

    func controlJob(
        _ request: JobCommandRequest,
        reply: @escaping @Sendable (JobCommandResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let newState: String
            let reason: String?
            switch request.command {
            case .pause:
                newState = "paused"
                reason = nil
                Task { await services.orchestrator?.requestPause(jobID: request.jobID) }
            case .resume:
                newState = "queued"
                reason = nil
                Task { await services.orchestrator?.requestResume(jobID: request.jobID) }
                Task { await services.orchestrator?.start() }
            case .cancel:
                newState = "cancelled"
                reason = "userCancelled"
                Task { await services.orchestrator?.requestCancel(jobID: request.jobID) }
            case .retry:
                newState = "queued"
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
                    let partial = details.destinationDirectory
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
                newState = "queued"
                reason = nil
                Task { await services.orchestrator?.requestResume(jobID: request.jobID) }
                Task { await services.orchestrator?.start() }
            }
            let revision = try JobRepository.updateJobState(
                database: database,
                id: request.jobID,
                state: newState,
                terminalReason: reason,
                expectedRevision: request.expectedRevision > 0 ? request.expectedRevision : nil
            )
            let response = JobCommandResponse(
                requestID: request.requestID,
                jobID: request.jobID,
                state: newState,
                revision: revision
            )
            remember(request.requestID, response, isMutation: true)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "control failed"))
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
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let revision = try JobRepository.setPriority(
                database: database,
                id: request.jobID,
                priority: request.priority
            )
            let response = SetJobPriorityResponse(
                requestID: request.requestID,
                jobID: request.jobID,
                priority: request.priority,
                revision: revision
            )
            remember(request.requestID, response, isMutation: true)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "set job priority failed"))
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
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
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
                let partial = details.destinationDirectory
                    .appendingPathComponent("\(filename).partial")
                let final = details.destinationDirectory
                    .appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: partial)
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: partial.path + ".segmap")
                )
                try? FileManager.default.removeItem(at: final)
            }

            let previousState = try JobRepository.deleteTerminalJob(
                database: database,
                id: request.jobID
            )
            let response = DeleteJobResponse(
                requestID: request.requestID,
                jobID: request.jobID,
                previousState: previousState
            )
            remember(request.requestID, response, isMutation: true)
            reply(response, nil)
        } catch let error as JobRepositoryError {
            switch error {
            case .notTerminal:
                reply(nil, XPCErrorCode.invalidPayload.error(detail: "job not terminal"))
            case .jobNotFound:
                reply(nil, XPCErrorCode.invalidPayload.error(detail: "job not found"))
            default:
                reply(nil, XPCErrorCode.internalError.error(detail: "delete job failed"))
            }
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "delete job failed"))
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
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database, let secretStore = services.secretStore else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
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
            let response = UpsertCredentialProfileResponse(
                requestID: request.requestID,
                profileID: request.profileID
            )
            remember(request.requestID, response, isMutation: true)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "credential upsert failed"))
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
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
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
            let response = UpsertProxyProfileResponse(
                requestID: request.requestID,
                profileID: request.profileID
            )
            remember(request.requestID, response, isMutation: true)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "proxy upsert failed"))
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
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let snap: DestinationRepository.Snapshot = if let bookmark = request.bookmarkData {
                try DestinationRepository.setDefaultBookmark(
                    database: database,
                    bookmarkData: bookmark,
                    displayName: request.displayName,
                    pathHint: request.pathDisplay
                )
            } else {
                try DestinationRepository.resetDefault(database: database)
            }
            let response = SetDefaultDestinationResponse(
                requestID: request.requestID,
                destination: DefaultDestinationSnapshot(
                    pathDisplay: snap.pathDisplay,
                    folderName: snap.folderName,
                    isDefaultDownloads: snap.isDefaultDownloads
                )
            )
            remember(request.requestID, response, isMutation: true)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "set destination failed"))
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
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
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
            let response = UpsertCookieProfileResponse(
                requestID: request.requestID,
                profileID: request.profileID
            )
            remember(request.requestID, response, isMutation: true)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "cookie profile upsert failed"))
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
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            _ = try BandwidthWindowEvaluator.parseWindowsJSON(request.windowsJSON)
            try ProfileRepository.upsertBandwidthPolicy(
                database: database,
                id: request.policyID,
                name: request.name,
                windowsJSON: request.windowsJSON,
                maxBytesPerSecond: request.maxBytesPerSecond
            )
            let response = UpsertBandwidthPolicyResponse(
                requestID: request.requestID,
                policyID: request.policyID
            )
            remember(request.requestID, response, isMutation: true)
            reply(response, nil)
        } catch is BandwidthWindowEvaluator.ParseError {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "invalid windowsJSON"))
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "bandwidth policy upsert failed"))
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
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            try OrganizationRepository.upsertProject(
                database: database,
                id: request.projectID,
                name: request.name,
                colorRole: request.colorRole
            )
            let response = UpsertProjectResponse(
                requestID: request.requestID,
                projectID: request.projectID
            )
            remember(request.requestID, response, isMutation: true)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "project upsert failed"))
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
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let resolvedTagID = try OrganizationRepository.upsertTag(
                database: database,
                id: request.tagID,
                name: request.name
            )
            let response = UpsertTagResponse(
                requestID: request.requestID,
                tagID: resolvedTagID
            )
            remember(request.requestID, response, isMutation: true)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "tag upsert failed"))
        }
    }

    func setJobTags(
        _ request: SetJobTagsRequest,
        reply: @escaping @Sendable (SetJobTagsResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            try OrganizationRepository.setJobTags(
                database: database,
                jobID: request.jobID,
                tagIDs: request.tagIDs
            )
            let response = SetJobTagsResponse(
                requestID: request.requestID,
                jobID: request.jobID
            )
            remember(request.requestID, response, isMutation: true)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "set job tags failed"))
        }
    }

    func setJobProject(
        _ request: SetJobProjectRequest,
        reply: @escaping @Sendable (SetJobProjectResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            try OrganizationRepository.setJobProject(
                database: database,
                jobID: request.jobID,
                projectID: request.projectID
            )
            let response = SetJobProjectResponse(
                requestID: request.requestID,
                jobID: request.jobID
            )
            remember(request.requestID, response, isMutation: true)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "set job project failed"))
        }
    }

    func setJobCategory(
        _ request: SetJobCategoryRequest,
        reply: @escaping @Sendable (SetJobCategoryResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            try JobRepository.setJobCategory(
                database: database,
                jobID: request.jobID,
                categoryStableKey: request.categoryStableKey
            )
            let response = SetJobCategoryResponse(
                requestID: request.requestID,
                jobID: request.jobID,
                categoryStableKey: request.categoryStableKey
            )
            remember(request.requestID, response, isMutation: true)
            reply(response, nil)
        } catch let error as JobRepositoryError {
            switch error {
            case .unknownCategory:
                reply(nil, XPCErrorCode.invalidPayload.error(detail: "unknown category"))
            case .jobNotFound:
                reply(nil, XPCErrorCode.invalidPayload.error(detail: "job not found"))
            default:
                reply(nil, XPCErrorCode.internalError.error(detail: "set job category failed"))
            }
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "set job category failed"))
        }
    }

    func setJobFilename(
        _ request: SetJobFilenameRequest,
        reply: @escaping @Sendable (SetJobFilenameResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(request.requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let filename = try JobRepository.setJobFilename(
                database: database,
                jobID: request.jobID,
                filename: request.filename
            )
            let response = SetJobFilenameResponse(
                requestID: request.requestID,
                jobID: request.jobID,
                filename: filename
            )
            remember(request.requestID, response, isMutation: true)
            reply(response, nil)
        } catch let error as JobRepositoryError {
            switch error {
            case .renameWhileActive:
                reply(nil, XPCErrorCode.invalidPayload.error(detail: "pause the download before renaming"))
            case .renameTargetExists:
                reply(nil, XPCErrorCode.invalidPayload.error(detail: "a file with that name already exists"))
            case .invalidFilename:
                reply(nil, XPCErrorCode.invalidPayload.error(detail: "invalid filename"))
            case .jobNotFound:
                reply(nil, XPCErrorCode.invalidPayload.error(detail: "job not found"))
            default:
                reply(nil, XPCErrorCode.internalError.error(detail: "set job filename failed"))
            }
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "set job filename failed"))
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
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            try CategoryRulesRepository.upsert(
                database: database,
                id: request.ruleID,
                priority: request.priority,
                enabled: request.enabled,
                predicateJSON: request.predicateJSON,
                categoryStableKey: request.categoryStableKey
            )
            let response = UpsertCategoryRuleResponse(
                requestID: request.requestID,
                ruleID: request.ruleID
            )
            remember(request.requestID, response, isMutation: true)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "category rule upsert failed"))
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
        if gateMutation(requestID: request.requestID, reply: reply) { return }

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let deleted = try JobRepository.clearEvents(database: database, jobID: request.jobID)
            let response = ClearEventsResponse(requestID: request.requestID, deletedCount: deleted)
            remember(request.requestID, response, isMutation: true)
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "clear events failed"))
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
