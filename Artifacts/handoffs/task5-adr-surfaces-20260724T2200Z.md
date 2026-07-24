# HANDOFF — TASK 5 ADR-bounded surfaces

**COMPLETE** for the community-path interpretation of HANDOFF TASK 5.
**NOT DONE (correctly blocked by ADR / credentials):** libtorrent download,
bundled yt-dlp binary fetch without checksummed manifests, Developer ID
notarization of a real DMG, shipping Safari appex.

Written 2026-07-24T2200Z. Local commits only — no push/release.

---

## What “OK” meant here

ADR 0006 / 0008 forbid stubs and forbid treating unsigned Safari / unpaid
notarization as shipping gates. Closing TASK 5 means wiring the **allowed**
surfaces and documenting the blocked ones so the next agent does not re-open
them as incomplete product work.

| Item | Done |
|---|---|
| Torrent | Compose inspects `.torrent` (TorrentCore in Presentation); magnets still rejected with clear copy |
| Media | `MediaSiteProbe` + Compose “Check with yt-dlp”; missing binary fails closed with UX |
| Signing | `Scripts/release/codesign.sh` + `make release-codesign` fail closed without `DM_CODESIGN_IDENTITY` |
| Notarize | existing script; checklist clarifies Track B fail-closed |
| Safari | `BrowserExtension/safari/README.md` — developer convert path only |
| Straggler preemption doc | marked **SUPERSEDED** by hedging |

---

## Gates

| lane | result |
|---|---|
| `verify-fast` | **350** unit, 0 fail |
| `test-integration` | **30**, 0 |

---

## Explicit non-goals still

- Linking libtorrent.a / magnet resolution
- Claiming Apple notarized or Safari extension for unsigned builds
- Implementing `straggler-preemption-design.md` preemption
