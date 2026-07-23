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

    public init() {}

    public func connect() async throws {
        if connection != nil, didHandshake { return }
        let connection = NSXPCConnection(machServiceName: EngineXPC.machServiceName)
        connection.remoteObjectInterface = EngineControlInterface.make()
        connection.resume()
        self.connection = connection

        let hello = ClientHello(
            protocolVersion: SchemaVersions.xpcProtocol,
            clientBuild: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            clientRole: .app,
            capabilities: [
                "enqueueBatch", "listJobs", "controlJob", "setJobPriority", "deleteJob",
                "upsertCredentialProfile", "upsertProxyProfile", "upsertCookieProfile",
                "listProfiles", "upsertBandwidthPolicy", "getBandwidthPolicy",
                "listOrganization", "upsertProject", "upsertTag", "setJobTags", "setJobProject",
                "getBoolSetting", "setBoolSetting",
                "listCategoryRules", "upsertCategoryRule", "listEvents"
            ]
        )
        let server: ServerHello = try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.handshake(hello) { serverHello, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let serverHello {
                    cont.resume(returning: serverHello)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
        _ = server
        didHandshake = true
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
        try await connect()
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
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.enqueueBatch(request) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func listJobs() async throws -> JobListSnapshot {
        try await connect()
        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.listJobs(requestID: requestID) { snapshot, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let snapshot {
                    cont.resume(returning: snapshot)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func controlJob(
        jobID: String,
        command: JobCommandKind,
        expectedRevision: Int = 0
    ) async throws -> JobCommandResponse {
        try await connect()
        let request = JobCommandRequest(
            requestID: UUID().uuidString,
            jobID: jobID,
            command: command,
            expectedRevision: expectedRevision
        )
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.controlJob(request) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func setJobPriority(jobID: String, priority: Int) async throws -> SetJobPriorityResponse {
        try await connect()
        let request = SetJobPriorityRequest(
            requestID: UUID().uuidString,
            jobID: jobID,
            priority: priority
        )
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.setJobPriority(request) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func listProfiles() async throws -> ListProfilesResponse {
        try await connect()
        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.listProfiles(requestID: requestID) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func deleteJob(jobID: String) async throws -> DeleteJobResponse {
        try await connect()
        let request = DeleteJobRequest(
            requestID: UUID().uuidString,
            jobID: jobID
        )
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.deleteJob(request) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func upsertCredentialProfile(
        displayName: String,
        username: String,
        password: String,
        profileID: String = UUID().uuidString.lowercased()
    ) async throws -> UpsertCredentialProfileResponse {
        try await connect()
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
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.upsertCredentialProfile(request) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func upsertProxyProfile(
        displayName: String,
        kind: String,
        host: String,
        port: Int,
        profileID: String = UUID().uuidString.lowercased()
    ) async throws -> UpsertProxyProfileResponse {
        try await connect()
        let request = UpsertProxyProfileRequest(
            requestID: UUID().uuidString,
            profileID: profileID,
            displayName: displayName,
            kind: kind,
            host: host,
            port: port
        )
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.upsertProxyProfile(request) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func upsertCookieProfile(
        displayName: String,
        profileID: String = UUID().uuidString.lowercased()
    ) async throws -> UpsertCookieProfileResponse {
        try await connect()
        let request = UpsertCookieProfileRequest(
            requestID: UUID().uuidString,
            profileID: profileID,
            displayName: displayName
        )
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.upsertCookieProfile(request) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func upsertBandwidthPolicy(
        name: String = "Global",
        windowsJSON: String,
        maxBytesPerSecond: Int64,
        policyID: String = "00000000-0000-7000-8000-0000000000b1"
    ) async throws -> UpsertBandwidthPolicyResponse {
        try await connect()
        let request = UpsertBandwidthPolicyRequest(
            requestID: UUID().uuidString,
            policyID: policyID,
            name: name,
            windowsJSON: windowsJSON,
            maxBytesPerSecond: maxBytesPerSecond
        )
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.upsertBandwidthPolicy(request) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func getBandwidthPolicy() async throws -> GetBandwidthPolicyResponse {
        try await connect()
        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.getBandwidthPolicy(requestID: requestID) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func listOrganization() async throws -> ListOrganizationResponse {
        try await connect()
        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.listOrganization(requestID: requestID) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func upsertProject(
        name: String,
        colorRole: String? = nil,
        projectID: String = UUID().uuidString.lowercased()
    ) async throws -> UpsertProjectResponse {
        try await connect()
        let request = UpsertProjectRequest(
            requestID: UUID().uuidString,
            projectID: projectID,
            name: name,
            colorRole: colorRole
        )
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.upsertProject(request) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func upsertTag(
        name: String,
        tagID: String = UUID().uuidString.lowercased()
    ) async throws -> UpsertTagResponse {
        try await connect()
        let request = UpsertTagRequest(
            requestID: UUID().uuidString,
            tagID: tagID,
            name: name
        )
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.upsertTag(request) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func setJobTags(jobID: String, tagIDs: [String]) async throws -> SetJobTagsResponse {
        try await connect()
        let request = SetJobTagsRequest(
            requestID: UUID().uuidString,
            jobID: jobID,
            tagIDs: tagIDs
        )
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.setJobTags(request) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func setJobProject(jobID: String, projectID: String?) async throws -> SetJobProjectResponse {
        try await connect()
        let request = SetJobProjectRequest(
            requestID: UUID().uuidString,
            jobID: jobID,
            projectID: projectID
        )
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.setJobProject(request) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func getBoolSetting(key: String) async throws -> GetBoolSettingResponse {
        try await connect()
        let request = GetBoolSettingRequest(requestID: UUID().uuidString, key: key)
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.getBoolSetting(request) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func setBoolSetting(key: String, value: Bool) async throws -> SetBoolSettingResponse {
        try await connect()
        let request = SetBoolSettingRequest(
            requestID: UUID().uuidString,
            key: key,
            value: value
        )
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.setBoolSetting(request) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func listCategoryRules() async throws -> ListCategoryRulesResponse {
        try await connect()
        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.listCategoryRules(requestID: requestID) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func upsertCategoryRule(
        predicateJSON: String,
        categoryStableKey: String,
        priority: Int,
        enabled: Bool = true,
        ruleID: String = UUID().uuidString.lowercased()
    ) async throws -> UpsertCategoryRuleResponse {
        try await connect()
        let request = UpsertCategoryRuleRequest(
            requestID: UUID().uuidString,
            ruleID: ruleID,
            priority: priority,
            enabled: enabled,
            predicateJSON: predicateJSON,
            categoryStableKey: categoryStableKey
        )
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.upsertCategoryRule(request) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    public func listEvents(jobID: String? = nil, limit: Int = 50) async throws -> ListEventsResponse {
        try await connect()
        let request = ListEventsRequest(
            requestID: UUID().uuidString,
            jobID: jobID,
            limit: min(max(limit, 1), EngineXPC.maxCollectionCount)
        )
        return try await withCheckedThrowingContinuation { cont in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: ClientError.remote(error as NSError))
            }) as? EngineControlProtocol else {
                cont.resume(throwing: ClientError.notConnected)
                return
            }
            proxy.listEvents(request) { response, error in
                if let error {
                    cont.resume(throwing: ClientError.remote(error))
                } else if let response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: ClientError.decoding)
                }
            }
        }
    }
}
