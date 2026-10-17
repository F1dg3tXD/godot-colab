# Godot Collab relay server

A small, optional dedicated server that lets two Godot editors collaborate over
the internet **without port forwarding**. The session host and every client make
outbound ENet/UDP connections to the relay; the relay forwards opaque packets
between them.

It is deliberately *not* an application server:

- It never parses scene, workspace, file or transfer payloads — it only moves the
  already-framed bytes (`CollabRelayProtocol`).
- It holds rooms in memory only and writes nothing to disk.
- It is not an authentication authority: it forwards the session-token
  handshake between peers, and enforces the room token it was given at
  registration time.
- Traffic is plain ENet/UDP; it is **not encrypted**. Do not use it for
  confidential data without an external tunnel (for example WireGuard/SSH).

## Running

The relay reuses the add-on's Godot classes, so run it with a Godot 4.7.2 binary
from a project that has the add-on installed (this repository works):

```sh
godot --headless --script tools/relay_server/relay_server.gd -- --port 45900
```

Options (after `--`):

| Option | Default | Meaning |
| --- | --- | --- |
| `--port <n>` | `45900` | UDP port to listen on |
| `--max-clients <n>` | `64` | Maximum simultaneous ENet clients |
| `--bind <address>` | `*` | Bind address (`*` = all interfaces) |
| `--help` | | Show usage |

Open the chosen UDP port in the relay host's firewall. The relay does **not**
need to be reachable from the editors on any port other than this one.

## How editors use it

1. In the dock, tick **Use a relay server** and enter the relay address (`host`
   or `host:port`).
2. Click **Host**. The dock generates a short room code and a `gc2.…` invitation
   that embeds the relay endpoint, the room and the session token.
3. A joining editor pastes the `gc2.…` code and joins through the same relay.

The relay assigns the host application id `1` and clients `2, 3, …`, mirroring
direct-connect ids, so the rest of the add-on is unchanged. When the host leaves,
the relay closes the room and disconnects its clients.

## Limits

- Rooms are per-relay-process and vanish when the host disconnects (or on
  restart). There is no persistence.
- A room accepts one host and up to `MAX_ROOM_MEMBERS` (32) participants.
- Only the host may kick a participant.
- There is no relay authentication beyond the room token; anyone who learns a
  room code *and* its token can join. Treat invitations as temporary credentials.

See [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md) and
[`docs/LIMITATIONS.md`](../../docs/LIMITATIONS.md) for the wider picture.
