// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Application
import Foundation

/// Opt-in pasteboard polling for links (FR-ING). Runs only while enabled.
@MainActor
public final class ClipboardMonitor: ObservableObject {
    public static let userDefaultsKey = "clipboardMonitoringEnabled"

    private let pasteboard: NSPasteboard
    private let pollIntervalNanoseconds: UInt64
    private var pollTask: Task<Void, Never>?
    private var lastChangeCount: Int
    private var lastString: String?
    private var onLinksDetected: ((String) -> Void)?

    public init(
        pasteboard: NSPasteboard = .general,
        pollIntervalNanoseconds: UInt64 = 750_000_000
    ) {
        self.pasteboard = pasteboard
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        lastChangeCount = pasteboard.changeCount
        lastString = pasteboard.string(forType: .string)
    }

    public var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.userDefaultsKey)
    }

    public func setHandler(_ handler: @escaping (String) -> Void) {
        onLinksDetected = handler
    }

    /// Starts or stops the timer based on the UserDefaults preference (default false).
    public func syncWithPreference() {
        if isEnabled {
            start()
        } else {
            stop()
        }
    }

    public func start() {
        guard pollTask == nil else { return }
        lastChangeCount = pasteboard.changeCount
        lastString = pasteboard.string(forType: .string)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollOnce()
                try? await Task.sleep(nanoseconds: self?.pollIntervalNanoseconds ?? 750_000_000)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func pollOnce() {
        guard isEnabled else { return }
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        let current = pasteboard.string(forType: .string) ?? ""
        let previous = lastString
        lastString = current
        guard ClipboardMonitoringDecision.shouldNotify(previousText: previous, newText: current)
        else { return }
        DownloadNotificationCenter.shared.postLinksDetected()
        onLinksDetected?(current)
    }
}
