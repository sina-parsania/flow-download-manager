# Dependencies

This document is the authoritative dependency manifest for **Download Manager**
(native macOS 14.0+, Apple Silicon / arm64 only). It records every third-party
component and the exact terms under which it is used.

Project status: **Phase 0 — repository foundation.** No shipping user download
features exist yet. The lists below reflect what is actually present in the
Phase 0 build, not future intent.

Scope of "shipped runtime dependency": a component whose code is distributed to
end users inside the signed, notarized product (linked, embedded, or bundled).
Build-time and developer tooling is listed separately and is **not** distributed.

## Shipped runtime dependencies (Phase 0)

Phase 0 ships **exactly one** third-party runtime dependency.

| Component | Version/commit | SPDX license | Source | Link relationship | Notes |
| --- | --- | --- | --- | --- | --- |
| GRDB.swift | 7.11.1 (exact pin) | MIT | https://github.com/groue/GRDB.swift | Static link via Swift Package Manager | Uses the system SQLite provided by macOS. No bundled native SQLite is included, and no additional transitive native libraries are introduced. Upstream maintainers own security/CVE review for this component. |

Notes on the pin:

- The version is pinned exactly (`7.11.1`), not a range, so the shipped build is
  reproducible.
- GRDB links against the SQLite that ships with macOS; the product does not
  vendor, compile, or bundle its own copy of SQLite or any other C library
  through this dependency.

## Developer-only tools (NOT shipped in the product)

These tools support building, formatting, and linting the source. They run on
developer and CI machines only. **None of them are linked, embedded, bundled, or
otherwise distributed** in the signed product, and none of their code reaches end
users.

They are installed via Homebrew by `make bootstrap-tools`.

| Tool | Role | Distributed in product? |
| --- | --- | --- |
| XcodeGen | Generates the Xcode project from configuration | No — build-time only |
| SwiftFormat | Source code formatting | No — build-time only |
| SwiftLint | Static lint / style enforcement | No — build-time only |

Because these are developer tooling and not part of the shipped artifact, their
versions are managed by the local Homebrew installation rather than pinned into
the product's runtime manifest above.

## Planned for later phases (NOT present in Phase 0)

The following components are anticipated for later phases of the product. They
are **absent from the current (Phase 0) build** — not linked, embedded, bundled,
downloaded, or otherwise distributed today.

Each will be introduced only in its respective phase, and only accompanied by a
full manifest entry covering exact source, build/link relationship, exact version
pin, and SPDX license terms. No version is asserted here, because none is fixed
yet.

- libcurl
- libtorrent
- yt-dlp
- yt-dlp-ejs
- Deno
- FFmpeg
- Sparkle

Until a component from this list appears in the **Shipped runtime dependencies**
table with a concrete version and license, it is not part of the product.
