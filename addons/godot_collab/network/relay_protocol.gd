@tool
## Framing for the optional dedicated relay server.
##
## The relay is a dumb star forwarder: peers connect to it over ENet (outbound
## UDP, so no port forwarding or NAT traversal is required) and it forwards
## opaque [CollabProtocol] packets between the session host and its clients. The
## relay never inspects application payloads, so it cannot be used to read scene
## or file data beyond the already-opaque bytes it must move.
##
## Each relay-level packet is a 10 byte header (`GCRL` magic, version, kind,
## u32 payload length) followed by a kind-specific body. [DATA] packets carry a
## u32 origin and u32 destination before the wrapped application bytes so a peer
## can address a specific participant even though every peer is otherwise
## connected only to the relay.
class_name CollabRelayProtocol
extends RefCounted

static var MAGIC: PackedByteArray = PackedByteArray([0x47, 0x43, 0x52, 0x4C]) # "GCRL"
const VERSION: int = 1
const HEADER_SIZE: int = 10
const MAX_PAYLOAD: int = CollabConstants.MAX_PACKET_PAYLOAD + 64

enum Kind {
	INVALID = 0,
	REGISTER = 1, ## client -> relay: join a room
	REGISTERED = 2, ## relay -> client: assigned id + host id
	DATA = 3, ## both ways: wrapped application bytes
	MEMBER_JOIN = 4, ## relay -> peers: a participant joined
	MEMBER_LEAVE = 5, ## relay -> peers: a participant left / the room closed
	ERROR = 6, ## relay -> client: registration refused
	KICK = 7, ## client -> relay: drop a participant
}

## Roles a peer can register with.
enum Role {
	HOST = 0,
	CLIENT = 1,
}

## The relay-assigned id of the session host. Clients see host-originated traffic
## as coming from this id, matching the direct-connect [constant CollabSessionCoordinator.HOST_PEER_ID].
const HOST_APP_ID: int = 1


static func encode_register(room: String, role: int, token: String, max_peers: int) -> PackedByteArray:
	return _frame(Kind.REGISTER, var_to_bytes({"room": room, "role": role, "token": token, "max_peers": max_peers}))


static func encode_registered(peer_id: int, host_id: int) -> PackedByteArray:
	return _frame(Kind.REGISTERED, var_to_bytes({"peer_id": peer_id, "host_id": host_id}))


static func encode_member_join(peer_id: int, role: int) -> PackedByteArray:
	return _frame(Kind.MEMBER_JOIN, var_to_bytes({"peer_id": peer_id, "role": role}))


static func encode_member_leave(peer_id: int) -> PackedByteArray:
	return _frame(Kind.MEMBER_LEAVE, var_to_bytes({"peer_id": peer_id}))


static func encode_error(message: String) -> PackedByteArray:
	return _frame(Kind.ERROR, var_to_bytes({"message": message}))


static func encode_kick(peer_id: int) -> PackedByteArray:
	return _frame(Kind.KICK, var_to_bytes({"peer_id": peer_id}))


## Wraps application bytes for the relay. [param origin] is filled in by the
## relay on the receiving side (peers send 0); [param dest] selects a single
## participant or [constant MultiplayerPeer.TARGET_PEER_BROADCAST].
static func encode_data(origin: int, dest: int, app_bytes: PackedByteArray) -> PackedByteArray:
	var body: PackedByteArray = PackedByteArray()
	_append_u32(body, origin)
	_append_u32(body, dest)
	body.append_array(app_bytes)
	return _frame(Kind.DATA, body)


## Decode result:
## { ok, error, kind, room, role, token, max_peers, peer_id, host_id, origin,
##   dest, data }
static func decode(packet: PackedByteArray) -> Dictionary:
	var result: Dictionary = {"ok": false, "error": "empty", "kind": Kind.INVALID, "data": PackedByteArray()}
	if packet.size() < HEADER_SIZE:
		result["error"] = "short"
		return result
	for i in MAGIC.size():
		if packet[i] != MAGIC[i]:
			result["error"] = "bad magic"
			return result
	if packet[4] != VERSION:
		result["error"] = "bad version"
		return result
	var kind: int = packet[5]
	var length: int = _read_u32(packet, 6)
	if length < 0 or length > MAX_PAYLOAD:
		result["error"] = "bad length"
		return result
	if packet.size() - HEADER_SIZE != length:
		result["error"] = "length mismatch"
		return result
	var body: PackedByteArray = packet.slice(HEADER_SIZE)
	result["kind"] = kind
	if kind == Kind.DATA:
		if body.size() < 8:
			result["error"] = "short data"
			return result
		result["origin"] = _read_u32(body, 0)
		result["dest"] = _read_u32(body, 4)
		result["data"] = body.slice(8)
		result["ok"] = true
		result["error"] = ""
		return result
	var payload: Variant = bytes_to_var(body)
	if typeof(payload) != TYPE_DICTIONARY:
		result["error"] = "bad payload"
		return result
	match kind:
		Kind.REGISTER:
			result["room"] = str((payload as Dictionary).get("room", ""))
			result["role"] = int((payload as Dictionary).get("role", Role.CLIENT))
			result["token"] = str((payload as Dictionary).get("token", ""))
			result["max_peers"] = int((payload as Dictionary).get("max_peers", 0))
		Kind.REGISTERED:
			result["peer_id"] = int((payload as Dictionary).get("peer_id", 0))
			result["host_id"] = int((payload as Dictionary).get("host_id", HOST_APP_ID))
		Kind.MEMBER_JOIN:
			result["peer_id"] = int((payload as Dictionary).get("peer_id", 0))
			result["role"] = int((payload as Dictionary).get("role", Role.CLIENT))
		Kind.MEMBER_LEAVE:
			result["peer_id"] = int((payload as Dictionary).get("peer_id", 0))
		Kind.ERROR:
			result["message"] = str((payload as Dictionary).get("message", "error"))
		Kind.KICK:
			result["peer_id"] = int((payload as Dictionary).get("peer_id", 0))
		_:
			result["error"] = "unknown kind"
			return result
	result["ok"] = true
	result["error"] = ""
	return result


static func _frame(kind: int, body: PackedByteArray) -> PackedByteArray:
	var out: PackedByteArray = PackedByteArray()
	out.append_array(MAGIC)
	out.append(VERSION)
	out.append(kind)
	_append_u32(out, body.size())
	out.append_array(body)
	return out


static func _append_u32(buf: PackedByteArray, value: int) -> void:
	var v: int = value & 0xFFFFFFFF
	buf.append((v >> 24) & 0xFF)
	buf.append((v >> 16) & 0xFF)
	buf.append((v >> 8) & 0xFF)
	buf.append(v & 0xFF)


static func _read_u32(buf: PackedByteArray, offset: int) -> int:
	if offset + 4 > buf.size():
		return -1
	return (buf[offset] << 24) | (buf[offset + 1] << 16) | (buf[offset + 2] << 8) | buf[offset + 3]
