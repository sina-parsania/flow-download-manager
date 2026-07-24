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
  will connect (`Scripts/install-chrome-native-host.sh`). The script now derives
  that ID from the extension directory path the way Chrome does, so it is no
  longer pasted by hand.

## Amendment — 2026-07-24

Decision 2 assumed the host could always reach the engine's Mach service. It
cannot on the install we advertise: community builds run the engine as the
app-scoped XPC service in `Contents/XPCServices` (ADR 0008), and the app
*unregisters* the LaunchAgent when it heals onto that service, so the Mach name a
helper process would address does not exist. Browser integration was dead on
every `curl | bash` install.

Two further decisions:

5. **Hand-off fallback.** When XPC is unreachable the host opens the URLs in the
   app through the registered `downloadmanager://` scheme, which prefills the Add
   sheet. The download is never silently dropped, and the answer carries
   `route: "appHandoff"` so the extension can tell the user a click is still
   required. The app is addressed by its own bundle URL, never by asking
   LaunchServices who claims the scheme — that scheme is unauthenticated and any
   installed app can register for it.

   Rejected: connecting to the bundled service with `NSXPCConnection(serviceName:)`
   from the host. `ServiceType: Application` means launchd instantiates the service
   per client application, and a second engine instance would break the
   sole-writer rule on the database. Also rejected: making the URL scheme enqueue
   directly. Any process — including a web page's link — can invoke a custom
   scheme, so an auto-enqueueing scheme is an unauthenticated remote-download
   surface. Prefill plus an explicit click is the correct posture.

6. **Header channel, envelope version 2.** The envelope carries a `headers` array
   so `Referer` / `User-Agent` / `Cookie` survive the hand-off; without them any
   download behind a login saved a login page. Version 1 is still accepted and its
   `headers` are discarded, so an un-updated extension keeps working. Everything
   from the extension is untrusted: `NativeMessagingHeaderPolicy` allowlists the
   names, re-validates every pair through `HeaderValidator`, drops `Cookie` for a
   multi-URL batch (the engine applies one header set to the whole batch), and
   trims the encoded set to the `EnqueueBatchRequest` payload limit. Header values
   are never logged and never echoed back — only canonical names are.

   The custom-scheme fallback carries URLs only. Headers therefore do not reach a
   transfer on a community install unless Flow is already running; the response
   reports which names were dropped so the user is told rather than left with a
   saved login page.
