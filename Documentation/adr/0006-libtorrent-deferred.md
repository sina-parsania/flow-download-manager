# ADR 0006 — libtorrent integration deferred to capability-complete pin

## Status
Accepted for Phase 4 scaffolding (2026-07-23).

## Context
Phase 4 requires BitTorrent via libtorrent. Shipping an incomplete Swift FFI
wrapper would violate the repository rule that in-scope work is complete and
out-of-scope work is absent.

## Decision
1. Land a complete pure-Swift bencode metadata reader (`TorrentCore`) for
   `.torrent` inspection and path safety checks.
2. Defer libtorrent.a linking, DHT/PEX/LSD, and magnet resolution until a pinned
   reproducible VendorBuild recipe + license/CVE review lands in a dedicated
   commit.
3. Magnets remain unsupported in the ingestion UI (Phase 1 behavior).

## Consequences
Users can inspect torrent file lists locally; they cannot download torrents
until the VendorBuild pin ships. No stub session types are exposed in the UI.
