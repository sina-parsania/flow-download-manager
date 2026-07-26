# Changelog

## Unreleased

### Tooling
- Pin SwiftFormat to **0.59.1** via `Tools/bin` so CI cannot silently pick Homebrew 0.61+/0.62+ and fail `format-check`
- CI fast gate runs on **macos-15 / Xcode 16 only** (macos-14’s Xcode 15.4 cannot build Swift 6)

### Browser companion
- Forward `Origin` with single-URL handoffs (and drop it on cross-origin redirects) so session-bound attachment downloads that require a same-origin browser context can succeed when Cookies are enabled

## 0.3.3 — 2026-07-26

Community transfer/recovery hardening. Still **unsigned** (ADR 0008).

### Transfer & curl
- Cap ranged probes at one body byte; skip probe when Cookie / Authorization / cookie jar / fragile signed query would burn a one-shot download (cloud signed URLs still segment)
- Validate `Content-Range` before writing ranged bytes; reject ranged HTTP 200 and shifted/malformed intervals
- Reject structurally invalid `.segmap` coverage; restart no-range partials via sibling replacement without wiping recovery bytes
- Reset response metadata at redirect boundaries; origin-scope Cookie / Authorization / Referer; reject HTTPS→HTTP
- Cooperative cancel via opaque C11 atomic abort flag
- Deterministic fault-service `dropFirst=` loss schedule for recovery tests

### Persistence & recovery
- Typed `JobState` transitions at the sole-writer repository
- Crash-recoverable finalization intent (schema `v6`) so promotion after agent crash does not blindly re-download

### Tooling
- CI / Makefile always vendor pinned libcurl before DownloadKit-linked builds
- Incomplete-work scan covers `BrowserExtension`

## 0.3.2 — 2026-07-25

Community fix release. Still **unsigned** (ADR 0008).

### Fixes
- CDN / signed-link naming: use Content-Disposition + Content-Type from the first probe before choosing the on-disk name (no more `binary` / UUID filenames)
- MIME→extension for extensionless URLs (`video/mp4` → `.mp4`, `text/html` → `.html`)
- Classify `text/html` / `.html` as documents; `media-cdn.*` host hint → videos
- Promote/rename partial to the real title after transfer when needed
- Ignore weak query values (`dl=true`) and opaque CDN path tokens

## 0.3.1 — 2026-07-25

Community patch on Apple Silicon. Still **unsigned** (ADR 0008).

### Product
- Menu-bar agent: Flow lives in the menu bar (no Dock tile), single instance, Launch at Login
- Purple Flow mark in the menu bar status item
- Chrome companion: one-click Open Chrome with Companion, native-host path hardening, extension icons
- Compose / library handoff: one window — Chrome links merge into the open Compose sheet

### Packaging & tooling
- Agent skills for local build-and-fix and community release (`/.cursor/skills/`)

## 0.3.0 — 2026-07-25

Community Flow release on Apple Silicon. Still **unsigned** (ADR 0008); Gatekeeper
bypass documented in `Documentation/install-from-github.md`.

### Transfer engine
- Resilient segmented transfers: validator-bound resume (no silent stitch of changed resources), stall-aware retry budget, jittered backoff, AIMD-from-ceiling concurrency
- Hedged tail with cancel of the losing replica (`DMCurlEasyDownloadRequestStop`)
- Curl multi refill + CURLSH DNS/SSL sharing; faster dead-slot recovery (keepalive / tighter timeouts)
- Fair-share per-host sockets across concurrent downloads
- Fault-server RTT / loss fixtures and throughput curves that assert relationships, not wall-clock constants
- `performance-compare` extracts real XCTest metrics from xcresult (no empty `"metrics": {}`)

### Product
- Per-host settings (connections, speed, user-agent, credentials) — Settings UI + XPC; per-job options still win
- App Intents for enqueue / list / pause / resume
- Compose: `.torrent` metadata inspection; optional yt-dlp page probe when a VendorBuild helper is present
- Chrome native-messaging hardening (headers / cookies / host handoff)
- Library UX: board pins, destination card, citrus list chrome, taller rows, column sorting, multi-select toolbar actions, modal job details (double-click / Info), filename ellipsis, speed / remaining-time smoothing
- Change-aware Library delivery (`pullJobChanges` / capability `jobChanges`): one full `listJobs`, then coalesced deltas; gap → full refresh; N-1 agents keep polling
- Surface download Size and Time remaining from `totalBytes`

### Updates (Sparkle)
- Sparkle 2.9.4 in-app updates: **Check for Updates…** is manual by default; automatic check / download are Settings opt-ins (off by default)
- Feed: `docs/appcast.xml` on `main` (`SUFeedURL`); until the feed is published, Check for Updates shows a local “You’re up to date” alert instead of Sparkle’s retrieval error
- Helper: `Scripts/release/sparkle-appcast.sh` (EdDSA private key stays in the maintainer Keychain)

### Packaging & docs
- Fail-closed `make release-codesign` without `DM_CODESIGN_IDENTITY`; notarize remains Track B
- Safari companion documented as developer-only (`BrowserExtension/safari/`)
- Straggler-preemption design marked superseded by hedging

## 0.2.0 — 2026-07-24

Community-stable Flow release for daily Apple Silicon use.

- **Flow Download Manager** branding (Dock / About / Settings)
- Board-first SwiftUI UI (pins, inspector, projects & tags, destination card)
- Reliable segmented resume via `.segmap` (no more “restart from 0” after relaunch)
- Ad-hoc engine hosting via bundled **XPC service** (macOS 26-safe; replaces broken endpoint-file handshake)
- Category auto-hints, rename, library-only vs delete-files remove
- One-line terminal installer: `Scripts/install.sh`
- Unsigned DMG ships as **Flow Download Manager.app**

## 0.1.0 — 2026-07-23

First community GitHub release (unsigned; not Apple notarized).

- Phase 1 universal transfer stack (pinned libcurl, queue, Settings, recovery)
- Phase 2 Chrome MV3 companion + embedded `ChromeNativeHost`
- Phase 3 media isolation + yt-dlp JSON probe hooks (binaries optional)
- Phase 4 torrent bencode inspection + metalink parser (no libtorrent yet)
- Phase 5 unsigned DMG / SBOM packaging; Developer ID optional (ADR 0008)

See `Documentation/install-from-github.md` for Gatekeeper install steps.
