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
| `--tag v0.2.0` | Pin a release tag |
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

## Option C — Build from source

```bash
git clone https://github.com/sina-parsania/flow-download-manager.git
cd flow-download-manager
make bootstrap-tools
make verify-fast
open .build/DerivedData/Build/Products/Debug/DownloadManager.app
```

## Chrome companion

Load `BrowserExtension/chrome` as an unpacked extension, then:

```bash
DM_CHROME_EXTENSION_ID=… make install-chrome-native-host
```

## What you do **not** need

- A paid Apple Developer Program membership  
- Notarization  
- Mac App Store  

## Security note

Prefer verifying `*.dmg.sha256` from the Release, or build from a reviewed commit.
Unsigned binaries trust the GitHub release publisher and your download path.
