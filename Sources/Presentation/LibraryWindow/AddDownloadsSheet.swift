// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Domain
import SwiftUI
import UniformTypeIdentifiers

/// Add / review sheet: extract URLs, classify, enqueue via the agent (FR-ING).
struct AddDownloadsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryModel
    @State private var input = ""
    @State private var extraction: URLTextExtractor.Result?
    @State private var isEnqueueing = false
    @State private var statusMessage: String?
    @State private var isImportPresented = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Downloads")
                .font(.title2.bold())

            Text("Paste links, drop a .txt/.csv file, or import from disk. Transfers run in the background engine.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $input)
                .font(.body.monospaced())
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                            lineWidth: isDropTargeted ? 2 : 1
                        )
                )
                .accessibilityLabel("Links to add")
                .onChange(of: input) { _, newValue in
                    extraction = URLTextExtractor.extract(from: newValue)
                }
                .onDrop(of: [.fileURL, .plainText, .utf8PlainText], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers)
                }

            HStack {
                Button("Import File…") { isImportPresented = true }
                Spacer()
            }

            if let extraction {
                HStack(spacing: 12) {
                    stat("Valid", extraction.validCount)
                    stat("Duplicate", extraction.duplicateCount)
                    stat("Unsupported", extraction.unsupportedCount)
                    stat("Invalid", extraction.invalidCount)
                }
                .font(.callout)
            }

            if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEnqueueing ? "Queuing…" : "Queue Selected") {
                    Task { await enqueue() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isEnqueueing || (extraction?.validCount ?? 0) == 0)
            }
        }
        .padding(24)
        .frame(width: 560, height: 460)
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

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading) {
            Text(title).foregroundStyle(.secondary)
            Text("\(value)").font(.headline.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    private func importFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 8_000_000 else {
                statusMessage = "File exceeds the 8 MB import limit."
                return
            }
            guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
            else {
                statusMessage = "Could not decode the file as text."
                return
            }
            if input.isEmpty {
                input = text
            } else {
                input += "\n" + text
            }
            extraction = URLTextExtractor.extract(from: input)
            statusMessage = "Imported \(url.lastPathComponent)."
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
                    guard let url else { return }
                    let ext = url.pathExtension.lowercased()
                    guard ext == "txt" || ext == "csv" || ext.isEmpty else { return }
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

    @MainActor
    private func enqueue() async {
        guard let extraction else { return }
        isEnqueueing = true
        statusMessage = nil
        defer { isEnqueueing = false }

        let items: [(url: String, categoryStableKey: String)] = extraction.items.compactMap { item in
            guard item.status == .valid else { return nil }
            let raw = item.raw
            let path = URL(string: raw)?.path
            let classified = ClassificationEngine.classify(
                filenameEvidence: URL(string: raw)?.lastPathComponent,
                mimeEvidence: nil,
                urlPath: path
            )
            return (raw, classified.stableKey)
        }
        guard !items.isEmpty else {
            statusMessage = "No valid links to queue."
            return
        }

        do {
            let response = try await library.engineClient.enqueueBatch(
                source: "paste",
                displayName: nil,
                items: items
            )
            statusMessage = "Queued \(response.acceptedCount) download(s)."
            await library.refreshFromEngine()
            dismiss()
        } catch {
            statusMessage = "Could not queue downloads. Is the engine running?"
        }
    }
}
