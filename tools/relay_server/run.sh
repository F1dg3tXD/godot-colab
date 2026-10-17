#!/usr/bin/env bash
#
# Run the Godot Collab relay server directly with a Godot binary.
#
# On a fresh checkout the GDScript global class cache (.godot/
# global_script_class_cache.cfg) does not exist yet, so `class_name` types
# (CollabRelayServer, CollabLog, ...) cannot be resolved and the script fails to
# parse. This wrapper imports the project once to build the cache, then starts
# the relay.
#
# Usage:
#   GODOT=/path/to/godot tools/relay_server/run.sh --port 45900
#   GODOT=godot               tools/relay_server/run.sh --port 45900 --max-clients 128

set -euo pipefail

GODOT="${GODOT:-godot}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_DIR"

if [ ! -f .godot/global_script_class_cache.cfg ]; then
    echo "Building GDScript class cache (first run)..." >&2
    "$GODOT" --headless --import >/dev/null 2>&1 || true
fi

exec "$GODOT" --headless --script tools/relay_server/relay_server.gd -- "$@"
