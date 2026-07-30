## Flow 0.4.0

**Upgrading applies schema v8.** Your downloads are untouched and keep their current location, but an older build cannot open the migrated database.

### Fixed

- **Speed limits now apply in aggregate** — the global and per-host limits were applied per transfer, so several downloads at once each ran at the full rate you set
- **Video pages work in a released build** — the yt-dlp helper was never found by an installed copy
- **Streaming pages no longer download as a few kilobytes of playlist text**

### New

- **Create category folders** (Settings) — sort each download into a folder named for its category. Off by default; affects new downloads only
- **Filter and search by project or tag** in the sidebar and search field
- **Quick Look** a finished download from the board
- **Numbered ranges** — `img[001-010].jpg` becomes ten links
- Resolve a video page to a direct link and queue it
- **Firefox** companion extension

Community build — not Apple notarized.
