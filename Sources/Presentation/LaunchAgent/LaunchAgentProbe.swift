// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A non-UI diagnostic that reports the current `SMAppService` status of the
/// embedded LaunchAgent plist, then exits. Invoked by launching the app with
/// `--smappservice-probe`.
///
/// The probe is deliberately READ-ONLY: it does not call `register()`, because
/// registration mutates the user's Login Items and, in a non-interactive session,
/// cannot reach `.enabled` (approval requires the System Settings GUI). A status
/// of `.notRegistered` (rather than `.notFound`) confirms the plist is correctly
/// embedded and discoverable. Registration itself is a user action in the UI and
/// is unit-tested via the `LaunchAgentManaging` seam.
public enum LaunchAgentProbe {
    public static let launchArgument = "--smappservice-probe"
    public static let reregisterArgument = "--smappservice-reregister"

    public static func runAndExit(plistName: String) -> Never {
        let agent = SMAppServiceLaunchAgent(plistName: plistName)
        if CommandLine.arguments.contains(reregisterArgument) {
            do {
                try agent.unregister()
                emit("unregistered status=\(agent.currentStatus())")
            } catch {
                emit("unregister-failed status=\(agent.currentStatus()) error=\(error)")
            }
            do {
                try agent.register()
                emit("registered status=\(agent.currentStatus())")
                exit(EXIT_SUCCESS)
            } catch {
                emit("register-failed status=\(agent.currentStatus()) error=\(error)")
                exit(EXIT_FAILURE)
            }
        }
        emit("plist=\(plistName) status=\(agent.currentStatus())")
        exit(EXIT_SUCCESS)
    }

    private static func emit(_ message: String) {
        FileHandle.standardOutput.write(Data("SMAPPSERVICE_PROBE \(message)\n".utf8))
    }
}
