// SPDX-License-Identifier: GPL-3.0-or-later

import Presentation
import SwiftUI

/// Application entry point. SwiftUI owns composition; the library window (sidebar,
/// AppKit-backed virtualized table, inspector) and background-engine status live in
/// `Presentation`. Phase 0 uses deterministic fixture read models; later phases
/// deliver read snapshots over XPC.
@main
struct DownloadManagerApp: App {
    /// Filename of the LaunchAgent property list embedded at
    /// `Contents/Library/LaunchAgents/` (must match its `Label`).
    static let launchAgentPlistName = "org.downloadmanager.local.DownloadEngineAgent.plist"

    @StateObject private var launchAgent: LaunchAgentModel
    @StateObject private var library: LibraryModel
    @StateObject private var menuBar = MenuBarController()

    init() {
        // Non-UI diagnostic path: report SMAppService status, then exit.
        if CommandLine.arguments.contains(LaunchAgentProbe.launchArgument) {
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
                .onAppear {
                    menuBar.install(
                        library: library,
                        openHandler: {},
                        addHandler: { library.addSheetPresented = true }
                    )
                }
                .onChange(of: library.rows) { _, _ in
                    menuBar.refreshMenu()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Downloads…") { library.addSheetPresented = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button(library.inspectorVisible ? "Hide Inspector" : "Show Inspector") {
                    library.inspectorVisible.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("Refresh Engine Status") { launchAgent.refresh() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
