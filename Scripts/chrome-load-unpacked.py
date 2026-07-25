#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Load an unpacked Chrome extension into a Flow-managed Chrome profile via CDP.

Chrome 137+ blocked `--load-extension` on branded builds for the default profile.
DevTools remote debugging also refuses the default profile. Flow therefore uses a
dedicated `--user-data-dir` and `Extensions.loadUnpacked` once; later launches
only need that profile path.

Usage:
  chrome-load-unpacked.py --chrome BIN --profile DIR --extension DIR [--port N]
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import time
import urllib.request


def wait_for_debug_port(port: int, timeout: float = 30.0) -> dict:
    deadline = time.time() + timeout
    last_error: Exception | None = None
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version", timeout=1) as response:
                return json.load(response)
        except Exception as error:  # noqa: BLE001
            last_error = error
            time.sleep(0.25)
    raise RuntimeError(f"Chrome debug port {port} did not open ({last_error})")


def _recv_exact(sock: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        piece = sock.recv(size - len(chunks))
        if not piece:
            raise RuntimeError("Chrome closed the DevTools socket")
        chunks.extend(piece)
    return bytes(chunks)


def _recv_frame(sock: socket.socket) -> str:
    header = _recv_exact(sock, 2)
    opcode = header[0] & 0x0F
    masked = (header[1] & 0x80) != 0
    length = header[1] & 0x7F
    if length == 126:
        length = struct.unpack(">H", _recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", _recv_exact(sock, 8))[0]
    if masked:
        mask = _recv_exact(sock, 4)
        payload = bytearray(_recv_exact(sock, length))
        for index, value in enumerate(payload):
            payload[index] = value ^ mask[index % 4]
        data = bytes(payload)
    else:
        data = _recv_exact(sock, length)
    if opcode == 0x8:
        raise RuntimeError("Chrome closed the DevTools WebSocket")
    if opcode != 0x1:
        return ""
    return data.decode("utf-8")


def _send_frame(sock: socket.socket, text: str) -> None:
    payload = text.encode("utf-8")
    mask = os.urandom(4)
    header = bytearray([0x81])
    length = len(payload)
    if length < 126:
        header.append(0x80 | length)
    elif length < 65536:
        header.append(0x80 | 126)
        header.extend(struct.pack(">H", length))
    else:
        header.append(0x80 | 127)
        header.extend(struct.pack(">Q", length))
    masked = bytearray(payload)
    for index, value in enumerate(masked):
        masked[index] = value ^ mask[index % 4]
    sock.sendall(header + mask + masked)


def load_unpacked(ws_url: str, extension_dir: str) -> str:
    if not ws_url.startswith("ws://"):
        raise RuntimeError(f"unsupported DevTools URL: {ws_url}")
    without_scheme = ws_url[len("ws://") :]
    host_port, _, path = without_scheme.partition("/")
    host, _, port_text = host_port.partition(":")
    port = int(port_text or "80")
    path = "/" + path

    sock = socket.create_connection((host, port), timeout=20)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host_port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n"
    )
    sock.sendall(request.encode("ascii"))
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("DevTools handshake failed")
        response += chunk
    if b"101" not in response.split(b"\r\n", 1)[0]:
        raise RuntimeError(f"DevTools handshake rejected: {response[:200]!r}")

    expected = base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
    ).decode("ascii")
    if expected.encode("ascii") not in response:
        raise RuntimeError("DevTools WebSocket accept key mismatch")

    message_id = 1
    payload = {
        "id": message_id,
        "method": "Extensions.loadUnpacked",
        "params": {"path": extension_dir},
    }
    _send_frame(sock, json.dumps(payload))
    deadline = time.time() + 20
    try:
        while time.time() < deadline:
            raw = _recv_frame(sock)
            if not raw:
                continue
            data = json.loads(raw)
            if data.get("id") != message_id:
                continue
            if "error" in data:
                raise RuntimeError(json.dumps(data["error"]))
            extension_id = (data.get("result") or {}).get("id")
            if not isinstance(extension_id, str) or not extension_id:
                raise RuntimeError(f"loadUnpacked returned no id: {data}")
            return extension_id
        raise TimeoutError("Extensions.loadUnpacked")
    finally:
        sock.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chrome", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--extension", required=True)
    parser.add_argument("--port", type=int, default=9333)
    args = parser.parse_args()

    chrome = os.path.abspath(args.chrome)
    profile = os.path.abspath(args.profile)
    extension = os.path.abspath(args.extension)
    if not os.path.isfile(chrome):
        print(f"error: Chrome binary not found: {chrome}", file=sys.stderr)
        return 2
    if not os.path.isfile(os.path.join(extension, "manifest.json")):
        print(f"error: extension manifest missing in {extension}", file=sys.stderr)
        return 2

    os.makedirs(profile, exist_ok=True)
    marker = os.path.join(profile, ".flow-companion-extension-id")
    if os.path.isfile(marker):
        print(open(marker, encoding="utf-8").read().strip())
        return 0

    command = [
        chrome,
        f"--user-data-dir={profile}",
        f"--remote-debugging-port={args.port}",
        "--remote-allow-origins=*",
        "--enable-unsafe-extension-debugging",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-sync",
    ]
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        version = wait_for_debug_port(args.port)
        ws_url = version.get("webSocketDebuggerUrl")
        if not isinstance(ws_url, str) or not ws_url:
            raise RuntimeError("Chrome did not publish webSocketDebuggerUrl")
        extension_id = load_unpacked(ws_url, extension)
        with open(marker, "w", encoding="utf-8") as handle:
            handle.write(extension_id + "\n")
        print(extension_id)
        return 0
    finally:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:  # noqa: BLE001
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
