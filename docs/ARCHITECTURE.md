# Architecture

This document describes how Godot Collab is put together. It is aimed at
someone maintaining the add-on, not at end users.

## Design constraints

- **Editor add-on, not a game.** Everything runs inside the Godot 4.7.2 editor
  process via `EditorPlugin`. No part of the collaboration depends on running
  the user's game.
- **Isolated networking.** The add-on never reads or replaces the editor's
  global `MultiplayerAPI` / `SceneMultiplayer` peer. Instead each session owns a
  dedicated `ENetMultiplayerPeer` and polls it manually from
  `EditorPlugin._process`. This keeps collaboration from interfering with any
  multiplayer the user's project itself uses.
- **No object serialization.** Wire messages are plain dictionaries encoded with
  `var_to_bytes`. Godot's `Object` encoding is never enabled on the wire, so a
  peer cannot smuggle a serialized object or script across.
- **Host-authoritative.** The host owns the workspace, the authoritative scene
  revision and participant list. Clients submit operations; the host decides.
- **Separation of concerns.** UI (`ui/`), transport (`network/`), session logic
  (`session/`), presence (`presence/`), scene editing (`collaboration/`),
  transfer (`project_transfer/`) and safety (`security/`) are separate scripts.

## Component map

| Component | File | Responsibility |
| --- | --- | --- |
| `CollabConstants` | `core/collab_constants.gd` | Protocol version, limits, enums (modes, connection/connectivity state). |
| `CollabSettings` | `core/collab_settings.gd` | Persist preferences via `EditorSettings` (with an in-memory fallback for headless use). |
| `CollabLog` | `core/collab_log.gd` | Leveled logging. |
| `CollabIdentity` | `core/identity.gd` | Engine version and project identity hashing. |
| `CollabProtocol` | `network/protocol.gd` | Framing (magic + version + type + length), encode/decode, per-type validation. |
| `CollabSessionManager` | `network/session_manager.gd` | Owns the `ENetMultiplayerPeer`, poll loop, reliable/unreliable send, peer tracking. |
| `CollabSessionCoordinator` | `session/session_coordinator.gd` | Handshake, approval, participant registry, cursor relay, routing of scene/save/transfer messages. |
| `CollabParticipant` / `CollabParticipantRegistry` | `network/participant.gd`, `network/participant_registry.gd` | Participant records and authoritative list. |
| `CollabPresenceService` | `presence/presence_service.gd` | Samples the local camera ray, sends/relays cursor updates, stores remote cursor state, draws overlays. |
| `CollabCursorState` | `presence/cursor_state.gd` | Per-participant cursor state + interpolation + staleness. |
| `CollabMarkerManager` | `presence/marker_manager.gd` | Spawns/updates/removes a live 3D `editorNodeVis` marker per remote participant in the editor viewport. |
| `CollabSceneOperations` | `collaboration/scene_operations.gd` | Builds and validates structured scene operations. |
| `CollabNodeIdMap` | `collaboration/node_id_map.gd` | Stable session-level node IDs ↔ local `Node` mapping. |
| `CollabDiffWatcher` | `collaboration/diff_watcher.gd` | Per-context debounced snapshot/diff watcher for supported editor changes. |
| `CollabSceneContext` | `collaboration/scene_context.gd` | Per-scene state (root, node-id map, diff watcher, revision, detached/dirty flags). |
| `CollabSceneSyncService` | `collaboration/scene_sync_service.gd` | Multi-scene operation apply/create/broadcast, scene-scoped snapshots, revision checks, conflict notices, host-side persistence. |
| `CollabWorkspaceService` | `collaboration/workspace_service.gd` | Host-authoritative scene creation, file authoring, scene listing, and the debounced **source-file watcher/sync**, with path/size/extension validation and `addons/` exclusion. |
| `CollabSaveService` | `collaboration/save_service.gd` | Explicit + auto save of the shared scene on the host. |
| `CollabProjectManifest` | `project_transfer/project_manifest.gd` | Eligible-file manifest with sizes and checksums. |
| `CollabTransferManager` | `project_transfer/transfer_manager.gd` | Chunked, checksummed, cancellable snapshot download; safe writes. |
| `CollabPathGuard` | `security/path_guard.gd` | Rejects absolute paths, traversal, symlink escapes. |
| `CollabRateLimiter` | `security/rate_limiter.gd` | Token-bucket rate limiting for joins, lookups, operations. |
| `CollabInviteCode` | `session/invite_code.gd` | Direct (`ip:port`) and short-code invitation encoding. |
| `CollabRendezvousClient` | `session/rendezvous_client.gd` | HTTP client for the rendezvous service. |
| `CollabUpnpForwarder` | `session/upnp_forwarder.gd` | Optional UPnP UDP mapping with cleanup. |
| `CollabConnectivity` | `session/connectivity.gd` | LAN address discovery + connectivity classification. |
| `CollabDock` | `ui/collab_dock.gd` | The editor dock UI. Emits signals; contains no protocol logic. |
| `plugin.gd` | `plugin.gd` | `EditorPlugin` entry point: builds services + dock, forwards 3D input/draw, wires signals. |

## Runtime data flow

```
Editor UI (CollabDock)
        │  signals (host/join/approve/save/download/…)
        ▼
plugin.gd ──────────────► CollabSessionCoordinator ─────► CollabSessionManager ─► ENetMultiplayerPeer (UDP)
   ▲   ▲                          │  ▲                          │
   │   │  editor callables        │  │  signals                 │ raw packets
   │   └── CollabPresenceService ◄┘  │                          │
   │            │ cursor updates     │                          ▼
   │            ▼                    └────── CollabProtocol (frame/decode/validate)
   │     _forward_3d_gui_input
   │     _forward_3d_draw_over_viewport
    └── CollabSceneSyncService / CollabSaveService / CollabTransferManager / CollabWorkspaceService
```

`plugin.gd` polls `CollabSessionManager`, `CollabSceneSyncService`,
`CollabSaveService`, `CollabTransferManager` and `CollabWorkspaceService` every
editor frame. (`CollabWorkspaceService.poll()` runs the debounced source-file
watcher; workspace *authoring* is event-driven.) Networking and UI never call
each other directly: the coordinator emits signals that `plugin.gd` translates
into dock updates, and the dock emits signals that `plugin.gd` translates into
coordinator calls.

## Wire protocol

### Framing

Every packet is:

```
[ 4 bytes magic "GCLB" ][ 1 byte version ][ 1 byte message type ][ 4 bytes big-endian payload length ][ var-encoded Dictionary ]
```

`HEADER_SIZE = 10`. Decoding rejects, in order: too-short packets, bad magic,
protocol-version mismatch, unknown/zero message type, payloads larger than
`MAX_PACKET_PAYLOAD` (1 MiB), length mismatches, and non-dictionary payloads.
Each message type additionally has a conservative structural validator (required
keys, string length caps, array size caps, byte-array type and chunk-size checks).
See `network/protocol.gd`.

### Message types

Session control (reliable): `HELLO`, `WELCOME`, `REJECT`, `PING`, `PONG`.
Presence: `PARTICIPANT_LIST/JOIN/LEAVE/UPDATE`, `JOIN_PENDING/APPROVED/DENIED`,
`CURSOR_UPDATE` (unreliable-ordered), `SCENE_FOCUS`.
Scene: `OPS`, `OPS_ACK`, `OPS_REJECT`, `SNAPSHOT_REQUEST/RESPONSE`,
`RESYNC_REQUIRED`, `CONFLICT_NOTICE`.
Saving: `SAVE_REQUEST`, `SAVE_RESULT`.
Transfer: `TRANSFER_MANIFEST`, `TRANSFER_REQUEST`, `TRANSFER_CHUNK`,
plus completion/error types.
Workspace authoring: `WORKSPACE_REQUEST` (client → host: create scene / add
file / list scenes), `WORKSPACE_RESULT` (host → peers: accept/reject),
`FILE_APPLY` (host → peers: canonical file bytes), `SCENE_LIST`.

Best-effort traffic (cursor updates) uses `TRANSFER_MODE_UNRELIABLE_ORDERED`;
everything else uses `TRANSFER_MODE_RELIABLE`. Control and file-transfer data
also use distinct channels via `set_transfer_channel`.

### Handshake and approval

1. Client connects; `CollabSessionManager` signals `peer_connected`.
2. Client sends `HELLO` with `protocol_version`, `username`, `project_id`,
   `scene_id`, `capabilities`, `token`, `engine_version`.
3. Host stashes the `HELLO` in `_pending`. If `require_token` is set, the
   invite token is compared in constant time. Protocol-version mismatches and
   unknown/invalid payloads are rejected with a reason.
4. If `approve_joins` is enabled the host emits `join_request` (shown in the
   dock as pending). On approval the host registers the participant, sends
   `WELCOME` (`peer_id`, `session_id`, `host_username`, `workspace_mode`,
   `project_id`, …), sends `JOIN_APPROVED`, and broadcasts the participant list.
5. On `WELCOME` the client adopts its assigned id and registers the host.
6. Disconnects emit `peer_disconnected`; the host removes the participant and
   broadcasts `PARTICIPANT_LEAVE`.

Incoming messages are only processed for admitted peers (plus handshake
messages from pending peers). This prevents a connected-but-unapproved client
from submitting scene or transfer work.

## Scene-edit protocol

Godot does not replicate arbitrary editor changes automatically, and repeatedly
overwriting whole `.tscn` files is not an acceptable design. Instead:

- Collaboration is **scene-scoped**. The plugin binds a `CollabSceneContext` for
  **every open scene root** (`EditorInterface.get_open_scene_roots()`), not just
  the focused tab, and each operation carries the `res://` scene path it
  belongs to (`scene_id`). Switching tabs therefore never re-targets the shared
  scene and never pushes a snapshot that could clobber another scene. The
  focused scene is tracked separately for presence/cursor purposes and broadcast
  with `SCENE_FOCUS`.
- When an operation arrives for a scene the host does not have open, the host
  loads a **detached** model from disk (`CollabSceneContext.detached = true`),
  applies the operation there, and writes it back, so client work is applied and
  persisted even if the host is looking at a different scene. Detached contexts
  are replaced by a bound context if the host later opens that scene.
- A **stable session node id** is assigned per node and mapped to the local node
  by `CollabNodeIdMap`. Each node-id map is owned by a scene context, so ids are
  scoped to their scene. Operations reference these ids, not paths, so renames
  and reparents do not break references.
- **Id allocation policy.** Authoritative ids are positive and **host-only**.
  `CollabDiffWatcher._ensure_id` uses `authoritative = is_host`: only the host
  ever allocates positive ids. Every non-host — including an editor that has not
  joined yet, or one that just restarted onto a stale scene — allocates
  non-authoritative *negative* ids, which are re-keyed to the host's
  authoritative ids when the host admits the peer and sends a snapshot (see
  reconciliation below). This is what makes it structurally impossible for a
  client operation to resolve to a *different* node that happens to share a
  number with a host node — the class of bug behind the "toggle hit the wrong
  node after a crash/rejoin" desync. `CollabNodeIdMap` reserves `-1` as the "no
  temp id" sentinel and never reuses ids (its counters are monotonic across
  `clear()`), so a node created right after a snapshot cannot collide with an id
  that a live node already holds.
- **Id reconciliation on join.** On session start a client calls
  `CollabSceneSyncService.request_snapshot()`. When the snapshot arrives and
  `auto_apply_snapshot` is on, the snapshot is applied (structure replaced,
  ids adopted). When it is off, `reconcile_ids_from_snapshot()` walks the local
  tree by node path and **rebinds** matching local nodes to the host's
  authoritative ids (`_snapshot_paths` / `_reconcile_walk`), returning the number
  of matched nodes. Either way the client's subsequent operations address the
  host's nodes, not stale local ones.
- Supported property operations are **not a fixed whitelist**: the diff watcher
  and the sync service both derive the syncable set from
  `CollabSceneOperations.collect_syncable_props(node)`, which filters
  `get_property_list()` by usage (storable/editor, excluding read-only), drops
  the reserved names it handles separately (`name`, `owner`, `transform`,
  `global_transform`, `script`), and only keeps names whose value
  `encode_value()` can represent. `is_property_syncable()` is the single gate
  used by both apply paths.
- `CollabSceneSyncService` converts supported editor changes into structured
  `OPS`. Every operation carries session id, operation id, source peer, scene
  identity, target node id, base revision, operation type, and validated
  arguments.
- Supported operations: node create (restricted node types), remove, rename,
  reparent, `Node3D` transform (position/rotation/scale), and the general
  Inspector-property set described above (encode/decode covers vectors, colors,
  rects, transforms, planes, AABBs, projections, `NodePath`, `StringName`,
  bounded arrays/packed arrays/dictionaries, and resource references as
  validated `res://` paths). `encode_value()` refuses values it cannot represent
  (for example a live `Object` inside a container) instead of writing a lossy
  value.
- The host validates each operation against the target scene's context and
  revision, applies accepted operations to that scene (live root when open,
  detached model otherwise) using editor-safe mechanisms, bumps that scene's
  revision, and broadcasts. Rejected operations produce `OPS_REJECT` /
  `RESYNC_REQUIRED` / `CONFLICT_NOTICE` with a reason.
- A per-context **diff watcher** (`collaboration/diff_watcher.gd`) periodically
  scans each bound scene for supported changes with debouncing, to catch edits
  made through editor panels that do not emit a reliable general-purpose event.
  It is bounded to supported property/node types for performance. A context's
  baseline is refreshed immediately after remote operations are applied, so a
  remote change is never echoed back as a new local operation.

### Conflict policy

The host is authoritative. Changes are ordered by accepted operation order and
the scene revision at which they were applied. When two peers edit the same
property concurrently, the host accepts operations in the order it receives
them; each accepted operation bumps that scene's revision and is broadcast. An
operation whose base revision cannot be reconciled is rejected and the sender is
told to resynchronize (snapshot). The host never silently drops a rejected
operation — it reports a conflict/error to the dock. Revisions are tracked
per scene, so activity in one scene does not invalidate operations in another.

### Host persistence of remote edits

Because the host owns the workspace, accepted remote edits must survive even if
the host never focuses the scene or clicks save. After applying remote
operations to a context, the sync service marks it dirty. `poll()` writes dirty
contexts back to disk (`PackedScene.pack` + `ResourceSaver.save`) after
`PERSIST_DEBOUNCE_MS` (1.2 s) of inactivity when the context is detached or is
not the focused tab. The explicit **Save shared scene** action first calls
`CollabSceneSyncService.persist_host_scenes()` (all dirty contexts) and then the
editor's own save for the focused scene via `CollabSaveService`.

### Resynchronization

The host pushes a snapshot of the current edited scene to a peer as soon as it
is admitted (`peer_ready`), so a joining peer mirrors exactly what the host has.
A snapshot carries every node's stable id, parent id, class, name, `res://`
script path, `Node3D` transform, and its syncable properties. Applying it
replaces the local children of the edited root with the host's tree, so both
peers converge on the same node ids and structure.

A peer may also request a snapshot at any time (`SNAPSHOT_REQUEST`); the host
answers with `SNAPSHOT_RESPONSE` for that peer's `scene_id`. When the peer is on
a scene the host does not have open, the host loads a detached copy from disk to
serve the snapshot. When `auto_apply_snapshot` is enabled (the default in
host-workspace mode) the peer applies an incoming snapshot immediately, because
the host owns the authoritative scene. Turning it off makes the receiver hold the
snapshot as *pending* until explicitly applied (`apply_pending_snapshot` /
`discard_pending_snapshot`); a snapshot that cannot be applied (no scene open, or
a different scene) is kept pending and reported rather than cleared. Rejected
operations are reported to the dock but no longer force a snapshot on their own,
so a peer's local-only edit (for example an unsupported node type) is never
silently wiped.

## Workspace authoring (new scenes and added files)

In host-workspace mode a collaborator can create a new scene or add a text
project file (`CollabWorkspaceService`):

1. The requester validates the path locally with `CollabPathGuard` and a strict
   extension allow-list (`WRITABLE_EXTENSIONS`) and size cap
   (`MAX_WORKSPACE_FILE_BYTES = 512 KiB`).
2. The host re-validates everything (path traversal / symlink escape, extension,
   size, scene root class against `SCENE_ROOT_CLASSES`, existing-file policy) and
   writes the file **inside the approved project root only**.
3. The host broadcasts the canonical bytes with `FILE_APPLY`, so every peer
   writes its own local copy, and refreshes the editor filesystem
   (`EditorFileSystem.update_file`) and re-advertises `SCENE_LIST`.

Files delivered this way are never executed or imported by the add-on; they
become ordinary project files the user's editor may scan. Binary/generated
assets are out of scope for this path and belong to project transfer.

Setting `godot_collab/collaboration/allow_workspace_authoring` (default on)
gates the whole feature; it is always disabled in Git presence mode.

## Source-file sync (host-authoritative)

Scene edits flow through the structured operation stream; ordinary **source
files** (scripts, text resources, `project.godot`, `export_presets.cfg`) flow
through a separate, host-authoritative file path in `CollabWorkspaceService` so
that editing a script on any peer reaches the host and the other peers:

1. On session start, if `godot_collab/collaboration/sync_source_files` is on,
   `plugin.gd` enables `file_sync_enabled` and calls `prime_file_baseline()`,
   which records a size+mtime baseline of every eligible file under the approved
   project root (`_walk_files`, bounded by `FILESYNC_MAX_FILES`).
2. `poll()` scans at most every `FILESYNC_INTERVAL_MS` (1200 ms). A file whose
   stat changed is read (capped at `MAX_WORKSPACE_FILE_BYTES`), sent to the host
   as a `WORKSPACE_REQUEST` ADD_FILE file op, and its baseline is refreshed.
3. The host validates the path (inside the approved root, not `addons/`, allowed
   extension, size) and rebroadcasts the canonical bytes with `FILE_APPLY`.
4. Each receiver writes only inside its project root and refreshes its own
   baseline so the write is not re-detected as a local change.

Eligibility (`is_source_file`) excludes generated/vendor trees — `.godot/`,
`.git/`, and **`addons/`**. Excluding `addons/` is a safety requirement: the
add-on's own scripts run inside the editor, and live-editing them mid-session
can crash the local editor and any client that receives the relayed bytes. The
dock also shows an explicit warning when a session starts. Scene files
(`.tscn`/`.scn`) are deliberately not handled here; they use the operation
stream. Files are written to disk only and are never imported or executed by the
add-on.

## Presence and remote cursors

- Local cursor sampling happens in `EditorPlugin._forward_3d_gui_input`. The
  callback observes `InputEventMouseMotion`, obtains the editor 3D viewport via
  `EditorInterface.get_editor_viewport_3d()` and the provided camera, and builds
  a world-space ray plus a normalized viewport position. It **always** returns
  `AFTER_GUI_INPUT_PASS`, so normal editor interaction is never consumed.
- The payload synchronizes the sender's camera transform, ray origin/direction,
  normalized viewport position, username, timestamp, and scene id.
- `CURSOR_UPDATE` is sent at `CURSOR_SEND_HZ` (unreliable-ordered), relayed by
  the host to other participants, interpolated over `CURSOR_INTERP_SECONDS`, and
  discarded when older than `CURSOR_STALE_SECONDS`.
- Drawing happens in `EditorPlugin._forward_3d_draw_over_viewport`, which calls
  `CollabPresenceService.draw_overlay`. Each participant gets a stable distinct
  colour; the local user is distinguishable. Markers are hidden when behind or
  outside the local view. A marker is a configurable point on the remote camera
  ray (depth/size/labels configurable) — it is **not** claimed to sit exactly on
  the surface under the remote pointer.
- Disconnect clears the participant's overlay immediately.
- `CollabMarkerManager` additionally renders a **live 3D marker** for every
  remote participant: it instances `assets/editorNodeVis.tscn`
  (`CollabUserMarker`) into a container parented to
  `EditorInterface.get_editor_viewport_3d()`. The marker shares the edited
  scene's `World3D` but is not part of the scene, so it is never serialised,
  never shows in the Scene dock and never marks the scene dirty. Its position is
  the interpolated point on the remote camera ray from `CollabCursorState`, and
  its orientation follows the remote camera (`set_from_camera`). Markers are
  created lazily, hidden for peers that are stale or in another scene, and
  removed on disconnect / session stop. Visibility, label display and scale are
  controlled by editor settings (`cursors/show_3d_markers`, `cursors/show_labels`,
  `cursors/marker_3d_scale`; depth via `cursors/marker_depth`).

## Workspace modes

- **Host-workspace** (`HOST_WORKSPACE`): the host owns the authoritative scene
  and is the source of project snapshots; scene operations, saving and project
  transfer are enabled.
- **Git presence** (`GIT_PRESENCE`): presence + cursors only. `plugin.gd` sets
  `CollabSceneSyncService.enabled = false`, and the download command is refused.
  Local files are never overwritten; Git remains responsible for moving commits.

## Settings

Preferences are stored under `godot_collab/*` in the editor's `EditorSettings`
(see `core/collab_settings.gd`): username, default port, max peers, rendezvous
URL, direct advertise host, UPnP toggle, cursor label/size/depth, auto-save +
delay, download directory, per-file/total transfer limits, join approval,
invite-token requirement, workspace authoring, and source-file sync. Session
tokens are never written to committed project files.

## Lifecycle

`_enter_tree` builds every service, the dock, and enables
`set_input_event_forwarding_always_enabled()` /
`set_force_draw_over_forwarding_enabled()`. `_exit_tree` disconnects signals,
closes the session, removes the UPnP mapping, frees every node it added, and
removes the dock. `CollabSessionManager.close()` defers the actual ENet teardown
if it is called from inside `poll()` (a disconnect signal), avoiding a
use-after-free of the native peer.
