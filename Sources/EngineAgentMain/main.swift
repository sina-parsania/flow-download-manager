// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Domain
import EngineAgent
import Foundation
import Persistence
import SharedObservability
import SharedSecurity
import XPCContracts

// Entry point for the per-user LaunchAgent and the app-scoped XPC service.
// launchd launches the LaunchAgent on demand when the app connects to the Mach
// service (`02-architecture.md` §2). The agent is the sole database writer and
// owns the XPC listener.
//
// Ad-hoc / DerivedData builds cannot use launchd MachServices (LWCR kills the
// process). In that mode the app embeds this binary as an Application-scoped
// XPC service and connects with `NSXPCConnection(serviceName:)`.

let log = EngineLog.agent
let startDate = Date()

/// Retains agent graph for the process lifetime (parked on `dispatchMain()`).
private final class AgentRuntimeRetain: @unchecked Sendable {
    static let shared = AgentRuntimeRetain()

    var database: EngineDatabase?
    var orchestrator: TransferOrchestrator?
    var delegate: EngineServiceListener?
    var listener: NSXPCListener?

    private init() {}

    func hold(
        database: EngineDatabase,
        orchestrator: TransferOrchestrator,
        delegate: EngineServiceListener,
        listener: NSXPCListener
    ) {
        self.database = database
        self.orchestrator = orchestrator
        self.delegate = delegate
        self.listener = listener
    }
}

/// Best-effort CPU/QoS boost so transfer work beats ordinary background apps
/// (IDM-like default). Cannot throttle other apps' sockets without a Network Extension.
func boostEngineSchedulingPriority() {
    _ = setpriority(PRIO_PROCESS, 0, -10)
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
}

func runAgent() -> Never {
    boostEngineSchedulingPriority()
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
        allowedIdentifiers: [
            XPCClientIdentities.appBundleIdentifier,
            XPCClientIdentities.nativeHostBundleIdentifier
        ]
    )
    let delegate = EngineServiceListener(validator: validator, services: services)

    let listener: NSXPCListener
    if isBundledXPCService() {
        listener = NSXPCListener.service()
        listener.delegate = delegate
        log.info("engine XPC service listener ready")
    } else {
        listener = NSXPCListener(machServiceName: EngineXPC.machServiceName)
        listener.delegate = delegate
        log.info("engine XPC listener on \(EngineXPC.machServiceName, privacy: .public)")
    }

    AgentRuntimeRetain.shared.hold(
        database: database,
        orchestrator: orchestrator,
        delegate: delegate,
        listener: listener
    )
    listener.resume()
    dispatchMain()
}

/// True when launchd started this binary as the app's embedded XPC service.
func isBundledXPCService() -> Bool {
    let name = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]
    guard let name, !name.isEmpty else { return false }
    return name == EngineXPC.machServiceName || name.hasSuffix(".DownloadEngineAgent")
}

runAgent()
