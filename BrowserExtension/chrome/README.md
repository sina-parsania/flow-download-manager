# Chrome Companion Extension (Phase 2)

Manifest V3 extension that sends URLs to the local `ChromeNativeHost` over
Chrome Native Messaging. The host enqueues through authenticated XPC; the
extension never touches the queue database or partial files.

## Local load

1. Build the **DownloadManager** app (embeds `ChromeNativeHost` in `Contents/MacOS/`).
2. Open `chrome://extensions`, enable Developer mode, **Load unpacked** → this `chrome/` directory.
3. Copy the extension ID, then:

```bash
DM_CHROME_EXTENSION_ID=<id> make install-chrome-native-host
```

4. Use popup **Check native host**, context menus (link / page / selection), or optional download takeover (off by default).
