---
name: build-and-fix
description: >-
  Builds Flow Download Manager (Debug or installable app), diagnoses compile/link
  failures, and fixes them until the build is green. Use when the user asks for a
  new build, build and install, بیلد جدید, make build-debug fails, or "fix the build".
---

# build-and-fix

Get a working Flow binary. Prefer fixing root causes over weakening gates
(no `try!`, no silenced warnings, no skipped tests).

## 0. Preconditions

```bash
git status --short
git diff --stat
```

- Dirty tree from another session → say so before claiming the build.
- After `project.yml` edits → `make project` first (`.xcodeproj` is generated).
- Needs `all` / unrestricted permissions for xcodebuild, `/Applications` install,
  and quitting a running app.

## 1. Quit stale apps

```bash
pkill -f "Flow Download Manager.app/Contents/MacOS/DownloadManager" 2>/dev/null || true
pkill -f "/DownloadManager.app/Contents/MacOS/DownloadManager" 2>/dev/null || true
sleep 1
```

## 2. Choose the build path

| User intent | Command |
|---|---|
| Fast compile check / inner loop | `make build-debug` |
| "بیلد جدید" / install & run locally | Debug → copy to `/Applications` (below) |
| Release DMG artifact | Use **release-flow** skill (`make release-dmg-unsigned`) |
| After source/layout changes | `make project` then build |

Prefer a dedicated DerivedData path so install is deterministic:

```bash
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/FlowDM-Build"
xcodebuild -project DownloadManager.xcodeproj -scheme DownloadManager \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath "$DERIVED" build
```

If `make project` / XcodeGen fights locked entitlements mid-iteration, build with
the **existing** `DownloadManager.xcodeproj` and regenerate once the tree is quiet.

## 3. On failure — diagnose, then fix

1. Capture the log (`tee /tmp/flow-build.log`).
2. Extract real errors (not the truncated `tail`):

```bash
rg -n "error:" /tmp/flow-build.log | head -80
```

3. Fix in order:
   - Missing file in `project.yml` → edit yaml → `make project` → rebuild
   - Swift 6 concurrency (`main actor-isolated … nonisolated`) → mark pure
     constants `nonisolated static let`, or hop to `@MainActor` / pass values in
   - SwiftFormat / SwiftLint (`docComments`, `redundantSelf`) → fix before rebuild
   - C / curl / link → also plan `make test-asan` after green (do not stop at compile)

4. Rebuild. Loop until **BUILD SUCCEEDED**. Never disable warnings-as-errors.

### Known failure modes in this repo

- `Configuration/DownloadManager.entitlements` deleted/missing → restore from git
  (`git checkout HEAD -- Configuration/DownloadManager.entitlements`)
- `@MainActor` class statics used from `nonisolated` helpers → mark constants
  `nonisolated static let`
- Deprecated `activate(options: [.activateIgnoringOtherApps])` → `activate()`
  (warnings-as-errors)
- `.alert` on `MenuBarExtra` → attach alerts to the `Window` / Settings content only

## 4. Install for local testing (optional)

When the user wants a runnable app (not just CI green):

```bash
APP_SRC="$DERIVED/Build/Products/Debug/DownloadManager.app"
APP_DST="/Applications/Flow Download Manager.app"
rm -rf "$APP_DST"
ditto "$APP_SRC" "$APP_DST"
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true
# Ad-hoc re-seal so Gatekeeper / Sparkle nested code stays consistent
codesign --force --deep --sign - "$APP_DST" 2>/dev/null || true
open "$APP_DST"
```

Verify post-install:

- Menu-bar only (`LSUIElement` + accessory) — no Dock tile
- One process (`SingleInstanceGuard`)
- Version / binary mtime matches this build

## 5. After a green build — scope tests

Compile-green ≠ done for transfer/XPC/C. Follow `.claude/skills/verify-scope/SKILL.md`:

| changed | also run |
|---|---|
| Presentation / App only | `make verify-fast` (or at least unit) |
| Engine / Persistence / XPC | + `make test-integration` (+ recovery) |
| CCurl / handle lifetime | + `make test-asan` |
| concurrency / shared state | + `make test-tsan` |

## 6. Report

State: configuration, DerivedData path, install path (if any), first failing
error (if fixed), lanes still **not** run. Do not imply release-ready from Debug alone.
