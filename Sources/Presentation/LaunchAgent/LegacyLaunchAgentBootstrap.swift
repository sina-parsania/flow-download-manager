// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SharedObservability

/// When `SMAppService` cannot see the embedded agent (common for ad-hoc /
/// DerivedData builds), install a classic per-user LaunchAgent that points at
/// the absolute agent binary and bootstrap it with `launchctl`.
///
/// Uses executable URL + argument array only (no shell).
public enum LegacyLaunchAgentBootstrap {
    public static let label = "org.downloadmanager.local.DownloadEngineAgent"

    public enum BootstrapError: Error, Sendable {
        case agentBinaryMissing
        case launchctlFailed(Int32)
    }

    /// Absolute path to the agent executable inside the running app bundle.
    public static func agentBinaryURL(bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL
            .appendingPathComponent("Contents/MacOS/DownloadEngineAgent", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    public static func plistURL() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base
            .appendingPathComponent("org.downloadmanager.local.DownloadManager", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(label).plist")
    }

    /// Write/update the plist and (re)load it under the current GUI domain.
    public static func installAndLoad(bundle: Bundle = .main) throws {
        guard let agent = agentBinaryURL(bundle: bundle) else {
            throw BootstrapError.agentBinaryMissing
        }
        let plist = try plistURL()
        let contents = plistXML(programPath: agent.path)
        try contents.write(to: plist, atomically: true, encoding: .utf8)

        let uid = getuid()
        let domain = "gui/\(uid)"
        let service = "\(domain)/\(label)"

        // Best-effort tear-down of a previous copy (exit ≠ 0 is fine).
        _ = runLaunchctl(arguments: ["bootout", service])
        let boot = runLaunchctl(arguments: ["bootstrap", domain, plist.path])
        if boot != 0 {
            // Already bootstrapped — try kickstart instead of failing hard.
            EngineLog.app.error(
                "legacy launchctl bootstrap exit=\(boot, privacy: .public)"
            )
        }
        _ = runLaunchctl(arguments: ["enable", service])
        let kick = runLaunchctl(arguments: ["kickstart", "-k", service])
        if kick != 0, boot != 0 {
            throw BootstrapError.launchctlFailed(kick == 0 ? boot : kick)
        }
        EngineLog.app.info("legacy LaunchAgent loaded label=\(label, privacy: .public)")
    }

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

    /// Best-effort stop of any agent binary still running outside launchd
    /// (manual debug launches, zombies after EX_CONFIG thrash).
    public static func terminateOrphanAgents() {
        let killall = URL(fileURLWithPath: "/usr/bin/killall")
        let process = Process()
        process.executableURL = killall
        process.arguments = ["-9", "DownloadEngineAgent"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            EngineLog.app.error(
                "killall DownloadEngineAgent failed: \(EngineLog.redacted(error), privacy: .public)"
            )
        }
    }

    public static func terminateOrphanAgentsAsync() async {
        await Task.detached(priority: .userInitiated) {
            terminateOrphanAgents()
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

    private static func plistXML(programPath: String) -> String {
        let escaped = programPath
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(escaped)</string>
            </array>
            <key>MachServices</key>
            <dict>
                <key>\(label)</key>
                <true/>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>ProcessType</key>
            <string>Adaptive</string>
        </dict>
        </plist>
        """
    }
}
