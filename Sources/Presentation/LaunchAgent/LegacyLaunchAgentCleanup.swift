// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SharedObservability

/// Tears down the per-user LaunchAgent that older builds installed by hand.
///
/// Nothing installs that agent any more — the engine is hosted by `SMAppService`
/// or by the bundled XPC service (ADR 0008) — but machines upgraded from an older
/// build can still have a loaded copy holding the Mach name, so heal paths unload
/// it before starting the bundled service.
///
/// Uses executable URL + argument array only (no shell).
public enum LegacyLaunchAgentCleanup {
    public static let label = "org.downloadmanager.local.DownloadEngineAgent"

    public static func unload() {
        let uid = getuid()
        let service = "gui/\(uid)/\(label)"
        _ = runLaunchctl(arguments: ["bootout", service])
        _ = runLaunchctl(arguments: ["remove", label])
    }

    /// Async unload so callers on the MainActor never block on `waitUntilExit`.
    public static func unloadAsync() async {
        await Task.detached(priority: .userInitiated) {
            unload()
        }.value
    }

    private static func runLaunchctl(arguments: [String]) -> Int32 {
        let launchctl = URL(fileURLWithPath: "/bin/launchctl")
        let process = Process()
        process.executableURL = launchctl
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            EngineLog.app.error(
                "launchctl spawn failed: \(EngineLog.redacted(error), privacy: .public)"
            )
            return -1
        }
    }
}
