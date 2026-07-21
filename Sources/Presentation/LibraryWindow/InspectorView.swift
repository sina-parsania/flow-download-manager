// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Inspector Overview for the selected job (`03-design-system-ui-ux.md` §7).
/// Shows source host, destination-neutral metadata and status; raw dependency
/// logs are never the default. Phase 0 renders read snapshots only.
struct InspectorView: View {
    let row: JobRowModel?

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
