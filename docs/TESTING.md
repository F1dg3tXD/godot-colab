# Testing

## Automated (headless)

The automated suite runs entirely in Godot's headless mode and needs no GUI.

```sh
cd /path/to/godot-colab
~/.apps/Godot/Godot_v4.7.2-stable_linux.x86_64 \
  --headless --script addons/godot_collab/tests/run_tests.gd
```

- Exit code `0` and a final `RESULT: PASS` mean all checks passed.
- Exit code `1` with `RESULT: FAIL` means at least one check failed; each failure
  is printed individually.
- The suite covers: protocol framing/validation (bad magic, truncated packets,
  oversized payloads, non-dictionary payloads), invitation code encode/decode,
  path guard (traversal/absolute/symlink), rate limiter, node-id allocation
  (positive authoritative ids, `-1` sentinel avoidance, no id reuse after
  `clear()`), marker scene instantiation with username/colour application and
  no-op default colour, a `CollabMarkerManager` check (marker created for a
  remote cursor, parented into the viewport container, removed when the cursor
  disappears or the peer is in another scene), an ENet loopback host/client
  handshake with cursor relay and host-disconnect detection, and a two-scene
  loopback test where a host scene is snapshotted to a joining peer and
  host/peer create/remove/transform edits propagate both ways without id
  collisions or duplicated nodes.

Editor load / parse smoke check (confirms the plugin script parses in an editor
context):

```sh
~/.apps/Godot/Godot_v4.7.2-stable_linux.x86_64 --headless --editor --quit 2>&1 \
  | grep -iE "SCRIPT ERROR|Parse Error|Compile Error|Failed to load"
```

Any `Unicode parsing error ... Unexpected NUL character` lines come from Godot
parsing its own `.godot/` import/cache binaries, not project source files. Addon
source must not contain literal NUL escapes (that would be a real bug the parser
reports).

Optional rendezvous service (Python 3 stdlib only):

```sh
python3 tools/rendezvous_server/rendezvous_server.py --host 127.0.0.1 --port 9080
# health check:
curl http://127.0.0.1:9080/health
```

### Automated coverage vs. GUI coverage

Automated tests do **not** drive the editor GUI. The following behaviours are
only verified by the manual procedure below: dock interactions, remote cursor
drawing in the viewport, editor-safe scene application, saving, project
download, and approval prompts. Do not report these as passing based on the
headless suite.

## Manual integration test (two editor instances)

Prepare two separate copies of the minimal project. See
[`../tests/minimal_project/README.md`](../tests/minimal_project/README.md).

```sh
# from the repo root
mkdir -p /tmp/opencode/alice /tmp/opencode/bob
cp -r tests/minimal_project/* /tmp/opencode/alice/
cp -r tests/minimal_project/* /tmp/opencode/bob/
cp -r addons/godot_collab /tmp/opencode/alice/addons/ 2>/dev/null || (mkdir -p /tmp/opencode/alice/addons && cp -r addons/godot_collab /tmp/opencode/alice/addons/)
mkdir -p /tmp/opencode/bob/addons && cp -r addons/godot_collab /tmp/opencode/bob/addons/
```

Open `/tmp/opencode/alice` and `/tmp/opencode/bob` in two Godot 4.7.2 editor
instances, enable **Godot Collab** in each, and run through the checks:

1. **Enable/disable/reload.** Enable the plugin, then disable and re-enable it.
   No errors in the editor's Output panel; the dock disappears and reappears.
2. **Host + client connect (loopback/LAN).** In Alice: set a username, click
   **Host Session**, copy the invitation code. In Bob: paste the code, click
   **Join Session**. Alice approves the prompt. Both docks show *Connected*.
3. **Usernames + participant list.** Both docks list two participants with the
   correct names and host/client roles.
4. **Remote cursors.** Move the mouse over Alice's 3D viewport: Bob sees a
   coloured 2D cursor + username overlay **and** a live 3D `editorNodeVis`
   marker for Alice (and vice-versa). Disconnect Alice: both the overlay and the
   3D marker disappear immediately.
5. **Normal editor controls still work.** Orbit/pan/zoom and selection in the 3D
   viewport behave normally on both sides.
6. **Incompatible project/scene warning.** Open a different scene in Bob (or
   point the two copies at different project identities). A clear
   compatibility/scene warning appears rather than silent corruption.
7. **Host scene mirrors to peers + supported edits replicate.** When Bob joins,
   his edited scene automatically mirrors Alice's (host) scene tree. Then
   transform the `Cube` via the Inspector and the 3D gizmo; rename it; add/remove
   a supported node; reparent it. Changes appear on both peers with no rebroadcast
   loop (check the Output panel for repeated application), and a peer edit stays
   visible on the peer that made it.
8. **Concurrent edits are deterministic.** Have both users move the same node at
   nearly the same time. The host's accepted order wins; the loser gets a
   conflict/reject notice, not a silent drop.
9. **Save persists.** On the host, click **Save Shared Scene**. Restart the
   editor and reopen the scene; verify the accepted changes are present.
10. **Project download + checksum.** From the client, request a project
    download to an approved empty directory. Verify progress, completion, that
    `project.godot` and required files exist, and that no checksum errors are
    reported.
11. **Invalid paths / oversized messages rejected.** (Covered in part by the
    headless suite.) Optionally point a transfer at a path containing `..` or an
    absolute path and confirm it is refused.
12. **No access outside the workspace.** Confirm a client cannot cause writes
    outside the chosen download directory.
13. **Failure messages.** Kill the host process; the client shows a clear
    disconnect/failure message. Attempt to join a bad address; a clear error
    appears.
14. **Git presence mode.** Start a session in **Git presence** mode on both
    sides: presence and cursors work, but scene edits are not applied, the
    download command is refused, and no local files are overwritten.

## Reporting results

When running the manual procedure, report the exact commands used, the Godot
build (`Godot Engine v4.7.2.stable.official`), the OS, and which numbered checks
passed or failed. Do not mark a GUI-only check as passing without actually
running two editors.
