# Changelog

## Unreleased

Nothing yet — next changes land here after `0.3.0`.

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
