// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import UserNotifications
import XPCContracts

/// Finder reveal / Quick Look helpers (FR-FS-006).
@MainActor
public enum FinderIntegration {
    public static func reveal(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public static func revealIfExists(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        reveal(url: url)
    }
}

/// Rate-limited user notifications for job completion/failure (FR-UX-004).
@MainActor
public final class DownloadNotificationCenter {
    public static let shared = DownloadNotificationCenter()

    private var authorized = false
    private var lastPostedAt: Date = .distantPast
    private let presentationDelegate = NotificationPresentationDelegate()

    private init() {}

    public func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.delegate = presentationDelegate
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.authorized = granted
            }
        }
    }

    public func postJobFinished(name: String, succeeded: Bool) {
        guard authorized else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPostedAt) >= 1.0 else { return }
        lastPostedAt = now

        let content = UNMutableNotificationContent()
        content.title = succeeded ? "Download complete" : "Download failed"
        content.body = name
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Clipboard monitoring found Phase-1-valid links (never auto-enqueues).
    public func postLinksDetected() {
        guard authorized else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPostedAt) >= 1.0 else { return }
        lastPostedAt = now

        let content = UNMutableNotificationContent()
        content.title = "Links detected"
        content.body = "Clipboard contains downloadable links. Review them in Add Downloads."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

private final class NotificationPresentationDelegate: NSObject, UNUserNotificationCenterDelegate,
    @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

/// Menu bar controller for aggregate status and quick actions (FR-UX-002).
@MainActor
public final class MenuBarController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private weak var library: LibraryModel?
    private var openHandler: (() -> Void)?
    private var addHandler: (() -> Void)?

    public func install(
        library: LibraryModel,
        openHandler: @escaping () -> Void,
        addHandler: @escaping () -> Void
    ) {
        self.library = library
        self.openHandler = openHandler
        self.addHandler = addHandler
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "arrow.down.circle",
                accessibilityDescription: "Downloads"
            )
        }
        statusItem = item
        refreshMenu()
    }

    public func refreshMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let active = library?.rows.count(where: { $0.statusRole == .active }) ?? 0
        let queued = library?.rows.count(where: { $0.statusRole == .queued }) ?? 0
        menu.addItem(NSMenuItem(
            title: active == 0 ? "No active downloads" : "\(active) active · \(queued) queued",
            action: nil,
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Download Manager", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let add = NSMenuItem(title: "Add Downloads…", action: #selector(addDownloads), keyEquivalent: "n")
        add.target = self
        menu.addItem(add)
        menu.addItem(.separator())
        let pauseAll = NSMenuItem(title: "Pause All", action: #selector(pauseAllDownloads), keyEquivalent: "")
        pauseAll.target = self
        menu.addItem(pauseAll)
        let resumeAll = NSMenuItem(title: "Resume All", action: #selector(resumeAllDownloads), keyEquivalent: "")
        resumeAll.target = self
        menu.addItem(resumeAll)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem.menu = menu
        if let button = statusItem.button {
            button.title = active > 0 ? "\(active)" : ""
        }
    }

    @objc private func openApp() {
        openHandler?()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func addDownloads() {
        addHandler?()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func pauseAllDownloads() {
        guard let library else { return }
        Task { await library.pauseAll() }
    }

    @objc private func resumeAllDownloads() {
        guard let library else { return }
        Task { await library.resumeAll() }
    }
}
