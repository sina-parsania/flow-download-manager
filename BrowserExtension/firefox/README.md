# Flow DM — Firefox companion

Only `manifest.json` lives here. The extension logic (`background.js`,
`popup.js`, `popup.html`, `icons/`) is **shared verbatim with the Chrome
companion** in `../chrome/` — Firefox aliases the `chrome.*` namespace, so the
same source runs on both. Keeping one copy is deliberate: `background.js`
validates cookie names and values before handing them to the native host, and
two drifting copies of that check is exactly the bug worth preventing.

Build a loadable directory with:

```bash
make browser-extension-firefox
```

That stages `../chrome/*` plus this manifest into
`.build/firefox-extension/`.

## What differs from the Chrome manifest

| | Chrome | Firefox |
|---|---|---|
| background | `service_worker` | `scripts` (event page) |
| extension id | derived from the unpacked directory path | fixed `browser_specific_settings.gecko.id` |
| host manifest key | `allowed_origins` (`chrome-extension://…`) | `allowed_extensions` (the gecko id) |
| host manifest directory | `…/Google/Chrome/NativeMessagingHosts` | `…/Mozilla/NativeMessagingHosts` |

## Install

```bash
make browser-extension-firefox
make install-firefox-native-host
```

Then open `about:debugging#/runtime/this-firefox` → **Load Temporary Add-on**
and pick `manifest.json` inside `.build/firefox-extension/`.

Temporary add-ons are removed when Firefox restarts. A permanently installed
build needs Mozilla signing, which — like the Safari companion — is out of
scope for unsigned community builds (ADR 0008).
