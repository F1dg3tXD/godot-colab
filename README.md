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

- Editor dock with username, connection status, host/join controls, generated
  invitation code, participant list, disconnect, collaboration mode, project
  sync status, and error messages.
- Isolated ENet/UDP session (host-authoritative). The add-on never touches the
  editor's global `MultiplayerAPI` peer.
- Direct IP:port connections and short invitation codes resolved through an
  optional rendezvous service (`tools/rendezvous_server/`).
- Optional UPnP UDP port mapping, with honest connectivity reporting
  (LAN-only vs. externally reachable vs. unverified).
- Remote 3D cursors and usernames drawn in the editor viewport, with per-user
  colours, interpolation, rate limiting, and stale-state removal.
- Host-authoritative scene operations: node create/remove/rename/reparent and
  `Node3D` transform plus a restricted set of Inspector properties.
- Explicit **Save Shared Scene** and optional auto-save on the host.
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

1. In editor **A**: open the dock, set a username, click **Host Session**.
   Copy the invitation code from the dock.
2. In editor **B**: set a username, paste the code into the session-code field,
   click **Join Session**.
3. The host sees an approval prompt; click **Approve**. Both docks now list two
   participants with host/client roles.
4. Move the mouse over editor **A**'s 3D viewport; a coloured cursor and username
   appear in editor **B**'s viewport (and vice-versa).
5. With a scene open on both sides, edit a `Node3D` transform (via the Inspector
   or the 3D gizmo). The change is applied to the host's scene and broadcast.

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
  collaboration/               scene ops, node-id mapping, diff watcher, save service
  project_transfer/            project manifest + chunked transfer manager
  security/                    path validation + rate limiting
  ui/                          editor dock
  tests/                       headless test harness
tests/minimal_project/         minimal 3D project for two-editor tests
tools/rendezvous_server/       optional rendezvous service (Python stdlib)
docs/                          architecture, limitations, security, testing
```

## License

See repository root. (Add a license before distributing.)
