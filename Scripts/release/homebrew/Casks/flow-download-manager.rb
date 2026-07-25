# SPDX-License-Identifier: GPL-3.0-or-later
#
# Homebrew cask for the community (unsigned) Flow Download Manager DMG.
#
# This file is the source of truth for a tap that a maintainer publishes
# separately; nothing here creates or pushes a repository. See
# Documentation/install-from-github.md for the tap-and-install steps and for what
# has to be done by hand at release time.
#
# The artifact is built by Scripts/release/build-dmg.sh, which stages the app as
# "Flow Download Manager.app" and names the image
# DownloadManager-<version>-unsigned.dmg.
cask "flow-download-manager" do
  version "0.3.1"
  sha256 "3bb7598c9904cb4dd7c990102bd193d45c1d8a81379c6d77fd3f698df753f827"

  url "https://github.com/sina-parsania/flow-download-manager/releases/download/v#{version}/DownloadManager-#{version}-unsigned.dmg",
      verified: "github.com/sina-parsania/flow-download-manager/"
  name "Flow Download Manager"
  desc "Download manager with segmented transfers and a browser companion"
  homepage "https://github.com/sina-parsania/flow-download-manager"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Apple Silicon only, macOS 14 or newer (project.yml deploymentTarget).
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Flow Download Manager.app"

  uninstall quit:      "org.downloadmanager.local.DownloadManager",
            launchctl: "org.downloadmanager.local.DownloadEngineAgent"

  zap trash: [
    "~/Library/Application Support/Google/Chrome/NativeMessagingHosts/org.downloadmanager.local.chrome_native_host.json",
    "~/Library/Application Support/org.downloadmanager.local.DownloadEngineAgent",
    "~/Library/Caches/org.downloadmanager.local.DownloadManager",
    "~/Library/HTTPStorages/org.downloadmanager.local.DownloadManager",
    "~/Library/LaunchAgents/org.downloadmanager.local.DownloadEngineAgent.plist",
    "~/Library/Preferences/org.downloadmanager.local.DownloadManager.plist",
    "~/Library/Saved Application State/org.downloadmanager.local.DownloadManager.savedState",
  ]

  caveats <<~EOS
    This build is NOT Developer ID signed and NOT Apple notarized. It is an
    ad-hoc signed community build (ADR 0008), so macOS quarantines it and the
    first launch is blocked until you allow it.

    Either install without the quarantine flag:

      brew install --cask --no-quarantine flow-download-manager

    or clear it afterwards:

      xattr -dr com.apple.quarantine "/Applications/Flow Download Manager.app"

    Verify the download yourself if you would rather not take that on trust: the
    release publishes DownloadManager-#{version}-unsigned.dmg.sha256 next to the
    image, and the project builds reproducibly from source with `make
    release-dmg-unsigned`.

    Browser companion: after the first launch, register the Chrome native
    messaging host from a source checkout with
    Scripts/install-chrome-native-host.sh.
  EOS
end
