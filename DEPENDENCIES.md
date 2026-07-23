# Dependencies

This document is the authoritative dependency manifest for **Download Manager**
(native macOS 14.0+, Apple Silicon / arm64 only). It records every third-party
component and the exact terms under which it is used.

Project status: **Phase 1 in progress — Universal Transfer Release.** Phase 0
foundation remains; this document now also covers the pinned libcurl stack
introduced for transfer networking.

Scope of "shipped runtime dependency": a component whose code is distributed to
end users inside the signed, notarized product (linked, embedded, or bundled).
Build-time and developer tooling is listed separately and is **not** distributed.

## Shipped runtime dependencies

| Component | Version/commit | SPDX license | Source | Link relationship | Notes |
| --- | --- | --- | --- | --- | --- |
| GRDB.swift | 7.11.1 (exact pin) | MIT | https://github.com/groue/GRDB.swift | Static link via Swift Package Manager | Uses the system SQLite provided by macOS. |
| curl (libcurl) | 8.21.0 | curl | https://curl.se/download/curl-8.21.0.tar.xz | Static link (`VendorBuild/prefix/arm64`) | Built by `make vendor-libcurl`. SHA-256 `aa1b66a70eace83dc624508745646c08ae561de512ab403adffb93ac87fc72e6`. |
| OpenSSL | 3.5.1 | Apache-2.0 | https://github.com/openssl/openssl/releases/download/openssl-3.5.1/openssl-3.5.1.tar.gz | Static link into libcurl + libssh2 | TLS for libcurl; crypto for libssh2. Apple SecTrust enabled for OS trust store. SHA-256 `529043b15cffa5f36077a4d0af83f3de399807181d607441d734196d889b641f`. |
| nghttp2 | 1.66.0 | MIT | https://github.com/nghttp2/nghttp2/releases/download/v1.66.0/nghttp2-1.66.0.tar.xz | Static link into libcurl | HTTP/2. SHA-256 `00ba1bdf0ba2c74b2a4fe6c8b1069dc9d82f82608af24442d430df97c6f9e631`. |
| libssh2 | 1.11.1 | BSD-3-Clause | https://www.libssh2.org/download/libssh2-1.11.1.tar.gz | Static link into libcurl | SFTP. SHA-256 `d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7`. |

Authoritative pin file: `VendorBuild/manifests/libcurl.json`. Rebuild with
`make vendor-libcurl` (space-free cache under
`~/Library/Caches/DownloadManager/vendor`, then published to
`VendorBuild/prefix/arm64`). See ADR 0005.

Notes:

- The product does **not** use `/usr/bin/curl`, Homebrew curl, or URLSession as a
  transfer implementation.
- System zlib is linked (`-lz`); it is part of the OS and not vendored.

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

## Planned for later phases (NOT present yet)

- libtorrent
- yt-dlp / yt-dlp-ejs / Deno
- FFmpeg
- Sparkle

Until a component from this list appears in the **Shipped runtime dependencies**
table with a concrete version and license, it is not part of the product.
