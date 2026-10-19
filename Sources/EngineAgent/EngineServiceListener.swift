// SPDX-License-Identifier: GPL-3.0-or-later

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
