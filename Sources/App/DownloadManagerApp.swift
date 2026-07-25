// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Presentation
import SwiftUI

/// Application entry point. SwiftUI owns composition; the library window (sidebar,
/// AppKit-backed virtualized table, inspector) and background-engine status live in
/// `Presentation`.
///
/// Flow runs as a menu-bar agent (no Dock tile): `LSUIElement` + accessory
/// activation policy, with one library window opened on demand.
@main
struct DownloadManagerApp: App {
    /// Filename of the LaunchAgent property list embedded at
    /// `Contents/Library/LaunchAgents/` (must match its `Label`).
    static let launchAgentPlistName = "org.downloadmanager.local.DownloadEngineAgent.plist"

    @NSApplicationDelegateAdaptor(FlowAppDelegate.self) private var appDelegate

    @StateObject private var launchAgent: LaunchAgentModel
    @StateObject private var library: LibraryModel
    @StateObject private var clipboardMonitor = ClipboardMonitor()
    @StateObject private var updateCheck = UpdateCheckController()
    @StateObject private var chromeCompanion = ChromeCompanionSetupController()
    @StateObject private var launchAtLogin = LaunchAtLoginController()

    init() {
        // Non-UI diagnostic path: report / re-register SMAppService, then exit.
        if CommandLine.arguments.contains(LaunchAgentProbe.launchArgument)
            || CommandLine.arguments.contains(LaunchAgentProbe.reregisterArgument) {
            LaunchAgentProbe.runAndExit(plistName: Self.launchAgentPlistName)
        }
        _launchAgent = StateObject(wrappedValue: LaunchAgentModel(
            manager: SMAppServiceLaunchAgent(plistName: Self.launchAgentPlistName)
        ))
        _library = StateObject(wrappedValue: LibraryModel(rows: []))
    }

    var body: some Scene {
        MenuBarExtra {
            AgentMenuContent(
                library: library,
                launchAgent: launchAgent,
                launchAtLogin: launchAtLogin,
                updateCheck: updateCheck,
                chromeCompanion: chromeCompanion
            )
        } label: {
            AgentMenuLabel(activeCount: library.rows.count(where: { $0.statusRole == .active }))
                .background(
                    OpenWindowBridge(
                        library: library,
                        clipboardMonitor: clipboardMonitor,
                        chromeCompanion: chromeCompanion
                    )
                )
        }
        .menuBarExtraStyle(.menu)

        // Single library window — never a WindowGroup (Chrome handoffs used to
        // spawn a new Compose host per openURL).
        Window("Flow Download Manager", id: "main") {
            RootView(model: library, launchAgent: launchAgent)
                .frame(minWidth: 900, minHeight: 520)
                .flowAppearance()
                .environmentObject(launchAgent)
                .environmentObject(chromeCompanion)
                .environmentObject(launchAtLogin)
                .onOpenURL { url in
                    library.handleOpenURL(url)
                    NotificationCenter.default.post(name: .flowRevealMainWindow, object: nil)
                }
                .alert(updateCheck.alertTitle, isPresented: $updateCheck.isAlertPresented) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(updateCheck.alertMessage)
                }
                .alert("Chrome companion", isPresented: $chromeCompanion.isIntroPresented) {
                    Button("Open Chrome with Companion") {
                        chromeCompanion.openChromeWithCompanion()
                    }
                    Button("Not Now", role: .cancel) {
                        chromeCompanion.dismissIntro()
                    }
                } message: {
                    Text(
                        "Send links from Chrome into Flow with one click. Chrome blocks "
                            + "silent install into your everyday profile, so Flow opens a "
                            + "dedicated Chrome profile with the companion already installed. "
                            + "Also in Settings → Browser companion."
                    )
                }
                .alert(chromeCompanion.resultTitle, isPresented: $chromeCompanion.isResultPresented) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(chromeCompanion.resultMessage)
                }
                .alert("Restart Chrome?", isPresented: $chromeCompanion.isRestartChromePresented) {
                    Button("Restart Chrome", role: .destructive) {
                        chromeCompanion.confirmRestartChromeAndOpen()
                    }
                    Button("Cancel", role: .cancel) {
                        chromeCompanion.cancelRestartChrome()
                    }
                } message: {
                    Text(
                        "Flow will open its dedicated Chrome profile (your everyday Chrome "
                            + "can stay open). The companion is installed only in that profile."
                    )
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateCheck.checkForUpdates()
                }
                Button("Open Chrome with Companion") {
                    chromeCompanion.openChromeWithCompanion()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Downloads…") { library.addSheetPresented = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button(library.inspectedID == nil ? "Show Details" : "Close Details") {
                    library.toggleInspector()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(library.inspectedID == nil && library.selectedID == nil)
                Divider()
                Button("Pause All") {
                    Task { await library.pauseAll() }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Resume All") {
                    Task { await library.resumeAll() }
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("Refresh Engine Status") { launchAgent.refresh() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(launchAgent)
                .environmentObject(updateCheck)
                .environmentObject(chromeCompanion)
                .environmentObject(launchAtLogin)
                .flowAppearance()
        }
    }
}

// MARK: - Menu bar

private struct AgentMenuLabel: View {
    let activeCount: Int

    var body: some View {
        // Purple Flow app mark in the menu bar (original colors — not SF Symbol).
        HStack(spacing: 3) {
            Image("MenuBarIcon")
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
            if activeCount > 0 {
                Text("\(activeCount)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(
            activeCount > 0
                ? "Flow Download Manager, \(activeCount) active"
                : "Flow Download Manager"
        )
    }
}

/// Always-mounted under the menu-bar label so handoffs can open the one window
/// even when the dropdown menu is closed.
private struct OpenWindowBridge: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var clipboardMonitor: ClipboardMonitor
    @ObservedObject var chromeCompanion: ChromeCompanionSetupController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                clipboardMonitor.setHandler { text in
                    library.presentClipboardLinks(text)
                    NotificationCenter.default.post(name: .flowRevealMainWindow, object: nil)
                }
                clipboardMonitor.syncWithPreference()
                chromeCompanion.presentIntroIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UserDefaults.didChangeNotification
            )) { _ in
                clipboardMonitor.syncWithPreference()
            }
            .onReceive(NotificationCenter.default.publisher(for: .flowRevealMainWindow)) { _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

private struct AgentMenuContent: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var launchAgent: LaunchAgentModel
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var updateCheck: UpdateCheckController
    @ObservedObject var chromeCompanion: ChromeCompanionSetupController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var activeCount: Int {
        library.rows.count(where: { $0.statusRole == .active })
    }

    private var queuedCount: Int {
        library.rows.count(where: { $0.statusRole == .queued })
    }

    var body: some View {
        Text(
            activeCount == 0
                ? "No active downloads"
                : "\(activeCount) active · \(queuedCount) queued"
        )
        if !launchAgent.isEngineReady {
            Text("Engine offline")
        }
        Divider()
        Button("Open Flow") {
            revealMainWindow()
        }
        Button("Add Downloads…") {
            library.addSheetPresented = true
            revealMainWindow()
        }
        .keyboardShortcut("n")
        Divider()
        Button("Pause All") {
            Task { await library.pauseAll() }
        }
        Button("Resume All") {
            Task { await library.resumeAll() }
        }
        Divider()
        Toggle(
            "Launch at Login",
            isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            )
        )
        Button("Settings…") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Open Chrome with Companion") {
            chromeCompanion.openChromeWithCompanion()
        }
        Button("Check for Updates…") {
            updateCheck.checkForUpdates()
        }
        Divider()
        Button("Quit Flow") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func revealMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
