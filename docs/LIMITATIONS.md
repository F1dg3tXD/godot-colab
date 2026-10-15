# Known limitations

This add-on intentionally implements a bounded, host-authoritative subset of
collaboration. The following are **not** implemented or not yet verified. They
are listed explicitly so nothing here is mistaken for working functionality.

## Verification status

- The headless test suite (`addons/godot_collab/tests/run_tests.gd`) covers the
  protocol framing/validation (including the workspace message types), invitation
  codes, path guard, rate limiter, value encode/decode for the general property
  set, file-sync path predicates + baseline scanning (including `addons/`
  exclusion), node-id reconciliation, an ENet loopback
  handshake/cursor/disconnect flow, a two-scene loopback
  snapshot/host<->peer edit-propagation flow, a **general inspector-property**
  host<->peer flow, a **rejoin-desync** flow (stale client scene + reconnect), and
  a **multi-scene isolation** flow (host focused on scene B while a client edits
  scene A). It passes (see [`TESTING.md`](TESTING.md)).
- The interactive editor behaviours (dock UI, remote cursor drawing,
  `_forward_3d_gui_input` / `_forward_3d_draw_over_viewport`, scene editing,
  saving, project download, approval prompts) require **two interactive Godot
  editor instances** and have a documented manual procedure but are **not**
  asserted by an automated GUI test.
- Testing so far is on **Linux**. Windows and macOS are untested.

## Networking and connectivity

- **No encryption.** ENet over UDP is not encrypted and the invite token is a
  shared bearer secret, not an authenticated identity. Do not treat a session as
  confidential or as strong authentication.
- **No relay.** If direct connectivity fails (CGNAT, symmetric NAT, restrictive
  firewalls, UPnP-unsupported routers), the session will not connect. The
  transport interfaces are designed so a relay could be added later, but none is
  built in.
- **UPnP is best-effort** and may silently fail on many routers. Failures are
  reported in the dock; manual port forwarding is the fallback.
- The rendezvous service maps short codes to endpoints; it is **not** an ENet
  relay and does not carry session traffic. Its default configuration is plain
  HTTP on localhost.
- Short code lookup and direct connection have only been exercised in local and
  loopback-style testing, not across real NATs between two networks.

## Scene collaboration

- Synchronized edits:
  - Node creation for supported node types.
  - Node removal, rename, reparent.
  - `Node3D` position/rotation/scale.
  - **Every syncable/storable property** the Inspector exposes, driven by
    `get_property_list()` (`CollabSceneOperations.collect_syncable_props`). This
    is not a fixed whitelist: bool, int, float, String, `StringName`,
    `Vector2(i)`, `Vector3(i)`, `Color`, `Rect2(i)`, `Transform2D/3D`, `Basis`,
    `Quaternion`, `Plane`, `AABB`, `Projection`, `NodePath`, arrays, packed
    arrays, dictionaries, and `Resource`/`Object` references (as validated
    `res://` paths) are supported, within depth/element caps.
  - Reserved properties are excluded from the generic property path because they
    have dedicated handling: `name`, `owner`, `transform`, `global_transform`,
    and `script`.
- **Not synchronized:** arbitrary *live script text about to be reloaded*, import
  settings, project settings, animation editors, shaders, particle/tilemap/
  material sub-editors, and custom inspectors that render to a texture. Editing
  a **source file** on disk is synchronized by the file-sync watcher (see
  below), but a script change does not hot-reload a running editor session.
- Resource references are carried as validated resource paths or explicitly
  supported serialized values; not every resource kind is handled.
- Container values (arrays/dictionaries) are bounded by
  `MAX_CONTAINER_ELEMENTS` (4096) and `MAX_CONTAINER_DEPTH` (6); values holding
  live `Object`s that cannot be represented as a path are refused rather than
  silently lossy.
- Stable node identity is **host-authoritative**: only the host allocates the
  positive id space. Every non-host (including an editor that has not joined yet)
  uses non-authoritative negative ids, so a client op can never resolve to a
  *different* node that merely shares a number. On join the client requests a
  snapshot and reconciles its node ids to the host's by path
  (`CollabSceneSyncService.reconcile_ids_from_snapshot`), which is what prevents
  the "toggle hit the wrong node after a crash/rejoin" desync.
- The diff watcher is bounded and best-effort. Very rapid edits or unsupported
  panels may produce changes that are not detected until the next scan or a
  resynchronization.
- Joining a host-workspace session **mirrors the host scene**: the host sends a
  snapshot and the peer applies it automatically (unless
  `collaboration/auto_apply_snapshot` is turned off). This replaces the peer's
  local scene children with the host's, so unsaved local edits made before
  joining are discarded by design.
- A snapshot is sent as a single packet and is capped at
  `CollabConstants.MAX_PACKET_PAYLOAD` (1 MiB). A scene whose serialized
  snapshot exceeds that cannot be sent and is reported as an error; snapshots
  are not chunked across packets.
- Node scripts are shared as `res://` paths. The script must exist at the same
  path on each peer; otherwise the node is created without its script.
- Conflict handling is deterministic (host order + revision) but is not a full
  CRDT/operational-transform system.
- Revisions are tracked **per scene**. A peer and the host can be working on
  different open scenes simultaneously; operations are routed by scene path.
- Host-side persistence of remote edits rewrites the scene file on the host
  (after a debounce, for scenes the host is not focused on, or when the host uses
  *Save shared scene*). The editor's open tab is not force-reloaded; the on-disk
  and in-memory copies are kept in sync because the same root was edited.
- A detached host context is a plain model loaded from disk. It has no editor
  environment, so editor-only side effects (for example `@tool` `_ready` logic
  that expects the edited scene) do not run for it.

## Presence and cursors

- A remote cursor is a configurable point on the remote user's camera ray. It is
  **not** guaranteed to lie on the exact surface under the remote pointer
  (no guaranteed surface picking).
- Cursors for users viewing a different scene or outside the local view may be
  hidden.
- The live 3D markers (`CollabMarkerManager` / `assets/editorNodeVis.tscn`) are
  only shown while a session is active and the editor has a 3D viewport. If the
  editor is opened in a layout without a 3D viewport the markers are skipped
  (the 2D overlay cursors still require the 3D viewport too). Markers follow the
  same configurable ray depth as the 2D overlay and are not surface-picked.

## Saving

- The explicit **Save shared scene** action first persists every scene with
  unpersisted remote edits, then saves the **currently active** edited scene via
  `EditorInterface.save_scene()`. Scenes with no remote edits and no local
  changes are not force-saved.
- Remote edits to a scene the host is not focused on are written back after a
  short debounce (1.2 s) so they survive even if the host never clicks save.
  This is a file write to the host's own scene path, not a transactional save.
- Auto-save is optional and time-based (after an inactivity period), not a
  robust transactional save.

## Workspace authoring (new scenes / added files)

- Only **text** files with an allowed extension
  (`WRITABLE_EXTENSIONS`) are accepted, up to `MAX_WORKSPACE_FILE_BYTES`
  (512 KiB). Larger files or binary assets must use project transfer.
- New scenes are limited to the root classes in `SCENE_ROOT_CLASSES`
  (`Node`, `Node2D`, `Node3D`, `Control`, `CanvasLayer`) and are created empty.
- Transferred files are written to disk but are **never executed or imported** by
  the add-on; the editor may scan them like any project file.
- The scene list is a directory scan of `res://` and is capped at
  `MAX_SCENE_LIST` (2048) entries; generated/hidden folders are skipped.
- Workspace authoring is disabled in Git presence mode and can be turned off with
  `godot_collab/collaboration/allow_workspace_authoring`.

## Source file sync (host-authoritative)

- When enabled (`godot_collab/collaboration/sync_source_files`, default on) the
  host and clients watch eligible **source files** and relay changed file
  contents to the host, which applies and re-broadcasts them. This covers
  scripts and text resources (`FILESYNC_EXTENSIONS`) plus `project.godot` and
  `export_presets.cfg`.
- Scene files (`.tscn`/`.scn`) are **not** handled here; they go through the
  structured scene-operation stream.
- Written to disk only; never imported or executed by the add-on, and only
  inside the approved project root.
- **Generated/cache data is excluded:** `.godot/`, `.git/`, and, critically,
  **`addons/`**. See the warning below.
- Bounded: `FILESYNC_MAX_FILES` (8000) tracked files, per-file size capped by
  `MAX_WORKSPACE_FILE_BYTES`, scan interval `FILESYNC_INTERVAL_MS` (1200 ms).
  Very large projects or rapid save storms may lag behind the scan interval.
- File sync does **not** hot-reload a running editor. A received `.gd`/`.tres`
  takes effect when the editor recompiles/reloads it, not instantly on arrival.

### Warning: do not edit the add-on's own files during a live session

- Editing anything under `addons/` while a session is live is **forbidden**.
  The add-on's scripts are executing inside the editor; changing them live can
  crash the local editor and, because a large transfer can also be relayed to
  other participants, crash their clients and corrupt their project copies.
- The guard is twofold: `addons/` is excluded from `EXCLUDED_PREFIXES` (file
  authoring) and `FILESYNC_EXCLUDED_PREFIXES` (file sync), and the dock shows a
  warning when a session starts. The exclusion is the enforced part; treat the
  warning as the rule.

## Project download

- A **complete snapshot** download is the supported path. Partial/on-demand file
  streaming is **not** implemented.
- Generated import/cache data (`.godot/`) is excluded. `.git/` is excluded from
  ordinary workspace downloads.
- After download the user opens the copied project in a new editor instance; the
  add-on does not hot-swap the current project.
- Downloads respect per-file and total size limits; larger projects must raise
  the limits or exclude files.

## Git presence mode

- Presence + cursors only. Local files are never overwritten.
- Uncommitted changes do **not** travel between machines through the add-on or
  through Git. Normal Git operations remain responsible for distributing and
  merging commits.
- Presence-only mode is independent of host-workspace mode; the two do not
  interconvert automatically.

## Scale and lifecycle

- The primary target is **two people**. More peers are allowed up to the
  configured maximum, but behaviour at higher counts is not load-tested.
- The add-on tracks connected peer ids manually because this engine build's
  `MultiplayerPeer` exposes no peer enumeration; this is correct but means peer
  state is derived from signals rather than queried from the peer.
