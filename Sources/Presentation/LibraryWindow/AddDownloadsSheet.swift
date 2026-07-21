// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Phase 0 Add sheet. It is deliberately INFORMATIONAL: it accepts input for
/// preview but does NOT pretend to queue a download (`bootstrap prompt §5`).
/// Real ingestion arrives in Phase 1. Demonstrates the appearance adapter on a
/// floating control.
struct AddDownloadsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    private var detectedCount: Int {
        input
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .count(where: { $0.hasPrefix("http://") || $0.hasPrefix("https://") })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Downloads")
                .font(.title2.bold())

            Text(
                "Paste or type links to preview extraction. Queuing and transfers arrive in a later release; nothing is downloaded yet."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $input)
                .font(.body.monospaced())
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .accessibilityLabel("Links to add")

            HStack {
                FloatingControlGroup {
                    Label("\(detectedCount) link\(detectedCount == 1 ? "" : "s") detected", systemImage: "link")
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .floatingControlSurface()
                }
                .accessibilityLabel("\(detectedCount) links detected")

                Spacer()

                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 380)
    }
}
