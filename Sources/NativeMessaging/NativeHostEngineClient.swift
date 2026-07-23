// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation
import XPCContracts

/// Non-UI XPC client used by the Chrome Native Messaging host.
public actor NativeHostEngineClient: NativeMessagingEngineBridge {
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
            clientBuild: "0.1.0-native-host",
            clientRole: .nativeHost,
            capabilities: ["enqueueBatch", "listJobs"]
        )
        let _: ServerHello = try await withCheckedThrowingContinuation { cont in
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
        didHandshake = true
    }

    public func enqueueURLs(
        _ urls: [String],
        displayName: String?
    ) async throws -> (acceptedCount: Int, jobIDs: [String]) {
        try await connect()
        let request = EnqueueBatchRequest(
            requestID: UUID().uuidString,
            source: "chrome-extension",
            displayName: displayName,
            items: urls.map { BatchURLItem(url: $0, categoryStableKey: "general") },
            credentialProfileID: nil,
            proxyProfileID: nil,
            cookieProfileID: nil,
            customHeadersJSON: nil,
            projectID: nil,
            scheduleStartAtISO8601: nil
        )
        let response: EnqueueBatchResponse = try await withCheckedThrowingContinuation { cont in
            guard let connection = self.connection,
                  let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                      cont.resume(throwing: ClientError.remote(error as NSError))
                  }) as? EngineControlProtocol
            else {
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
        return (response.acceptedCount, response.jobIDs)
    }

    public func listJobCount() async throws -> Int {
        try await connect()
        let requestID = UUID().uuidString
        let snapshot: JobListSnapshot = try await withCheckedThrowingContinuation { cont in
            guard let connection = self.connection,
                  let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                      cont.resume(throwing: ClientError.remote(error as NSError))
                  }) as? EngineControlProtocol
            else {
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
        return snapshot.jobs.count
    }
}
