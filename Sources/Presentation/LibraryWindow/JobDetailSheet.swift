// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import SwiftUI
import XPCContracts

/// Modal job details — opened by double-click, fully detached from multi-select.
struct JobDetailSheet: View {
    @ObservedObject var model: LibraryModel
    var onDeleteFromDisk: (JobRowModel.ID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.flowPalette) private var palette

    var body: some View {
        NavigationStack {
            Group {
                if let row = model.inspectedRow {
                    InspectorView(
                        row: row,
                        engineClient: model.engineClient,
                        onCommand: { command in
                            Task { await model.control(jobID: row.id, command: command) }
                        },
                        onPriorityBump: { delta in
                            Task { await model.bumpPriority(jobID: row.id, by: delta) }
                        },
                        onOrganizationChanged: {
                            Task { await model.refreshFromEngine() }
                        },
                        onRevealInFinder: {
                            Task { await model.revealInFinder(jobID: row.id) }
                        },
                        onOpenFile: {
                            Task { await model.openFile(jobID: row.id) }
                        },
                        onRemoveFromLibrary: {
                            Task {
                                await model.remove(jobID: row.id, deleteFiles: false)
                                dismiss()
                            }
                        },
                        onDeleteFromDisk: {
                            let id = row.id
                            model.closeInspector()
                            dismiss()
                            onDeleteFromDisk(id)
                        }
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, idealWidth: 480, minHeight: 520, idealHeight: 640)
            .background(palette.mist.opacity(0.35))
            .navigationTitle(model.inspectedRow?.name ?? "Details")
            .navigationSubtitle(model.inspectedRow?.sourceHost ?? "")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        model.closeInspector()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .flowAppearance()
        .onChange(of: model.inspectedID) { _, newValue in
            if newValue == nil {
                dismiss()
            }
        }
    }
}
