# Known limitations

This add-on intentionally implements a bounded, host-authoritative subset of
collaboration. The following are **not** implemented or not yet verified. They
are listed explicitly so nothing here is mistaken for working functionality.

## Verification status

- The headless test suite (`addons/godot_collab/tests/run_tests.gd`) covers the
  protocol framing/validation, invitation codes, path guard, rate limiter, and
  an ENet loopback handshake/cursor/disconnect flow. It passes (see
  [`TESTING.md`](TESTING.md)).
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

- Only a **restricted** set of edits is synchronized:
  - Node creation for supported node types.
  - Node removal, rename, reparent.
  - `Node3D` position/rotation/scale.
  - A restricted set of common Inspector properties.
- **Not synchronized:** arbitrary script editing, all resource types, import
  settings, project settings, animation editors, shaders, particle/tilemap/
  material sub-editors, and custom inspectors. Do not assume these propagate.
- Resource references are carried as validated resource paths or explicitly
  supported serialized values; not every resource kind is handled.
- The diff watcher is bounded and best-effort. Very rapid edits or unsupported
  panels may produce changes that are not detected until the next scan or a
  resynchronization.
- Conflict handling is deterministic (host order + revision) but is not a full
  CRDT/operational-transform system.

## Presence and cursors

- A remote cursor is a configurable point on the remote user's camera ray. It is
  **not** guaranteed to lie on the exact surface under the remote pointer
  (no guaranteed surface picking).
- Cursors for users viewing a different scene or outside the local view may be
  hidden.

## Saving

- The host saves the **currently active** edited scene via
  `EditorInterface.save_scene()`. Other open scenes and project files are not
  saved by a shared-save command.
- Auto-save is optional and time-based (after an inactivity period), not a
  robust transactional save.

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
