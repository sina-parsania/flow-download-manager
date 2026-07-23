// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation
import Persistence
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

    public init(
        engineBuild: String,
        databaseVersion: Int,
        isDatabaseOpen: @escaping @Sendable () -> Bool,
        startDate: Date,
        now: @escaping @Sendable () -> Date = { Date() },
        database: EngineDatabase? = nil,
        orchestrator: TransferOrchestrator? = nil,
        progressLedger: JobProgressLedger? = nil
    ) {
        self.engineBuild = engineBuild
        self.databaseVersion = databaseVersion
        self.isDatabaseOpen = isDatabaseOpen
        self.startDate = startDate
        self.now = now
        self.database = database
        self.orchestrator = orchestrator
        self.progressLedger = progressLedger
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
            capabilities: ["health", "enqueueBatch", "listJobs", "controlJob"]
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
            let result = try JobRepository.insertBatch(
                database: database,
                source: request.source,
                displayName: request.displayName,
                items: items
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
            let jobs = rows.map { job, resource, category -> JobSnapshot in
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
                    categoryKey: category.stableKey
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

    private func isValidRequestID(_ requestID: String) -> Bool {
        requestID.count <= EngineXPC.maxPayloadStringLength && UUID(uuidString: requestID) != nil
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
