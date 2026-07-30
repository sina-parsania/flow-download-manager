## Flow 0.4.2


### Fixed
- **Check for Updates actually works.** Since 0.3.5 every update check failed with "An error occurred in retrieving update information". Flow was downloading the update feed itself and handing Sparkle a local file, which Sparkle refuses to accept — so the check failed no matter what the feed contained. If you are on 0.4.1 or earlier you will need to install this one manually; after that, in-app updates work


Community build — not Apple notarized.
