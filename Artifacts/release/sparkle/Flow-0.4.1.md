## Flow 0.4.1


### Fixed
- **Downloads get the right file extension.** A link like `getfile.jsp?fileid=…` serving a disk image was saved as `getfile.jsp`, which Finder refuses to open. Extensions now come from macOS's own type database instead of a short hand-written list, so disk images, installers, archives and office documents all land with the extension they should have
- **Check for Updates works again.** The update feed pointed at a release-notes file that is never published, so Sparkle reported "An error occurred in retrieving update information" even though the update itself was fine


Community build — not Apple notarized.
