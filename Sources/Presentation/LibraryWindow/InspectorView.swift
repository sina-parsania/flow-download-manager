// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Domain
import SwiftUI
import XPCContracts

/// Inspector Overview for the selected job (`03-design-system-ui-ux.md` §7).
struct InspectorView: View {
    let row: JobRowModel?
    let engineClient: EngineClient
    let onCommand: (JobCommandKind) -> Void
    let onPriorityBump: (Int) -> Void
    let onOrganizationChanged: () -> Void
    var onRevealInFinder: (() -> Void)?
    var onRemoveFromLibrary: (() -> Void)?
    var onDeleteFromDisk: (() -> Void)?
    @Environment(\.flowPalette) private var palette
    @State private var events: [EventSnapshot] = []
    @State private var eventsError: String?
    @State private var showEventsSheet = false
    @State private var projects: [ProjectSnapshot] = []
    @State private var tags: [TagSnapshot] = []
    @State private var selectedCategoryKey = "other"
    @State private var selectedProjectID = ""
    @State private var selectedTagIDs: Set<String> = []
    @State private var newProjectName = ""
    @State private var newTagName = ""
    @State private var showCreateProjectSheet = false
    @State private var showCreateTagSheet = false
    @State private var showOrganizationAlert = false
    @State private var organizationError: String?
    @State private var isSavingOrganization = false
    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var isSavingName = false
    @FocusState private var projectNameFocused: Bool
    @FocusState private var tagNameFocused: Bool
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        Group {
            if let row {
                Form {
                    Section("Overview") {
                        nameRow(for: row)
                        labeled("Source", row.sourceHost)
                        LabeledContent("URL") {
                            Text(row.sourceURL)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(4)
                                .multilineTextAlignment(.trailing)
                        }
                        .accessibilityLabel("Download URL")
                        labeled("State", row.state.rawValue)
                        Picker("Category", selection: $selectedCategoryKey) {
                            ForEach(ClassificationEngine.builtInStableKeys, id: \.self) { key in
                                Text(categoryDisplayName(key)).tag(key)
                            }
                        }
                        .disabled(isSavingOrganization)
                        .onChange(of: selectedCategoryKey) { _, newValue in
                            Task { await saveCategory(jobID: row.id, categoryKey: newValue) }
                        }
                        .accessibilityLabel("Category")
                    }
                    Section("Organization") {
                        if projects.isEmpty {
                            Text("No projects yet.")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Button("Create project…") {
                                newProjectName = ""
                                showCreateProjectSheet = true
                            }
                            .disabled(isSavingOrganization)
                            .accessibilityLabel("Create project")
                        } else {
                            Picker("Project", selection: $selectedProjectID) {
                                Text("None").tag("")
                                ForEach(projects, id: \.id) { project in
                                    Text(project.name).tag(project.id)
                                }
                            }
                            .disabled(isSavingOrganization)
                            .onChange(of: selectedProjectID) { _, newValue in
                                Task { await saveProject(jobID: row.id, projectID: newValue) }
                            }
                            .accessibilityLabel("Project")
                            Button("New project…") {
                                newProjectName = ""
                                showCreateProjectSheet = true
                            }
                            .disabled(isSavingOrganization)
                            .accessibilityLabel("New project")
                        }

                        if tags.isEmpty {
                            Text("No tags yet.")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Button("Create tag…") {
                                newTagName = ""
                                showCreateTagSheet = true
                            }
                            .disabled(isSavingOrganization)
                            .accessibilityLabel("Create tag")
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
                            Button("New tag…") {
                                newTagName = ""
                                showCreateTagSheet = true
                            }
                            .disabled(isSavingOrganization)
                            .accessibilityLabel("New tag")
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
                        } else {
                            Button {
                                showEventsSheet = true
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "list.bullet.rectangle")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(palette.signal)
                                        .frame(width: 28, height: 28)
                                        .background(
                                            palette.signal.opacity(0.18),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(events.isEmpty ? "No activity yet" : "\(events.count) recent events")
                                            .font(FlowTheme.Typeface.body(13))
                                            .foregroundStyle(palette.ink)
                                        Text(eventsSummaryLine)
                                            .font(FlowTheme.Typeface.caption(11))
                                            .foregroundStyle(palette.inkSoft)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(palette.inkSoft)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open events")
                            .accessibilityHint("Shows a detailed activity log for this download")
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
                        if row.state == .completed || row.state == .downloading
                            || row.state == .paused || row.state == .failed
                            || row.state == .cancelled || row.state == .queued {
                            Button("Open in Finder") {
                                onRevealInFinder?()
                            }
                        }
                        if DeleteJobGuard.allowsDelete(row.state) {
                            Divider()
                            Button("Remove from Library") {
                                onRemoveFromLibrary?()
                            }
                            .help("Remove from Flow only — keeps the file on disk")
                            Button("Delete File & Remove…", role: .destructive) {
                                onDeleteFromDisk?()
                            }
                            .help("Delete the file from disk and remove it from Flow")
                        }
                    }
                }
                .formStyle(.grouped)
                .task(id: row.id) {
                    syncOrganizationSelection(from: row)
                    draftName = row.name
                    isEditingName = false
                    await loadOrganization()
                    await loadEvents(for: row.id)
                }
                .onChange(of: row.name) { _, newName in
                    if !isEditingName {
                        draftName = newName
                    }
                }
                .onChange(of: row.categoryKey) { _, _ in
                    syncOrganizationSelection(from: row)
                }
                .onChange(of: row.projectID) { _, _ in
                    syncOrganizationSelection(from: row)
                }
                .onChange(of: row.tagIDs) { _, _ in
                    syncOrganizationSelection(from: row)
                }
                .sheet(isPresented: $showEventsSheet) {
                    JobEventsSheet(
                        jobName: row.name,
                        jobID: row.id,
                        events: $events,
                        engineClient: engineClient,
                        onReload: { await loadEvents(for: row.id) }
                    )
                    .flowAppearance()
                }
                .sheet(isPresented: $showCreateProjectSheet) {
                    organizationNameSheet(
                        title: "New project",
                        subtitle: "Creates a project and assigns it to this download.",
                        placeholder: "Project name",
                        name: $newProjectName,
                        focus: $projectNameFocused,
                        isBusy: isSavingOrganization,
                        confirmTitle: "Create & Assign",
                        onCancel: {
                            showCreateProjectSheet = false
                            newProjectName = ""
                        },
                        onConfirm: {
                            Task { await createProject(andAssignTo: row.id) }
                        }
                    )
                    .flowAppearance()
                    .onAppear { projectNameFocused = true }
                }
                .sheet(isPresented: $showCreateTagSheet) {
                    organizationNameSheet(
                        title: "New tag",
                        subtitle: "Creates a tag and attaches it to this download.",
                        placeholder: "Tag name",
                        name: $newTagName,
                        focus: $tagNameFocused,
                        isBusy: isSavingOrganization,
                        confirmTitle: "Create & Attach",
                        onCancel: {
                            showCreateTagSheet = false
                            newTagName = ""
                        },
                        onConfirm: {
                            Task { await createTag(andAttachTo: row.id) }
                        }
                    )
                    .flowAppearance()
                    .onAppear { tagNameFocused = true }
                }
                .alert("Organization", isPresented: $showOrganizationAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(organizationError ?? "Something went wrong.")
                }
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Text("Select a pin")
                        .font(FlowTheme.Typeface.title(16))
                        .foregroundStyle(palette.ink)
                    Text("Details land here when you tap a download on the board.")
                        .font(FlowTheme.Typeface.body(12))
                        .foregroundStyle(palette.inkSoft)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityLabel("Inspector")
    }

    private var eventsSummaryLine: String {
        guard let first = events.first else {
            return "Open to watch state changes and recovery"
        }
        return "Latest: \(JobEventFormatting.title(for: first.type))"
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

    @ViewBuilder
    private func nameRow(for row: JobRowModel) -> some View {
        if isEditingName {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Filename", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFieldFocused)
                    .disabled(isSavingName)
                    .onSubmit {
                        Task { await saveName(jobID: row.id) }
                    }
                HStack {
                    Spacer()
                    Button("Cancel") {
                        draftName = row.name
                        isEditingName = false
                    }
                    .disabled(isSavingName)
                    Button(isSavingName ? "Saving…" : "Save") {
                        Task { await saveName(jobID: row.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isSavingName
                            || draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || draftName == row.name
                    )
                }
                if canRenameWhileActive(row.state) == false {
                    Text("Pause the download before renaming.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Edit filename")
        } else {
            LabeledContent("Name") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.name)
                        .font(.body.monospacedDigit())
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .multilineTextAlignment(.trailing)
                    Button("Edit") {
                        draftName = row.name
                        isEditingName = true
                        nameFieldFocused = true
                    }
                    .disabled(isSavingOrganization || isSavingName)
                    .accessibilityLabel("Edit filename")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Name: \(row.name)")
        }
    }

    private func canRenameWhileActive(_ state: JobState) -> Bool {
        switch state {
        case .connecting, .downloading, .verifying, .merging, .postProcessing:
            return false
        default:
            return true
        }
    }

    private func organizationNameSheet(
        title: String,
        subtitle: String,
        placeholder: String,
        name: Binding<String>,
        focus: FocusState<Bool>.Binding,
        isBusy: Bool,
        confirmTitle: String,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: name)
                .textFieldStyle(.roundedBorder)
                .focused(focus)
                .disabled(isBusy)
                .onSubmit {
                    guard !name.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return
                    }
                    onConfirm()
                }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
                Button(isBusy ? "Saving…" : confirmTitle, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isBusy
                            || name.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func syncOrganizationSelection(from row: JobRowModel) {
        if ClassificationEngine.builtInStableKeys.contains(row.categoryKey) {
            selectedCategoryKey = row.categoryKey
        } else {
            selectedCategoryKey = "other"
        }
        selectedProjectID = row.projectID ?? ""
        selectedTagIDs = Set(row.tagIDs)
    }

    private func categoryDisplayName(_ key: String) -> String {
        key.prefix(1).uppercased() + key.dropFirst()
    }

    @MainActor
    private func saveName(jobID: UUID) async {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            organizationError = "Enter a filename."
            showOrganizationAlert = true
            return
        }
        guard !isSavingName else { return }
        if let row, !canRenameWhileActive(row.state) {
            organizationError = "Pause the download before renaming."
            showOrganizationAlert = true
            return
        }
        if trimmed == row?.name {
            isEditingName = false
            return
        }
        isSavingName = true
        defer { isSavingName = false }
        do {
            let response = try await engineClient.setJobFilename(
                jobID: jobID.uuidString.lowercased(),
                filename: trimmed
            )
            draftName = response.filename
            isEditingName = false
            organizationError = nil
            onOrganizationChanged()
        } catch {
            organizationError = "Unable to rename: \(error.localizedDescription)"
            showOrganizationAlert = true
        }
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
    private func saveCategory(jobID: UUID, categoryKey: String) async {
        guard !isSavingOrganization else { return }
        if categoryKey == row?.categoryKey { return }
        isSavingOrganization = true
        defer { isSavingOrganization = false }
        do {
            _ = try await engineClient.setJobCategory(
                jobID: jobID.uuidString.lowercased(),
                categoryStableKey: categoryKey
            )
            organizationError = nil
            onOrganizationChanged()
        } catch {
            organizationError = "Unable to update category: \(error.localizedDescription)"
            showOrganizationAlert = true
            if let row {
                selectedCategoryKey = ClassificationEngine.builtInStableKeys.contains(row.categoryKey)
                    ? row.categoryKey
                    : "other"
            }
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
            organizationError = "Unable to update project: \(error.localizedDescription)"
            showOrganizationAlert = true
            if let row {
                selectedProjectID = row.projectID ?? ""
            }
        }
    }

    @MainActor
    private func createProject(andAssignTo jobID: UUID) async {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            organizationError = "Enter a project name."
            showOrganizationAlert = true
            return
        }
        guard !isSavingOrganization else { return }
        isSavingOrganization = true
        defer { isSavingOrganization = false }
        do {
            let created = try await engineClient.upsertProject(name: name)
            _ = try await engineClient.setJobProject(
                jobID: jobID.uuidString.lowercased(),
                projectID: created.projectID
            )
            newProjectName = ""
            showCreateProjectSheet = false
            selectedProjectID = created.projectID
            organizationError = nil
            await loadOrganization()
            onOrganizationChanged()
        } catch {
            organizationError = "Unable to create project: \(error.localizedDescription)"
            showOrganizationAlert = true
        }
    }

    @MainActor
    private func createTag(andAttachTo jobID: UUID) async {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            organizationError = "Enter a tag name."
            showOrganizationAlert = true
            return
        }
        guard !isSavingOrganization else { return }
        isSavingOrganization = true
        defer { isSavingOrganization = false }
        do {
            let created = try await engineClient.upsertTag(name: name)
            var next = selectedTagIDs
            next.insert(created.tagID)
            _ = try await engineClient.setJobTags(
                jobID: jobID.uuidString.lowercased(),
                tagIDs: Array(next).sorted()
            )
            selectedTagIDs = next
            newTagName = ""
            showCreateTagSheet = false
            organizationError = nil
            await loadOrganization()
            onOrganizationChanged()
        } catch {
            organizationError = "Unable to create tag: \(error.localizedDescription)"
            showOrganizationAlert = true
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
                limit: 80
            )
            events = response.events
        } catch {
            events = []
            eventsError = "Unable to load events."
        }
    }
}

// MARK: - Events modal

private struct JobEventsSheet: View {
    let jobName: String
    let jobID: UUID
    @Binding var events: [EventSnapshot]
    let engineClient: EngineClient
    let onReload: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.flowPalette) private var palette
    @State private var isClearing = false
    @State private var clearError: String?
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            if events.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(events, id: \.sequence) { event in
                            JobEventCard(event: event)
                        }
                    }
                    .padding(16)
                }
            }
            if let clearError {
                Text(clearError)
                    .font(FlowTheme.Typeface.caption(12))
                    .foregroundStyle(palette.ember)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 460, idealHeight: 560)
        .background(palette.mist)
        .confirmationDialog(
            "Clear all events for this download?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clean all", role: .destructive) {
                Task { await clearAll() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            await onReload()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activity")
                    .font(FlowTheme.Typeface.title(16))
                    .foregroundStyle(palette.ink)
                Text(jobName)
                    .font(FlowTheme.Typeface.caption(12))
                    .foregroundStyle(palette.inkSoft)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                confirmClear = true
            } label: {
                Text(isClearing ? "Cleaning…" : "Clean all")
                    .font(FlowTheme.Typeface.body(12))
                    .foregroundStyle(events.isEmpty || isClearing ? palette.inkSoft : palette.ember)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(palette.chipFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(events.isEmpty || isClearing)
            .accessibilityLabel("Clean all events")

            Button("Done") { dismiss() }
                .font(FlowTheme.Typeface.body(13))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(palette.inkSoft)
            Text("No events")
                .font(FlowTheme.Typeface.title(15))
                .foregroundStyle(palette.ink)
            Text("State changes and recovery notes will show up here.")
                .font(FlowTheme.Typeface.body(12))
                .foregroundStyle(palette.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func clearAll() async {
        guard !isClearing else { return }
        isClearing = true
        clearError = nil
        defer { isClearing = false }
        do {
            _ = try await engineClient.clearEvents(jobID: jobID.uuidString.lowercased())
            events = []
            await onReload()
        } catch {
            clearError = "Couldn’t clear events. Try again."
        }
    }
}

private struct JobEventCard: View {
    let event: EventSnapshot
    @Environment(\.flowPalette) private var palette

    private var fields: [String: String] {
        JobEventFormatting.payloadFields(event.sanitizedPayload)
    }

    private var detailKeys: [String] {
        fields.keys.filter { $0 != "state" }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            if let state = fields["state"] {
                stateBadge(state)
            }
            detailRows
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.pinSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.pinStroke, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(JobEventFormatting.title(for: event.type)) at \(event.occurredAtISO8601)")
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(JobEventFormatting.title(for: event.type))
                .font(FlowTheme.Typeface.body(13))
                .foregroundStyle(palette.ink)
            Spacer(minLength: 0)
            Text(JobEventFormatting.relativeTime(iso8601: event.occurredAtISO8601))
                .font(FlowTheme.Typeface.caption(11))
                .foregroundStyle(palette.inkSoft)
        }
    }

    private func stateBadge(_ state: String) -> some View {
        Text(state.capitalized)
            .font(FlowTheme.Typeface.caption(11))
            .foregroundStyle(palette.onSignal)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(palette.signal.opacity(0.85), in: Capsule())
    }

    @ViewBuilder
    private var detailRows: some View {
        let keys = detailKeys
        if !keys.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(keys, id: \.self) { (key: String) in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(JobEventFormatting.fieldLabel(key))
                            .font(FlowTheme.Typeface.caption(11))
                            .foregroundStyle(palette.inkSoft)
                            .frame(width: 88, alignment: .leading)
                        Text(fields[key] ?? "")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(palette.ink)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

enum JobEventFormatting {
    static func title(for type: String) -> String {
        switch type {
        case "state.changed": return "State changed"
        case "recovery.requeued": return "Requeued"
        default:
            return type
                .replacingOccurrences(of: ".", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    static func fieldLabel(_ key: String) -> String {
        switch key {
        case "revision": return "Revision"
        case "previousState": return "Previous"
        case "terminalReason": return "Reason"
        default: return key.capitalized
        }
    }

    static func relativeTime(iso8601: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso8601) else { return iso8601 }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }

    static func payloadFields(_ payload: String?) -> [String: String] {
        guard let payload, let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var fields: [String: String] = [:]
        for (key, value) in object {
            fields[key] = String(describing: value)
        }
        return fields
    }
}
