## Flow 0.4.5


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


Community build — not Apple notarized.
