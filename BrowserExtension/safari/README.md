# Safari Web Extension (developer mode only)

Safari will not load an **unsigned** extension for normal users. Distribution
requires Apple Developer Program signing (see ADR 0008). Flow’s default
community builds stay unsigned, so this companion is **not** a shipping gate.

## What this folder is

Instructions to convert the Chrome MV3 companion into a Safari Web Extension
for **local developer** experimentation. There is no committed Safari `.appex`
target in the XcodeGen project — that would imply a signed distribution path we
do not have.

## Convert from Chrome (local)

```bash
# Requires Xcode command-line tools. Regenerates a disposable Xcode project.
xcrun safari-web-extension-converter \
  BrowserExtension/chrome \
  --project-location /tmp/flow-safari-extension \
  --app-name "Flow Download Manager Safari" \
  --bundle-identifier org.downloadmanager.local.SafariExtension \
  --force
```

Then open the generated project, enable the extension under
**Safari → Settings → Extensions**, and point native messaging at the same
`ChromeNativeHost` Mach / host name used by Chrome
(`org.downloadmanager.local.ChromeNativeHost`) if your Safari build supports
the native-messaging bridge for that host.

## Native messaging on Safari

Safari’s native messaging story differs from Chrome’s. Until a signed app +
appex pair ships under Track B (Developer ID), treat Safari capture as
**unsupported for end users**. Prefer the Chrome extension or the macOS Share /
Compose sheet.

## Do not

- Claim “Safari extension available” in release notes for unsigned builds
- Commit signing identities or a notarized appex into this repository
- Block community releases on Safari packaging
