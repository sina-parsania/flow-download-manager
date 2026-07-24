# Accessibility report — automated lane

Status (as of v0.3.0): the automated accessibility foundation covers the shipping
controls; the interactive VoiceOver/keyboard scripts below still require a human
UI lane and remain the one open accessibility item.

## Automated foundation (verified in source)

- Library table cells keep per-column `accessibilityLabel`s (status, name, progress,
  speed, ETA, size, category).
- Inspector Overview + Organization: project picker and tag toggles labeled.
- Settings: ZIP auto-extract toggle, bandwidth, profiles, cookie/header editors
  expose labels (see `SettingsView`).
- Menu bar / bulk controls and confirmation alerts use standard AppKit/SwiftUI
  accessibility trees.
- Colour remains supplemental to symbol + text for job state.

## Manual scripts (still required)

Record results under `Artifacts/validation/accessibility-report.md` when run:

1. VoiceOver order: sidebar → toolbar → table → inspector → Settings.
2. Keyboard-only: Add sheet, filter change, inspector toggle, project/tag edit,
   pause/resume/cancel, Settings ZIP toggle.
3. Increase Contrast + Reduce Transparency + Reduce Motion on macOS 14/15/26.

## Status

- Automated labels/roles/keyboard affordances: **implemented**.
- Manual VoiceOver evidence pack: **pending interactive lane** (not runnable in
  headless `verify-fast`).
