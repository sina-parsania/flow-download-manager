# Install from GitHub (no Apple Developer ID)

Download Manager is **GPL-3.0-or-later** and ships for free from GitHub. Builds are
**not** Developer ID–signed or notarized. That matches many open-source macOS
apps: Gatekeeper may warn once; you can still run the app.

## Option A — Build from source (recommended)

On an Apple Silicon Mac with Xcode 15+:

```bash
git clone https://github.com/<owner>/flow-download-manager.git
cd flow-download-manager
make bootstrap-tools
make verify-fast
open DownloadManager.xcodeproj   # or: make build-debug
```

Run the Debug/Release app from Xcode, or from DerivedData products.

## Option B — Unsigned DMG from a GitHub Release

1. Download `DownloadManager-*-unsigned.dmg` from Releases.
2. Open the DMG and drag **Download Manager** to Applications.
3. First launch — if macOS says the app can’t be opened:
   - Finder → Applications → **Control-click** the app → **Open** → **Open**
   - Or clear quarantine in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Download Manager.app"
```

(Exact `.app` name may be `DownloadManager.app` depending on the build.)

4. Chrome companion: load `BrowserExtension/chrome` unpacked and run
   `DM_CHROME_EXTENSION_ID=… make install-chrome-native-host` (see that folder’s README).

## What you do **not** need

- A paid Apple Developer Program membership  
- Notarization  
- Mac App Store  

## Security note

Prefer building from a reviewed commit, or verify Release checksums when published.
Unsigned binaries trust the GitHub release publisher and your download path.
