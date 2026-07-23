# Changelog

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
