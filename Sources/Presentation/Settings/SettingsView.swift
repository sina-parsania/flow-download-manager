// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import XPCContracts

/// Minimal Settings surface for credential/proxy profiles and About.
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
        .frame(minWidth: 480, minHeight: 420)
        .task { await model.reload() }
    }
}

@MainActor
private final class SettingsModel: ObservableObject {
    @Published var credentials: [CredentialProfileSnapshot] = []
    @Published var proxies: [ProxyProfileSnapshot] = []
    @Published var showAddCredential = false
    @Published var showAddProxy = false
    @Published var credentialDisplayName = ""
    @Published var credentialUsername = ""
    @Published var credentialPassword = ""
    @Published var proxyDisplayName = ""
    @Published var proxyKind = "http"
    @Published var proxyHost = ""
    @Published var proxyPortText = "8080"
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

    func reload() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await client.listProfiles()
            credentials = response.credentials
            proxies = response.proxies
            statusMessage = nil
            statusIsError = false
        } catch {
            statusMessage = "Unable to load profiles from the engine."
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
}
