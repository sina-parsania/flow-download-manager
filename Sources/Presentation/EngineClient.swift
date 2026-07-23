// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation
import XPCContracts

/// App-side XPC client for the engine control interface.
@MainActor
public final class EngineClient: ObservableObject {
    public enum ClientError: Error, Sendable {
        case notConnected
        case remote(NSError)
        case decoding
    }

    private var connection: NSXPCConnection?
    private var didHandshake = false
    /// When set, connect via the app-scoped XPC service instead of the LaunchAgent Mach service.
    private var prefersBundledXPCService = false

    public init() {}

    public func connect() async throws {
        if connection != nil, didHandshake { return }
        try await openConnectionAndHandshake()
    }

    /// Prefer the embedded `DownloadEngineAgent.xpc` (ad-hoc / healed direct mode).
    public func useBundledXPCService() {
        prefersBundledXPCService = true
        resetConnection()
    }

    /// Clear bundled-service preference and fall back to Mach service addressing.
    public func clearDirectEndpoint() {
        prefersBundledXPCService = false
        resetConnection()
    }

    /// Drop a dead XPC session so the next call re-handshakes.
    public func resetConnection() {
        if let connection {
            connection.invalidationHandler = nil
            connection.interruptionHandler = nil
            connection.invalidate()
        }
        connection = nil
        didHandshake = false
    }

    /// Lightweight liveness check used by LaunchAgent heal / ensureRunning.
    /// Returns `false` on timeout or any XPC failure (never throws).
    public func ping(timeoutSeconds: Double = 2.5) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.healthProbeSucceeded()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func healthProbeSucceeded() async -> Bool {
        do {
            let requestID = UUID().uuidString
            _ = try await perform { proxy, reply in
                proxy.healthStatus(requestID: requestID, reply: reply)
            } as EngineHealthSnapshot
            return true
        } catch {
            return false
        }
    }

    private func openConnectionAndHandshake() async throws {
        resetConnection()
        if !prefersBundledXPCService,
           DirectAgentHost.shared.currentTransportIfReady == .bundledXPCService {
            prefersBundledXPCService = true
        }
        let connection = if prefersBundledXPCService {
            // App-scoped XPC service (ad-hoc / healed). Demand-launched by launchd.
            NSXPCConnection(serviceName: EngineXPC.machServiceName)
        } else {
            NSXPCConnection(machServiceName: EngineXPC.machServiceName)
        }
        connection.remoteObjectInterface = EngineControlInterface.make()
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.didHandshake = false
                self?.connection = nil
            }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.didHandshake = false
                self?.connection = nil
            }
        }
        connection.resume()
        self.connection = connection

        let hello = ClientHello(
            protocolVersion: SchemaVersions.xpcProtocol,
            clientBuild: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            clientRole: .app,
            capabilities: [
                "enqueueBatch", "listJobs", "controlJob", "setJobPriority", "deleteJob",
                "upsertCredentialProfile", "upsertProxyProfile", "upsertCookieProfile",
                "listProfiles", "getDefaultDestination", "setDefaultDestination",
                "upsertBandwidthPolicy", "getBandwidthPolicy",
                "listOrganization", "upsertProject", "upsertTag", "setJobTags", "setJobProject",
                "setJobCategory", "setJobFilename",
                "getBoolSetting", "setBoolSetting",
                "listCategoryRules", "upsertCategoryRule", "listEvents", "clearEvents"
            ]
        )
        do {
            _ = try await Self.invoke(Self.box(connection)) { proxy, reply in
                proxy.handshake(hello, reply: reply)
            } as ServerHello
            didHandshake = true
        } catch {
            resetConnection()
            throw error
        }
    }

    /// Connect (with one automatic reconnect after failure).
    private func perform<T: AnyObject & Sendable>(
        _ call: @escaping @Sendable (
            EngineControlProtocol,
            @escaping @Sendable (T?, NSError?) -> Void
        ) -> Void
    ) async throws -> T {
        do {
            try await connect()
            return try await Self.invoke(Self.box(connection), call)
        } catch {
            resetConnection()
            try await connect()
            return try await Self.invoke(Self.box(connection), call)
        }
    }

    public func enqueueBatch(
        source: String,
        displayName: String?,
        items: [(url: String, categoryStableKey: String)],
        credentialProfileID: String? = nil,
        proxyProfileID: String? = nil,
        cookieProfileID: String? = nil,
        customHeadersJSON: String? = nil,
        projectID: String? = nil,
        scheduleStartAtISO8601: String? = nil
    ) async throws -> EnqueueBatchResponse {
        let request = EnqueueBatchRequest(
            requestID: UUID().uuidString,
            source: source,
            displayName: displayName,
            items: items.map { BatchURLItem(url: $0.url, categoryStableKey: $0.categoryStableKey) },
            credentialProfileID: credentialProfileID,
            proxyProfileID: proxyProfileID,
            cookieProfileID: cookieProfileID,
            customHeadersJSON: customHeadersJSON,
            projectID: projectID,
            scheduleStartAtISO8601: scheduleStartAtISO8601
        )
        return try await perform { proxy, reply in
            proxy.enqueueBatch(request, reply: reply)
        }
    }

    public func listJobs() async throws -> JobListSnapshot {
        let requestID = UUID().uuidString
        return try await perform { proxy, reply in
            proxy.listJobs(requestID: requestID, reply: reply)
        }
    }

    public func controlJob(
        jobID: String,
        command: JobCommandKind,
        expectedRevision: Int = 0
    ) async throws -> JobCommandResponse {
        let request = JobCommandRequest(
            requestID: UUID().uuidString,
            jobID: jobID,
            command: command,
            expectedRevision: expectedRevision
        )
        return try await perform { proxy, reply in
            proxy.controlJob(request, reply: reply)
        }
    }

    public func setJobPriority(jobID: String, priority: Int) async throws -> SetJobPriorityResponse {
        let request = SetJobPriorityRequest(
            requestID: UUID().uuidString,
            jobID: jobID,
            priority: priority
        )
        return try await perform { proxy, reply in
            proxy.setJobPriority(request, reply: reply)
        }
    }

    public func listProfiles() async throws -> ListProfilesResponse {
        let requestID = UUID().uuidString
        return try await perform { proxy, reply in
            proxy.listProfiles(requestID: requestID, reply: reply)
        }
    }

    public func getDefaultDestination() async throws -> DefaultDestinationSnapshot {
        let requestID = UUID().uuidString
        let response: GetDefaultDestinationResponse = try await perform { proxy, reply in
            proxy.getDefaultDestination(requestID: requestID, reply: reply)
        }
        return response.destination
    }

    public func setDefaultDestination(
        bookmarkData: Data?,
        displayName: String?,
        pathDisplay: String? = nil
    ) async throws -> DefaultDestinationSnapshot {
        let request = SetDefaultDestinationRequest(
            requestID: UUID().uuidString,
            bookmarkData: bookmarkData,
            displayName: displayName,
            pathDisplay: pathDisplay
        )
        let response: SetDefaultDestinationResponse = try await perform { proxy, reply in
            proxy.setDefaultDestination(request, reply: reply)
        }
        return response.destination
    }

    public func deleteJob(jobID: String, deleteFiles: Bool = false) async throws -> DeleteJobResponse {
        let request = DeleteJobRequest(
            requestID: UUID().uuidString,
            jobID: jobID,
            deleteFiles: deleteFiles
        )
        return try await perform { proxy, reply in
            proxy.deleteJob(request, reply: reply)
        }
    }

    public func upsertCredentialProfile(
        displayName: String,
        username: String,
        password: String,
        profileID: String = UUID().uuidString.lowercased()
    ) async throws -> UpsertCredentialProfileResponse {
        guard let passwordData = password.data(using: .utf8), !passwordData.isEmpty else {
            throw ClientError.decoding
        }
        let request = UpsertCredentialProfileRequest(
            requestID: UUID().uuidString,
            profileID: profileID,
            displayName: displayName,
            username: username,
            passwordUTF8: passwordData
        )
        return try await perform { proxy, reply in
            proxy.upsertCredentialProfile(request, reply: reply)
        }
    }

    public func upsertProxyProfile(
        displayName: String,
        kind: String,
        host: String,
        port: Int,
        profileID: String = UUID().uuidString.lowercased()
    ) async throws -> UpsertProxyProfileResponse {
        let request = UpsertProxyProfileRequest(
            requestID: UUID().uuidString,
            profileID: profileID,
            displayName: displayName,
            kind: kind,
            host: host,
            port: port
        )
        return try await perform { proxy, reply in
            proxy.upsertProxyProfile(request, reply: reply)
        }
    }

    public func upsertCookieProfile(
        displayName: String,
        profileID: String = UUID().uuidString.lowercased()
    ) async throws -> UpsertCookieProfileResponse {
        let request = UpsertCookieProfileRequest(
            requestID: UUID().uuidString,
            profileID: profileID,
            displayName: displayName
        )
        return try await perform { proxy, reply in
            proxy.upsertCookieProfile(request, reply: reply)
        }
    }

    public func upsertBandwidthPolicy(
        name: String = "Global",
        windowsJSON: String,
        maxBytesPerSecond: Int64,
        policyID: String = "00000000-0000-7000-8000-0000000000b1"
    ) async throws -> UpsertBandwidthPolicyResponse {
        let request = UpsertBandwidthPolicyRequest(
            requestID: UUID().uuidString,
            policyID: policyID,
            name: name,
            windowsJSON: windowsJSON,
            maxBytesPerSecond: maxBytesPerSecond
        )
        return try await perform { proxy, reply in
            proxy.upsertBandwidthPolicy(request, reply: reply)
        }
    }

    public func getBandwidthPolicy() async throws -> GetBandwidthPolicyResponse {
        let requestID = UUID().uuidString
        return try await perform { proxy, reply in
            proxy.getBandwidthPolicy(requestID: requestID, reply: reply)
        }
    }

    public func listOrganization() async throws -> ListOrganizationResponse {
        let requestID = UUID().uuidString
        return try await perform { proxy, reply in
            proxy.listOrganization(requestID: requestID, reply: reply)
        }
    }

    public func upsertProject(
        name: String,
        colorRole: String? = nil,
        projectID: String = UUID().uuidString.lowercased()
    ) async throws -> UpsertProjectResponse {
        let request = UpsertProjectRequest(
            requestID: UUID().uuidString,
            projectID: projectID,
            name: name,
            colorRole: colorRole
        )
        return try await perform { proxy, reply in
            proxy.upsertProject(request, reply: reply)
        }
    }

    public func upsertTag(
        name: String,
        tagID: String = UUID().uuidString.lowercased()
    ) async throws -> UpsertTagResponse {
        let request = UpsertTagRequest(
            requestID: UUID().uuidString,
            tagID: tagID,
            name: name
        )
        return try await perform { proxy, reply in
            proxy.upsertTag(request, reply: reply)
        }
    }

    public func setJobTags(jobID: String, tagIDs: [String]) async throws -> SetJobTagsResponse {
        let request = SetJobTagsRequest(
            requestID: UUID().uuidString,
            jobID: jobID,
            tagIDs: tagIDs
        )
        return try await perform { proxy, reply in
            proxy.setJobTags(request, reply: reply)
        }
    }

    public func setJobProject(jobID: String, projectID: String?) async throws -> SetJobProjectResponse {
        let request = SetJobProjectRequest(
            requestID: UUID().uuidString,
            jobID: jobID,
            projectID: projectID
        )
        return try await perform { proxy, reply in
            proxy.setJobProject(request, reply: reply)
        }
    }

    public func setJobCategory(
        jobID: String,
        categoryStableKey: String
    ) async throws -> SetJobCategoryResponse {
        let request = SetJobCategoryRequest(
            requestID: UUID().uuidString,
            jobID: jobID,
            categoryStableKey: categoryStableKey
        )
        return try await perform { proxy, reply in
            proxy.setJobCategory(request, reply: reply)
        }
    }

    public func setJobFilename(
        jobID: String,
        filename: String
    ) async throws -> SetJobFilenameResponse {
        let request = SetJobFilenameRequest(
            requestID: UUID().uuidString,
            jobID: jobID,
            filename: filename
        )
        return try await perform { proxy, reply in
            proxy.setJobFilename(request, reply: reply)
        }
    }

    public func getBoolSetting(key: String) async throws -> GetBoolSettingResponse {
        let request = GetBoolSettingRequest(requestID: UUID().uuidString, key: key)
        return try await perform { proxy, reply in
            proxy.getBoolSetting(request, reply: reply)
        }
    }

    public func setBoolSetting(key: String, value: Bool) async throws -> SetBoolSettingResponse {
        let request = SetBoolSettingRequest(
            requestID: UUID().uuidString,
            key: key,
            value: value
        )
        return try await perform { proxy, reply in
            proxy.setBoolSetting(request, reply: reply)
        }
    }

    public func listCategoryRules() async throws -> ListCategoryRulesResponse {
        let requestID = UUID().uuidString
        return try await perform { proxy, reply in
            proxy.listCategoryRules(requestID: requestID, reply: reply)
        }
    }

    public func upsertCategoryRule(
        predicateJSON: String,
        categoryStableKey: String,
        priority: Int,
        enabled: Bool = true,
        ruleID: String = UUID().uuidString.lowercased()
    ) async throws -> UpsertCategoryRuleResponse {
        let request = UpsertCategoryRuleRequest(
            requestID: UUID().uuidString,
            ruleID: ruleID,
            priority: priority,
            enabled: enabled,
            predicateJSON: predicateJSON,
            categoryStableKey: categoryStableKey
        )
        return try await perform { proxy, reply in
            proxy.upsertCategoryRule(request, reply: reply)
        }
    }

    public func listEvents(jobID: String? = nil, limit: Int = 50) async throws -> ListEventsResponse {
        let request = ListEventsRequest(
            requestID: UUID().uuidString,
            jobID: jobID,
            limit: min(max(limit, 1), EngineXPC.maxCollectionCount)
        )
        return try await perform { proxy, reply in
            proxy.listEvents(request, reply: reply)
        }
    }

    public func clearEvents(jobID: String) async throws -> ClearEventsResponse {
        let request = ClearEventsRequest(
            requestID: UUID().uuidString,
            jobID: jobID
        )
        return try await perform { proxy, reply in
            proxy.clearEvents(request, reply: reply)
        }
    }

    private final class ConnectionBox: @unchecked Sendable {
        let connection: NSXPCConnection
        init(_ connection: NSXPCConnection) {
            self.connection = connection
        }
    }

    private static func box(_ connection: NSXPCConnection?) -> ConnectionBox? {
        connection.map(ConnectionBox.init)
    }

    /// XPC replies arrive on a connection queue — keep this helper `nonisolated`
    /// so continuation resumes are not incorrectly MainActor-isolated (SIGTRAP).
    private nonisolated static func invoke<T: AnyObject & Sendable>(
        _ box: ConnectionBox?,
        _ call: @escaping @Sendable (
            EngineControlProtocol,
            @escaping @Sendable (T?, NSError?) -> Void
        ) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            guard let connection = box?.connection,
                  let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                      cont.resume(throwing: ClientError.remote(error as NSError))
                  }) as? EngineControlProtocol
            else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            call(proxy) { value, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let value {
                    cont.resume(returning: value)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }
}
