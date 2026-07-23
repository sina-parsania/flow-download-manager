// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Domain
import SwiftUI
import UniformTypeIdentifiers
import XPCContracts

/// Add / review sheet: extract URLs, classify, enqueue via the agent (FR-ING).
struct AddDownloadsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.flowPalette) private var palette
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var launchAgent: LaunchAgentModel
    @State private var input = ""
    @State private var extraction: URLTextExtractor.Result?
    @State private var isEnqueueing = false
    @State private var statusMessage: String?
    @State private var isImportPresented = false
    @State private var isDropTargeted = false
    @State private var showRouting = false
    @State private var showHeaders = false

    @State private var credentials: [CredentialProfileSnapshot] = []
    @State private var proxies: [ProxyProfileSnapshot] = []
    @State private var cookies: [CookieProfileSnapshot] = []
    @State private var projects: [ProjectSnapshot] = []
    @State private var classificationRules: [CategoryRulesEngine.Rule] = []
    @State private var selectedCredentialID = ""
    @State private var selectedProxyID = ""
    @State private var selectedCookieID = ""
    @State private var selectedProjectID = ""
    @State private var customHeadersText = ""
    @State private var headersError: String?
    @State private var useStartAt = false
    @State private var startAt = Date().addingTimeInterval(3600)
    @State private var confirmationPhase: ConfirmationGate.Phase = .none
    @State private var confirmationCounts: [(stableKey: String, count: Int)] = []

    private var validCount: Int {
        extraction?.validCount ?? 0
    }

    private var optionsLocked: Bool {
        isEnqueueing || confirmationPhase == .needsConfirmation
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    pasteStage
                    if let extraction, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        liveStats(extraction)
                    }
                    DestinationFolderCard(
                        engineClient: library.engineClient,
                        compact: false,
                        onHealEngine: {
                            await launchAgent.repair()
                            return launchAgent.isEngineReady
                        }
                    )
                    .disabled(optionsLocked)
                    scheduleCard
                    routingCard
                    headersCard
                    if confirmationPhase == .needsConfirmation, !confirmationCounts.isEmpty {
                        confirmationCard
                    }
                    if let statusMessage {
                        Text(statusMessage)
                            .font(FlowTheme.Typeface.body(13))
                            .foregroundStyle(palette.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
                .padding(.bottom, 8)
            }

            footerBar
        }
        .frame(width: 580, height: 740)
        .background(palette.mist)
        .foregroundStyle(palette.ink)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task {
            if let pending = library.pendingClipboardText {
                input = pending
                extraction = URLTextExtractor.extract(from: pending)
                library.pendingClipboardText = nil
            }
            await loadBindingOptions()
        }
        .fileImporter(
            isPresented: $isImportPresented,
            allowedContentTypes: [.plainText, .commaSeparatedText, .utf8PlainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first {
                    importFile(url)
                }
            case .failure:
                statusMessage = "Could not import the selected file."
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Compose")
                .font(FlowTheme.Typeface.display(32, weight: .heavy))
                .foregroundStyle(palette.ink)
            Text("Drop links onto the stage. Flow sorts them and queues the board.")
                .font(FlowTheme.Typeface.body(14))
                .foregroundStyle(palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pasteStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $input)
                    .font(FlowTheme.Typeface.mono(13))
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .frame(minHeight: 140)
                    .foregroundStyle(palette.ink)
                    .accessibilityLabel("Links to add")
                    .onChange(of: input) { _, newValue in
                        extraction = URLTextExtractor.extract(from: newValue)
                        confirmationPhase = .none
                        confirmationCounts = []
                    }
                    .onDrop(
                        of: [.fileURL, .plainText, .utf8PlainText],
                        isTargeted: $isDropTargeted
                    ) { providers in
                        handleDrop(providers)
                    }

                if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Paste or drop links here")
                            .font(FlowTheme.Typeface.title(15))
                            .foregroundStyle(palette.inkSoft)
                        Text("One URL per line works best. Lists and .txt / .csv files are fine.")
                            .font(FlowTheme.Typeface.caption(12))
                            .foregroundStyle(palette.inkSoft.opacity(0.85))
                    }
                    .padding(18)
                    .allowsHitTesting(false)
                }
            }
            .background(palette.pinSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? palette.signal : palette.pinStroke,
                        lineWidth: isDropTargeted ? 2.5 : 1
                    )
            }
            .shadow(color: palette.ink.opacity(palette.isDark ? 0.12 : 0.05), radius: 6, y: 3)

            HStack(spacing: 10) {
                Button {
                    isImportPresented = true
                } label: {
                    Label("Load links from a .txt / .csv", systemImage: "tray.and.arrow.down")
                        .font(FlowTheme.Typeface.body(13))
                        .foregroundStyle(palette.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(palette.chipFill, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(optionsLocked)
                .help("Choose a text or CSV file; its links are pasted into the stage above.")
                .accessibilityLabel("Load links from a text or CSV file")

                if isDropTargeted {
                    Text("Release to add")
                        .font(FlowTheme.Typeface.caption(12))
                        .foregroundStyle(palette.signalDeep)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func liveStats(_ extraction: URLTextExtractor.Result) -> some View {
        HStack(spacing: 10) {
            statChip("Ready", extraction.validCount, emphasize: extraction.validCount > 0)
            statChip("Dupes", extraction.duplicateCount, emphasize: false)
            statChip("Skip", extraction.unsupportedCount, emphasize: false)
            statChip("Bad", extraction.invalidCount, emphasize: extraction.invalidCount > 0)
        }
    }

    private func statChip(_ title: String, _ value: Int, emphasize: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(FlowTheme.Typeface.caption(10))
                .tracking(0.8)
                .foregroundStyle(palette.inkSoft)
            Text("\(value)")
                .font(FlowTheme.Typeface.title(18))
                .foregroundStyle(emphasize ? palette.ink : palette.inkSoft)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(palette.chipFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionEyebrow("When")
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $useStartAt) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Schedule for later")
                            .font(FlowTheme.Typeface.title(14))
                            .foregroundStyle(palette.ink)
                        Text(
                            useStartAt
                                ? "This batch waits until the time below, then joins the queue."
                                : "Off = start as soon as the engine has a free slot."
                        )
                        .font(FlowTheme.Typeface.caption(12))
                        .foregroundStyle(palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(palette.signal)
                .accessibilityLabel("Schedule for later")

                if useStartAt {
                    DatePicker(
                        "Start time",
                        selection: $startAt,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.plateFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("Scheduled start time")
                }
            }
            .padding(14)
            .background(palette.pinSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.pinStroke, lineWidth: 1)
            }
        }
        .disabled(optionsLocked)
    }

    private var routingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showRouting.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        sectionEyebrow("Routing")
                        Text(routingSummary)
                            .font(FlowTheme.Typeface.body(13))
                            .foregroundStyle(palette.inkSoft)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: showRouting ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.inkSoft)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showRouting ? "Hide routing options" : "Show routing options")

            if showRouting {
                VStack(spacing: 12) {
                    routeRow(
                        title: "Sign-in",
                        help: "Optional login for sites that need a username/password.",
                        selection: $selectedCredentialID,
                        noneLabel: "No sign-in",
                        options: credentials.map { ($0.id, $0.displayName) }
                    )
                    routeRow(
                        title: "Proxy",
                        help: "Send traffic through a proxy profile.",
                        selection: $selectedProxyID,
                        noneLabel: "Direct connection",
                        options: proxies.map { ($0.id, $0.displayName) }
                    )
                    routeRow(
                        title: "Cookies",
                        help: "Attach a saved browser cookie jar.",
                        selection: $selectedCookieID,
                        noneLabel: "No cookies",
                        options: cookies.map { ($0.id, $0.displayName) }
                    )
                    routeRow(
                        title: "Project",
                        help: "Tag this batch under a project on the board.",
                        selection: $selectedProjectID,
                        noneLabel: "No project",
                        options: projects.map { ($0.id, $0.name) }
                    )
                }
                .padding(14)
                .background(palette.pinSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(palette.pinStroke, lineWidth: 1)
                }
                .disabled(optionsLocked)
            }
        }
    }

    private var headersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showHeaders.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        sectionEyebrow("Headers")
                        Text(
                            customHeadersText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "None — only if a site needs extra HTTP headers"
                                : "Custom headers set"
                        )
                        .font(FlowTheme.Typeface.body(13))
                        .foregroundStyle(palette.inkSoft)
                        .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: showHeaders ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.inkSoft)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showHeaders ? "Hide custom headers" : "Show custom headers")

            if showHeaders {
                VStack(alignment: .leading, spacing: 8) {
                    Text("One header per line, like Referer: https://example.com")
                        .font(FlowTheme.Typeface.caption(12))
                        .foregroundStyle(palette.inkSoft)
                    TextEditor(text: $customHeadersText)
                        .font(FlowTheme.Typeface.mono(12))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 72, maxHeight: 110)
                        .foregroundStyle(palette.ink)
                        .background(palette.plateFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(palette.pinStroke, lineWidth: 1)
                        }
                        .accessibilityLabel("Custom headers")
                        .onChange(of: customHeadersText) { _, _ in
                            headersError = nil
                        }
                    if let headersError {
                        Text(headersError)
                            .font(FlowTheme.Typeface.caption(12))
                            .foregroundStyle(palette.ember)
                    }
                }
                .padding(14)
                .background(palette.pinSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(palette.pinStroke, lineWidth: 1)
                }
                .disabled(optionsLocked)
            }
        }
    }

    private var confirmationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Check categories")
                .font(FlowTheme.Typeface.title(15))
                .foregroundStyle(palette.ink)
            Text(
                "Some links look uncertain or landed in Other. Glance at the counts, then queue anyway if that’s fine."
            )
            .font(FlowTheme.Typeface.body(13))
            .foregroundStyle(palette.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
            ForEach(confirmationCounts, id: \.stableKey) { entry in
                HStack {
                    Text(entry.stableKey.capitalized)
                        .font(FlowTheme.Typeface.body(13))
                    Spacer()
                    Text("\(entry.count)")
                        .font(FlowTheme.Typeface.mono(13))
                }
                .foregroundStyle(palette.ink)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(entry.stableKey): \(entry.count)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.signal.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(palette.signal.opacity(0.45), lineWidth: 1)
        }
    }

    private var footerBar: some View {
        HStack(spacing: 12) {
            Button("Close") { dismiss() }
                .font(FlowTheme.Typeface.body(13))
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(palette.chipFill, in: Capsule())
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

            Spacer(minLength: 0)

            if confirmationPhase == .needsConfirmation {
                Button("Back") {
                    confirmationPhase = .none
                    confirmationCounts = []
                }
                .font(FlowTheme.Typeface.body(13))
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(palette.chipFill, in: Capsule())
                .buttonStyle(.plain)
                .disabled(isEnqueueing)

                primaryButton(
                    title: isEnqueueing ? "Starting…" : "Start anyway",
                    enabled: !isEnqueueing && validCount > 0
                ) {
                    confirmationPhase = .confirmed
                    Task { await enqueue() }
                }
                .accessibilityLabel("Start anyway")
            } else {
                primaryButton(
                    title: isEnqueueing
                        ? "Starting…"
                        : (validCount == 0 ? "Start" : "Start \(validCount)"),
                    enabled: !isEnqueueing && validCount > 0
                ) {
                    Task { await enqueue() }
                }
                .accessibilityLabel("Start downloads")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(palette.mistDeep.opacity(0.92))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.pinStroke)
                .frame(height: 1)
        }
    }

    // MARK: - Bits

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title.uppercased())
            .font(FlowTheme.Typeface.caption(10))
            .tracking(1.3)
            .foregroundStyle(palette.inkSoft)
    }

    private var routingSummary: String {
        var parts: [String] = []
        if !selectedCredentialID.isEmpty { parts.append("sign-in") }
        if !selectedProxyID.isEmpty { parts.append("proxy") }
        if !selectedCookieID.isEmpty { parts.append("cookies") }
        if !selectedProjectID.isEmpty { parts.append("project") }
        return parts.isEmpty ? "Defaults — expand to attach sign-in, proxy, cookies, project" : parts
            .joined(separator: " · ")
    }

    private func routeRow(
        title: String,
        help: String,
        selection: Binding<String>,
        noneLabel: String,
        options: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(FlowTheme.Typeface.title(13))
                .foregroundStyle(palette.ink)
            Text(help)
                .font(FlowTheme.Typeface.caption(11))
                .foregroundStyle(palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Picker(title, selection: selection) {
                Text(noneLabel).tag("")
                ForEach(options, id: \.0) { id, name in
                    Text(name).tag(id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func primaryButton(title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(FlowTheme.Typeface.title(14))
                .foregroundStyle(enabled ? palette.onSignal : palette.inkSoft)
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
                .background(
                    enabled ? palette.signal : palette.chipFill,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
        .shadow(color: enabled ? palette.signal.opacity(0.18) : .clear, radius: 4, y: 2)
    }

    // MARK: - Logic (unchanged behavior)

    @MainActor
    private func loadBindingOptions() async {
        do {
            let profiles = try await library.engineClient.listProfiles()
            credentials = profiles.credentials
            proxies = profiles.proxies
            cookies = profiles.cookies
            let organization = try await library.engineClient.listOrganization()
            projects = organization.projects
            let rulesResponse = try await library.engineClient.listCategoryRules()
            classificationRules = rulesResponse.rules.map {
                CategoryRulesEngine.Rule(
                    id: $0.id,
                    priority: $0.priority,
                    enabled: $0.enabled,
                    predicateJSON: $0.predicateJSON,
                    categoryStableKey: $0.categoryStableKey
                )
            }
        } catch {
            statusMessage = "Could not load profiles from the engine."
        }
    }

    private func importFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let text = try ImportTextIngest.readText(from: url)
            if input.isEmpty {
                input = text
            } else {
                input += "\n" + text
            }
            extraction = URLTextExtractor.extract(from: input)
            statusMessage = "Imported \(url.lastPathComponent)."
        } catch let error as ImportTextIngest.ReadError {
            switch error {
            case .exceedsSizeLimit:
                statusMessage = "File exceeds the 8 MB import limit."
            case .undecodable:
                statusMessage = "Could not decode the file as text."
            case .unsupportedExtension, .notAFileURL:
                statusMessage = "Could not import the selected file."
            }
        } catch {
            statusMessage = "Could not read the selected file."
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL? = if let data = item as? Data {
                        URL(dataRepresentation: data, relativeTo: nil)
                    } else if let url = item as? URL {
                        url
                    } else {
                        nil
                    }
                    guard let url, ImportTextIngest.isImportableFile(url) else { return }
                    Task { @MainActor in
                        importFile(url)
                    }
                }
                handled = true
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    guard let string, !string.isEmpty else { return }
                    Task { @MainActor in
                        if input.isEmpty {
                            input = string
                        } else {
                            input += "\n" + string
                        }
                        extraction = URLTextExtractor.extract(from: input)
                    }
                }
                handled = true
            }
        }
        return handled
    }

    /// XPC-friendly chunk size — keeps large pastes (1000+) responsive and durable.
    private static let enqueueChunkSize = 250

    @MainActor
    private func enqueue() async {
        guard let extraction else { return }

        let rules = classificationRules
        let validItems = extraction.items.filter { $0.status == .valid }
        guard !validItems.isEmpty else {
            statusMessage = "No valid links to queue."
            return
        }

        isEnqueueing = true
        statusMessage = "Classifying \(validItems.count) link(s)…"
        defer { isEnqueueing = false }

        var classifiedItems: [(url: String, categoryStableKey: String)] = []
        var results: [ClassificationEngine.ClassificationResult] = []
        classifiedItems.reserveCapacity(validItems.count)
        results.reserveCapacity(validItems.count)

        // Chunk classify + yield so the sheet stays responsive on 1000+ URLs.
        for (index, item) in validItems.enumerated() {
            let raw = item.raw
            let classified = ClassificationEngine.classify(
                filenameEvidence: URL(string: raw)?.lastPathComponent,
                mimeEvidence: nil,
                urlPath: raw,
                rules: rules
            )
            classifiedItems.append((raw, classified.stableKey))
            results.append(classified)
            if index > 0, index % Self.enqueueChunkSize == 0 {
                statusMessage = "Classifying… \(index)/\(validItems.count)"
                await Task.yield()
            }
        }

        if confirmationPhase != .confirmed, ConfirmationGate.shouldConfirm(results: results) {
            confirmationCounts = ConfirmationGate.categoryCounts(results: results)
            confirmationPhase = .needsConfirmation
            statusMessage = nil
            return
        }

        var scheduleISO: String?
        if useStartAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            scheduleISO = formatter.string(from: startAt)
        }

        var customHeadersJSON: String?
        let trimmedHeaders = customHeadersText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHeaders.isEmpty {
            do {
                let parsed = try HeaderValidator.parseHeaderLines(trimmedHeaders)
                customHeadersJSON = try HeaderValidator.encodeExtraHeadersJSON(parsed)
                headersError = nil
            } catch {
                headersError = "Invalid custom headers. Use Header-Name: value lines."
                return
            }
        }

        do {
            var accepted = 0
            let totalChunks = max(1, (classifiedItems.count + Self.enqueueChunkSize - 1) / Self.enqueueChunkSize)
            for (chunkIndex, chunkStart) in stride(
                from: 0, to: classifiedItems.count, by: Self.enqueueChunkSize
            ).enumerated() {
                let end = min(chunkStart + Self.enqueueChunkSize, classifiedItems.count)
                let chunk = Array(classifiedItems[chunkStart ..< end])
                statusMessage = "Queuing… \(chunkIndex + 1)/\(totalChunks)"
                let response = try await library.engineClient.enqueueBatch(
                    source: "paste",
                    displayName: nil,
                    items: chunk,
                    credentialProfileID: selectedCredentialID.isEmpty ? nil : selectedCredentialID,
                    proxyProfileID: selectedProxyID.isEmpty ? nil : selectedProxyID,
                    cookieProfileID: selectedCookieID.isEmpty ? nil : selectedCookieID,
                    customHeadersJSON: customHeadersJSON,
                    projectID: selectedProjectID.isEmpty ? nil : selectedProjectID,
                    scheduleStartAtISO8601: scheduleISO
                )
                accepted += response.acceptedCount
            }
            statusMessage = "Queued \(accepted) download(s)."
            await library.refreshFromEngine()
            dismiss()
        } catch {
            statusMessage = "Could not queue downloads. Is the engine running?"
            confirmationPhase = .none
        }
    }
}
