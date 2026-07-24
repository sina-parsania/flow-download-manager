---
paths:
  - "Sources/Presentation/**"
  - "Sources/App/**"
---

# Presentation — copy, state, accessibility

## Never render an enum identifier

`state.rawValue` in UI produced `RETRYWAITING`, `POSTPROCESSING`, `AWAITINGUSERSELECTION` on screen and in VoiceOver. Use `JobState.displayName` (sentence case) and `JobState.shortLabel` (≤6 chars, all caps, for the board chip).

Both are **exhaustive switches with no `default:`** — that is the point. A new state must be a compile error, not a leaked identifier. Keep it that way.

## No engineering vocabulary in user-facing strings

Banned from anything a user can read: `XPC`, `LaunchAgent`, `SMAppService`, `plist`, `SQLite`, `Application Support`, `segmap`, `debug`, raw status codes, and interpolated `Error` / `NSError` values.

Errors go to `EngineLog` (redacted). The user gets a plain sentence and a next step.

macOS says **Click**, never *Tap*.

## Every failure must be visible

`LibraryModel.lastErrorMessage` was published, written in nine places, and rendered nowhere — so every pause / delete / priority / engine failure was silently swallowed. If you add a failure path, verify something on screen actually shows it.

Empty states must distinguish "nothing here yet" from "the engine isn't running". A cheerful empty hero shown when the engine is dead is a bug.

## Accessibility: label is *what*, value is *what it is now*

A changing quantity belongs in `accessibilityValue`, not baked into `accessibilityLabel`. `"Progress: 45%"` as a label gives VoiceOver nothing to announce on change; label `"Progress"` + value `"45%"` does.

Every `TextField` / `SecureField` needs an `.accessibilityLabel` — placeholder text is not a label, and three fields here share the placeholder "Display name".

Honour `accessibilityReduceMotion` for animation. Do not use it as an excuse to skip animation entirely — the progress ring must still read as continuous between polls.

## The UI polls; respect the cost

`LibraryModel` polls at 500 ms while a job is live and 5 s idle. Anything reacting to `rows` runs at that rate.

Observe `rowIdentitySignature` (id + state), not `rows`, for anything coarse — the menu bar rebuilt itself twice a second during downloads because `rows` changes on every progress tick.

Search is debounced through `searchQuery`; `searchText` is the raw field binding. Filter on `searchQuery`.

## Destructive actions

Confirm what is bulk or irreversible-on-disk. `Clear Failed` confirms with a count; `Delete File & Remove` confirms by name. `Remove from Library` is deliberately unconfirmed — it drops only the record and leaves the file.

There is no undo: removal deletes the row through XPC with no tombstone. Do not write copy that implies otherwise.
