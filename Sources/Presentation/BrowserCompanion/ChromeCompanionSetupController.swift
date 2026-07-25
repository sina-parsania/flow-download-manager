// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SharedObservability

/// Makes the Chrome companion usable without the Chrome Web Store.
///
/// Chrome blocks silent install of unpacked extensions, so Flow:
/// 1. Registers the native-messaging host + materializes the extension folder
/// 2. Restarts Chrome with `--load-extension` (one click — no Load unpacked)
/// 3. Optionally drops a small launcher in `~/Applications`
@MainActor
public final class ChromeCompanionSetupController: ObservableObject {
    public static let introDismissedDefaultsKey = "chromeCompanion.introDismissed"
    public static let hostName = "org.downloadmanager.local.ChromeNativeHost"
    public static let launcherAppName = "Open Chrome with Flow Companion.app"

    @Published public var isIntroPresented = false
    @Published public var isResultPresented = false
    @Published public var isRestartChromePresented = false
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
        isIntroPresented = true
    }

    public func dismissIntro() {
        UserDefaults.standard.set(true, forKey: Self.introDismissedDefaultsKey)
        isIntroPresented = false
    }

    public func copyExtensionFolderPath() {
        let path = resolvedExtensionPath()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    public func revealExtensionFolder() {
        let url = URL(fileURLWithPath: resolvedExtensionPath())
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    public func refreshStatus() {
        let supportURL = Self.installedExtensionDirectory()
        extensionFolderPath = supportURL.path
        let hostURL = Self.preferredHostURL()
        let manifestURL = Self.chromeManifestURL()
        guard let hostURL else {
            isRegistered = false
            statusLine = "ChromeNativeHost missing from this build"
            return
        }
        let hasExtension = FileManager.default.fileExists(
            atPath: supportURL.appendingPathComponent("manifest.json").path
        )
        guard hasExtension,
              FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["path"] as? String,
              path == hostURL.path,
              let origins = json["allowed_origins"] as? [String]
        else {
            isRegistered = false
            statusLine = hasExtension
                ? "Extension ready — open Chrome from Flow to attach it"
                : "Not set up yet — use Open Chrome with Companion"
            return
        }
        let expectedIDs = Set(
            ChromeUnpackedExtensionID.candidates(for: supportURL).map {
                "chrome-extension://\($0)/"
            }
        )
        if expectedIDs.isSubset(of: Set(origins)) {
            isRegistered = true
            statusLine = "Ready — Open Chrome with Companion (one click)"
        } else {
            isRegistered = false
            statusLine = "Host manifest is stale — open Chrome with Companion again"
        }
    }

    /// Registers the host, then opens Chrome with the companion attached.
    public func openChromeWithCompanion() {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try prepareCompanionFiles()
            UserDefaults.standard.set(true, forKey: Self.introDismissedDefaultsKey)
            isIntroPresented = false

            if Self.isChromeRunning() {
                isRestartChromePresented = true
                return
            }
            try launchChromeWithExtension()
            presentOpenedResult()
        } catch {
            presentFailure(error)
        }
    }

    public func confirmRestartChromeAndOpen() {
        isRestartChromePresented = false
        guard !isBusy else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try prepareCompanionFiles()
                Self.quitChrome()
                try await Task.sleep(for: .milliseconds(1200))
                try launchChromeWithExtension()
                presentOpenedResult()
            } catch {
                presentFailure(error)
            }
        }
    }

    public func cancelRestartChrome() {
        isRestartChromePresented = false
    }

    /// Drops `~/Applications/Open Chrome with Flow Companion.app` for Dock/double-click use.
    public func installApplicationsLauncher() {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try prepareCompanionFiles()
            let launcher = try Self.writeApplicationsLauncher(extensionPath: resolvedExtensionPath())
            NSWorkspace.shared.activateFileViewerSelecting([launcher])
            resultTitle = "Launcher installed"
            resultMessage = """
            Created:

            \(launcher.path)

            Double-click it (or keep it in the Dock) whenever you want Chrome with the \
            Flow companion already attached — no Load unpacked step.
            """
            isResultPresented = true
        } catch {
            presentFailure(error)
        }
    }

    // MARK: - Private actions

    private func prepareCompanionFiles() throws {
        let extensionURL = try Self.materializeExtensionDirectory()
        extensionFolderPath = extensionURL.path
        let hostURL = try Self.requirePreferredHostURL()
        let ids = ChromeUnpackedExtensionID.candidates(for: extensionURL).map {
            ChromeUnpackedExtensionID.make(directoryPath: $0)
        }
        try Self.writeNativeHostManifests(hostURL: hostURL, extensionIDs: ids)
        refreshStatus()
    }

    private func launchChromeWithExtension() throws {
        let extensionPath = resolvedExtensionPath()
        guard FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: extensionPath).appendingPathComponent("manifest.json").path
        ) else {
            throw CompanionSetupError.extensionMissing
        }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil
        else {
            throw CompanionSetupError.chromeMissing
        }

        // Chrome 137+ branded builds ignore `--load-extension` unless this
        // temporary kill-switch feature is disabled (still required on 150).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-na",
            "Google Chrome",
            "--args",
            "--disable-features=DisableLoadExtensionCommandLineSwitch",
            "--load-extension=\(extensionPath)",
            "--restore-last-session"
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CompanionSetupError.chromeMissing
        }

        // Give Chrome a beat, then open the extensions page so the companion is visible.
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
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
        }
    }

    private func presentOpenedResult() {
        resultTitle = "Chrome opened with Flow"
        resultMessage = """
        The companion should appear on chrome://extensions for this session.

        Pin “Flow Download Manager Companion” from the puzzle icon, then use the \
        popup or right-click → send link.

        Chrome 137+ blocks silent extension loading; Flow re-enables the temporary \
        developer switch for this launch only.
        """
        isResultPresented = true
        EngineLog.browserExtension.info("Chrome launched with companion load-extension")
    }

    private func presentFailure(_ error: Error) {
        resultTitle = "Couldn’t set up the companion"
        resultMessage = error.localizedDescription
        isResultPresented = true
        EngineLog.browserExtension.error(
            "Chrome companion setup failed \(EngineLog.redacted(error), privacy: .public)"
        )
    }

    private func resolvedExtensionPath() -> String {
        extensionFolderPath.isEmpty
            ? Self.installedExtensionDirectory().path
            : extensionFolderPath
    }

    // MARK: - Paths / Chrome process

    public static func installedExtensionDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("org.downloadmanager.local.DownloadManager", isDirectory: true)
            .appendingPathComponent("ChromeCompanion", isDirectory: true)
    }

    public static func preferredHostURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(
                "Applications/Flow Download Manager.app/Contents/MacOS/ChromeNativeHost"
            ),
            URL(fileURLWithPath: "/Applications/Flow Download Manager.app/Contents/MacOS/ChromeNativeHost"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ChromeNativeHost")
        ]
        for url in candidates {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public static func embeddedHostURL() -> URL? {
        preferredHostURL()
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

    static func requirePreferredHostURL() throws -> URL {
        guard let url = preferredHostURL() else {
            throw CompanionSetupError.hostMissing
        }
        return url
    }

    static func requireEmbeddedHostURL() throws -> URL {
        try requirePreferredHostURL()
    }

    static func isChromeRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
    }

    static func quitChrome() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome") {
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(8)
        while isChromeRunning(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if isChromeRunning() {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome") {
                app.forceTerminate()
            }
        }
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

    static func writeApplicationsLauncher(extensionPath: String) throws -> URL {
        let apps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let appURL = apps.appendingPathComponent(launcherAppName, isDirectory: true)
        if FileManager.default.fileExists(atPath: appURL.path) {
            try FileManager.default.removeItem(at: appURL)
        }

        let escapedForAppleScript = extensionPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        on run
          set extPath to "\(escapedForAppleScript)"
          do shell script "/usr/bin/open -na " & quoted form of "/Applications/Google Chrome.app" & " --args --disable-features=DisableLoadExtensionCommandLineSwitch --load-extension=" & quoted form of extPath & " --restore-last-session"
        end run
        """
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-chrome-launcher-\(UUID().uuidString).applescript")
        try source.write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", appURL.path, temp.path]
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? "osacompile failed"
            throw CompanionSetupError.launcherFailed(message)
        }
        return appURL
    }
}

private enum CompanionSetupError: LocalizedError {
    case hostMissing
    case extensionMissing
    case chromeMissing
    case manifestEncodeFailed
    case launcherFailed(String)

    var errorDescription: String? {
        switch self {
        case .hostMissing:
            return "This Flow build is missing ChromeNativeHost."
        case .extensionMissing:
            return "The Chrome companion files are not bundled in this build."
        case .chromeMissing:
            return "Google Chrome is not installed."
        case .manifestEncodeFailed:
            return "Could not encode the native host manifest."
        case let .launcherFailed(detail):
            return "Could not create the Chrome launcher. \(detail)"
        }
    }
}
