# Install Flow Download Manager

Flow is **GPL-3.0-or-later** and ships for free from GitHub. Community builds are
**not** Developer ID–signed or Apple-notarized ([ADR 0008](adr/0008-community-github-distribution.md)).
Gatekeeper may warn once; that is expected.

## Option A — Terminal (recommended)

Apple Silicon · macOS 14+:

```bash
curl -fsSL https://raw.githubusercontent.com/sina-parsania/flow-download-manager/main/Scripts/install.sh | bash
```

What it does:

1. Fetches the latest (or `--tag`) unsigned Release DMG
2. Verifies the published SHA-256 when available
3. Installs **Flow Download Manager.app** to `~/Applications` (or `/Applications` with `--system`)
4. Clears `com.apple.quarantine`
5. Launches Flow (unless `--no-open`)

Useful flags:

| Flag | Effect |
| --- | --- |
| `--system` | Install to `/Applications` (may need admin) |
| `--tag v0.3.0` | Pin a release tag |
| `--dir ~/Apps` | Custom install parent directory |
| `--no-open` | Install only |
| `--dmg /path/to.dmg` | Install from a local DMG (skip download) |

Re-run the same command to upgrade.

## Option B — GitHub Release DMG (Finder)

1. Open [Releases](https://github.com/sina-parsania/flow-download-manager/releases) and download `DownloadManager-*-unsigned.dmg`.
2. Open the DMG and drag **Flow Download Manager** to Applications.
3. First launch — if macOS blocks the app:
   - Finder → Control-click the app → **Open** → **Open**
   - Or:

```bash
xattr -dr com.apple.quarantine "$HOME/Applications/Flow Download Manager.app"
```

## Option C — Homebrew cask

> Not published yet. The cask source lives at
> [`Scripts/release/homebrew/Casks/flow-download-manager.rb`](../Scripts/release/homebrew/Casks/flow-download-manager.rb);
> the tap below does not exist until a maintainer creates it (see
> [Publishing the cask](#publishing-the-cask)).

```bash
brew tap sina-parsania/flow
brew install --cask --no-quarantine flow-download-manager
```

`--no-quarantine` is what makes the first launch work without the Finder dance:
community builds are ad-hoc signed, not notarized, so Homebrew's default
quarantine flag would leave the app blocked. Drop the flag if you would rather
approve the app yourself, then clear it after install:

```bash
xattr -dr com.apple.quarantine "/Applications/Flow Download Manager.app"
```

`brew uninstall --cask flow-download-manager` removes the app and stops the
background engine; add `--zap` to also delete the download library, preferences
and the Chrome host manifest.

### Publishing the cask

Nothing in this repository publishes anything. A maintainer has to:

1. Create a public repo named `homebrew-flow` under the `sina-parsania` account
   (that name is what makes `brew tap sina-parsania/flow` work).
2. Copy `Scripts/release/homebrew/Casks/flow-download-manager.rb` to `Casks/`
   in that repo.
3. Per release: set `version`, then set `sha256` to the value in the published
   `DownloadManager-<version>-unsigned.dmg.sha256` asset — checked against the
   asset actually attached to the GitHub Release, not a local build.
4. Verify before pushing:
   `brew audit --cask --new --online Casks/flow-download-manager.rb` and
   `brew install --cask --no-quarantine ./Casks/flow-download-manager.rb`.

The cask is a third-party tap on purpose. `homebrew/cask` proper requires a
signed, notarized artifact, which ADR 0008 deliberately does not produce.

## Option D — Build from source

```bash
git clone https://github.com/sina-parsania/flow-download-manager.git
cd flow-download-manager
make bootstrap-tools
make verify-fast
open .build/DerivedData/Build/Products/Debug/DownloadManager.app
```

## Chrome companion

The companion extension hands links to Flow through a native messaging host
embedded in the app bundle. Register the host manifest from a source checkout:

```bash
Scripts/install-chrome-native-host.sh
```

It finds the host inside an installed **Flow Download Manager.app** (or a local
build), derives the unpacked extension ID from the extension directory the same
way Chrome does, and writes the manifest for every Chromium-family browser it
finds. Then load `BrowserExtension/chrome` at `chrome://extensions` →
Developer mode → **Load unpacked**.

If Chrome shows a different extension ID than the script printed, re-run it with
`DM_CHROME_EXTENSION_ID=<that id>`.

### What the extension sends

Downloads behind a login need the request context the browser would have sent, so
the companion attaches `Referer` and `User-Agent` to every hand-off, and — only
after you enable **Send sign-in cookies** in the popup and grant the permission
Chrome asks for — a `Cookie` header for a single link. Cookies are never attached
to a multi-link selection, because Flow applies one header set to the whole batch
and that would replay one site's session against every other host in the list.

### If the background engine is off

On a community install the engine runs as a service inside the app bundle, which a
browser helper cannot address directly. When the companion cannot reach it, it
opens the links in Flow's **Add** sheet instead of dropping them, and says so —
the toolbar badge turns amber and the popup tells you to click **Add** in Flow.
Sign-in cookies are deliberately *not* carried on that path: a custom-scheme URL
is handed to macOS and recorded, and a session cookie has no business in one. For
authenticated downloads, start Flow first so the direct path is available.

## What you do **not** need

- A paid Apple Developer Program membership  
- Notarization  
- Mac App Store  

## Security note

Prefer verifying `*.dmg.sha256` from the Release, or build from a reviewed commit.
Unsigned binaries trust the GitHub release publisher and your download path.
