// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import SwiftUI
import XPCContracts

/// Minimal Settings surface for credential/proxy profiles, projects/tags, and About.
public struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @AppStorage(ClipboardMonitor.userDefaultsKey) private var clipboardMonitoringEnabled = false

    public init() {}

    public var body: some View {
        Form {
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
                    TextField("Username", text: $model.credentialUsername)
                    SecureField("Password", text: $model.credentialPassword)
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
                    Picker("Kind", selection: $model.proxyKind) {
                        Text("HTTP").tag("http")
                        Text("HTTPS").tag("https")
                        Text("SOCKS5").tag("socks5")
                    }
                    TextField("Host", text: $model.proxyHost)
                    TextField("Port", text: $model.proxyPortText)
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
                    Button("Save cookie profile") {
                        Task { await model.saveCookie() }
                    }
                    .disabled(!model.canSaveCookie || model.isBusy)
                }
                Text("Creates an empty cookie jar under Application Support. Values never enter SQLite.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Bandwidth") {
                TextField("Max bytes/second (0 = unlimited)", text: $model.bandwidthMaxBytesText)
                Toggle(
                    "Only between 00:00 and 08:00 daily",
                    isOn: $model.bandwidthNightWindowOnly
                )
                .accessibilityLabel("Only between 00:00 and 08:00 daily")
                Text(
                    "When the night window is on, new downloads start only in that local window "
                        + "and use the max rate. Outside the window, queued jobs wait."
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

            Section("About") {
                LabeledContent("Product", value: "Download Manager")
                LabeledContent(
                    "Version",
                    value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
                )
                LabeledContent("License", value: "GPL-3.0-or-later")
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
    @Published var showAddCredential = false
    @Published var showAddProxy = false
    @Published var showAddCookie = false
    @Published var showAddProject = false
    @Published var showAddTag = false
    @Published var showAddRule = false
    @Published var credentialDisplayName = ""
    @Published var credentialUsername = ""
    @Published var credentialPassword = ""
    @Published var proxyDisplayName = ""
    @Published var proxyKind = "http"
    @Published var proxyHost = ""
    @Published var proxyPortText = "8080"
    @Published var cookieDisplayName = ""
    @Published var bandwidthMaxBytesText = "0"
    @Published var bandwidthNightWindowOnly = false
    @Published var projectName = ""
    @Published var tagName = ""
    @Published var ruleExtension = ""
    @Published var ruleCategoryKey = "other"
    @Published var statusMessage: String?
    @Published var statusIsError = false
    @Published var isBusy = false

    private let client = EngineClient()

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
        Int64(bandwidthMaxBytesText.trimmingCharacters(in: .whitespacesAndNewlines))
            .map { $0 >= 0 } == true
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
            let profiles = try await client.listProfiles()
            credentials = profiles.credentials
            proxies = profiles.proxies
            cookies = profiles.cookies
            let organization = try await client.listOrganization()
            projects = organization.projects
            tags = organization.tags
            let rules = try await client.listCategoryRules()
            categoryRules = rules.rules
            let bandwidth = try await client.getBandwidthPolicy()
            if let policy = bandwidth.policy {
                bandwidthMaxBytesText = String(policy.maxBytesPerSecond)
                let windows = (try? BandwidthWindowEvaluator.parseWindowsJSON(policy.windowsJSON)) ?? []
                bandwidthNightWindowOnly =
                    windows == [BandwidthWindowEvaluator.dailyMidnightToEightPreset]
            } else {
                bandwidthMaxBytesText = "0"
                bandwidthNightWindowOnly = false
            }
            statusMessage = nil
            statusIsError = false
        } catch {
            statusMessage = "Unable to load settings from the engine."
            statusIsError = true
        }
    }

    func saveCredential() async {
        guard canSaveCredential else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await client.upsertCredentialProfile(
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
            _ = try await client.upsertProxyProfile(
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
            _ = try await client.upsertCookieProfile(
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
        guard canSaveBandwidth,
              let maxBytes = Int64(bandwidthMaxBytesText.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let windows: [BandwidthWindow] = bandwidthNightWindowOnly
                ? [BandwidthWindowEvaluator.dailyMidnightToEightPreset]
                : []
            let windowsJSON = try BandwidthWindowEvaluator.encodeWindowsJSON(windows)
            _ = try await client.upsertBandwidthPolicy(
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
            _ = try await client.upsertProject(
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
            _ = try await client.upsertTag(
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
            _ = try await client.upsertCategoryRule(
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
}
