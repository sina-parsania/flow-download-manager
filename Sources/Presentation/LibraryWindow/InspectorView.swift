// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import XPCContracts

/// Inspector Overview for the selected job (`03-design-system-ui-ux.md` §7).
struct InspectorView: View {
    let row: JobRowModel?
    let engineClient: EngineClient
    let onCommand: (JobCommandKind) -> Void
    let onPriorityBump: (Int) -> Void
    let onOrganizationChanged: () -> Void
    @State private var events: [EventSnapshot] = []
    @State private var eventsError: String?
    @State private var projects: [ProjectSnapshot] = []
    @State private var tags: [TagSnapshot] = []
    @State private var selectedProjectID = ""
    @State private var selectedTagIDs: Set<String> = []
    @State private var organizationError: String?
    @State private var isSavingOrganization = false

    var body: some View {
        Group {
            if let row {
                Form {
                    Section("Overview") {
                        labeled("Name", row.name)
                        labeled("Source", row.sourceHost)
                        labeled("State", row.state.rawValue)
                        labeled("Category", row.categoryKey)
                    }
                    Section("Organization") {
                        if let organizationError {
                            Text(organizationError)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        Picker("Project", selection: $selectedProjectID) {
                            Text("None").tag("")
                            ForEach(projects, id: \.id) { project in
                                Text(project.name).tag(project.id)
                            }
                        }
                        .disabled(isSavingOrganization || projects.isEmpty && selectedProjectID.isEmpty)
                        .onChange(of: selectedProjectID) { _, newValue in
                            Task { await saveProject(jobID: row.id, projectID: newValue) }
                        }
                        .accessibilityLabel("Project")

                        if tags.isEmpty {
                            Text("No tags yet. Create tags in Settings.")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        } else {
                            ForEach(tags, id: \.id) { tag in
                                Toggle(tag.name, isOn: Binding(
                                    get: { selectedTagIDs.contains(tag.id) },
                                    set: { enabled in
                                        if enabled {
                                            selectedTagIDs.insert(tag.id)
                                        } else {
                                            selectedTagIDs.remove(tag.id)
                                        }
                                        Task { await saveTags(jobID: row.id) }
                                    }
                                ))
                                .disabled(isSavingOrganization)
                                .accessibilityLabel("Tag \(tag.name)")
                            }
                        }
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
                        }
                        HStack {
                            Button("Retry") { onCommand(.retry) }
                                .disabled(!(row.state == .failed || row.state == .cancelled))
                                .help("Retry without wiping partial data")
                            Button("Restart") { onCommand(.restart) }
                                .disabled(!(row.state == .paused || row.state == .failed || row.state == .cancelled))
                                .help("Restart from scratch (wipe partial)")
                        }
                        HStack {
                            Text("Priority \(row.priority)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Priority Down") { onPriorityBump(-1) }
                                .accessibilityLabel("Priority Down")
                            Button("Priority Up") { onPriorityBump(1) }
                                .accessibilityLabel("Priority Up")
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
                    syncOrganizationSelection(from: row)
                    await loadOrganization()
                    await loadEvents(for: row.id)
                }
                .onChange(of: row.projectID) { _, _ in
                    syncOrganizationSelection(from: row)
                }
                .onChange(of: row.tagIDs) { _, _ in
                    syncOrganizationSelection(from: row)
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

    private func syncOrganizationSelection(from row: JobRowModel) {
        selectedProjectID = row.projectID ?? ""
        selectedTagIDs = Set(row.tagIDs)
    }

    @MainActor
    private func loadOrganization() async {
        do {
            let organization = try await engineClient.listOrganization()
            projects = organization.projects
            tags = organization.tags
            organizationError = nil
        } catch {
            organizationError = "Unable to load projects and tags."
        }
    }

    @MainActor
    private func saveProject(jobID: UUID, projectID: String) async {
        guard !isSavingOrganization else { return }
        let normalized = projectID.isEmpty ? nil : projectID
        if normalized == (row?.projectID) { return }
        isSavingOrganization = true
        defer { isSavingOrganization = false }
        do {
            _ = try await engineClient.setJobProject(
                jobID: jobID.uuidString.lowercased(),
                projectID: normalized
            )
            organizationError = nil
            onOrganizationChanged()
        } catch {
            organizationError = "Unable to update project."
            if let row {
                selectedProjectID = row.projectID ?? ""
            }
        }
    }

    @MainActor
    private func saveTags(jobID: UUID) async {
        guard !isSavingOrganization else { return }
        let next = Array(selectedTagIDs).sorted()
        if next == (row?.tagIDs.sorted() ?? []) { return }
        isSavingOrganization = true
        defer { isSavingOrganization = false }
        do {
            _ = try await engineClient.setJobTags(
                jobID: jobID.uuidString.lowercased(),
                tagIDs: next
            )
            organizationError = nil
            onOrganizationChanged()
        } catch {
            organizationError = "Unable to update tags."
            if let row {
                selectedTagIDs = Set(row.tagIDs)
            }
        }
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
