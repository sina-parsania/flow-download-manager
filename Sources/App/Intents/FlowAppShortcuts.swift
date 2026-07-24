// SPDX-License-Identifier: GPL-3.0-or-later

import AppIntents
import Foundation

/// Invocation phrases for Spotlight, the Shortcuts gallery and voice.
///
/// This is what replaces a scripting port: the same actions another download
/// manager exposes over an open localhost socket are reachable here through the
/// system, with nothing listening on a port and no unauthenticated caller to
/// worry about.
///
/// Every phrase has to contain the application name token — that is what the
/// system matches on, and a phrase without it is rejected at build time.
struct FlowAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddDownloadIntent(),
            phrases: [
                "Add a download to \(.applicationName)",
                "Download a link with \(.applicationName)",
                "Queue a download in \(.applicationName)"
            ],
            shortTitle: "Add Download",
            systemImageName: "arrow.down.circle"
        )
        AppShortcut(
            intent: AddDownloadsIntent(),
            phrases: [
                "Add downloads to \(.applicationName)",
                "Queue downloads in \(.applicationName)"
            ],
            shortTitle: "Add Downloads",
            systemImageName: "square.and.arrow.down.on.square"
        )
        AppShortcut(
            intent: PauseAllDownloadsIntent(),
            phrases: [
                "Pause all downloads in \(.applicationName)",
                "Pause \(.applicationName) downloads"
            ],
            shortTitle: "Pause All",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ResumeAllDownloadsIntent(),
            phrases: [
                "Resume all downloads in \(.applicationName)",
                "Resume \(.applicationName) downloads"
            ],
            shortTitle: "Resume All",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: GetDownloadsIntent(),
            phrases: [
                "Get downloads from \(.applicationName)",
                "Check \(.applicationName) downloads"
            ],
            shortTitle: "Get Downloads",
            systemImageName: "list.bullet.rectangle"
        )
    }
}
