#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write a Native Messaging host manifest for Flow Download Manager.

Called by Scripts/install-chrome-native-host.sh and
Scripts/install-firefox-native-host.sh. Every value arrives as an argument,
never as text spliced into a program, so paths containing quotes or newlines
cannot change what runs.

The two browser families identify an extension differently, which is the only
reason `--flavor` exists:

  chrome   `allowed_origins`, holding `chrome-extension://<id>/` URLs, where the
           id is derived from the unpacked directory path.
  firefox  `allowed_extensions`, holding the literal `browser_specific_settings
           .gecko.id` from the extension manifest. Firefox does not derive an id
           from the path, so `--extension-dir` is not consulted for this flavor.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path

ID_ALPHABET_BASE = ord("a")


def unpacked_extension_id(directory: str) -> str:
    """Reproduce Chrome's ID for an unpacked extension loaded from `directory`.

    Chrome hashes the absolute directory path with SHA-256 and maps the first 16
    bytes -- 32 hex digits -- from 0-f onto a-p.
    """
    digest = hashlib.sha256(directory.encode("utf-8")).hexdigest()[:32]
    return "".join(chr(ID_ALPHABET_BASE + int(char, 16)) for char in digest)


def candidate_paths(directory: str) -> list[str]:
    """The path spellings Chrome may have canonicalised the load path into."""
    absolute = os.path.abspath(directory).rstrip("/")
    resolved = str(Path(directory).resolve()).rstrip("/")
    seen: list[str] = []
    for path in (absolute, resolved):
        if path and path not in seen:
            seen.append(path)
    return seen


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host-name", required=True)
    parser.add_argument("--host-path", required=True)
    parser.add_argument("--flavor", choices=("chrome", "firefox"), default="chrome")
    parser.add_argument("--extension-dir", default="")
    parser.add_argument("--extra-ids", default="")
    parser.add_argument("destinations", nargs="+")
    args = parser.parse_args()

    ids: list[str] = []
    if args.flavor == "chrome":
        if not args.extension_dir:
            parser.error("--extension-dir is required for --flavor chrome")
        for path in candidate_paths(args.extension_dir):
            extension_id = unpacked_extension_id(path)
            if extension_id not in ids:
                ids.append(extension_id)
    for raw in args.extra_ids.split(","):
        extra = raw.strip()
        if extra and extra not in ids:
            ids.append(extra)

    if not ids:
        parser.error("no extension ids to allow; pass --extra-ids")

    if args.flavor == "firefox":
        allow_key = "allowed_extensions"
        allow_values = list(ids)
        description = "Flow Download Manager Firefox Native Messaging host"
    else:
        allow_key = "allowed_origins"
        allow_values = [f"chrome-extension://{value}/" for value in ids]
        description = "Flow Download Manager Chrome Native Messaging host"

    document = {
        "name": args.host_name,
        "description": description,
        "path": os.path.abspath(args.host_path),
        "type": "stdio",
        allow_key: allow_values,
    }
    body = json.dumps(document, indent=2) + "\n"

    for destination in args.destinations:
        directory = Path(destination)
        directory.mkdir(parents=True, exist_ok=True)
        target = directory / f"{args.host_name}.json"
        target.write_text(body, encoding="utf-8")
        print(f"wrote {target}")

    for value in allow_values:
        print(f"allow {value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
