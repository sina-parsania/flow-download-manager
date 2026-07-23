// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import XPCContracts

/// Inspector Overview for the selected job (`03-design-system-ui-ux.md` §7).
struct InspectorView: View {
    let row: JobRowModel?
    let onCommand: (JobCommandKind) -> Void

    var body: some View {
        Group {
            if let row {
                Form {
                    Section("Overview") {
                        labeled("Name", row.name)
                        labeled("Source", row.sourceHost)
                        labeled("State", row.state.rawValue)
                        labeled("Category", row.categoryKey)
                        if let project = row.projectName { labeled("Project", project) }
                        if !row.tagNames.isEmpty { labeled("Tags", row.tagNames.joined(separator: ", ")) }
                    }
                    Section("Transfer") {
                        labeled("Progress", JobRowFormatting.progressText(
                            fraction: row.progressFraction, transferred: row.bytesTransferred, total: row.totalBytes
                        ))
                        labeled("Speed", JobRowFormatting.speed(row.speedBytesPerSecond))
                        labeled("Time remaining", JobRowFormatting.eta(row.etaSeconds))
                        labeled("Size", JobRowFormatting.size(row.totalBytes))
                    }
                    Section("Actions") {
                        HStack {
                            Button("Pause") { onCommand(.pause) }
                                .disabled(![.queued, .connecting, .downloading, .scheduled].contains(row.state))
                            Button("Resume") { onCommand(.resume) }
                                .disabled(row.state != .paused)
                            Button("Cancel") { onCommand(.cancel) }
                            Button("Retry") { onCommand(.retry) }
                                .disabled(!(row.state == .failed || row.state == .cancelled))
                        }
                        if row.state == .completed {
                            Button("Show in Finder") {
                                // Destination defaults under Downloads/DownloadManager/<name>
                                let downloads = FileManager.default.urls(
                                    for: .downloadsDirectory, in: .userDomainMask
                                ).first
                                let base = downloads?
                                    .appendingPathComponent("DownloadManager", isDirectory: true)
                                    .appendingPathComponent(row.name)
                                if let base {
                                    FinderIntegration.revealIfExists(path: base.path)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "No selection",
                    systemImage: "sidebar.right",
                    description: Text("Select a download to see its details.")
                )
            }
        }
        .accessibilityLabel("Inspector")
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.body.monospacedDigit())
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}
