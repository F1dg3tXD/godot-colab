# Godot Collab

Roblox Studio-style multiplayer collaboration for the **Godot 4.7.2 editor**.

Godot Collab is a real editor add-on (an `EditorPlugin`), not a game project that
imitates the editor. It adds a dock to the Godot editor, opens an isolated ENet
(UDP) session, shows remote users' 3D cursors in the editor's 3D viewport, and
lets a host own an authoritative shared scene that clients can edit through a
structured, validated operation protocol.

> Status: early but functional. The connection layer, participant presence,
> remote 3D cursors, and the host-authoritative scene-edit protocol are
> implemented. See [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) for exactly what
> is and is not supported today.

## Features

- **Top-toolbar controls** (Host, Join, Copy Code, Request Snapshot, Disconnect)
  next to the playtest buttons, plus an editor dock with username, connection
  status, generated invitation code, session-code input, participant list,
  collaboration mode, project sync status, and error messages.
- Isolated ENet/UDP session (host-authoritative). The add-on never touches the
  editor's global `MultiplayerAPI` peer.
- Direct IP:port connections and short invitation codes resolved through an
  optional rendezvous service (`tools/rendezvous_server/`).
- Optional UPnP UDP port mapping, with honest connectivity reporting
  (LAN-only vs. externally reachable vs. unverified).
- Remote 3D cursors and usernames drawn in the editor viewport, with per-user
  colours, interpolation, rate limiting, and stale-state removal.
- Live 3D `editorNodeVis` markers for each remote participant, so collaborators
  see each other moving in the editor's 3D view in real time.
- Host-authoritative scene operations: node create/remove/rename/reparent,
  `Node3D` transform, and the **general Inspector-property set** (derived from
  `get_property_list()`, not a fixed whitelist), including slash sub-properties
  such as `surface_material_override/0` and `theme_override_*`, both host→client
  and client→host.
- **Resource reference sync.** Assigning a resource in the Inspector (a material,
  texture, `Environment`, …) is synced. File-backed resources travel by `res://`
  path; **embedded (path-less) resources** — e.g. a material created inline, or a
  texture dragged straight from the filesystem — are serialised and rebuilt on
  the other side. In-place edits to an embedded resource (changing its colour)
  are detected through the resource's `changed` signal. Executable payloads
  (scripts, packed scenes) are refused.
- **Multi-scene collaboration.** Every open scene is tracked independently, so
  collaborators can work in different scenes at once and the host switching tabs
  never reverts anyone's edits. Changes to a scene the host is not viewing are
  applied and persisted on the host.
- **Source-file sync.** Changed scripts, resources, `project.godot` and binary
  assets (images, models, audio, fonts) are relayed to the host and to other
  peers (generated caches and, deliberately, `addons/` are excluded). Files are
  written to disk only, never executed. A scene file that is *open in the editor*
  is protected: it is driven by the operation stream, not by raw file writes.
- **Workspace authoring.** Collaborators can ask the host to create a new scene
  or add a project file — including by dropping a binary asset into the
  Filesystem dock; the host validates it (path/size/extension) and distributes a
  local copy to every peer.
- **Ctrl+S just works.** In a host-workspace session, pressing Ctrl+S is promoted
  to a full *shared* save: the host persists every scene that received remote
  edits and notifies all peers. A client's Ctrl+S is forwarded to the host. This
  is on top of the explicit **Save Shared Scene** button.
- **Rejoin-safe node identity.** Node ids are host-authoritative only; a client
  that restarts onto a stale scene reconciles its ids to the host's on join, so
  its edits can never hit the wrong node.
- Explicit **Save Shared Scene** (persists remote edits, then saves the focused
  scene) and optional auto-save on the host.
- Host-owned project snapshot download (chunked, checksummed, path-safe) that
  builds a local project copy.
- **Git presence mode**: presence + cursors only, for users who already share a
  Git repository and keep their own checkouts.

## Requirements

- Godot **4.7.2** stable.
- GDScript only. No native extensions, no C#, no custom engine build, no
  third-party dependencies.
- Python 3 (standard library only) only if you want to run the optional
  rendezvous service.

## Installation

1. Copy `addons/godot_collab/` into your Godot project's `addons/` directory.
2. Open the project in Godot 4.7.2.
3. `Project > Project Settings > Plugins`, then enable **Godot Collab**.
4. A **Godot Collab** dock appears (left, upper-right slot).

To remove it, disable the plugin. It tears down its nodes, timers, network
peers, and UPnP mapping.

## Quick start (two editors on one machine)

1. In editor **A**: open the dock, set a username, click **Host** in the top
   toolbar. Copy the invitation code from the dock (**Copy Code** in the toolbar).
2. In editor **B**: set a username, paste the code into the dock's session-code
   field, click **Join** in the top toolbar.
3. Both docks now list two participants with host/client roles. (Host approval is
   off by default for easy LAN use; enable *Require host approval* in the dock on
   untrusted networks, and the host will then confirm each join.)
4. Move the mouse over editor **A**'s 3D viewport; a coloured cursor and username
   appear in editor **B**'s viewport (and vice-versa).
5. With a scene open on both sides, edit a `Node3D` transform (via the Inspector
   or the 3D gizmo) or any other Inspector property. The change is applied to the
   host's scene and broadcast; client edits reach the host too. Changes to source
   files (scripts, `project.godot`) are relayed as well — but never edit files
   under `addons/` while a session is live.

For LAN testing, use the host's LAN IP in a direct invitation. For internet
testing, run the rendezvous service and/or configure UPnP or manual port
forwarding. See [`docs/TESTING.md`](docs/TESTING.md).

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — components, data flow,
  protocol, conflict policy.
- [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) — what is not implemented or
  verified yet.
- [`docs/SECURITY.md`](docs/SECURITY.md) — threat model and protections.
- [`docs/TESTING.md`](docs/TESTING.md) — reproducible automated and manual tests.
- [`tools/rendezvous_server/`](tools/rendezvous_server/) — optional short-code
  lookup service.

## Repository layout

```
addons/godot_collab/
  plugin.cfg, plugin.gd        EditorPlugin entry point + wiring
  core/                        constants, settings, logging, identity
  network/                     wire protocol, ENet session manager, participants
  session/                     session coordinator, invite codes, rendezvous, UPnP, connectivity
  presence/                    local/remote cursor sampling and overlay drawing
  collaboration/               per-scene sync contexts, scene ops, node-id mapping, diff watcher, save, workspace authoring + source-file sync
  project_transfer/            project manifest + chunked transfer manager
  security/                    path validation + rate limiting
  ui/                          editor dock + top-toolbar controls
  tests/                       headless test harness
tests/minimal_project/         minimal 3D project for two-editor tests
tools/rendezvous_server/       optional rendezvous service (Python stdlib)
docs/                          architecture, limitations, security, testing
```

## License

See repository root. (Add a license before distributing.)
