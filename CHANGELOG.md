# Changelog

## Unreleased

## 0.4.5 — 2026-08-02

Speed release. If your downloads from a site were stuck around 1 MB/s while other
download managers were much faster, this is the one that fixes it.

### Fixed
- **Downloads from sites with signed links no longer run on a single connection.** A link carrying a `sig=` or expiring signature — most streaming and file-host links — made Flow give up on splitting the download entirely and fetch it through one connection. On a high-latency connection a single stream tops out around 1 MB/s no matter how fast your line is, which is exactly the cap people were hitting. Those downloads now split across connections like any other
- **A cached response from a CDN no longer disables splitting.** Content delivery networks answer the first request differently depending on whether the file is already cached near you. Flow read one of those answers as "this server does not support splitting" and stayed on one connection for the rest of the download
- **Resuming after a bad connection actually works.** When a download hit trouble and Flow re-divided the remaining work, it wrote a progress map it could not read back. The download finished fine, but if you quit and reopened, Flow silently started that file again from zero
- **The speed shown while a download is stalled.** When a connection went quiet, Flow kept displaying the last speed it managed — sometimes for a minute — instead of showing the transfer slowing to nothing
- **Servers asking you to wait are now obeyed.** When a site responds "too many requests, retry in N seconds", Flow waits the requested time instead of guessing its own, which stops it burning retry attempts by coming back too early

### Changed
- **Flow now finds the right number of connections for each site by itself.** It starts conservatively and adds connections while they measurably help, then stops. The best number turns out to differ a lot between sites — one may be at its fastest with 8, another with 20 — so a single fixed setting was always wrong somewhere. Measured across two sites, 24–45% faster than the previous fixed count
- **What it learns is remembered per site for a week**, so a queue of files from the same place does not spend the first half-minute of every item working it out again
- A site setting you enter yourself in Settings still wins over all of this

### Note
Still **unsigned** (ADR 0008) — expect the usual Gatekeeper warning on first launch.

## 0.4.2 — 2026-07-30

### Fixed
- **Check for Updates actually works.** Since 0.3.5 every update check failed with "An error occurred in retrieving update information". Flow was downloading the update feed itself and handing Sparkle a local file, which Sparkle refuses to accept — so the check failed no matter what the feed contained. If you are on 0.4.1 or earlier you will need to install this one manually; after that, in-app updates work

## 0.4.1 — 2026-07-30

### Fixed
- **Downloads get the right file extension.** A link like `getfile.jsp?fileid=…` serving a disk image was saved as `getfile.jsp`, which Finder refuses to open. Extensions now come from macOS's own type database instead of a short hand-written list, so disk images, installers, archives and office documents all land with the extension they should have
- **Check for Updates works again.** The update feed pointed at a release-notes file that is never published, so Sparkle reported "An error occurred in retrieving update information" even though the update itself was fine

## 0.4.0 — 2026-07-29

Community release. Still **unsigned** (ADR 0008).

Upgrading applies schema `v8`. Existing downloads are untouched and keep their
current location; a database migrated to v8 cannot be opened by an older build.

### Fixed
- **Speed limits are now enforced in aggregate.** The global and per-host limits were applied per transfer, so several concurrent downloads each ran at the full configured rate — actual throughput reached up to 5× the number you set
- **Video pages work in a released build.** The yt-dlp helper was resolved relative to the working directory, which is `/` for a launched app, so the probe never found it and the button stayed disabled
- Streaming pages (HLS/DASH) are no longer mistaken for downloadable files — a `.m3u8` or `.mpd` link produced a few kilobytes of playlist text named like a video

### Library
- **Create category folders** (Settings): sorts each download into a folder named for its category inside your download folder (schema `v8`). Off by default; affects new downloads only, and a download that has started keeps the folder it began in
- Fixed: after a crash, finalization looked for the partial file in the parent of a job's category folder
- Fixed: every state change rewrote the Location column back to the parent folder

### Media pages
- Resolve a video page to a direct link and queue it, with the site's own headers forwarded. Copy-protected and live pages are still refused, and pages that only offer separate audio and video are reported as such
- Choose the yt-dlp helper in Settings → Media pages; Flow also finds a Homebrew install, but never runs a binary that other local users could replace

### Browser companion
- Firefox extension, sharing the Chrome extension's source. Temporary add-on only — a permanent install needs Mozilla signing (ADR 0008)

### Internal
- Adding an XPC RPC is now guarded by a contract-drift test
- Mutation records for XPC mutations can no longer be forgotten by a new handler

## 0.3.5 — 2026-07-27

Community patch. Still **unsigned** (ADR 0008).

### Updates (Sparkle)
- Fix in-app updates: download a fresh appcast (no stale HTTP/bundled cache), then hand Sparkle a local feed file
- Re-sign Sparkle release zips with the full ad-hoc pipeline so EdDSA validation succeeds

## 0.3.4 — 2026-07-27

Community library UX release. Still **unsigned** (ADR 0008).

### Library
- Persist per-job destination path, start/finish timestamps, and final filename (schema `v7`)
- Table columns **Started**, **Finished**, and **Location** (sortable)
- **Open in Finder** uses each job’s stored path instead of the global default folder alone
- **Open File** for completed downloads (context menu, board, inspector)

### Tooling
- Pin SwiftFormat to **0.59.1** and SwiftLint to **0.57.1** via sha256-verified `Tools/bin` binaries (`Scripts/run-swiftformat.sh` / `Scripts/lint.sh`) so CI images that preinstall Homebrew 0.62+/0.65 cannot hijack the gate
- SwiftLint `only_rules` limited to the safety set (force_*/empty_count/…); metric defaults like `file_length` are not part of this project's lint gate
- CI fast gate runs on **macos-15 / Xcode 16 only** (macos-14’s Xcode 15.4 cannot build Swift 6)
- `make format` passes `--format` to the pinned SwiftFormat wrapper

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
