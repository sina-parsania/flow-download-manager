# Accessibility report — Phase 0

Status: foundation in place; manual VoiceOver/keyboard scripts run on an interactive
UI lane (`05-quality-testing-release-gates.md` §9, `03-design-system-ui-ux.md` §14).

## Automated foundation (present in Phase 0)

- **Labels on every actionable/informative element.** Sidebar filters, engine
  status badge, table cells (status, name+host, progress, speed, ETA, size,
  category), inspector fields, and the Add sheet all set `accessibilityLabel`.
  Decorative symbols are hidden (`accessibilityHidden`).
- **Table rows** expose name, state, progress, speed, ETA and category through
  per-cell labels (`JobColumn`), matching the §14 requirement.
- **Colour is supplemental.** Status is conveyed by symbol + text; the status
  colour (`JobColumn.color(for:)`) never carries meaning alone.
- **Keyboard.** Primary actions have shortcuts surfaced in the menu bar:
  ⌘N Add, ⌥⌘I Inspector, ⌘F Search (via `.searchable`), ⇧⌘R refresh engine status.
- **Reduce Motion / Transparency.** The progress cell never animates; the
  appearance adapter uses system materials/glass which honour Reduce Transparency
  automatically. No continuous decorative motion is used.
- **Monospaced digits** for rates/bytes/time keep numeric columns legible and
  stable.

## Manual scripts (interactive lane — not run in the headless gate)

The following require an interactive, automation-permitted macOS session and run on
a physical/VM UI lane before release:

1. VoiceOver order: sidebar → toolbar → table → inspector.
2. Full keyboard-only completion of: open Add sheet, change filter, toggle
   inspector, select a row, read its details.
3. Increase Contrast + Reduce Transparency + Reduce Motion appearance snapshots on
   macOS 14, 15 and 26.

## Status

- Automated labels/roles/keyboard: **implemented** and compiled into the app.
- Automated accessibility audit + manual VoiceOver scripts: **pending an
  interactive UI lane** (the headless Phase 0 session cannot drive VoiceOver).
