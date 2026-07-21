#!/usr/bin/env bash
# Lifecycle wrapper for the deterministic loopback fault service
# (08-validation-commands.md §6). Binds only to loopback; all state lives under
# the build scratch root, never a real user destination.
set -euo pipefail
cd "$(dirname "$0")/.."

STATE=".build/test-services"
PIDFILE="$STATE/pid"
PORTFILE="$STATE/port"
mkdir -p "$STATE"

port() { cat "$PORTFILE" 2>/dev/null || true; }

up() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "test-services already up on port $(port)"; return
    fi
    swift build --product test-services >/dev/null
    local bin; bin="$(swift build --product test-services --show-bin-path)/test-services"
    rm -f "$PORTFILE"
    nohup "$bin" serve 0 > "$STATE/out.log" 2>&1 &
    echo $! > "$PIDFILE"
    for _ in $(seq 1 50); do [ -s "$PORTFILE" ] && break; sleep 0.1; done
    echo "test-services up on port $(port) (pid $(cat "$PIDFILE"))"
}

health() {
    local p; p="$(port)"; [ -z "$p" ] && { echo "not running" >&2; exit 1; }
    curl -fsS "http://127.0.0.1:$p/health"; echo
}

reset() {
    local p; p="$(port)"; [ -z "$p" ] && { echo "not running" >&2; exit 1; }
    curl -fsS "http://127.0.0.1:$p/control/reset"; echo
}

logs() {
    local p; p="$(port)"; [ -z "$p" ] && { echo "not running" >&2; exit 1; }
    curl -fsS "http://127.0.0.1:$p/control/logs"; echo
}

down() {
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE" "$PORTFILE"
    echo "test-services down"
}

case "${1:-}" in
    up) up ;;
    health) health ;;
    reset) reset ;;
    logs) logs ;;
    down) down ;;
    *) echo "usage: test-services.sh {up|health|reset|logs|down}" >&2; exit 2 ;;
esac
