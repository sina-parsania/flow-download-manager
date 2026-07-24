# Chrome Companion Extension (Phase 2)

Manifest V3 extension that sends URLs to the local `ChromeNativeHost` over
Chrome Native Messaging. The host enqueues through authenticated XPC; the
extension never touches the queue database or partial files.

## Local load (developers)

Prefer **Settings → Browser companion → Set Up Chrome Companion…** in a running
Flow build. That path works for end users without a source checkout.

Manual / script path:

1. Install Flow (`Documentation/install-from-github.md`) or build the
   **DownloadManager** app, which embeds `ChromeNativeHost` in `Contents/MacOS/`.
2. Register the host manifest — the script finds the app and derives this
   directory's unpacked extension ID the same way Chrome does:

```bash
Scripts/install-chrome-native-host.sh
```

3. Open `chrome://extensions`, enable Developer mode, **Load unpacked** → this
   `chrome/` directory. If Chrome shows a different ID than the script printed,
   re-run it with `DM_CHROME_EXTENSION_ID=<that id>`.
4. Use popup **Check native host**, context menus (link / page / selection), or
   optional download takeover (off by default).

## Wire protocol

Envelope version **2** (`NativeMessagingProtocol.currentVersion`). Version 1 is
still accepted by the host, and this extension retries at version 1 if it meets an
older host, so the two can be updated independently.

Version 2 adds `headers`, an array of `{name, value}`. The extension sends
`Referer` and `User-Agent` on every request. `Cookie` is sent only when

- the popup's **Send sign-in cookies** toggle is on, and
- Chrome has granted the optional `cookies` + `<all_urls>` permission, and
- the request carries exactly one URL.

The host allowlists header names, revalidates every pair, and drops `Cookie`
outright for a multi-URL batch — the engine applies one header set to the whole
batch, so a mixed batch would replay one site's session against every other host.

## Badge states

| Badge | Meaning |
| --- | --- |
| none | Queued by the engine |
| amber `…` | Flow's engine was unreachable; links were opened in Flow's Add sheet and need a click. Sign-in cookies were not carried over. |
| red `!` | Flow could not be reached at all; nothing was accepted |
