// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Column definitions and reusable cell construction for the download table.
/// Name and Status cannot be hidden (`03-design-system-ui-ux.md` §5). Numeric
/// columns use monospaced digits.
@MainActor
struct JobColumn {
    let identifier: NSUserInterfaceItemIdentifier
    let title: String
    let width: CGFloat
    let minWidth: CGFloat
    let makeCell: @MainActor (NSTableView, JobRowModel) -> NSView

    static let all: [JobColumn] = [
        JobColumn(identifier: .init("status"), title: "Status", width: 110, minWidth: 80) { table, model in
            textCell(
                table,
                id: .init("cell.status"),
                text: model.state.rawValue,
                monospaced: false,
                color: color(for: model.statusRole),
                accessibility: "Status: \(model.state.rawValue)"
            )
        },
        JobColumn(identifier: .init("name"), title: "Name", width: 260, minWidth: 140) { table, model in
            nameCell(table, model: model)
        },
        JobColumn(identifier: .init("progress"), title: "Progress", width: 200, minWidth: 120) { table, model in
            progressCell(table, model: model)
        },
        JobColumn(identifier: .init("speed"), title: "Speed", width: 90, minWidth: 70) { table, model in
            textCell(
                table,
                id: .init("cell.speed"),
                text: JobRowFormatting.speed(model.speedBytesPerSecond),
                monospaced: true,
                accessibility: "Speed: \(JobRowFormatting.speed(model.speedBytesPerSecond))"
            )
        },
        JobColumn(identifier: .init("eta"), title: "ETA", width: 80, minWidth: 60) { table, model in
            textCell(
                table,
                id: .init("cell.eta"),
                text: JobRowFormatting.eta(model.etaSeconds),
                monospaced: true,
                accessibility: "Time remaining: \(JobRowFormatting.eta(model.etaSeconds))"
            )
        },
        JobColumn(identifier: .init("size"), title: "Size", width: 90, minWidth: 70) { table, model in
            textCell(
                table,
                id: .init("cell.size"),
                text: JobRowFormatting.size(model.totalBytes),
                monospaced: true,
                accessibility: "Size: \(JobRowFormatting.size(model.totalBytes))"
            )
        },
        JobColumn(identifier: .init("category"), title: "Category", width: 110, minWidth: 80) { table, model in
            let summary = ([model.categoryKey] + (model.projectName.map { [$0] } ?? []) + model.tagNames)
                .joined(separator: " · ")
            return textCell(
                table,
                id: .init("cell.category"),
                text: summary,
                monospaced: false,
                color: .secondaryLabelColor,
                accessibility: "Category: \(summary)"
            )
        }
    ]

    // MARK: cell factories

    private static func textCell(
        _ tableView: NSTableView, id: NSUserInterfaceItemIdentifier, text: String,
        monospaced: Bool, color: NSColor = .labelColor, accessibility: String
    ) -> NSTableCellView {
        let cell = dequeueTextCell(tableView, id: id)
        cell.textField?.stringValue = text
        cell.textField?.font = monospaced
            ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize)
        cell.textField?.textColor = color
        cell.textField?.setAccessibilityLabel(accessibility)
        return cell
    }

    private static func dequeueTextCell(
        _ tableView: NSTableView,
        id: NSUserInterfaceItemIdentifier
    ) -> NSTableCellView {
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            return reused
        }
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private static func nameCell(_ tableView: NSTableView, model: JobRowModel) -> NSView {
        let id = NSUserInterfaceItemIdentifier("cell.name")
        let cell: NSTableCellView = dequeueTextCell(tableView, id: id)
        let name = NSMutableAttributedString(string: model.name + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
        ])
        name.append(NSAttributedString(string: model.sourceHost, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        cell.textField?.attributedStringValue = name
        cell.textField?.maximumNumberOfLines = 2
        cell.textField?.usesSingleLineMode = false
        cell.textField?.setAccessibilityLabel("\(model.name), from \(model.sourceHost)")
        return cell
    }

    private static func progressCell(_ tableView: NSTableView, model: JobRowModel) -> NSView {
        let id = NSUserInterfaceItemIdentifier("cell.progress")
        let cell: ProgressCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? ProgressCellView {
            cell = reused
        } else {
            cell = ProgressCellView()
            cell.identifier = id
        }
        let text = JobRowFormatting.progressText(
            fraction: model.progressFraction, transferred: model.bytesTransferred, total: model.totalBytes
        )
        cell.configure(fraction: model.progressFraction, text: text)
        return cell
    }

    private static func color(for role: JobRowModel.StatusRole) -> NSColor {
        switch role {
        case .active: return .controlAccentColor
        case .queued: return .secondaryLabelColor
        case .paused: return .secondaryLabelColor
        case .success: return .systemGreen
        case .failure: return .systemRed
        }
    }
}

/// Reusable progress cell: a determinate bar plus a monospaced-digit label.
/// Honors Reduce Motion by never animating (progress reflects throttled snapshots
/// — `03-design-system-ui-ux.md` §5).
@MainActor
final class ProgressCellView: NSTableCellView {
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(bar)
        addSubview(label)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 2)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(fraction: Double?, text: String) {
        if let fraction {
            bar.isIndeterminate = false
            bar.doubleValue = max(0, min(1, fraction))
        } else {
            bar.isIndeterminate = false
            bar.doubleValue = 0
        }
        label.stringValue = text
        setAccessibilityLabel("Progress: \(text)")
    }
}
