// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Background-engine status. Engine is required and auto-started — no Stop toggle.
public struct EngineStatusView: View {
    @ObservedObject private var model: LaunchAgentModel

    public init(model: LaunchAgentModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(headline)
                    .font(.headline)
            } icon: {
                Image(systemName: symbolName)
                    .foregroundStyle(symbolColor)
                    .accessibilityHidden(true)
            }

            Text(detail)
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
                if model.status.needsSystemSettingsApproval {
                    Button("Open System Settings") { model.openSystemSettingsLoginItems() }
                        .keyboardShortcut(.defaultAction)
                    Button("Recheck") {
                        Task { await model.ensureRunning() }
                    }
                } else if !model.isOperational {
                    Button("Start Engine") {
                        Task { await model.ensureRunning() }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Repair") {
                        Task { await model.repair() }
                    }
                } else {
                    Button("Repair Connection") {
                        Task { await model.repair() }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Background engine status")
        .onAppear {
            model.refresh()
            Task { await model.ensureRunning() }
        }
    }

    private var headline: String {
        if model.isOperational { return "Background engine is on" }
        return model.status.headline
    }

    private var detail: String {
        if model.runtimeMode == .directChild, model.isEngineReady {
            return "Transfer engine is running inside the app (local debug). It stays on while Flow is open."
        }
        if model.runtimeMode == .legacyLaunchd, model.isEngineReady {
            return "Transfer engine is running (local LaunchAgent). It starts with Flow automatically."
        }
        return model.status.detail
    }

    private var symbolName: String {
        if model.isOperational { return "checkmark.circle.fill" }
        switch model.status {
        case .requiresApproval: return "exclamationmark.triangle.fill"
        case .notRegistered, .notFound: return "arrow.triangle.2.circlepath"
        case .unknown: return "questionmark.circle"
        case .enabled: return "checkmark.circle.fill"
        }
    }

    private var symbolColor: Color {
        if model.isOperational { return .green }
        switch model.status {
        case .requiresApproval: return .orange
        case .notFound, .unknown: return .red
        case .notRegistered: return .secondary
        case .enabled: return .green
        }
    }
}
