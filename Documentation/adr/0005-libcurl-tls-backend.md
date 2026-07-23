# ADR 0005 — Pinned libcurl TLS backend (OpenSSL + Apple SecTrust)

Status: accepted (Phase 1)

## Context

Phase 1 requires a reproducible arm64 libcurl build that does not depend on
`/usr/bin/curl` or Homebrew. Historically the natural macOS choice was Secure
Transport. Upstream curl removed Secure Transport in 8.15.0; curl 8.21.0 (the
pinned version) no longer offers `--with-secure-transport`. Available TLS
backends are OpenSSL (and relatives), GnuTLS, mbedTLS, wolfSSL, rustls, Schannel,
and AmiSSL.

## Decision

- Pin **OpenSSL 3.5.1** as the libcurl TLS backend and as the crypto backend for
  libssh2 (SFTP).
- Enable **`--with-apple-sectrust`** so certificate verification uses the OS trust
  store on macOS.
- Keep nghttp2 and libssh2 as pinned static dependencies.
- Build in a space-free cache directory (libtool cannot install into paths that
  contain whitespace such as `/Volumes/T7 Shield/...`), then publish the prefix
  into `VendorBuild/prefix/arm64` via `ditto`.

## Consequences

- Runtime `curl_version_info` reports an OpenSSL SSL version string; tests assert
  that rather than “Secure Transport”.
- Link line includes `-lssl -lcrypto` plus Security/CoreFoundation/CoreServices/
  SystemConfiguration frameworks.
- `DEPENDENCIES.md` / `THIRD_PARTY_NOTICES.md` must list curl, OpenSSL, nghttp2,
  and libssh2 with exact pins and notices.
