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
    private var healthCache: [String: EngineHealthSnapshot] = [:]
    private var enqueueCache: [String: EnqueueBatchResponse] = [:]
    private var listCache: [String: JobListSnapshot] = [:]
    private var commandCache: [String: JobCommandResponse] = [:]
    private var credentialCache: [String: UpsertCredentialProfileResponse] = [:]
    private var proxyCache: [String: UpsertProxyProfileResponse] = [:]
    private var cookieCache: [String: UpsertCookieProfileResponse] = [:]
    private var listProfilesCache: [String: ListProfilesResponse] = [:]
    private var bandwidthUpsertCache: [String: UpsertBandwidthPolicyResponse] = [:]
    private var bandwidthGetCache: [String: GetBandwidthPolicyResponse] = [:]
    private var listOrganizationCache: [String: ListOrganizationResponse] = [:]
    private var upsertProjectCache: [String: UpsertProjectResponse] = [:]
    private var upsertTagCache: [String: UpsertTagResponse] = [:]
    private var setJobTagsCache: [String: SetJobTagsResponse] = [:]
    private var setJobPriorityCache: [String: SetJobPriorityResponse] = [:]
    private var deleteJobCache: [String: DeleteJobResponse] = [:]
    private var listCategoryRulesCache: [String: ListCategoryRulesResponse] = [:]
    private var upsertCategoryRuleCache: [String: UpsertCategoryRuleResponse] = [:]
    private var listEventsCache: [String: ListEventsResponse] = [:]
    private var snapshotSequence: Int64 = 0

    init(services: EngineServices) {
        self.services = services
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
                "listProfiles", "upsertBandwidthPolicy", "getBandwidthPolicy",
                "listOrganization", "upsertProject", "upsertTag", "setJobTags",
                "listCategoryRules", "upsertCategoryRule", "listEvents", "setJobPriority",
                "deleteJob"
            ]
        ), nil)
    }

    func healthStatus(requestID: String, reply: @escaping @Sendable (EngineHealthSnapshot?, NSError?) -> Void) {
        guard isValidRequestID(requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = healthCache[requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        let snapshot = EngineHealthSnapshot(
            requestID: requestID,
            engineBuild: services.engineBuild,
            databaseVersion: services.databaseVersion,
            databaseOpen: services.isDatabaseOpen(),
            uptimeSeconds: services.now().timeIntervalSince(services.startDate)
        )
        healthCache[requestID] = snapshot
        lock.unlock()
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = enqueueCache[request.requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

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
                scheduleStartAt: scheduleStartAt
            )
            let response = EnqueueBatchResponse(
                requestID: request.requestID,
                batchID: result.batchID,
                jobIDs: result.jobIDs,
                acceptedCount: result.jobIDs.count
            )
            lock.lock()
            enqueueCache[request.requestID] = response
            lock.unlock()
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = listCache[requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            let rows = try JobRepository.fetchJobRows(database: database)
            let progressMap = services.progressLedger?.all() ?? [:]
            let jobs = rows.map { job, resource, category, projectName, tagNames -> JobSnapshot in
                let host = URL(string: resource.canonicalURL)?.host ?? ""
                let name = resource.filenameEvidence
                    ?? URL(string: resource.canonicalURL)?.lastPathComponent
                    ?? resource.canonicalURL
                let live = progressMap[job.id]
                let total = live?.totalBytes ?? resource.expectedSize
                let transferred = live?.bytesTransferred ?? 0
                let speed = live?.speedBytesPerSecond ?? 0
                let fraction = live?.progressFraction
                return JobSnapshot(
                    id: job.id,
                    name: name,
                    sourceHost: host,
                    state: job.state,
                    progressFraction: fraction,
                    bytesTransferred: transferred,
                    totalBytes: total,
                    speedBytesPerSecond: speed,
                    categoryKey: category.stableKey,
                    projectName: projectName,
                    tagNames: tagNames,
                    priority: job.priority
                )
            }
            lock.lock()
            snapshotSequence += 1
            let sequence = snapshotSequence
            let snapshot = JobListSnapshot(requestID: requestID, sequence: sequence, jobs: jobs)
            listCache[requestID] = snapshot
            lock.unlock()
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = commandCache[request.requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

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
                Task { await services.orchestrator?.clearControl(jobID: request.jobID) }
                Task { await services.orchestrator?.start() }
            case .cancel:
                newState = "cancelled"
                reason = "userCancelled"
                Task { await services.orchestrator?.requestCancel(jobID: request.jobID) }
            case .retry:
                newState = "queued"
                reason = nil
                Task { await services.orchestrator?.clearControl(jobID: request.jobID) }
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
            lock.lock()
            commandCache[request.requestID] = response
            lock.unlock()
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = setJobPriorityCache[request.requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

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
            lock.lock()
            setJobPriorityCache[request.requestID] = response
            lock.unlock()
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = deleteJobCache[request.requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            // Optional partial cleanup for failed/cancelled only — never delete completed files.
            let transferDetails = try? JobRepository.loadJobForTransfer(
                database: database,
                id: request.jobID
            )
            if let details = transferDetails {
                if details.state == "failed" || details.state == "cancelled" {
                    let filename = FilenameSanitizer.sanitize(details.suggestedFilename)
                    let partial = details.destinationDirectory
                        .appendingPathComponent("\(filename).partial")
                    let accessed = details.destinationDirectory.startAccessingSecurityScopedResource()
                    defer {
                        if accessed { details.destinationDirectory.stopAccessingSecurityScopedResource() }
                    }
                    try? FileManager.default.removeItem(at: partial)
                }
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
            lock.lock()
            deleteJobCache[request.requestID] = response
            lock.unlock()
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = credentialCache[request.requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

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
            lock.lock()
            credentialCache[request.requestID] = response
            lock.unlock()
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = proxyCache[request.requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

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
            lock.lock()
            proxyCache[request.requestID] = response
            lock.unlock()
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = listProfilesCache[requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

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
            lock.lock()
            listProfilesCache[requestID] = response
            lock.unlock()
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "list profiles failed"))
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = cookieCache[request.requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

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
            lock.lock()
            cookieCache[request.requestID] = response
            lock.unlock()
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = bandwidthUpsertCache[request.requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

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
            lock.lock()
            bandwidthUpsertCache[request.requestID] = response
            lock.unlock()
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = bandwidthGetCache[requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

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
            lock.lock()
            bandwidthGetCache[requestID] = response
            lock.unlock()
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = listOrganizationCache[requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

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
            lock.lock()
            listOrganizationCache[requestID] = response
            lock.unlock()
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = upsertProjectCache[request.requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

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
            lock.lock()
            upsertProjectCache[request.requestID] = response
            lock.unlock()
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = upsertTagCache[request.requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

        guard let database = services.database else {
            reply(nil, XPCErrorCode.internalError.error(detail: "database unavailable"))
            return
        }

        do {
            try OrganizationRepository.upsertTag(
                database: database,
                id: request.tagID,
                name: request.name
            )
            let response = UpsertTagResponse(
                requestID: request.requestID,
                tagID: request.tagID
            )
            lock.lock()
            upsertTagCache[request.requestID] = response
            lock.unlock()
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = setJobTagsCache[request.requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

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
            lock.lock()
            setJobTagsCache[request.requestID] = response
            lock.unlock()
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "set job tags failed"))
        }
    }

    func listCategoryRules(
        requestID: String,
        reply: @escaping @Sendable (ListCategoryRulesResponse?, NSError?) -> Void
    ) {
        guard isValidRequestID(requestID) else {
            reply(nil, XPCErrorCode.invalidPayload.error(detail: "malformed requestID"))
            return
        }
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = listCategoryRulesCache[requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

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
            lock.lock()
            listCategoryRulesCache[requestID] = response
            lock.unlock()
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = upsertCategoryRuleCache[request.requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

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
            lock.lock()
            upsertCategoryRuleCache[request.requestID] = response
            lock.unlock()
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
        lock.lock()
        guard didHandshake else {
            lock.unlock()
            reply(nil, XPCErrorCode.handshakeRequired.error())
            return
        }
        if let cached = listEventsCache[request.requestID] {
            lock.unlock()
            reply(cached, nil)
            return
        }
        lock.unlock()

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
            lock.lock()
            listEventsCache[request.requestID] = response
            lock.unlock()
            reply(response, nil)
        } catch {
            reply(nil, XPCErrorCode.internalError.error(detail: "list events failed"))
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
