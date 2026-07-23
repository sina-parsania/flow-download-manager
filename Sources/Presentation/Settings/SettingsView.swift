// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import XPCContracts

/// Minimal Settings surface for credential/proxy profiles, projects/tags, and About.
public struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    public init() {}

    public var body: some View {
        Form {
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
    @Published var projects: [ProjectSnapshot] = []
    @Published var tags: [TagSnapshot] = []
    @Published var showAddCredential = false
    @Published var showAddProxy = false
    @Published var showAddProject = false
    @Published var showAddTag = false
    @Published var credentialDisplayName = ""
    @Published var credentialUsername = ""
    @Published var credentialPassword = ""
    @Published var proxyDisplayName = ""
    @Published var proxyKind = "http"
    @Published var proxyHost = ""
    @Published var proxyPortText = "8080"
    @Published var projectName = ""
    @Published var tagName = ""
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

    var canSaveProject: Bool {
        !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSaveTag: Bool {
        !tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func reload() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let profiles = try await client.listProfiles()
            credentials = profiles.credentials
            proxies = profiles.proxies
            let organization = try await client.listOrganization()
            projects = organization.projects
            tags = organization.tags
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
}
