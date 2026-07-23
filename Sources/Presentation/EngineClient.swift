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
                "enqueueBatch", "listJobs", "controlJob",
                "upsertCredentialProfile", "upsertProxyProfile", "listProfiles"
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
        items: [(url: String, categoryStableKey: String)]
    ) async throws -> EnqueueBatchResponse {
        try await connect()
        let request = EnqueueBatchRequest(
            requestID: UUID().uuidString,
            source: source,
            displayName: displayName,
            items: items.map { BatchURLItem(url: $0.url, categoryStableKey: $0.categoryStableKey) }
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
}
