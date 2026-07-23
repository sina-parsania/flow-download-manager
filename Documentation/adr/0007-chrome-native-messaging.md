# ADR 0007 — Chrome Native Messaging bridge

- Status: Accepted
- Date: 2026-07-23

## Context

Phase 2 requires a companion browser extension that can hand links to the local
download manager without giving the extension direct queue or filesystem access.

## Decision

1. Ship a Manifest V3 Chrome extension under `BrowserExtension/chrome/` that talks
   only to a signed native messaging host over stdio.
2. The host (`ChromeNativeHost`) speaks the versioned Native Messaging envelope
   (`SchemaVersions.nativeMessaging`) and forwards allowlisted commands to the
   engine over authenticated XPC with `ClientRole.nativeHost`.
3. The extension never opens sockets, writes partial files, or mutates the job DB.
4. Host registration is local-dev only until Developer ID signing replaces the
   `org.downloadmanager.local` identifiers.

## Consequences

- Agent allowlist must include `XPCClientIdentities.nativeHostBundleIdentifier`.
- Unpacked extension IDs must be substituted into the host manifest before Chrome
  will connect (`Scripts/install-chrome-native-host.sh`).
