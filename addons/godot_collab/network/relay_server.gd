@tool
## Dedicated relay server for internet sessions.
##
## Runs headless (see `tools/relay_server/`) and forwards opaque
## [CollabProtocol] packets between one session host and its clients so peers
## behind NAT, CGNAT or restrictive firewalls can collaborate without port
## forwarding. Both host and clients make an outbound ENet/UDP connection to the
## relay; the relay never opens inbound ports to participants.
##
## Participants register with a room code. The first host to register owns the
## room (and its token); clients must present the same token. The relay assigns
## the host application id 1 and clients 2, 3, ... so the existing coordinator
## logic (which assumes host id 1) works unchanged over a relay.
##
## The relay is explicitly *not* an application server: it never parses scene,
## transfer or workspace payloads, only wraps and routes bytes.
class_name CollabRelayServer
extends Node

signal status(text: String)

const DEFAULT_MAX_CLIENTS: int = 64
const MAX_ROOM_MEMBERS: int = 32

var _peer: ENetMultiplayerPeer = null
var _running: bool = false
## enet peer id -> { room: String, role: int, app_id: int }
var _peers: Dictionary = {}
## room -> { token: String, host_id: int, max_peers: int, members: { app_id: int: enet_id: int } }
var _rooms: Dictionary = {}
var _app_to_enet: Dictionary = {}
var _next_app_id: int = 2
var _logs: CollabLog = null


func _init(logs: CollabLog = null) -> void:
	_logs = logs


func set_logger(logs: CollabLog) -> void:
	_logs = logs


func is_running() -> bool:
	return _running


func start(port: int, max_clients: int = DEFAULT_MAX_CLIENTS, bind_address: String = "*") -> Error:
	if _running:
		return ERR_ALREADY_IN_USE
	var peer := ENetMultiplayerPeer.new()
	var err: Error = peer.create_server(port, maxi(1, max_clients), 3)
	if err != OK:
		_log_error("Relay failed to bind UDP %d: %s" % [port, error_string(err)])
		return err
	if bind_address != "*" and not bind_address.is_empty():
		peer.set_bind_ip(bind_address)
	peer.peer_connected.connect(_on_peer_connected)
	peer.peer_disconnected.connect(_on_peer_disconnected)
	_peer = peer
	_running = true
	_log_info("Relay listening on UDP %d (max %d clients)." % [port, max_clients])
	status.emit("Relay listening on UDP %d." % port)
	return OK


func stop() -> void:
	if _peer != null:
		if _peer.peer_connected.is_connected(_on_peer_connected):
			_peer.peer_connected.disconnect(_on_peer_connected)
		if _peer.peer_disconnected.is_connected(_on_peer_disconnected):
			_peer.peer_disconnected.disconnect(_on_peer_disconnected)
		_peer.close()
	_peer = null
	_peers.clear()
	_rooms.clear()
	_app_to_enet.clear()
	_next_app_id = 2
	_running = false


func poll() -> void:
	if _peer == null:
		return
	_peer.poll()
	while _peer != null and _peer.get_available_packet_count() > 0:
		var from_peer: int = _peer.get_packet_peer()
		var raw: PackedByteArray = _peer.get_packet()
		_handle(from_peer, raw)


func room_count() -> int:
	return _rooms.size()


# ---------------------------------------------------------------------------
# Registration / membership
# ---------------------------------------------------------------------------

func _handle(enet_id: int, raw: PackedByteArray) -> void:
	var decoded: Dictionary = CollabRelayProtocol.decode(raw)
	if not decoded.get("ok", false):
		_log_warn("Relay dropped a malformed packet from %d: %s" % [enet_id, str(decoded.get("error", "?"))])
		return
	var kind: int = int(decoded.get("kind", CollabRelayProtocol.Kind.INVALID))
	if kind == CollabRelayProtocol.Kind.REGISTER:
		_handle_register(enet_id, decoded)
	elif kind == CollabRelayProtocol.Kind.DATA:
		_handle_data(enet_id, decoded)
	elif kind == CollabRelayProtocol.Kind.KICK:
		_handle_kick(enet_id, decoded)


func _handle_register(enet_id: int, decoded: Dictionary) -> void:
	if _peers.has(enet_id):
		return
	var room: String = str(decoded.get("room", "")).strip_edges()
	if room.is_empty() or room.length() > 64:
		_reject(enet_id, "Invalid room code.")
		return
	var role: int = int(decoded.get("role", CollabRelayProtocol.Role.CLIENT))
	var token: String = str(decoded.get("token", ""))
	var requested_max: int = int(decoded.get("max_peers", 0))
	if role == CollabRelayProtocol.Role.HOST:
		if _rooms.has(room):
			_reject(enet_id, "Room '%s' already has a host." % room)
			return
		var room_max: int = clampi(requested_max if requested_max > 0 else MAX_ROOM_MEMBERS, 1, MAX_ROOM_MEMBERS)
		_rooms[room] = {"token": token, "host_id": CollabRelayProtocol.HOST_APP_ID, "max_peers": room_max, "members": {}}
		_register_member(enet_id, room, role)
		_log_info("Relay room '%s' opened by host." % room)
		return
	# Client registration.
	if not _rooms.has(room):
		_reject(enet_id, "No active host for room '%s'." % room)
		return
	var room_data: Dictionary = _rooms[room]
	if str(room_data.get("token", "")) != token:
		_reject(enet_id, "Invalid session token for room '%s'." % room)
		return
	if (room_data["members"] as Dictionary).size() >= int(room_data.get("max_peers", MAX_ROOM_MEMBERS)):
		_reject(enet_id, "Room '%s' is full." % room)
		return
	_register_member(enet_id, room, role)


func _register_member(enet_id: int, room: String, role: int) -> void:
	var app_id: int = CollabRelayProtocol.HOST_APP_ID if role == CollabRelayProtocol.Role.HOST else _next_app_id
	if role != CollabRelayProtocol.Role.HOST:
		_next_app_id += 1
	_peers[enet_id] = {"room": room, "role": role, "app_id": app_id}
	_app_to_enet[app_id] = enet_id
	(_rooms[room]["members"] as Dictionary)[app_id] = enet_id
	_send_to_enet(enet_id, CollabRelayProtocol.encode_registered(app_id, CollabRelayProtocol.HOST_APP_ID))
	# Tell the other members, and tell the newcomer about the existing host.
	_broadcast_room(room, CollabRelayProtocol.encode_member_join(app_id, role), app_id)
	_log_info("Relay: app %d (role %d) joined room '%s'." % [app_id, role, room])


func _handle_data(enet_id: int, decoded: Dictionary) -> void:
	var info: Variant = _peers.get(enet_id)
	if info == null:
		return
	var app_id: int = int((info as Dictionary)["app_id"])
	var role: int = int((info as Dictionary)["role"])
	var room: String = str((info as Dictionary)["room"])
	var app_bytes: PackedByteArray = decoded.get("data", PackedByteArray())
	if app_bytes.is_empty():
		return
	if role == CollabRelayProtocol.Role.HOST:
		var dest: int = int(decoded.get("dest", 0))
		var wrapped: PackedByteArray = CollabRelayProtocol.encode_data(app_id, dest, app_bytes)
		if dest == 0 or dest == MultiplayerPeer.TARGET_PEER_BROADCAST:
			_broadcast_room(room, wrapped, app_id)
		else:
			_send_to_app(room, dest, wrapped)
	else:
		# A client always speaks to the host; the relay stamps the true origin.
		_send_to_app(room, CollabRelayProtocol.HOST_APP_ID, CollabRelayProtocol.encode_data(app_id, CollabRelayProtocol.HOST_APP_ID, app_bytes))


func _handle_kick(enet_id: int, decoded: Dictionary) -> void:
	var info: Variant = _peers.get(enet_id)
	if info == null:
		return
	# Only the host may kick.
	if int((info as Dictionary)["role"]) != CollabRelayProtocol.Role.HOST:
		return
	var room: String = str((info as Dictionary)["room"])
	var target: int = int(decoded.get("peer_id", 0))
	var target_enet: Variant = _app_to_enet.get(target)
	if target_enet == null or target == CollabRelayProtocol.HOST_APP_ID:
		return
	_drop_member(room, target)
	if _peer != null and _peer.get_peer(int(target_enet)) != null:
		_peer.disconnect_peer(int(target_enet), true)


func _on_peer_connected(_peer_id: int) -> void:
	pass # Registration follows; nothing to do until then.


func _on_peer_disconnected(enet_id: int) -> void:
	var info: Variant = _peers.get(enet_id)
	if info == null:
		return
	var app_id: int = int((info as Dictionary)["app_id"])
	var room: String = str((info as Dictionary)["room"])
	if app_id == CollabRelayProtocol.HOST_APP_ID:
		_close_room(room)
	else:
		_drop_member(room, app_id)
	_broadcast_room(room, CollabRelayProtocol.encode_member_leave(app_id), app_id)


func _close_room(room: String) -> void:
	if not _rooms.has(room):
		return
	var members: Dictionary = (_rooms[room]["members"] as Dictionary).duplicate()
	for app_id in members.keys():
		var enet_id: int = int(members[app_id])
		_peers.erase(enet_id)
		_app_to_enet.erase(app_id)
		if _peer != null and _peer.get_peer(enet_id) != null:
			_peer.disconnect_peer(enet_id, false)
	_rooms.erase(room)
	_log_info("Relay room '%s' closed." % room)


func _drop_member(room: String, app_id: int) -> void:
	var enet_id: Variant = _app_to_enet.get(app_id)
	if enet_id != null:
		_peers.erase(int(enet_id))
	_app_to_enet.erase(app_id)
	if _rooms.has(room):
		(_rooms[room]["members"] as Dictionary).erase(app_id)


func _reject(enet_id: int, message: String) -> void:
	_send_to_enet(enet_id, CollabRelayProtocol.encode_error(message))
	if _peer != null:
		_peer.disconnect_peer(enet_id, false)


# ---------------------------------------------------------------------------
# Sending helpers
# ---------------------------------------------------------------------------

func _send_to_enet(enet_id: int, bytes: PackedByteArray) -> void:
	if _peer == null:
		return
	_peer.set_target_peer(enet_id)
	_peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	_peer.set_transfer_channel(0)
	_peer.put_packet(bytes)


func _send_to_app(room: String, app_id: int, bytes: PackedByteArray) -> void:
	if not _rooms.has(room):
		return
	var members: Dictionary = _rooms[room]["members"]
	if not members.has(app_id):
		return
	_send_to_enet(int(members[app_id]), bytes)


func _broadcast_room(room: String, bytes: PackedByteArray, except_app: int) -> void:
	if not _rooms.has(room):
		return
	var members: Dictionary = (_rooms[room]["members"] as Dictionary).duplicate()
	for app_id in members.keys():
		if int(app_id) == except_app:
			continue
		_send_to_enet(int(members[app_id]), bytes)


func _log_info(message: String) -> void:
	if _logs != null:
		_logs.info(message)
	else:
		print("Godot Collab relay: ", message)


func _log_warn(message: String) -> void:
	if _logs != null:
		_logs.warn(message)
	else:
		print("Godot Collab relay WARN: ", message)


func _log_error(message: String) -> void:
	if _logs != null:
		_logs.error(message)
	else:
		printerr("Godot Collab relay ERROR: ", message)
