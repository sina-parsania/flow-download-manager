// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import EngineAgent
import Foundation
import Persistence
import SharedObservability
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
        log.info("engine database opened")
    } catch {
        // Database corruption/open failure enters recovery rather than silently
        // recreating history (`02-architecture.md` §17). Phase 0 surfaces the
        // failure and exits non-zero so launchd records it.
        log.error("engine database open failed: \(EngineLog.redacted(error), privacy: .public)")
        exit(EXIT_FAILURE)
    }

    let services = EngineServices(
        engineBuild: AgentBuild.version,
        databaseVersion: SchemaVersions.database,
        isDatabaseOpen: { true },
        startDate: startDate
    )
    let validator = CodeSigningIdentityValidator(
        allowedIdentifiers: [XPCClientIdentities.appBundleIdentifier]
    )
    let delegate = EngineServiceListener(validator: validator, services: services)

    let listener = NSXPCListener(machServiceName: EngineXPC.machServiceName)
    listener.delegate = delegate
    listener.resume()
    log.info("engine XPC listener resumed on \(EngineXPC.machServiceName, privacy: .public)")

    // Keep the database alive for the process lifetime.
    withExtendedLifetime(database) {
        dispatchMain()
    }
}

runAgent()
