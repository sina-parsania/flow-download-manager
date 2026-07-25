// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Application
import Foundation
import XPCContracts

/// Hands URLs to the Flow app when the engine's XPC listener is not reachable.
public protocol AppHandoffPerforming: Sendable {
    func handOff(urls: [String]) async throws
}

public enum AppHandoffError: Error, Equatable, Sendable {
    case noURLs
    case appNotFound
    case openFailed
}

/// Builds the `downloadmanager://` URL the app parses with `OpenURLIngest`.
///
/// Only URLs travel this way. Headers and cookies deliberately do not: a custom
/// scheme URL is handed to LaunchServices, which records it, and any process can
/// observe an open request — so a session cookie in the query string would be a
/// credential leak. The engine path is the only one that carries headers.
public enum AppHandoffURL {
    /// LaunchServices has to carry the whole batch in one URL; keep it short
    /// enough to stay well inside its limits.
    public static let maxURLCount = 32

    public static func make(urls: [String]) -> URL? {
        let limited = Array(urls.prefix(maxURLCount))
        guard !limited.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = OpenURLIngest.scheme
        components.host = "enqueue"
        components.queryItems = limited.map { URLQueryItem(name: "url", value: $0) }
        return components.url
    }
}

/// Opens the hand-off URL with the Flow app bundle that contains this host.
///
/// The app is addressed by bundle URL, never by asking LaunchServices which
/// application claims `downloadmanager://`: that scheme is unauthenticated and any
/// installed app can register for it, so resolving by scheme would let a third
/// party intercept the user's downloads.
public struct WorkspaceAppHandoff: AppHandoffPerforming {
    private let applicationURL: URL?

    public init(applicationURL: URL? = WorkspaceAppHandoff.resolveApplicationURL()) {
        self.applicationURL = applicationURL
    }

    public func handOff(urls: [String]) async throws {
        guard let url = AppHandoffURL.make(urls: urls) else { throw AppHandoffError.noURLs }
        guard let applicationURL else { throw AppHandoffError.appNotFound }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        if #available(macOS 12.0, *) {
            configuration.createsNewApplicationInstance = false
        }
        do {
            _ = try await NSWorkspace.shared.open(
                [url],
                withApplicationAt: applicationURL,
                configuration: configuration
            )
        } catch {
            throw AppHandoffError.openFailed
        }
    }

    /// Prefers the `.app` this executable is embedded in, then a LaunchServices
    /// lookup by the app's bundle identifier.
    public static func resolveApplicationURL() -> URL? {
        if let containing = containingApplicationURL() { return containing }
        return NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: XPCClientIdentities.appBundleIdentifier
        )
    }

    /// Walks up from `…/Flow Download Manager.app/Contents/MacOS/ChromeNativeHost`.
    static func containingApplicationURL() -> URL? {
        let bundle = Bundle.main
        if bundle.bundleURL.pathExtension == "app" { return bundle.bundleURL }
        guard let executable = bundle.executableURL?.resolvingSymlinksInPath() else { return nil }
        var candidate = executable.deletingLastPathComponent()
        for _ in 0 ..< 3 {
            if candidate.pathExtension == "app" { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { return nil }
            candidate = parent
        }
        return nil
    }
}
