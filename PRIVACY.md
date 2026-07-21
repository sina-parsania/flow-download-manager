# Privacy Policy

This document describes how Download Manager handles data. It is an engineering
privacy policy for a local-first application, not legal advice. A qualified
privacy reviewer must review it before public release.

**Project status.** Download Manager is at **Phase 0 — repository foundation**.
No user-facing download, browser, media, or torrent features have shipped yet.
This policy describes the data-handling architecture and the commitments that
those features are being built to honor. It will be revised as each phase ships
and its actual behavior is verified against network capture.

**Platform.** Native macOS 14.0 or later on Apple Silicon (arm64), distributed
directly under Developer ID (code-signed and notarized), not via the Mac App
Store. The product is composed of a main app and a per-user LaunchAgent
(`DownloadEngineAgent`) that communicate over an authenticated, versioned XPC
interface. All components described here run on the user's own Mac.

## 1. Summary

- **Local-only by default.** Processing happens on your Mac. Data is used to
  perform the downloads and management tasks you request, and stays on your
  device.
- **No account.** There is no sign-up, sign-in, or user profile hosted by the
  project. You do not create an identity with us to use the app.
- **No telemetry uploaded by default.** The app does not collect or upload usage
  analytics, crash pings, or behavioral metrics by default.
- **No background network analytics.** The app does not perform background
  network analytics or beacon to a project-operated server.
- **No third-party data sharing.** The project does not sell, rent, or share
  your data with third parties. Diagnostic material leaves your Mac only when
  you explicitly export and send it.

Network connections the app makes are those required to do the work you ask of
it — for example, contacting the servers you are downloading from and, when you
choose, checking for signed application updates. These connections are inherent
to the requested task, not analytics.

## 2. Data classes, storage, and retention

The following classes describe where data lives and how long it is kept. Local
databases are stored in the app's per-user application support location on your
Mac.

| Class | Storage | Retention |
|---|---|---|
| Job / history metadata | SQLite (local) | User-configurable; default indefinite |
| Credentials / tokens / cookie jars | macOS Keychain | Until removal or expiry |
| Partial files | Staging or destination volume | Per explicit failure/cancel policy |
| Redacted logs / events | Unified log / SQLite summary | Bounded |
| Diagnostic export | User-selected file | User controlled |

Notes on each class:

- **Job / history metadata** records what you downloaded and its outcome
  (identities, sizes, states, timestamps, categories). Retention is
  user-configurable and defaults to indefinite so your history persists until
  you choose to remove it. Event and attempt detail may be compacted after a
  documented window while preserving the terminal summary and audit-critical
  errors.
- **Credentials / tokens / cookie jars** are secrets used to authenticate to the
  servers you download from. They are held in the macOS Keychain and retained
  until you remove them or they expire. They are never written to the SQLite
  database (see redaction below).
- **Partial files** are the incomplete bytes of an in-progress or interrupted
  download, written to a staging area or the destination you selected. Their
  retention after a failure or cancellation follows an explicit per-job or
  global policy, not silent accumulation.
- **Redacted logs / events** are the diagnostic and recovery records the app
  keeps (in the macOS unified log and as a summarized SQLite event journal).
  They are redacted at the source and bounded in size; the journal supports
  crash recovery and troubleshooting, not analytics.
- **Diagnostic export** is a file you deliberately produce to share with a
  maintainer for support. It is written to a location you choose and remains
  entirely under your control.

## 3. Redaction and secret handling

The app is designed so that sensitive material never accumulates in the general
database or logs:

- **URLs are reduced to scheme + host** where a URL is recorded for diagnostics
  or host-level observation. Full paths, query strings, and fragments — which
  can carry tokens or identifying detail — are not retained in those records.
- **Secrets are never stored in the database.** Passwords, tokens, and cookie
  jars live only in the macOS Keychain. The database holds an **opaque Keychain
  reference** and non-secret metadata, never the secret value itself.
- **Logs redact credentials, cookies, headers, and paths.** Log and event
  output marks sensitive values as private/sensitive at the point of
  interpolation so they are not written in the clear. Clipboard and pasteboard
  contents are not logged.

Because a diagnostic export is assembled from these already-redacted records,
it inherits the same protections. You can review an export locally before
choosing to share it.

## 4. Your controls

The app is being built to give you direct control over your data. Each control
below states what it does to your **downloaded files**, which are yours and are
never removed as a side effect of clearing metadata:

- **Export data.** Produce a local diagnostic export (see above). This creates a
  file you choose the location for; it does not transmit anything on its own and
  does not touch your downloaded files.
- **Delete history.** Remove job and history metadata according to your
  selection. Deleting metadata does **not** delete the corresponding downloaded
  files on disk; foreign-key and cascade rules are defined so that clearing
  history never cascades into your saved files.
- **Delete credentials.** Remove a credential, token, or cookie jar from the
  Keychain. This deletes the secret; it does not delete any downloaded files.
  Jobs that depended on that credential are left in an actionable
  "authentication required" state rather than failing silently.
- **Clear logs.** Discard the redacted logs and event summaries. This affects
  diagnostics only and does not delete any downloaded files.
- **Delete a downloaded file.** A separate, explicit action that resolves and
  previews the exact recorded file identity before removal. It never recursively
  deletes a destination directory.

## 5. Opt-in features with privacy implications

Two capabilities have privacy consequences beyond local processing. **Neither is
present yet** — they are planned for later phases. When they ship, each will be
**opt-in** and will state its implications during onboarding before you enable
it:

- **Browser cookie transfer.** A future browser-integration phase may, at your
  request, transfer cookies from your browser so a download can authenticate as
  your logged-in session. Onboarding will state the purpose, the host scope, how
  long anything is retained, and how to revoke access. Captured data is handled
  by the local engine, never sent to a project-operated server.
- **BitTorrent public-IP exposure.** A future torrent phase involves
  peer-to-peer participation, which can expose your public IP address to peers
  and trackers. Onboarding will explain this exposure, seeding behavior, and the
  relevant controls before you use the feature. The app does not claim anonymity.

Until those phases ship, these features do not exist in the app and this section
describes intended policy only.

## 6. Third parties

The project does not sell, rent, trade, or otherwise share your data with third
parties, and does not embed third-party analytics or advertising SDKs. When you
download from a remote server, or check for a signed update, you interact with
those services directly and their own policies apply to that interaction; the
project does not receive a copy of that activity.

## 7. Changes to this policy

This policy will be updated as features ship and their real behavior is verified.
Material changes will be reflected here in the repository, with the project
status and per-feature sections kept accurate to what the app actually does.

## 8. Contact

Privacy questions and reports should go to the project's designated privacy
contact: `<privacy-contact configured by the release owner>`. This placeholder
**must be set to a real, monitored channel before public release.** Security
vulnerabilities should be reported through the channel documented in
`SECURITY.md`.
