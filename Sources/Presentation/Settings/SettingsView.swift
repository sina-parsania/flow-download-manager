// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Foundation
import SwiftUI
import XPCContracts

/// Minimal Settings surface for credential/proxy profiles, projects/tags, and About.
public struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @EnvironmentObject private var launchAgent: LaunchAgentModel
    @EnvironmentObject private var updateCheck: UpdateCheckController
    @AppStorage(ClipboardMonitor.userDefaultsKey) private var clipboardMonitoringEnabled = false
    @AppStorage(FlowAppearanceMode.userDefaultsKey) private var appearanceModeRaw = FlowAppearanceMode.system.rawValue

    public init() {}

    public var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearanceModeRaw) {
                    ForEach(FlowAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Theme")
                Text((FlowAppearanceMode(rawValue: appearanceModeRaw) ?? .system).detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Download folder") {
                DestinationFolderCard(
                    engineClient: model.engineClient,
                    compact: true,
                    onHealEngine: {
                        launchAgent.attachEngineClient(model.engineClient)
                        await launchAgent.repair()
                        return launchAgent.isEngineReady
                    }
                )
                Text("New downloads land in this folder. Compose uses the same default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Clipboard") {
                Toggle(
                    "Monitor clipboard for links",
                    isOn: $clipboardMonitoringEnabled
                )
                .accessibilityLabel("Monitor clipboard for links")
                Text(
                    "When enabled, new pasteboard text with valid links opens Add Downloads "
                        + "prefilled. Downloads are never queued automatically."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Post-processing") {
                Toggle(
                    "Auto-extract ZIP archives",
                    isOn: $model.zipAutoExtractEnabled
                )
                .accessibilityLabel("Auto-extract ZIP archives")
                .disabled(model.isBusy)
                .onChange(of: model.zipAutoExtractEnabled) { _, newValue in
                    Task { await model.saveZipAutoExtract(newValue) }
                }
                Text(
                    "When enabled, completed .zip downloads extract into a sibling "
                        + "folder. Turn off to keep archives intact."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Credentials") {
                if model.credentials.isEmpty {
                    Text("No credential profiles yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.credentials, id: \.id) { profile in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                            Text(profile.username)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DisclosureGroup("Add credential", isExpanded: $model.showAddCredential) {
                    TextField("Display name", text: $model.credentialDisplayName)
                        .accessibilityLabel("Credential display name")
                    TextField("Username", text: $model.credentialUsername)
                        .accessibilityLabel("Credential username")
                    SecureField("Password", text: $model.credentialPassword)
                        .accessibilityLabel("Credential password")
                    Button("Save credential") {
                        Task { await model.saveCredential() }
                    }
                    .disabled(!model.canSaveCredential || model.isBusy)
                }
            }

            Section("Proxies") {
                if model.proxies.isEmpty {
                    Text("No proxy profiles yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.proxies, id: \.id) { profile in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                            Text("\(profile.kind)://\(profile.host):\(profile.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DisclosureGroup("Add proxy", isExpanded: $model.showAddProxy) {
                    TextField("Display name", text: $model.proxyDisplayName)
                        .accessibilityLabel("Proxy display name")
                    Picker("Kind", selection: $model.proxyKind) {
                        Text("HTTP").tag("http")
                        Text("HTTPS").tag("https")
                        Text("SOCKS5").tag("socks5")
                    }
                    TextField("Host", text: $model.proxyHost)
                        .accessibilityLabel("Proxy host")
                    TextField("Port", text: $model.proxyPortText)
                        .accessibilityLabel("Proxy port")
                    Button("Save proxy") {
                        Task { await model.saveProxy() }
                    }
                    .disabled(!model.canSaveProxy || model.isBusy)
                }
            }

            Section("Cookies") {
                if model.cookies.isEmpty {
                    Text("No cookie profiles yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.cookies, id: \.id) { profile in
                        Text(profile.displayName)
                    }
                }
                DisclosureGroup("Add cookie profile", isExpanded: $model.showAddCookie) {
                    TextField("Display name", text: $model.cookieDisplayName)
                        .accessibilityLabel("Cookie profile display name")
                    Button("Save cookie profile") {
                        Task { await model.saveCookie() }
                    }
                    .disabled(!model.canSaveCookie || model.isBusy)
                }
                Text(
                    "Creates an empty cookie profile for sites that need a sign-in. Flow keeps cookies "
                        + "in their own file, never alongside your download history."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Bandwidth") {
                TextField("Speed limit, MB per second", text: $model.bandwidthMaxMegabytesText)
                    .accessibilityLabel("Speed limit in megabytes per second")
                Toggle(
                    "Only between 00:00 and 08:00 daily",
                    isOn: $model.bandwidthNightWindowOnly
                )
                .accessibilityLabel("Only between 00:00 and 08:00 daily")
                Text(
                    "Enter 0 for no limit. When the night window is on, new downloads start only in "
                        + "that local window and use the speed limit. Outside the window, queued jobs wait."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button("Save bandwidth policy") {
                    Task { await model.saveBandwidth() }
                }
                .disabled(!model.canSaveBandwidth || model.isBusy)
            }

            Section("Projects & Tags") {
                if model.projects.isEmpty {
                    Text("No projects yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.projects, id: \.id) { project in
                        Text(project.name)
                    }
                }
                DisclosureGroup("Add project", isExpanded: $model.showAddProject) {
                    TextField("Project name", text: $model.projectName)
                        .accessibilityLabel("Project name")
                    Button("Save project") {
                        Task { await model.saveProject() }
                    }
                    .disabled(!model.canSaveProject || model.isBusy)
                }

                if model.tags.isEmpty {
                    Text("No tags yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.tags, id: \.id) { tag in
                        Text(tag.name)
                    }
                }
                DisclosureGroup("Add tag", isExpanded: $model.showAddTag) {
                    TextField("Tag name", text: $model.tagName)
                        .accessibilityLabel("Tag name")
                    Button("Save tag") {
                        Task { await model.saveTag() }
                    }
                    .disabled(!model.canSaveTag || model.isBusy)
                }
            }

            Section("Category Rules") {
                if model.categoryRules.isEmpty {
                    Text("No custom rules. Built-in extension maps apply.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.categoryRules, id: \.id) { rule in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(".\(model.extensionLabel(for: rule)) → \(rule.categoryStableKey)")
                            Text("priority \(rule.priority)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DisclosureGroup("Add extension rule", isExpanded: $model.showAddRule) {
                    TextField("Extension (e.g. mp4)", text: $model.ruleExtension)
                        .accessibilityLabel("File extension for this rule")
                    Picker("Category", selection: $model.ruleCategoryKey) {
                        ForEach(ClassificationEngine.builtInStableKeys, id: \.self) { key in
                            Text(key).tag(key)
                        }
                    }
                    Button("Save rule") {
                        Task { await model.saveRule() }
                    }
                    .disabled(!model.canSaveRule || model.isBusy)
                }
            }

            Section("Per-host settings") {
                Text(
                    "Override connections, speed, user-agent, or credentials for a "
                        + "hostname. Per-download Compose options still win."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if model.hostSettings.isEmpty {
                    Text("No host overrides yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.hostSettings, id: \.host) { setting in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(setting.host)
                                .font(.body.weight(.medium))
                            Text(model.hostSettingSummary(setting))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Remove", role: .destructive) {
                                Task { await model.deleteHostSetting(setting.host) }
                            }
                            .disabled(model.isBusy)
                        }
                        .padding(.vertical, 2)
                    }
                }

                DisclosureGroup("Add host override", isExpanded: $model.showAddHostSetting) {
                    TextField("Host (example.com)", text: $model.hostSettingHost)
                        .accessibilityLabel("Host name for override")
                    TextField("Max connections (1–32)", text: $model.hostSettingConnectionsText)
                        .accessibilityLabel("Maximum connections for this host")
                    TextField("Speed limit MB/s (blank = none)", text: $model.hostSettingSpeedText)
                        .accessibilityLabel("Speed limit megabytes per second for this host")
                    TextField("User-Agent (optional)", text: $model.hostSettingUserAgent)
                        .accessibilityLabel("Custom user agent for this host")
                    Picker("Credential profile", selection: $model.hostSettingCredentialID) {
                        Text("None").tag("")
                        ForEach(model.credentials, id: \.id) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                    }
                    Button("Save host override") {
                        Task { await model.saveHostSetting() }
                    }
                    .disabled(!model.canSaveHostSetting || model.isBusy)
                }
            }

            Section("About") {
                LabeledContent("Product", value: "Flow Download Manager")
                LabeledContent(
                    "Version",
                    value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
                )
                LabeledContent("License", value: "GPL-3.0-or-later")
                Button("Check for Updates…") {
                    updateCheck.checkForUpdates()
                }
                .accessibilityLabel("Check for Updates")
                Text(
                    "Flow checks the signed appcast and can download and install updates "
                        + "in the background. You do not need to open GitHub."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let status = model.statusMessage {
                Section {
                    Text(status)
                        .foregroundStyle(model.statusIsError ? .red : .secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 480)
        .task { await model.reload() }
    }
}

@MainActor
private final class SettingsModel: ObservableObject {
    @Published var credentials: [CredentialProfileSnapshot] = []
    @Published var proxies: [ProxyProfileSnapshot] = []
    @Published var cookies: [CookieProfileSnapshot] = []
    @Published var projects: [ProjectSnapshot] = []
    @Published var tags: [TagSnapshot] = []
    @Published var categoryRules: [CategoryRuleSnapshot] = []
    @Published var hostSettings: [HostSettingSnapshot] = []
    @Published var showAddCredential = false
    @Published var showAddProxy = false
    @Published var showAddCookie = false
    @Published var showAddProject = false
    @Published var showAddTag = false
    @Published var showAddRule = false
    @Published var showAddHostSetting = false
    @Published var credentialDisplayName = ""
    @Published var credentialUsername = ""
    @Published var credentialPassword = ""
    @Published var proxyDisplayName = ""
    @Published var proxyKind = "http"
    @Published var proxyHost = ""
    @Published var proxyPortText = "8080"
    @Published var cookieDisplayName = ""
    /// Speed limit shown in MB/s; the engine stores bytes per second.
    @Published var bandwidthMaxMegabytesText = "0"
    @Published var bandwidthNightWindowOnly = false
    @Published var projectName = ""
    @Published var tagName = ""
    @Published var ruleExtension = ""
    @Published var ruleCategoryKey = "other"
    @Published var hostSettingHost = ""
    @Published var hostSettingConnectionsText = ""
    @Published var hostSettingSpeedText = ""
    @Published var hostSettingUserAgent = ""
    @Published var hostSettingCredentialID = ""
    @Published var zipAutoExtractEnabled = true
    @Published var statusMessage: String?
    @Published var statusIsError = false
    @Published var isBusy = false
    private var suppressZipSettingSave = false

    let engineClient = EngineClient()
    private static let zipAutoExtractKey = "zipAutoExtractEnabled"

    var canSaveCredential: Bool {
        !credentialDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !credentialUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !credentialPassword.isEmpty
    }

    var canSaveProxy: Bool {
        !proxyDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !proxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Int(proxyPortText).map { (1 ... 65535).contains($0) } == true
    }

    var canSaveCookie: Bool {
        !cookieDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSaveBandwidth: Bool {
        Self.bytesPerSecond(fromMegabytesText: bandwidthMaxMegabytesText) != nil
    }

    var canSaveHostSetting: Bool {
        let host = hostSettingHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return false }
        let connectionsText = hostSettingConnectionsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let speedText = hostSettingSpeedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let userAgent = hostSettingUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasConnections = !connectionsText.isEmpty
        let hasSpeed = !speedText.isEmpty
        let hasUA = !userAgent.isEmpty
        let hasCredential = !hostSettingCredentialID.isEmpty
        guard hasConnections || hasSpeed || hasUA || hasCredential else { return false }
        if hasConnections {
            guard let value = Int(connectionsText), (1 ... 32).contains(value) else { return false }
        }
        if hasSpeed {
            guard Self.bytesPerSecond(fromMegabytesText: speedText).map({ $0 > 0 }) == true else {
                return false
            }
        }
        return true
    }

    /// Parses the MB/s field into the bytes-per-second value the engine stores.
    /// Accepts a comma as the decimal separator and rejects absurd magnitudes so
    /// the `Double` to `Int64` conversion can never trap.
    static func bytesPerSecond(fromMegabytesText text: String) -> Int64? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let megabytes = Double(normalized),
              megabytes.isFinite,
              megabytes >= 0,
              megabytes <= 1_000_000
        else {
            return nil
        }
        return Int64((megabytes * 1_000_000).rounded())
    }

    /// Renders a stored bytes-per-second value as a short MB/s string.
    static func megabytesText(fromBytesPerSecond bytes: Int64) -> String {
        guard bytes > 0 else { return "0" }
        // 6 decimals is exact for whole bytes, so the value round-trips unchanged.
        var text = String(format: "%.6f", Double(bytes) / 1_000_000)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    var canSaveProject: Bool {
        !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSaveTag: Bool {
        !tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSaveRule: Bool {
        CategoryRulesEngine.extensionPredicateJSON(ruleExtension) != nil
            && ClassificationEngine.builtInStableKeys.contains(ruleCategoryKey)
    }

    func extensionLabel(for rule: CategoryRuleSnapshot) -> String {
        guard let data = rule.predicateJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ext = object["extension"] as? String
        else {
            return "?"
        }
        return ext
    }

    func reload() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let profiles = try await engineClient.listProfiles()
            credentials = profiles.credentials
            proxies = profiles.proxies
            cookies = profiles.cookies
            let organization = try await engineClient.listOrganization()
            projects = organization.projects
            tags = organization.tags
            let rules = try await engineClient.listCategoryRules()
            categoryRules = rules.rules
            let bandwidth = try await engineClient.getBandwidthPolicy()
            if let policy = bandwidth.policy {
                bandwidthMaxMegabytesText = Self.megabytesText(fromBytesPerSecond: policy.maxBytesPerSecond)
                let windows = (try? BandwidthWindowEvaluator.parseWindowsJSON(policy.windowsJSON)) ?? []
                bandwidthNightWindowOnly =
                    windows == [BandwidthWindowEvaluator.dailyMidnightToEightPreset]
            } else {
                bandwidthMaxMegabytesText = "0"
                bandwidthNightWindowOnly = false
            }
            let zipSetting = try await engineClient.getBoolSetting(key: Self.zipAutoExtractKey)
            suppressZipSettingSave = true
            zipAutoExtractEnabled = zipSetting.value
            suppressZipSettingSave = false
            let hosts = try await engineClient.listHostSettings()
            hostSettings = hosts.settings
            statusMessage = nil
            statusIsError = false
        } catch {
            statusMessage = "Unable to load settings from the engine."
            statusIsError = true
        }
    }

    func saveZipAutoExtract(_ enabled: Bool) async {
        guard !suppressZipSettingSave else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await engineClient.setBoolSetting(key: Self.zipAutoExtractKey, value: enabled)
            statusMessage = nil
            statusIsError = false
        } catch {
            statusMessage = "Unable to save ZIP extract preference."
            statusIsError = true
        }
    }

    func saveCredential() async {
        guard canSaveCredential else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await engineClient.upsertCredentialProfile(
                displayName: credentialDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
                username: credentialUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                password: credentialPassword
            )
            credentialDisplayName = ""
            credentialUsername = ""
            credentialPassword = ""
            showAddCredential = false
            statusMessage = "Credential profile saved."
            statusIsError = false
            await reload()
        } catch {
            statusMessage = "Unable to save credential profile."
            statusIsError = true
        }
    }

    func saveProxy() async {
        guard canSaveProxy, let port = Int(proxyPortText) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await engineClient.upsertProxyProfile(
                displayName: proxyDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: proxyKind,
                host: proxyHost.trimmingCharacters(in: .whitespacesAndNewlines),
                port: port
            )
            proxyDisplayName = ""
            proxyHost = ""
            proxyPortText = "8080"
            proxyKind = "http"
            showAddProxy = false
            statusMessage = "Proxy profile saved."
            statusIsError = false
            await reload()
        } catch {
            statusMessage = "Unable to save proxy profile."
            statusIsError = true
        }
    }

    func saveCookie() async {
        guard canSaveCookie else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await engineClient.upsertCookieProfile(
                displayName: cookieDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            cookieDisplayName = ""
            showAddCookie = false
            statusMessage = "Cookie profile saved."
            statusIsError = false
            await reload()
        } catch {
            statusMessage = "Unable to save cookie profile."
            statusIsError = true
        }
    }

    func saveBandwidth() async {
        guard let maxBytes = Self.bytesPerSecond(fromMegabytesText: bandwidthMaxMegabytesText)
        else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let windows: [BandwidthWindow] = bandwidthNightWindowOnly
                ? [BandwidthWindowEvaluator.dailyMidnightToEightPreset]
                : []
            let windowsJSON = try BandwidthWindowEvaluator.encodeWindowsJSON(windows)
            _ = try await engineClient.upsertBandwidthPolicy(
                windowsJSON: windowsJSON,
                maxBytesPerSecond: maxBytes
            )
            statusMessage = "Bandwidth policy saved."
            statusIsError = false
            await reload()
        } catch {
            statusMessage = "Unable to save bandwidth policy."
            statusIsError = true
        }
    }

    func saveProject() async {
        guard canSaveProject else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await engineClient.upsertProject(
                name: projectName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            projectName = ""
            showAddProject = false
            statusMessage = "Project saved."
            statusIsError = false
            await reload()
        } catch {
            statusMessage = "Unable to save project."
            statusIsError = true
        }
    }

    func saveTag() async {
        guard canSaveTag else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await engineClient.upsertTag(
                name: tagName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            tagName = ""
            showAddTag = false
            statusMessage = "Tag saved."
            statusIsError = false
            await reload()
        } catch {
            statusMessage = "Unable to save tag."
            statusIsError = true
        }
    }

    func saveRule() async {
        guard canSaveRule,
              let predicate = CategoryRulesEngine.extensionPredicateJSON(ruleExtension)
        else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let priority = categoryRules.map(\.priority).max().map { $0 + 1 } ?? 0
            _ = try await engineClient.upsertCategoryRule(
                predicateJSON: predicate,
                categoryStableKey: ruleCategoryKey,
                priority: priority
            )
            ruleExtension = ""
            ruleCategoryKey = "other"
            showAddRule = false
            statusMessage = "Category rule saved."
            statusIsError = false
            await reload()
        } catch {
            statusMessage = "Unable to save category rule."
            statusIsError = true
        }
    }

    func saveHostSetting() async {
        guard canSaveHostSetting else { return }
        isBusy = true
        defer { isBusy = false }
        let connectionsText = hostSettingConnectionsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let speedText = hostSettingSpeedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let userAgent = hostSettingUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentialID = hostSettingCredentialID.isEmpty ? nil : hostSettingCredentialID
        do {
            _ = try await engineClient.upsertHostSetting(
                host: hostSettingHost.trimmingCharacters(in: .whitespacesAndNewlines),
                maxConnections: connectionsText.isEmpty ? nil : Int(connectionsText),
                maxBytesPerSecond: speedText.isEmpty
                    ? nil
                    : Self.bytesPerSecond(fromMegabytesText: speedText),
                userAgent: userAgent.isEmpty ? nil : userAgent,
                credentialProfileID: credentialID,
                clearUserAgent: userAgent.isEmpty,
                clearCredentialProfileID: credentialID == nil
            )
            hostSettingHost = ""
            hostSettingConnectionsText = ""
            hostSettingSpeedText = ""
            hostSettingUserAgent = ""
            hostSettingCredentialID = ""
            showAddHostSetting = false
            statusMessage = "Host override saved."
            statusIsError = false
            await reload()
        } catch {
            statusMessage = "Unable to save host override."
            statusIsError = true
        }
    }

    func deleteHostSetting(_ host: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await engineClient.deleteHostSetting(host: host)
            statusMessage = "Host override removed."
            statusIsError = false
            await reload()
        } catch {
            statusMessage = "Unable to remove host override."
            statusIsError = true
        }
    }

    func hostSettingSummary(_ setting: HostSettingSnapshot) -> String {
        var parts: [String] = []
        if let connections = setting.maxConnections {
            parts.append("\(connections) connections")
        }
        if let rate = setting.maxBytesPerSecond, rate > 0 {
            parts.append(Self.megabytesText(fromBytesPerSecond: rate) + " MB/s")
        }
        if let userAgent = setting.userAgent, !userAgent.isEmpty {
            parts.append("custom UA")
        }
        if let credentialID = setting.credentialProfileID {
            let name = credentials.first { $0.id == credentialID }?.displayName ?? "credentials"
            parts.append(name)
        }
        return parts.isEmpty ? "no overrides" : parts.joined(separator: " · ")
    }
}
