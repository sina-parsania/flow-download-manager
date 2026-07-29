# COMPLETE — slices 2 and 3: yt-dlp reachability + the m3u8 leak

Two correctness defects in the media path, both of which made already-built
machinery either unreachable or actively wrong. Committed on `feat/rnd-slices`;
**not pushed** (RULE 3 — push is a separate authorization).

## Evidence

```
make verify-fast       500 tests, 0 failures — incomplete-work-scan: clean — verify-fast: OK
make test-integration   62 tests, 0 failures — ** TEST SUCCEEDED **
```

Unit 482 → 500. `test-recovery` / `test-asan` / `test-tsan` / `test-performance`
not required and deliberately not claimed: neither slice touches a partial file,
C, shared mutable state, or the transfer hot path. Both are pure resolution and
classification policy above the engine.

## Slice 3 — the m3u8 leak (shipped first, it is the smaller and more urgent)

A muxed HLS rendition reports real `vcodec` **and** `acodec`, so the codec-only
`isProgressive` check called it downloadable — while its URL is a `.m3u8`
playlist. curl would have written a few kilobytes of text named like a video.
DASH behaved identically.

The `protocol` field is what actually separates a stream from a file and it was
not being read at all. `YtdlpFormat.isSegmentedDelivery` now rejects anything
that is not `https`/`http`/`ftps`/`ftp`, falling back to the URL extension
(`.m3u8`/`.m3u`/`.mpd`/`.ism`, parsed as a *path* so a query string cannot hide
it) when an extractor omits the field.

The top-level `directURL` fallback needed the same guard repeated — it bypasses
the formats filter entirely because it has no codec information to judge.

**This was a RULE 2 case.** The `httpURL` doc comment claimed it screened out
m3u8 URLs. It only ever caught the literal `m3u8://` pseudo-scheme; a real HLS
rendition is served from an ordinary `https://…/720p.m3u8` and passed straight
through. The comment described a check the code did not perform, and that is
exactly why the leak existed. The comment is now corrected to say what it
actually does and to point at what does the real work.

Mutation-tested: reverting `isProgressive` to the codec-only check fails three
new tests, each printing a real manifest URL escaping to the engine. Ordinary
progressive downloads are unaffected, and a page offering both a stream and a
real file still resolves to the file.

## Slice 2 — yt-dlp reachable from a shipped build

`vendorMediaExecutable` resolved from `FileManager.currentDirectoryPath`. That
is the repo root only when launched from a shell inside the repo; a
GUI-launched app has cwd `/`, so the candidate was literally
`/VendorBuild/prefix/arm64/media/bin/yt-dlp`. Every released build resolved
`nil`, the probe button was permanently disabled, and the whole media chain —
probe, DRM policy, resolution, queueing — was unreachable by any user.

`MediaHelperLocator` resolves **bundled → user-chosen → discovered**. The broken
cwd-relative resolver is deleted rather than left available; it had no other
callers.

### Provenance is the security property

This type decides which binary Flow executes, so where the path came from
matters more than whether it exists.

- `media.ytdlpPath` is written by exactly **one** code path: the `NSOpenPanel`
  in Settings. Never from the native messaging host, the clipboard monitor, a
  dropped file, a URL, or any XPC payload. Flow already accepts external input
  on a native messaging channel, so this is a live surface, not a hypothetical.
- Auto-discovery is limited to `/opt/homebrew/bin` and `/usr/local/bin`, and
  rejects any candidate that is group- or world-writable — checking the **parent
  directory as well as the file**, because a writable directory defeats a
  locked-down binary. `/usr/local/bin` is frequently user-writable on a migrated
  Mac, which is the case that motivated the check.
- The resolved path is shown in Settings before it is ever run, with its source
  named, so a discovered binary is inspectable rather than magic.

### Tests

First coverage this resolver has ever had, including one that pins the actual
defect: resolution must return the same answer with the working directory set to
`/` as anywhere else. That test would have caught the original bug, and no
existing test could have — under `swift test` the cwd happens to be the repo
root, which is exactly why it went unnoticed.

## NOT done

- **Not pushed.** Committed locally on `feat/rnd-slices` only.
- **Bundling a helper inside the .app** — left absent, not stubbed. The
  VendorBuild manifest still has a null download URL and no checksum, and
  shipping an unpinned binary is a separate decision. `bundledExecutable` exists
  and is preferred by resolution, so bundling later needs no change here.
- **Full HLS/DASH download support.** Slice 3 only stops the leak. Actually
  downloading a stream needs a manifest parser, a segment fetcher, a new on-disk
  ledger and a concat step — the L-sized slice at the end of the plan.
- **`ffmpeg`** — untouched. Adaptive streams still cannot be joined.
