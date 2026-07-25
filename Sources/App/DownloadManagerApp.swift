// SPDX-License-Identifier: GPL-3.0-or-later

import Presentation
import SwiftUI

/// Application entry point. SwiftUI owns composition; the library window (sidebar,
/// AppKit-backed virtualized table, inspector) and background-engine status live in
/// `Presentation`.
@main
struct DownloadManagerApp: App {
    /// Filename of the LaunchAgent property list embedded at
    /// `Contents/Library/LaunchAgents/` (must match its `Label`).
    static let launchAgentPlistName = "org.downloadmanager.local.DownloadEngineAgent.plist"

    @StateObject private var launchAgent: LaunchAgentModel
    @StateObject private var library: LibraryModel
    @StateObject private var menuBar = MenuBarController()
    @StateObject private var clipboardMonitor = ClipboardMonitor()
    @StateObject private var updateCheck = UpdateCheckController()
    @StateObject private var chromeCompanion = ChromeCompanionSetupController()

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
        WindowGroup {
            RootView(model: library, launchAgent: launchAgent)
                .frame(minWidth: 900, minHeight: 520)
                .flowAppearance()
                .environmentObject(launchAgent)
                .environmentObject(chromeCompanion)
                .onAppear {
                    menuBar.install(
                        library: library,
                        openHandler: {},
                        addHandler: { library.addSheetPresented = true }
                    )
                    clipboardMonitor.setHandler { text in
                        library.presentClipboardLinks(text)
                    }
                    clipboardMonitor.syncWithPreference()
                    chromeCompanion.presentIntroIfNeeded()
                }
                // Rebuild on job identity/state, not on `rows` — that changes on
                // every progress tick, which rebuilt the whole menu twice a
                // second while anything was downloading.
                .onChange(of: library.rowIdentitySignature) { _, _ in
                    menuBar.refreshMenu()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UserDefaults.didChangeNotification
                )) { _ in
                    clipboardMonitor.syncWithPreference()
                }
                .onOpenURL { url in
                    // Local-dev `downloadmanager://` handoff — prefills Add sheet only.
                    library.handleOpenURL(url)
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
                        "Send links from Chrome into Flow with one click. Chrome can’t "
                            + "install this companion silently for community builds, so Flow "
                            + "opens Chrome with the companion already attached. "
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
                        "Chrome is already running, so Flow needs to restart it once to "
                            + "attach the companion. Your last session will be restored."
                    )
                }
        }
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
                .flowAppearance()
        }
    }
}
