// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import XPCContracts

/// Inspector Overview for the selected job (`03-design-system-ui-ux.md` §7).
struct InspectorView: View {
    let row: JobRowModel?
    let engineClient: EngineClient
    let onCommand: (JobCommandKind) -> Void
    let onPriorityBump: (Int) -> Void
    @State private var events: [EventSnapshot] = []
    @State private var eventsError: String?

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
                    Section("Events") {
                        if let eventsError {
                            Text(eventsError)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        } else if events.isEmpty {
                            Text("No events yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(events, id: \.sequence) { event in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.type)
                                        .font(.body.monospaced())
                                    Text(event.occurredAtISO8601)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let payload = event.sanitizedPayload, !payload.isEmpty {
                                        Text(payload)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(event.type) at \(event.occurredAtISO8601)")
                            }
                        }
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
                        HStack {
                            Text("Priority \(row.priority)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Priority Down") { onPriorityBump(-1) }
                            Button("Priority Up") { onPriorityBump(1) }
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
                .task(id: row.id) {
                    await loadEvents(for: row.id)
                }
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

    @MainActor
    private func loadEvents(for jobID: UUID) async {
        eventsError = nil
        do {
            let response = try await engineClient.listEvents(
                jobID: jobID.uuidString.lowercased(),
                limit: 40
            )
            events = response.events
        } catch {
            events = []
            eventsError = "Unable to load events."
        }
    }
}
