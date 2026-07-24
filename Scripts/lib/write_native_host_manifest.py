#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write the Chrome Native Messaging host manifest for Flow Download Manager.

Called by Scripts/install-chrome-native-host.sh. Every value arrives as an
argument, never as text spliced into a program, so paths containing quotes or
newlines cannot change what runs.
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
    parser.add_argument("--extension-dir", required=True)
    parser.add_argument("--extra-ids", default="")
    parser.add_argument("destinations", nargs="+")
    args = parser.parse_args()

    ids: list[str] = []
    for path in candidate_paths(args.extension_dir):
        extension_id = unpacked_extension_id(path)
        if extension_id not in ids:
            ids.append(extension_id)
    for raw in args.extra_ids.split(","):
        extra = raw.strip()
        if extra and extra not in ids:
            ids.append(extra)

    document = {
        "name": args.host_name,
        "description": "Flow Download Manager Chrome Native Messaging host",
        "path": os.path.abspath(args.host_path),
        "type": "stdio",
        "allowed_origins": [f"chrome-extension://{value}/" for value in ids],
    }
    body = json.dumps(document, indent=2) + "\n"

    for destination in args.destinations:
        directory = Path(destination)
        directory.mkdir(parents=True, exist_ok=True)
        target = directory / f"{args.host_name}.json"
        target.write_text(body, encoding="utf-8")
        print(f"wrote {target}")

    for value in ids:
        print(f"allow chrome-extension://{value}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
