// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Column definitions and reusable cell construction for the download table.
/// Numeric columns use monospaced digits.
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
                text: model.state.displayName,
                monospaced: false,
                color: color(for: model.statusRole),
                accessibility: "Status: \(model.state.displayName)"
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
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.cell?.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        let cell: NameCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NameCellView {
            cell = reused
        } else {
            cell = NameCellView()
            cell.identifier = id
        }
        cell.configure(name: model.name, host: model.sourceHost)
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
        case .active: return FlowAppKitChrome.statusActive
        case .queued: return .secondaryLabelColor
        case .paused: return .secondaryLabelColor
        case .success: return FlowAppKitChrome.statusSuccess
        case .failure: return FlowAppKitChrome.statusFailure
        }
    }
}

/// Name + host stacked; each line truncates with an ellipsis (never wraps).
@MainActor
final class NameCellView: NSTableCellView {
    private let nameField = NSTextField(labelWithString: "")
    private let hostField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureField(
            nameField,
            font: .systemFont(ofSize: NSFont.systemFontSize),
            color: .labelColor
        )
        configureField(
            hostField,
            font: .systemFont(ofSize: NSFont.smallSystemFontSize),
            color: .secondaryLabelColor
        )
        addSubview(nameField)
        addSubview(hostField)
        textField = nameField
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            hostField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            hostField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            hostField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 1),
            hostField.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(name: String, host: String) {
        nameField.stringValue = name
        hostField.stringValue = host
        toolTip = host.isEmpty ? name : "\(name)\n\(host)"
        setAccessibilityLabel("\(name), from \(host)")
    }

    private func configureField(_ field: NSTextField, font: NSFont, color: NSColor) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = font
        field.textColor = color
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.cell?.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
}

/// Citrus gradient progress bar — replaces the system-accent `NSProgressIndicator`.
@MainActor
final class FlowProgressBarView: NSView {
    var fraction: Double = 0 {
        didSet {
            let clamped = max(0, min(1, fraction))
            if clamped != fraction {
                fraction = clamped
                return
            }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = min(bounds.height, 8)
        let track = NSRect(
            x: bounds.minX,
            y: bounds.midY - height / 2,
            width: bounds.width,
            height: height
        )
        let radius = height / 2
        let trackPath = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        FlowAppKitChrome.progressTrack.setFill()
        trackPath.fill()

        let fillWidth = track.width * CGFloat(fraction)
        guard fillWidth > 0.5 else { return }
        let fillRect = NSRect(
            x: track.minX,
            y: track.minY,
            width: max(fillWidth, height),
            height: track.height
        )
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        if let gradient = NSGradient(
            starting: FlowAppKitChrome.signal,
            ending: FlowAppKitChrome.signalDeep
        ) {
            gradient.draw(in: fillPath, angle: 0)
        } else {
            FlowAppKitChrome.signalDeep.setFill()
            fillPath.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Reusable progress cell: a determinate bar plus a monospaced-digit label.
/// Honors Reduce Motion by never animating (progress reflects throttled snapshots
/// — `03-design-system-ui-ux.md` §5).
@MainActor
final class ProgressCellView: NSTableCellView {
    private let bar = FlowProgressBarView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bar.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.cell?.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(bar)
        addSubview(label)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bar.heightAnchor.constraint(equalToConstant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 3)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// The label stays constant ("Progress") and the quantity is published as an
    /// accessibility *value*, so VoiceOver announces the change instead of treating
    /// every update as a differently named element.
    func configure(fraction: Double?, text: String) {
        let clamped = fraction.map { max(0, min(1, $0)) } ?? 0
        bar.fraction = clamped
        label.stringValue = text
        setAccessibilityLabel("Progress")
        setAccessibilityValue(text)
        setAccessibilityValueDescription(text)
        bar.setAccessibilityLabel("Progress")
        bar.setAccessibilityValueDescription(text)
        label.setAccessibilityLabel("Progress")
        label.setAccessibilityValueDescription(text)
    }
}

/// Selected-row chrome in Flow citrus instead of the system accent blue.
@MainActor
final class FlowTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let inset = bounds.insetBy(dx: 2, dy: 1)
        let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
        let fill = isEmphasized
            ? FlowAppKitChrome.selectionFill
            : FlowAppKitChrome.selectionFillInactive
        fill.setFill()
        path.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        // Keep standard label colors — wash is soft enough without forced white text.
        .normal
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
