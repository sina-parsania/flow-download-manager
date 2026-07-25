// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import ServiceManagement

/// Keeps Flow as a single running process (Neat-style menu-bar agent).
public enum SingleInstanceGuard {
    /// If another copy of this bundle is already running, activate it and exit.
    public static func terminateIfDuplicate() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != mine
        }
        guard let existing = others.first else { return }
        // macOS 14+: `activateIgnoringOtherApps` is deprecated (no-op); plain activate.
        existing.activate()
        exit(EXIT_SUCCESS)
    }
}

/// Launch-at-login for the main Flow app via `SMAppService.mainApp`.
@MainActor
public final class LaunchAtLoginController: ObservableObject {
    public static let defaultsKey = "flow.launchAtLogin"

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var lastErrorMessage: String?

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            isEnabled = true
        case .notRegistered, .notFound, .requiresApproval:
            isEnabled = defaults.bool(forKey: Self.defaultsKey)
        @unknown default:
            isEnabled = defaults.bool(forKey: Self.defaultsKey)
        }
    }

    public func setEnabled(_ enabled: Bool) {
        lastErrorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            defaults.set(enabled, forKey: Self.defaultsKey)
            isEnabled = enabled
        } catch {
            lastErrorMessage =
                "Couldn’t update Launch at Login. Check System Settings → Login Items."
            isEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// AppKit hooks for accessory (menu-bar) activation and reopen behavior.
public final class FlowAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationWillFinishLaunching(_ notification: Notification) {
        SingleInstanceGuard.terminateIfDuplicate()
        // Hide Dock tile; status item + windows stay available (Neat-style).
        NSApp.setActivationPolicy(.accessory)
    }

    public func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        NotificationCenter.default.post(name: .flowRevealMainWindow, object: nil)
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        // Menu-bar agent stays alive when the library window is closed.
        false
    }
}

public extension Notification.Name {
    /// Posted when the library window should be shown (menu, reopen, handoff).
    static let flowRevealMainWindow = Notification.Name(
        "org.downloadmanager.local.revealMainWindow"
    )
}
