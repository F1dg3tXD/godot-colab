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
- The suite (currently **275 checks**) covers: protocol framing/validation (bad
  magic, truncated packets, oversized payloads, non-dictionary payloads, and the
  workspace message types `WORKSPACE_REQUEST`/`WORKSPACE_RESULT`/`FILE_APPLY`/
  `FILE_REMOVE`/`SCENE_LIST`, including text **and** byte payloads), **relay
  framing** (`CollabRelayProtocol` register/registered/member-join/data round
  trips, short and oversized packets rejected), invitation code
  encode/decode (including the relay `gc2.…` form), path guard
  (traversal/absolute/symlink), rate limiter, node-id
  allocation (positive authoritative ids, `-1` sentinel avoidance, no id reuse
  after `clear()`), general property value encode/decode (vectors, rects,
  transforms, AABBs, `StringName`, arrays, dictionaries; refusal of containers
  holding live `Object`s; **null object properties** encode as `null`; an
  **embedded-resource round-trip**), **inline-resource safety** (GDScript/
  PackedScene/oversized/empty inline payloads refused), **pending-resource
  queueing and resolution** (an unresolved path resource is queued, resolves on a
  later poll, and times out to a conflict; the queue is capped),
  **settings defaults**
  (empty rendezvous default, approval off by default, per-file cap ≤ packet cap),
  `is_syncable_property_name` (slash sub-properties allowed;
  `_`/`metadata/`/reserved refused) and `collect_syncable_props` behaviour
  (general properties accepted, `name`/`script`/`transform` reserved), source-file
  path predicates and baseline scanning (`addons/`, `.godot/`, `.git/` excluded;
  **binary assets included**; **open scenes protected**), node-id reconciliation
  against a host snapshot, marker scene instantiation with username/colour
  application and no-op default colour, a `CollabMarkerManager` check (marker
  created for a remote cursor, parented into the viewport container, removed when
  the cursor disappears or the peer is in another scene), an ENet loopback
  host/client handshake with cursor relay and host-disconnect detection, a
  two-scene loopback test where a host scene is snapshotted to a joining peer and
  host/peer create/remove/transform edits propagate both ways without id
  collisions or duplicated nodes, a **general inspector-property** loopback test
  (`editor_description`/`process_priority` host→client, `visible` client→host,
  plus an **inline `material_override`** host→client, an **in-place edit of that
  embedded material's colour**, and an **in-place edit of a nested `BoxShape3D`
  sub-resource** on a `CollisionShape3D`), a **workspace rename/delete** loopback
  test (a file renamed on one peer converges to the new path with no duplicate and
  the old path removed), a **rejoin-desync** test (a
  client with a stale local scene joins, is snapshotted, and its later edits
  target the correct node; then it reconnects with a fresh client and is re-keyed
  to host ids), a **multi-scene isolation** test where the host is focused on
  scene B while a client edits scene A (the edit must reach A, not B), and a
  **relay** test (`_test_relay_session`) that starts an in-process
  `CollabRelayServer`, has a host and a client register to one room, and asserts
  that registration assigns ids, that a HELLO is routed host→client via the relay,
  that a cursor packet is relayed, and that a host departure disconnects the
  client. A companion `_test_relay_token_rejection` asserts a client with a bad
  room token is rejected with a clear error.

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
only verified by the manual procedure below: dock and **top-toolbar**
interactions, remote cursor drawing in the viewport, editor-safe scene
application, saving (including **Ctrl+S shared save**), project download, and
approval prompts. Do not report these as passing based on the headless suite.

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
2. **Top toolbar + host/client connect (loopback/LAN).** Confirm the top toolbar
   shows **Host / Join / Paste & Join / Copy Code / Request Snapshot / Disconnect**
   next to the playtest buttons, and that Host/Join/Paste & Join are disabled while
   a session is active and Disconnect is disabled while disconnected. In Alice: set
   a username, click **Host** in the toolbar, then **Copy Code**. In Bob: click
   **Paste & Join** in the toolbar (this reads the clipboard) or paste the code into
   the dock's session-code field and click **Join**. Both docks show *Connected*.
   (With the default approval-off, no prompt appears; enable *Require host
   approval* in the dock to test the approval prompt path — the client dock should
   show "Waiting for host approval".)
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
9c. **Ctrl+S shared save.** With the session running, have the client move a node
    in a scene the host is *not* focused on, then press Ctrl+S in the client. The
    client should not error; on the host, focus that scene and confirm the move is
    present, and that the host's on-disk copy contains it after the host's own
    Ctrl+S or a moment of inactivity. Press Ctrl+S on the host with a client
    connected and confirm no rebroadcast loop appears in the Output panel.
9a. **Multi-scene: host on a different tab.** With a session running, open two
    scenes in the host editor (A and B) and focus B. In the client, edit scene A
    (move a node). Verify the change appears in A on the host and that B is
    untouched. Switch the host focus back to A; the client's change must still be
    there (it must not be reverted by the tab switch). Close A on the host, edit
    A again from the client, and verify the host writes it to disk; reopen A and
    confirm the change is present.
8a. **General property sync.** Change a property that is not a transform or a
    "famous" one — e.g. set `process_priority`, `editor_description`,
    `visible`, `modulate`, or a `CollisionShape3D`'s `shape` size — on one peer
    and confirm it appears on the other. Change a property from the **client**
    and confirm it reaches the host (client → host must work too).
8b. **Source file sync.** With the session running, edit a script
    (`res://scripts/*.gd`) on the client and save it. Confirm the host's file
    contents change on disk (and, if the editor reloads it, the host reflects
    it). Then edit `project.godot` on the host and confirm the client receives
    it. Confirm that editing anything under `addons/` is **not** relayed, and
    that the dock shows the "do not edit addons while a session is live"
    warning.
8d. **Resources + binary asset sync.** On one peer, assign a new material (create
    a `StandardMaterial3D` in the Inspector, or drag a texture from the
    Filesystem dock onto a `MeshInstance3D`'s `Material Override`) and confirm it
    appears on the other peer. Edit that material's colour **in place** and confirm
    the change propagates (allow up to ~1.5 s). Edit a `CollisionShape3D`'s
    `shape` size in place and confirm it propagates. Set
    `surface_material_override/0` and confirm it propagates. Separately, drop a
    binary image/model/audio file into the Filesystem dock and confirm both peers
    get a local copy.
8f. **File rename/delete propagation.** With the session running, rename a synced
    source file (e.g. a `.gd` script) on one peer. Confirm the other peer ends up
    with the file at the **new** path and **not** the old path (no duplicate or
    stale file). Then delete a synced file on one peer and confirm it is removed
    on the other. Confirm that an **open** scene file is still protected (a
    rename/delete of an open scene does not corrupt the editor's tab).
8e. **Open-scene protection.** Open `res://scenes/test.tscn` on the host and have
    the client save a change to that same scene file path: confirm the operation
    stream carries the change and the raw file watcher does not double-write it.
8c. **Rejoin after a crash.** With the session running, close the client editor
    (kill it). Reopen the client project and join again. Toggle a node's
    visibility / move a node from the client and confirm it affects the
    **same** node on the host (no phantom node, no wrong-node edit).
9b. **Workspace authoring.** From the client dock, use **New scene...** to
    create `res://scenes/test_from_client.tscn` and **Add file...** to add a
    small `.gd` file. Confirm both peers receive the files (the client's local
    copy appears, and the host's Project filesystem refreshes). Use **Open
    selected** to open the new scene. Confirm a path with `..`, an absolute path,
    or a disallowed extension is rejected.
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
15. **Relay session (no port forwarding).** Run the relay from a third terminal:

    ```sh
    ~/.apps/Godot/Godot_v4.7.2-stable_linux.x86_64 \
      --headless --script tools/relay_server/relay_server.gd -- --port 45900
    ```

    On editor A, tick **Use a relay server**, enter `127.0.0.1` (or
    `127.0.0.1:45900`), and click **Host**. The dock should report a relay
    connection and generate a `gc2.…` code. On editor B, click **Paste & Join**
    with that code (no extra configuration needed) and confirm the participant
    list, remote cursors, and a supported edit all work through the relay.
    Verify the host leaving disconnects the client with a clear message, and that
    a client using a corrupted `gc2.…` code (wrong token) is rejected cleanly.
    To exercise the relay path across two networks, run the relay on a host
    reachable by both editors and open its **UDP** port in that host's firewall.

## Reporting results

When running the manual procedure, report the exact commands used, the Godot
build (`Godot Engine v4.7.2.stable.official`), the OS, and which numbered checks
passed or failed. Do not mark a GUI-only check as passing without actually
running two editors.
