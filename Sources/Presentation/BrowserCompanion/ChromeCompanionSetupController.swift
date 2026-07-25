// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SharedObservability

/// Makes the Chrome companion usable without the Chrome Web Store.
///
/// Chrome blocks silent install into the everyday profile, so Flow:
/// 1. Registers the native-messaging host + materializes the extension folder
/// 2. Installs the companion once into a dedicated Chrome profile (CDP)
/// 3. Opens that profile (one click) — optionally drops a Dock launcher
@MainActor
public final class ChromeCompanionSetupController: ObservableObject {
    public static let introDismissedDefaultsKey = "chromeCompanion.introDismissed"
    // Referenced from nonisolated setup helpers (manifest / launcher writers).
    public nonisolated static let hostName = "org.downloadmanager.local.chrome_native_host"
    public nonisolated static let launcherAppName = "Open Chrome with Flow Companion.app"

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
        var expectedIDs = Set(
            ChromeUnpackedExtensionID.candidates(for: supportURL).map {
                "chrome-extension://\($0)/"
            }
        )
        let marker = Self.chromeProfileDirectory()
            .appendingPathComponent(".flow-companion-extension-id")
        if let installed = try? String(contentsOf: marker, encoding: .utf8) {
            let trimmed = installed.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                expectedIDs.insert("chrome-extension://\(trimmed)/")
            }
        }
        if !expectedIDs.isDisjoint(with: Set(origins)) {
            isRegistered = true
            statusLine = "Ready — opens Flow’s Chrome profile (companion installed)"
        } else {
            isRegistered = false
            statusLine = "Host manifest is stale — open Chrome with Companion again"
        }
    }

    /// Registers the host, installs into Flow’s Chrome profile if needed, then opens it.
    public func openChromeWithCompanion() {
        guard !isBusy else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Self.prepareCompanionFilesSync()
                }.value
                extensionFolderPath = Self.installedExtensionDirectory().path
                refreshStatus()
                UserDefaults.standard.set(true, forKey: Self.introDismissedDefaultsKey)
                isIntroPresented = false
                try launchChromeWithExtension()
                presentOpenedResult()
            } catch {
                presentFailure(error)
            }
        }
    }

    public func confirmRestartChromeAndOpen() {
        // Kept for older alert bindings; dedicated profile no longer needs a full restart.
        isRestartChromePresented = false
        openChromeWithCompanion()
    }

    public func cancelRestartChrome() {
        isRestartChromePresented = false
    }

    /// Drops `~/Applications/Open Chrome with Flow Companion.app` for Dock/double-click use.
    public func installApplicationsLauncher() {
        guard !isBusy else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Self.prepareCompanionFilesSync()
                }.value
                extensionFolderPath = Self.installedExtensionDirectory().path
                refreshStatus()
                let launcher = try Self.writeApplicationsLauncher(
                    extensionPath: resolvedExtensionPath()
                )
                NSWorkspace.shared.activateFileViewerSelecting([launcher])
                resultTitle = "Launcher installed"
                resultMessage = """
                Created:

                \(launcher.path)

                Double-click it (or keep it in the Dock) to open Flow’s Chrome profile \
                with the companion already installed.
                """
                isResultPresented = true
            } catch {
                presentFailure(error)
            }
        }
    }

    // MARK: - Private actions

    nonisolated static func prepareCompanionFilesSync() throws {
        let extensionURL = try materializeExtensionDirectory()
        let hostURL = try requirePreferredHostURL()
        var ids = ChromeUnpackedExtensionID.candidates(for: extensionURL).map {
            ChromeUnpackedExtensionID.make(directoryPath: $0)
        }
        // Also allow the stable Application Support folders Chrome may Load unpacked from.
        for url in companionExtensionDirectories() {
            for path in ChromeUnpackedExtensionID.candidates(for: url) {
                let id = ChromeUnpackedExtensionID.make(directoryPath: path)
                if !ids.contains(id) {
                    ids.append(id)
                }
            }
        }
        let installedID = try ensureCompanionInstalledInChromeProfile(
            extensionPath: extensionURL.path
        )
        if !ids.contains(installedID) {
            ids.append(installedID)
        }
        try writeNativeHostManifests(hostURL: hostURL, extensionIDs: ids)
    }

    /// Folders that may already hold a Load unpacked install.
    nonisolated static func companionExtensionDirectories() -> [URL] {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [
            root.appendingPathComponent("Flow Download Manager/ChromeCompanion", isDirectory: true),
            root.appendingPathComponent(
                "org.downloadmanager.local.DownloadManager/ChromeCompanion",
                isDirectory: true
            )
        ]
    }

    private func launchChromeWithExtension() throws {
        let extensionPath = resolvedExtensionPath()
        guard FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: extensionPath).appendingPathComponent("manifest.json").path
        ) else {
            throw CompanionSetupError.extensionMissing
        }
        guard Self.chromeBinaryURL() != nil else {
            throw CompanionSetupError.chromeMissing
        }
        let profile = Self.chromeProfileDirectory().path
        // Use `open -na` so Chrome is AppKit-launched and not tied to Flow’s process tree.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-na",
            "Google Chrome",
            "--args",
            "--user-data-dir=\(profile)",
            "--no-first-run",
            "--no-default-browser-check",
            "chrome://extensions"
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CompanionSetupError.chromeMissing
        }
    }

    private func presentOpenedResult() {
        resultTitle = "Chrome opened with Flow"
        resultMessage = """
        Flow opened its dedicated Chrome profile where the companion is installed.

        On chrome://extensions you should see “Flow Download Manager Companion”. \
        Pin it, then Check native host.

        This is a separate Chrome profile (Chrome 137+ blocks installing into your \
        main profile automatically). Sign into Chrome Sync here if you want bookmarks.
        """
        isResultPresented = true
        EngineLog.browserExtension.info("Chrome launched with Flow companion profile")
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

    public nonisolated static func chromeProfileDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("org.downloadmanager.local.DownloadManager", isDirectory: true)
            .appendingPathComponent("ChromeProfile", isDirectory: true)
    }

    public nonisolated static func installedExtensionDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Prefer the folder Chrome already has Load unpacked pointed at (stable ID).
        let existingLoad = root
            .appendingPathComponent("Flow Download Manager", isDirectory: true)
            .appendingPathComponent("ChromeCompanion", isDirectory: true)
        if FileManager.default.fileExists(
            atPath: existingLoad.appendingPathComponent("manifest.json").path
        ) {
            return existingLoad
        }
        return root
            .appendingPathComponent("org.downloadmanager.local.DownloadManager", isDirectory: true)
            .appendingPathComponent("ChromeCompanion", isDirectory: true)
    }

    nonisolated static func chromeBinaryURL() -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            )
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated static func ensureCompanionInstalledInChromeProfile(extensionPath: String) throws -> String {
        let profile = chromeProfileDirectory()
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let marker = profile.appendingPathComponent(".flow-companion-extension-id")
        if let existing = try? String(contentsOf: marker, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        guard let chromeBinary = chromeBinaryURL() else {
            throw CompanionSetupError.chromeMissing
        }
        let script = try resolveLoadUnpackedScriptURL()

        // Launch a second Chrome with Flow’s profile only — do not quit the user’s Chrome.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            script.path,
            "--chrome", chromeBinary.path,
            "--profile", profile.path,
            "--extension", extensionPath
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outText = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errText = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !outText.isEmpty else {
            throw CompanionSetupError.installFailed(errText.isEmpty ? outText : errText)
        }
        return outText
    }

    nonisolated static func resolveLoadUnpackedScriptURL() throws -> URL {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("chrome-load-unpacked.py", isDirectory: false),
            FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts/chrome-load-unpacked.py", isDirectory: false)
        if FileManager.default.fileExists(atPath: repo.path) {
            return repo
        }
        throw CompanionSetupError.extensionMissing
    }

    public nonisolated static func preferredHostURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Prefer /Applications (Launchpad / Finder Applications) over ~/Applications.
        let candidates = [
            URL(fileURLWithPath: "/Applications/Flow Download Manager.app/Contents/MacOS/ChromeNativeHost"),
            home.appendingPathComponent(
                "Applications/Flow Download Manager.app/Contents/MacOS/ChromeNativeHost"
            ),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ChromeNativeHost")
        ]
        for url in candidates {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public nonisolated static func embeddedHostURL() -> URL? {
        preferredHostURL()
    }

    public nonisolated static func bundledExtensionSourceURL() -> URL? {
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

    nonisolated static func chromeManifestURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Google/Chrome/NativeMessagingHosts",
                isDirectory: true
            )
            .appendingPathComponent("\(hostName).json", isDirectory: false)
    }

    nonisolated static func requirePreferredHostURL() throws -> URL {
        guard let url = preferredHostURL() else {
            throw CompanionSetupError.hostMissing
        }
        return url
    }

    nonisolated static func requireEmbeddedHostURL() throws -> URL {
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

    nonisolated static func materializeExtensionDirectory() throws -> URL {
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

    nonisolated static func flattenIfNestedChromeFolder(at destination: URL) throws {
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

    nonisolated static func writeNativeHostManifests(hostURL: URL, extensionIDs: [String]) throws {
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

    nonisolated static func writeApplicationsLauncher(extensionPath: String) throws -> URL {
        let apps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let appURL = apps.appendingPathComponent(launcherAppName, isDirectory: true)
        if FileManager.default.fileExists(atPath: appURL.path) {
            try FileManager.default.removeItem(at: appURL)
        }

        let escapedProfile = Self.chromeProfileDirectory().path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        on run
          set profilePath to "\(escapedProfile)"
          do shell script "/usr/bin/open -na " & quoted form of "/Applications/Google Chrome.app" & " --args --user-data-dir=" & quoted form of profilePath & " chrome://extensions"
        end run
        """
        // Keep signature of writeApplicationsLauncher(extensionPath:) for call sites.
        _ = extensionPath
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
    case installFailed(String)

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
        case let .installFailed(detail):
            return "Could not install the companion into Flow’s Chrome profile. \(detail)"
        }
    }
}
