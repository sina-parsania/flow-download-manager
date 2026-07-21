// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation
import XPCContracts

/// Runtime facts the engine reports over the control interface. Injected so tests
/// drive uptime, build and database status deterministically.
public struct EngineServices: Sendable {
    public let engineBuild: String
    public let databaseVersion: Int
    public let isDatabaseOpen: @Sendable () -> Bool
    public let startDate: Date
    public let now: @Sendable () -> Date

    public init(
        engineBuild: String,
        databaseVersion: Int,
        isDatabaseOpen: @escaping @Sendable () -> Bool,
        startDate: Date,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engineBuild = engineBuild
        self.databaseVersion = databaseVersion
        self.isDatabaseOpen = isDatabaseOpen
        self.startDate = startDate
        self.now = now
    }
}

/// Per-connection exported object implementing ``EngineControlProtocol``.
///
/// XPC may deliver calls on arbitrary queues, so all mutable state (handshake
/// flag, idempotency cache) is guarded by a lock; that invariant justifies
/// `@unchecked Sendable`. A fresh exporter is created per accepted connection, so
/// the idempotency cache is connection-scoped.
final class EngineControlExporter: NSObject, EngineControlProtocol, @unchecked Sendable {
    private let services: EngineServices
    private let lock = NSLock()
    private var didHandshake = false
    private var idempotencyCache: [String: EngineHealthSnapshot] = [:]

    init(services: EngineServices) {
        self.services = services
    }

    func handshake(_ hello: ClientHello, reply: @escaping @Sendable (ServerHello?, NSError?) -> Void) {
        // Reject unknown protocol major version before trusting any other field.
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
            capabilities: ["health"]
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
        // health is idempotent: replay the stored response for a duplicate ID.
        if let cached = idempotencyCache[requestID] {
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
        idempotencyCache[requestID] = snapshot
        lock.unlock()

        reply(snapshot, nil)
    }

    private func isValidRequestID(_ requestID: String) -> Bool {
        requestID.count <= EngineXPC.maxPayloadStringLength && UUID(uuidString: requestID) != nil
    }
}

/// `NSXPCListenerDelegate` that authorizes and configures new connections.
///
/// Rejects any peer that fails identity validation (`fail closed`,
/// `06-licensing-security-privacy.md` §4) and otherwise wires the shared
/// interface plus a fresh exporter.
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
