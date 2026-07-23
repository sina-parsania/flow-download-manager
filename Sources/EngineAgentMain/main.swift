// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import EngineAgent
import Foundation
import Persistence
import SharedObservability
import SharedSecurity
import XPCContracts

// Entry point for the per-user LaunchAgent. launchd launches this on demand when
// the app connects to the Mach service (`02-architecture.md` §2). The agent is
// the sole database writer and owns the XPC listener.

let log = EngineLog.agent
let startDate = Date()

func runAgent() -> Never {
    let database: EngineDatabase
    do {
        let url = try EngineDatabase.defaultURL(agentIdentifier: EngineXPC.machServiceName)
        database = try EngineDatabase(url: url)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("DownloadManager", isDirectory: true)
        try JobRepository.ensureProductionSeed(
            database: database,
            defaultDestinationDirectory: downloads.appendingPathComponent("DownloadManager", isDirectory: true)
        )
        log.info("engine database opened")
    } catch {
        log.error("engine database open failed: \(EngineLog.redacted(error), privacy: .public)")
        exit(EXIT_FAILURE)
    }

    let progressLedger = JobProgressLedger()
    let secretStore = KeychainSecretStore(service: EngineXPC.machServiceName)
    let orchestrator = TransferOrchestrator(
        database: database,
        progressLedger: progressLedger,
        secretStore: secretStore
    )
    Task { await orchestrator.start() }

    let services = EngineServices(
        engineBuild: AgentBuild.version,
        databaseVersion: SchemaVersions.database,
        isDatabaseOpen: { true },
        startDate: startDate,
        database: database,
        orchestrator: orchestrator,
        progressLedger: progressLedger,
        secretStore: secretStore
    )
    let validator = CodeSigningIdentityValidator(
        allowedIdentifiers: [XPCClientIdentities.appBundleIdentifier]
    )
    let delegate = EngineServiceListener(validator: validator, services: services)

    let listener = NSXPCListener(machServiceName: EngineXPC.machServiceName)
    listener.delegate = delegate
    listener.resume()
    log.info("engine XPC listener resumed on \(EngineXPC.machServiceName, privacy: .public)")

    withExtendedLifetime(database) {
        withExtendedLifetime(orchestrator) {
            dispatchMain()
        }
    }
}

runAgent()
