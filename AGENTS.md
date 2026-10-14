# Project: Godot Collab — Collaborative Godot Editor Add-on

You are building a Godot editor add-on that adds Roblox Studio-style multiplayer collaboration to the Godot 4.7.2 editor.

The add-on must be a real editor plugin, not a game project that imitates the editor. It must integrate with the actual Godot editor UI and work inside the 3D editor viewport.

## Core requirements

- Engine version: Godot 4.7.2 stable.
- Language: strictly typed GDScript.
- Plugin path: `addons/godot_collab/`.
- Primary interface: a dock inside the Godot editor.
- Transport: Godot's ENet networking, using UDP.
- Initial collaboration target: two people working on a shared project.
- Host: authoritative owner of the collaborative workspace.
- Client: can join the host's workspace, see remote users, and submit supported scene changes.
- Project delivery: downloading a host project snapshot must be supported before attempting partial/on-demand file streaming.
- Git support: both users can open separate local checkouts of the same repository in a presence-only mode.
- All functionality must work in the editor; do not require running the user's game to enable collaboration.

Use Godot 4.7/4.7.2 documentation and the APIs available in the installed engine. Verify uncertain API names and signatures from the class reference or installed engine. Do not guess APIs, and do not silently substitute a different API when a method is unavailable.

## Development rules

1. Inspect the working directory before modifying it. If a project already exists, preserve its structure and unrelated files.
2. Start by producing a concise architecture and implementation checklist.
3. Work in small, verifiable milestones. Implement, test, and document each milestone before proceeding.
4. Use strict typing, explicit error handling, descriptive names, and small focused scripts.
5. Use `@tool` and editor-specific APIs where required.
6. Never modify the editor's global multiplayer peer as a shortcut. Isolate the add-on's networking from Godot editor internals. Verify the correct approach for using an independent MultiplayerAPI/SceneMultiplayer or an isolated packet-processing layer in Godot 4.7.2.
7. Avoid unnecessary external dependencies, native extensions, C#, and custom engine builds.
8. Do not leave essential behavior as TODOs, placeholder functions, or mock networking in the final implementation.
9. Do not claim internet connectivity works until the relevant connection path has actually been implemented and tested.
10. Keep a `README.md`, an architecture document, a known-limitations section, and reproducible test instructions.

## Milestone 1: Plugin foundation

Create the add-on with a valid `plugin.cfg` and an `EditorPlugin` entry point.

Suggested initial structure:

- `addons/godot_collab/plugin.cfg`
- `addons/godot_collab/plugin.gd`
- `addons/godot_collab/ui/collab_dock.gd`
- `addons/godot_collab/network/`
- `addons/godot_collab/presence/`
- `addons/godot_collab/collaboration/`
- `addons/godot_collab/project_transfer/`
- `addons/godot_collab/security/`
- `addons/godot_collab/tests/`
- `tools/rendezvous_server/`
- `README.md`
- `docs/ARCHITECTURE.md`
- `docs/LIMITATIONS.md`

You may change this structure if you provide a clear reason.

The dock must contain:

- Username field.
- Current connection status.
- Host Session button.
- Join Session button.
- Generated invitation code and copy button.
- Session-code input.
- Participant list with usernames and host/client roles.
- Disconnect button.
- Current collaboration mode.
- Project synchronization status.
- Error/status messages.

Persist preferences such as username and display options using an appropriate editor settings mechanism. Do not place session secrets in committed project files.

The plugin must cleanly enable and disable without leaving nodes, timers, network peers, callbacks, or port mappings behind.

## Milestone 2: ENet connection layer

Create a reusable network/session manager.

Responsibilities:

- Start a host with a configurable UDP port and peer limit.
- Connect a client to an explicit IP address and UDP port.
- Detect connection success, connection failure, peer departure, and host disconnection.
- Exchange protocol version, username, assigned session peer ID, project identity, and session capabilities.
- Maintain an authoritative participant list.
- Validate all incoming message types and payload sizes.
- Handle timeouts, stale participants, reconnects, and intentional disconnects.
- Provide structured errors to the dock.

Use reliable delivery for session management, scene operations, and file-transfer control messages. Use an appropriate unreliable or unreliable-ordered mode for frequently updated cursor state.

Do not send script text, arbitrary Object instances, or untrusted serialized objects as network messages. Define explicit serializable data structures and safe conversion routines.

Keep networking and UI separate. The UI must not contain the core protocol logic.

## Milestone 3: Session codes and connectivity

Create an invitation subsystem with a clean boundary between session-code lookup and the ENet transport.

The invite code must resolve to a real, usable session. Do not generate a random code and assume that this makes the host reachable.

Implement:

- Host-side session registration.
- Code expiration and explicit session closure.
- A join flow that resolves a code to a host endpoint and authentication challenge.
- Configurable direct-connect addresses for testing and LAN usage.
- Optional UPnP UDP port forwarding, with errors and cleanup handled properly.
- Manual port-forwarding and direct-address fallback instructions.
- A small optional rendezvous service under `tools/rendezvous_server/` if required for short human-shareable codes.

The rendezvous service maps short invitation codes to connection information. It is not automatically an ENet relay.

The host must display the session's actual connectivity state. Distinguish between LAN-only connectivity, externally reachable direct connectivity, and a connection that has not been verified.

Document that UPnP can fail and that CGNAT, restrictive firewalls, or unsupported routers can prevent direct connections. Design the transport/session interfaces so a relay can be added later without rewriting the editor UI.

Do not build a relay into the initial milestone unless direct connectivity is already working and tested.

## Milestone 4: Remote 3D cursor and participant presence

Use the official Godot editor APIs.

Investigate and use the appropriate Godot 4.7.2 APIs, including:

- `EditorPlugin._forward_3d_gui_input()`
- `EditorPlugin._forward_3d_draw_over_viewport()`
- `EditorPlugin.update_overlays()`
- `EditorInterface.get_editor_viewport_3d()`
- `Viewport.get_camera_3d()`

Check actual signatures and required setup conditions before implementation.

Requirements:

- Capture mouse movement in the editor's 3D viewport without breaking standard editor interactions.
- Obtain the sender's editor-camera transform and construct a world-space cursor ray.
- Synchronize the sender's world-space camera transform, ray origin/direction or equivalent representation, normalized viewport cursor position where useful, username, timestamp, and scene identity.
- Show other users' cursors and usernames as visual overlays/markers in the local editor viewport.
- Use distinct, consistent colors per participant and make the local user distinguishable from remote users.
- Support camera positions and viewing directions that differ between users.
- Make cursor visualization configurable, including marker depth/size and labels.
- Interpolate cursor updates for smoothness.
- Rate-limit cursor updates and discard stale state.
- Hide remote markers outside the current view or when they are behind the local view camera, as appropriate.
- Remove a participant's visualization immediately on disconnect.
- Do not consume viewport inputs unless absolutely necessary.

Do not claim the cursor is placed on the exact surface under the other user's pointer unless accurate surface-picking integration has been implemented. A configurable 3D cursor point on the remote camera ray is an acceptable first implementation.

Verify whether the editor invokes the viewport input callbacks in the required state. If a callback requires an edited scene root or additional plugin setup, implement and document it correctly.

## Milestone 5: Collaborative scene-edit protocol

Implement host-authoritative scene collaboration.

Important: Godot does not automatically replicate arbitrary changes made through every editor panel. Do not attempt to solve this with repeated overwrites of entire `.tscn` files.

Create a protocol that represents supported edits as structured operations. Each operation should contain the session ID, operation ID, source peer, scene identity, target node ID, base revision, operation type, and validated arguments.

Begin with:

- Initial scene snapshot and resynchronization.
- Node creation for supported node types.
- Node removal.
- Node rename.
- Node reparenting.
- `Node3D` position, rotation, and scale changes.
- A restricted set of common Inspector property changes.
- Resource references represented by validated resource paths or explicitly supported serialized values.
- Conflict reporting and authoritative host responses.

Use stable session-level node IDs rather than relying entirely on node paths that change when nodes are renamed or reparented. Maintain mappings from those IDs to local nodes on each peer.

The protocol must:

- Support host-originated and client-originated changes.
- Apply accepted client operations to the host's edited scene.
- Broadcast authoritative changes to participants.
- Avoid rebroadcast loops when applying remote operations.
- Validate node types, properties, paths, operation payloads, and scene revisions.
- Reject unsupported property types cleanly.
- Request a snapshot when a peer's scene state cannot be reconciled.
- Detect when users are editing different scenes or incompatible project revisions.
- Prevent a disconnected client from submitting stale operations.
- Provide visible errors and conflict information rather than silently discarding changes.

Use a snapshot/diff watcher for supported changes made through the normal Godot editor when a reliable general-purpose editor event is unavailable. Debounce scans and keep the implementation performant. Prefer editor undo/redo and editor-safe change mechanisms when available.

For simultaneous edits to the same property, make the host authoritative and establish a deterministic conflict policy based on accepted operation order and revisions. Document the policy.

Do not claim that arbitrary script editing, all resource types, import settings, project settings, animation editors, shaders, or every custom inspector are synchronized unless each feature has actually been implemented and tested.

## Milestone 6: Saving shared changes

The host owns the authoritative workspace and saved output in host-owned-workspace mode.

Requirements:

- Make accepted shared scene changes appear in the host's live edited scene.
- Mark the scene as modified when necessary.
- Provide an explicit Save Shared Scene command.
- Add optional configurable auto-save after a short inactivity period.
- Report the last successful save and any failure.
- Use appropriate editor saving APIs, such as `EditorInterface.save_scene()` for the currently active scene, where applicable.
- Avoid saving unrelated scenes or project files unintentionally.
- Never replace a scene file on disk while ignoring the editor's in-memory unsaved changes.
- Warn the host before potentially destructive operations.

Test saving by restarting the editor and reopening the scene. Verify that accepted changes persist on the host's computer.

## Milestone 7: Project download and on-demand files

The client must be able to download a project snapshot from the host.

Implement:

- A manifest of eligible project files.
- Project identity and file size information.
- Bounded, chunked file transfers.
- A per-file checksum such as SHA-256.
- Transfer progress, cancellation, errors, and retry support.
- A local download/cache directory chosen by the user.
- Safe path validation and rejection of absolute paths, path traversal, and symlink escapes.
- A configurable per-file and total-project size limit.
- Clear handling of missing, changed, and incompatible resources.

Default to transferring source project files, not generated `.godot/` import/cache data. Exclude `.git/` from ordinary workspace downloads unless an explicit Git-clone mode requests it.

After downloading, validate the presence of `project.godot` and required files. Explain how to open the local copy in a new Godot editor instance.

Only implement partial/on-demand file delivery after complete snapshot download works. Streaming should mean that files are delivered into a local workspace/cache as needed; do not pretend that a regular Godot editor project can be edited directly from an arbitrary remote file stream.

For security, restrict the host to an explicitly approved project root. Do not expose arbitrary filesystem paths to clients.

## Milestone 8: Git presence mode

Provide a mode for users who already share a Git repository and maintain their own local checkouts.

In this mode:

- Do not automatically overwrite project files or replace another user's local checkout.
- Exchange presence, remote cursors, usernames, scene identity, project identity, and relevant status.
- Warn when participants have different project identities or scene revisions.
- Explain that normal Git operations are still responsible for distributing commits and merging changes.
- Do not imply that uncommitted files automatically travel between computers through Git.
- Keep presence-only mode independent of the authoritative host workspace mode.

Allow the host to choose the workspace policy for each session. Show the current mode prominently so users know whether they are editing the host-owned workspace or their own checkout.

## Security and reliability requirements

- Require the host to approve a new participant before granting workspace access.
- Treat invitation codes as temporary credentials, not permanent identities.
- Rate-limit failed session lookups and join attempts in the rendezvous service.
- Validate packet types and limit message sizes, recursion, transfer sizes, and operation rates.
- Do not allow clients to read arbitrary host filesystem paths.
- Do not automatically execute transferred scripts or downloaded projects.
- Keep all disk writes inside the approved workspace.
- Reject path traversal and unsafe paths before any filesystem operation.
- Fail safely on incompatible protocol versions.
- Close connections and clean up port mappings when sessions terminate.
- Document that basic ENet UDP traffic is not encrypted by default; do not claim confidentiality or secure authentication unless those protections are actually implemented.

## Testing requirements

Create a minimal test project and a reproducible manual integration test procedure.

Test with two separate Godot 4.7.2 editor instances and separate project copies.

Verify:

1. The plugin enables, disables, and reloads without errors.
2. Host and client can connect over loopback or LAN.
3. Usernames and participant lists update.
4. Remote 3D cursors follow their users and disappear after disconnect.
5. Regular editor mouse controls continue to work.
6. Incompatible project/scene identities produce a clear warning.
7. Supported edits appear on both peers without replication loops.
8. Concurrent edits have deterministic conflict behavior.
9. The host can save a shared scene and retain changes after reopening it.
10. Project downloads preserve eligible files and pass checksum validation.
11. Invalid paths and oversized messages are rejected.
12. A client cannot access files outside the approved workspace.
13. Network failures and connection interruptions produce useful messages.
14. The Git presence-only mode does not silently overwrite local work.

Run available Godot headless parsing/smoke tests and report the exact commands and outcomes. If a test requires a GUI or two interactive editor processes, document that explicitly instead of claiming it passed.

## Definition of done

The repository must contain the complete add-on, installation instructions, a clear architecture document, security notes, a test project, and a list of known limitations.

The first complete milestone must provide a working editor dock, an actual ENet connection, usernames, remote 3D cursors, participant presence, and a usable disconnect/reconnect workflow.

The later milestones must be implemented as working features or explicitly documented as not yet implemented. Do not disguise unimplemented functionality with mock responses or success messages.

Start by inspecting the workspace and installed Godot version, then present the implementation checklist and begin with the smallest working vertical slice.
