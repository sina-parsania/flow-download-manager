// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SharedObservability

/// Installs Flow’s Chrome companion for end users: copies the bundled extension
/// into Application Support, registers the native-messaging host for Chromium
/// browsers, and opens the one-time Chrome “Load unpacked” steps.
@MainActor
public final class ChromeCompanionSetupController: ObservableObject {
    public static let introDismissedDefaultsKey = "chromeCompanion.introDismissed"
    public static let hostName = "org.downloadmanager.local.ChromeNativeHost"

    @Published public var isIntroPresented = false
    @Published public var isResultPresented = false
    @Published public var resultTitle = ""
    @Published public var resultMessage = ""
    @Published public var statusLine = "Not set up yet"
    @Published public var extensionFolderPath = ""
    @Published public var isBusy = false
    @Published public var isRegistered = false

    public init() {
        extensionFolderPath = Self.installedExtensionDirectory().path
        refreshStatus()
    }

    public func presentIntroIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.introDismissedDefaultsKey) else { return }
        guard !isRegistered else {
            UserDefaults.standard.set(true, forKey: Self.introDismissedDefaultsKey)
            return
        }
        isIntroPresented = true
    }

    public func dismissIntro() {
        UserDefaults.standard.set(true, forKey: Self.introDismissedDefaultsKey)
        isIntroPresented = false
    }

    public func copyExtensionFolderPath() {
        let path = extensionFolderPath.isEmpty
            ? Self.installedExtensionDirectory().path
            : extensionFolderPath
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    public func revealExtensionFolder() {
        let url = URL(fileURLWithPath: extensionFolderPath.isEmpty
            ? Self.installedExtensionDirectory().path
            : extensionFolderPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    public func refreshStatus() {
        let supportURL = Self.installedExtensionDirectory()
        extensionFolderPath = supportURL.path
        let hostURL = Self.embeddedHostURL()
        let manifestURL = Self.chromeManifestURL()
        guard let hostURL else {
            isRegistered = false
            statusLine = "ChromeNativeHost missing from this build"
            return
        }
        guard FileManager.default.fileExists(atPath: supportURL.appendingPathComponent("manifest.json").path),
              FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["path"] as? String,
              path == hostURL.path,
              let origins = json["allowed_origins"] as? [String]
        else {
            isRegistered = false
            statusLine = "Native host not registered yet"
            return
        }
        let expectedIDs = Set(
            ChromeUnpackedExtensionID.candidates(for: supportURL).map {
                "chrome-extension://\($0)/"
            }
        )
        let allowed = Set(origins)
        if expectedIDs.isSubset(of: allowed) {
            isRegistered = true
            statusLine = "Native host registered — Load unpacked in Chrome if you haven’t yet"
        } else {
            isRegistered = false
            statusLine = "Host manifest is stale — run Set Up again"
        }
    }

    public func runSetup() {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let extensionURL = try Self.materializeExtensionDirectory()
            extensionFolderPath = extensionURL.path
            let hostURL = try Self.requireEmbeddedHostURL()
            let ids = ChromeUnpackedExtensionID.candidates(for: extensionURL).map {
                ChromeUnpackedExtensionID.make(directoryPath: $0)
            }
            try Self.writeNativeHostManifests(hostURL: hostURL, extensionIDs: ids)
            refreshStatus()
            UserDefaults.standard.set(true, forKey: Self.introDismissedDefaultsKey)
            isIntroPresented = false

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(extensionURL.path, forType: .string)
            NSWorkspace.shared.activateFileViewerSelecting([extensionURL])
            if let extensionsURL = URL(string: "chrome://extensions"),
               let chromeApp = NSWorkspace.shared.urlForApplication(
                   withBundleIdentifier: "com.google.Chrome"
               ) {
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open(
                    [extensionsURL],
                    withApplicationAt: chromeApp,
                    configuration: configuration
                )
            }

            resultTitle = "Almost done in Chrome"
            resultMessage = """
            Load this exact folder in Chrome (path also copied to the clipboard):

            \(extensionURL.path)

            Steps:
            1. chrome://extensions → turn on Developer mode
            2. Click Load unpacked
            3. Press ⌘⇧G, paste the path above, press Return, then Open

            The folder must contain manifest.json (not a parent folder).
            Then open the companion popup → Check native host.
            """
            isResultPresented = true
            EngineLog.browserExtension.info("Chrome companion setup wrote host manifests")
        } catch {
            resultTitle = "Couldn’t set up the companion"
            resultMessage = error.localizedDescription
            isResultPresented = true
            EngineLog.browserExtension.error(
                "Chrome companion setup failed \(EngineLog.redacted(error), privacy: .public)"
            )
        }
    }

    // MARK: - Paths

    /// Stable install dir without spaces in the product segment (easier in Chrome’s Go to Folder).
    public static func installedExtensionDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("org.downloadmanager.local.DownloadManager", isDirectory: true)
            .appendingPathComponent("ChromeCompanion", isDirectory: true)
    }

    public static func embeddedHostURL() -> URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/ChromeNativeHost", isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    public static func bundledExtensionSourceURL() -> URL? {
        let resourceRoot = Bundle.main.resourceURL
        let bundledCandidates = [
            resourceRoot?.appendingPathComponent("ChromeCompanion", isDirectory: true),
            resourceRoot?.appendingPathComponent("ChromeCompanion/chrome", isDirectory: true)
        ].compactMap(\.self)
        for url in bundledCandidates {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) {
                return url
            }
        }
        // Source-tree / Xcode run without the sync script.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BrowserExtension/chrome", isDirectory: true)
        if FileManager.default.fileExists(atPath: repo.appendingPathComponent("manifest.json").path) {
            return repo
        }
        return nil
    }

    static func chromeManifestURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Google/Chrome/NativeMessagingHosts",
                isDirectory: true
            )
            .appendingPathComponent("\(hostName).json", isDirectory: false)
    }

    static func requireEmbeddedHostURL() throws -> URL {
        guard let url = embeddedHostURL() else {
            throw CompanionSetupError.hostMissing
        }
        return url
    }

    static func materializeExtensionDirectory() throws -> URL {
        guard let source = bundledExtensionSourceURL() else {
            throw CompanionSetupError.extensionMissing
        }
        let destination = installedExtensionDirectory()
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
        try flattenIfNestedChromeFolder(at: destination)
        guard fm.fileExists(atPath: destination.appendingPathComponent("manifest.json").path) else {
            throw CompanionSetupError.extensionMissing
        }
        return destination
    }

    /// XcodeGen folder copies sometimes land as `ChromeCompanion/chrome/manifest.json`.
    static func flattenIfNestedChromeFolder(at destination: URL) throws {
        let nested = destination.appendingPathComponent("chrome", isDirectory: true)
        let nestedManifest = nested.appendingPathComponent("manifest.json")
        let topManifest = destination.appendingPathComponent("manifest.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: nestedManifest.path),
              !fm.fileExists(atPath: topManifest.path)
        else { return }
        for item in try fm.contentsOfDirectory(
            at: nested,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: item, to: target)
        }
        try fm.removeItem(at: nested)
    }

    static func writeNativeHostManifests(hostURL: URL, extensionIDs: [String]) throws {
        let document: [String: Any] = [
            "name": hostName,
            "description": "Flow Download Manager Chrome Native Messaging host",
            "path": hostURL.path,
            "type": "stdio",
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" }
        ]
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        )
        var body = String(data: data, encoding: .utf8) ?? ""
        if !body.hasSuffix("\n") { body.append("\n") }
        guard let utf8 = body.data(using: .utf8) else {
            throw CompanionSetupError.manifestEncodeFailed
        }

        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let browserRoots = [
            "Google/Chrome",
            "Google/Chrome Beta",
            "Google/Chrome Dev",
            "Google/Chrome Canary",
            "Chromium",
            "BraveSoftware/Brave-Browser",
            "Microsoft Edge",
            "Vivaldi",
            "Arc/User Data"
        ]

        var destinations: [URL] = []
        for root in browserRoots {
            let browserSupport = support.appendingPathComponent(root, isDirectory: true)
            if FileManager.default.fileExists(atPath: browserSupport.path) {
                destinations.append(
                    browserSupport.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
                )
            }
        }
        if destinations.isEmpty {
            destinations.append(
                support.appendingPathComponent("Google/Chrome/NativeMessagingHosts", isDirectory: true)
            )
        }

        for directory in destinations {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("\(hostName).json")
            try utf8.write(to: target, options: .atomic)
        }
    }
}

private enum CompanionSetupError: LocalizedError {
    case hostMissing
    case extensionMissing
    case manifestEncodeFailed

    var errorDescription: String? {
        switch self {
        case .hostMissing:
            return "This Flow build is missing ChromeNativeHost."
        case .extensionMissing:
            return "The Chrome companion files are not bundled in this build."
        case .manifestEncodeFailed:
            return "Could not encode the native host manifest."
        }
    }
}
