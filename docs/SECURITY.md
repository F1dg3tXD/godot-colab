# Security notes

Collaboration means accepting data and influence from another person's machine.
This document states what the add-on protects against, what it does **not**
protect against, and how to configure it safely.

## What is protected

- **No object deserialization.** Wire payloads are plain dictionaries encoded
  with `var_to_bytes`. Godot's `Object`/script encoding is never enabled on the
  wire, so a peer cannot smuggle a serialized `Object`, resource, or script into
  the host.
- **Bounded packets.** Every packet is validated for magic, protocol version,
  message type, and payload length (`MAX_PACKET_PAYLOAD`, 1 MiB). Per-type
  validators cap string lengths, array sizes, operation batch sizes
  (`MAX_OPS_PER_MESSAGE`), and file-transfer chunk sizes (`MAX_TRANSFER_CHUNK`,
  512 KiB). Oversized or malformed packets are dropped before decoding.
- **Admitted-peers-only processing.** Only handshake messages are processed from
  peers that have not been admitted. A connected-but-unapproved client cannot
  submit scene, save, or transfer messages.
- **Host approval.** By default the host must approve each new participant
  before it gains workspace access (`KEY_APPROVE_JOINS`).
- **Invite token.** When required, a HELLO token is compared using a
  constant-time comparison (`CollabSessionCoordinator._constant_time_equal`) to
  resist trivial timing attacks. Tokens are per-session and temporary.
- **Path safety.** Project transfers reject absolute paths, `..` traversal, and
  symlink escapes via `CollabPathGuard`, before any filesystem operation. All
  writes stay inside the explicitly approved destination directory. The host
  never accepts an arbitrary host filesystem path from a client.
- **Rate limiting.** `CollabRateLimiter` bounds join attempts, operation rates,
  and rendezvous lookups; the rendezvous server also rate-limits failed lookups
  per IP.
- **No auto-execution.** Transferred scripts are never executed and downloaded
  projects are never opened or run automatically. The user opens a downloaded
  project manually.
- **Clean teardown.** Closing a session closes the ENet peer and removes any
  UPnP mapping; disabling the plugin tears everything down.

## What is not protected

- **Confidentiality.** ENet UDP traffic is **not encrypted**. Anyone able to
  observe the traffic can read it. The add-on makes no confidentiality claim.
- **Authentication/identity.** The invite token is a shared bearer secret, not a
  verified identity. Anyone who obtains the code/token can attempt to join (the
  host still has to approve). There is no public-key identity, no signed
  handshake, and no replay protection beyond short code expiry.
- **Man-in-the-middle.** Without transport encryption there is no protection
  against an active network attacker.
- **Interfaces expose endpoints.** Direct invites contain a host IP and port.
  Treat direct invite strings as sensitive.

## Invitation codes

- Invitation codes are **temporary credentials**, not permanent identities.
  Short codes expire (`INVITE_TTL_SECONDS`, default 600 s) and are refreshed by
  the host while the session is open; codes are unregistered on session close.
- Do not post invitation codes publicly. Prefer sharing them out of band.

## Rendezvous service

- Ships configured for localhost/plain HTTP. For any non-local use, run it behind
  TLS (reverse proxy) and treat codes as secrets. It maps codes to endpoints and
  rate-limits failed lookups, but it does not authenticate hosts.
- The rendezvous service does not relay session traffic.

## Recommended safe configuration

- Keep **require invite token** and **approve joins** enabled.
- Prefer LAN or a trusted network for testing; use a VPN or a TLS-terminated
  rendezvous setup for anything wider.
- Set conservative **per-file** and **total transfer** limits and a dedicated
  download directory.
- Only approve participants you expect.
