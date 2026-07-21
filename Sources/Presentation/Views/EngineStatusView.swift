// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Background-engine status and registration controls. Explains background
/// processing, offers register/unregister by user action, and links to System
/// Settings when approval is required (`bootstrap prompt §4`).
public struct EngineStatusView: View {
    @ObservedObject private var model: LaunchAgentModel

    public init(model: LaunchAgentModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(model.status.headline)
                    .font(.headline)
            } icon: {
                Image(systemName: symbolName)
                    .foregroundStyle(symbolColor)
                    .accessibilityHidden(true)
            }

            Text(model.status.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = model.lastErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error: \(error)")
            }

            HStack(spacing: 8) {
                switch model.status {
                case .enabled:
                    Button("Stop Background Engine") { model.unregister() }
                case .requiresApproval:
                    Button("Open System Settings") { model.openSystemSettingsLoginItems() }
                        .keyboardShortcut(.defaultAction)
                    Button("Recheck") { model.refresh() }
                default:
                    Button("Start Background Engine") { model.register() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Background engine status")
        .onAppear { model.refresh() }
    }

    private var symbolName: String {
        switch model.status {
        case .enabled: return "checkmark.circle.fill"
        case .requiresApproval: return "exclamationmark.triangle.fill"
        case .notRegistered: return "pause.circle"
        case .notFound, .unknown: return "questionmark.circle"
        }
    }

    private var symbolColor: Color {
        switch model.status {
        case .enabled: return .green
        case .requiresApproval: return .orange
        case .notFound, .unknown: return .red
        case .notRegistered: return .secondary
        }
    }
}
