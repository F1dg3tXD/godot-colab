#!/usr/bin/env bash
#
# Container entry point for the Godot Collab relay image.
#
# Runs two services together:
#   1. the ENet/UDP relay (Godot, headless)   -> $RELAY_PORT      (default 45900/udp)
#   2. the short-code rendezvous (Python)     -> $RENDEZVOUS_PORT (default 9080/tcp)
#
# Any command-line arguments are forwarded to the relay (e.g. `--port 45900`);
# when none are given the RELAY_* environment variables are used.

set -euo pipefail

RELAY_BIND="${RELAY_BIND:-*}"
RELAY_MAX_CLIENTS="${RELAY_MAX_CLIENTS:-64}"
RELAY_PORT="${RELAY_PORT:-45900}"
RENDEZVOUS_BIND="${RENDEZVOUS_BIND:-0.0.0.0}"
RENDEZVOUS_PORT="${RENDEZVOUS_PORT:-9080}"

relay_args=("$@")
if [ "${#relay_args[@]}" -eq 0 ]; then
    relay_args=(--port "$RELAY_PORT" --max-clients "$RELAY_MAX_CLIENTS" --bind "$RELAY_BIND")
fi

godot --headless --script tools/relay_server/relay_server.gd -- "${relay_args[@]}" &
relay_pid=$!

python3 tools/rendezvous_server/rendezvous_server.py --host "$RENDEZVOUS_BIND" --port "$RENDEZVOUS_PORT" &
rendezvous_pid=$!

shutdown() {
    kill "$relay_pid" "$rendezvous_pid" 2>/dev/null || true
}
trap shutdown TERM INT

# Exit (and stop the other service) as soon as either service stops.
wait -n "$relay_pid" "$rendezvous_pid"
status=$?
shutdown
wait 2>/dev/null || true
exit "$status"
