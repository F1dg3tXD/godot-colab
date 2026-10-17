@tool
## Low-level ENet transport for the add-on.
##
## This node owns a private [ENetMultiplayerPeer] and polls it manually. It
## deliberately never touches the editor's global [MultiplayerAPI] peer, so
## enabling/disabling the add-on cannot destabilise the editor's own
## networking. All higher level protocol logic (handshake, participants,
## scene ops, transfers) lives above this layer.
##
## Packet framing/validation is done in [CollabProtocol]. This class only moves
## opaque byte packets and tracks connection lifecycle.
class_name CollabSessionManager
extends Node

signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int)
signal connection_state_changed(state: CollabConstants.ConnectionState)
signal connection_failed(reason: String)
signal host_disconnected()
## Raw decoded message. [param payload] is only ever plain data.
signal message_received(peer_id: int, type: int, payload: Dictionary)

## Reliable channel for control/session/scene messages.
const CH_CONTROL: int = 0
## Unreliable-ordered channel for high-frequency cursor state.
const CH_CURSOR: int = 1
## Reliable channel used for file transfer data (kept separate from control so
## a large transfer cannot head-of-line block session management).
const CH_TRANSFER: int = 2
const CHANNEL_COUNT: int = 3

const CLIENT_CONNECT_TIMEOUT: float = 10.0

var _peer: ENetMultiplayerPeer = null
var _state: CollabConstants.ConnectionState = CollabConstants.ConnectionState.DISCONNECTED
var _is_host: bool = false
var _connect_started_ms: int = 0
var _connect_timeout_ms: int = 10000
var _logs: CollabLog = null
## Connected peer ids, tracked from signals because this engine build exposes no
## peer enumeration on [MultiplayerPeer].
var _connected_peers: Array[int] = []
var _in_poll: bool = false
var _close_requested: bool = false

## Relay mode: both host and clients connect outbound to a [CollabRelayServer]
## instead of hosting/connecting directly. The application-level host role is
## tracked separately from the transport role, because a relay host is an ENet
## *client* of the relay but is still the authoritative session host.
var _relay_mode: bool = false
var _relay_host_role: bool = false
var _relay_room: String = ""
var _relay_token: String = ""
var _relay_max_peers: int = 0
var _relay_registered: bool = false
var _relay_app_id: int = 0
var _relay_host_id: int = CollabRelayProtocol.HOST_APP_ID
## Outbound relay envelopes queued before the relay confirms registration. The
## host emits `session_started` (and initial broadcasts) the instant it calls
## host_via_relay, which happens before REGISTERED arrives; without buffering
## those early packets would be silently dropped by the relay.
var _relay_outbox: Array[Dictionary] = []
var _relay_outbox_limit: int = 512


func _init(logs: CollabLog = null) -> void:
	_logs = logs


func set_logger(logs: CollabLog) -> void:
	_logs = logs


func get_state() -> CollabConstants.ConnectionState:
	return _state


func is_host() -> bool:
	return _is_host


func is_relay() -> bool:
	return _relay_mode


func is_active() -> bool:
	return _state == CollabConstants.ConnectionState.HOSTING \
		or _state == CollabConstants.ConnectionState.CONNECTING \
		or _state == CollabConstants.ConnectionState.CONNECTED


func local_peer_id() -> int:
	if _relay_mode:
		if _relay_app_id != 0:
			return _relay_app_id
		return CollabRelayProtocol.HOST_APP_ID if _relay_host_role else 0
	if _peer == null:
		return 0
	return _peer.get_unique_id()


## Starts a server (authoritative host). Returns [constant OK] on success.
func host(port: int, max_peers: int, bind_address: String = "*") -> Error:
	_teardown_peer()
	_peer = ENetMultiplayerPeer.new()
	var err: Error = _peer.create_server(port, max_peers, 3)
	if err != OK:
		_log_error("Failed to host on port %d: %s" % [port, error_string(err)])
		_teardown_peer()
		return err
	if bind_address != "*" and not bind_address.is_empty():
		_peer.set_bind_ip(bind_address)
	_peer.peer_connected.connect(_on_peer_connected)
	_peer.peer_disconnected.connect(_on_peer_disconnected)
	_is_host = true
	_set_state(CollabConstants.ConnectionState.HOSTING)
	_log_info("Hosting on UDP port %d (max %d peers)." % [port, max_peers])
	return OK


## Connects to a host. Connection completion is reported asynchronously through
## [signal peer_connected] / [signal connection_failed].
func join(address: String, port: int, timeout_seconds: int = 10) -> Error:
	_teardown_peer()
	_peer = ENetMultiplayerPeer.new()
	var err: Error = _peer.create_client(address, port, 3)
	if err != OK:
		_log_error("Failed to connect to %s:%d: %s" % [address, port, error_string(err)])
		_teardown_peer()
		return err
	_peer.peer_connected.connect(_on_peer_connected)
	_peer.peer_disconnected.connect(_on_peer_disconnected)
	_is_host = false
	_connect_started_ms = Time.get_ticks_msec()
	_connect_timeout_ms = int(timeout_seconds * 1000.0)
	_set_state(CollabConstants.ConnectionState.CONNECTING)
	_log_info("Connecting to %s:%d..." % [address, port])
	return OK


## Hosts a session through a dedicated relay server. Both this process and its
## clients make outbound connections to [param address]:[param port]; the relay
## forwards traffic, so no inbound port needs to be reachable.
func host_via_relay(address: String, port: int, room: String, token: String, max_peers: int, timeout_seconds: int = 10) -> Error:
	return _begin_relay(address, port, room, token, max_peers, true, timeout_seconds)


## Joins a relay-hosted session. Reaches the host through the relay, so it works
## behind NAT/CGNAT without port forwarding.
func join_via_relay(address: String, port: int, room: String, token: String, timeout_seconds: int = 10) -> Error:
	return _begin_relay(address, port, room, token, 0, false, timeout_seconds)


func _begin_relay(address: String, port: int, room: String, token: String, max_peers: int, as_host: bool, timeout_seconds: int) -> Error:
	if address.strip_edges().is_empty() or port <= 0:
		return ERR_INVALID_PARAMETER
	if room.strip_edges().is_empty():
		return ERR_INVALID_PARAMETER
	_teardown_peer()
	_peer = ENetMultiplayerPeer.new()
	var err: Error = _peer.create_client(address, port, 3)
	if err != OK:
		_log_error("Failed to reach relay %s:%d: %s" % [address, port, error_string(err)])
		_teardown_peer()
		return err
	_peer.peer_connected.connect(_on_peer_connected)
	_peer.peer_disconnected.connect(_on_peer_disconnected)
	_relay_mode = true
	_relay_host_role = as_host
	_relay_room = room
	_relay_token = token
	_relay_max_peers = max_peers
	_relay_registered = false
	_relay_app_id = 0
	_is_host = as_host
	_relay_outbox = []
	_connect_started_ms = Time.get_ticks_msec()
	_connect_timeout_ms = int(timeout_seconds * 1000.0)
	_set_state(CollabConstants.ConnectionState.CONNECTING)
	_log_info("%s room '%s' via relay %s:%d..." % ["Hosting" if as_host else "Joining", room, address, port])
	return OK


## Tears down any active peer and resets to [constant CollabConstants.ConnectionState.DISCONNECTED].
## When called from inside [method poll] (e.g. a signal handler reacting to a
## disconnect) the actual teardown is deferred to the end of the poll so the
## native ENet peer is never freed while it is still on the call stack.
func close() -> void:
	if _peer != null and _state != CollabConstants.ConnectionState.DISCONNECTED:
		if _is_host and not _relay_mode:
			_peer.set_refuse_new_connections(true)
		_log_info("Closing session.")
	if _in_poll:
		_close_requested = true
		return
	_teardown_peer()
	_set_state(CollabConstants.ConnectionState.DISCONNECTED)
	_is_host = false


## Restricts new incoming connections (used while awaiting host approval).
func set_accepting_connections(accepting: bool) -> void:
	if _peer != null and _is_host and not _relay_mode:
		_peer.set_refuse_new_connections(not accepting)


func disconnect_peer(peer_id: int, now: bool = false) -> void:
	if _peer == null:
		return
	if _relay_mode:
		if _is_host:
			_relay_put(CollabRelayProtocol.encode_kick(peer_id))
		_connected_peers.erase(peer_id)
		return
	_peer.disconnect_peer(peer_id, now)


## Sends a message to a specific peer. Returns [constant OK] when queued.
func send_to(peer_id: int, type: CollabProtocol.MessageType, payload: Dictionary, reliable: bool = true, channel: int = 0) -> Error:
	if _peer == null or _state == CollabConstants.ConnectionState.DISCONNECTED:
		return ERR_UNCONFIGURED
	var bytes := CollabProtocol.encode(type, payload)
	if bytes.is_empty():
		_log_error("Refused to send oversized/uncodable %s." % CollabProtocol.MessageType.keys()[type])
		return ERR_INVALID_DATA
	if _relay_mode:
		return _relay_put(CollabRelayProtocol.encode_data(0, peer_id, bytes), reliable, channel)
	_peer.set_target_peer(peer_id)
	_peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED)
	_peer.set_transfer_channel(channel)
	return _peer.put_packet(bytes)


func send_to_server(type: CollabProtocol.MessageType, payload: Dictionary, reliable: bool = true, channel: int = 0) -> Error:
	if _relay_mode:
		return send_to(CollabRelayProtocol.HOST_APP_ID, type, payload, reliable, channel)
	return send_to(MultiplayerPeer.TARGET_PEER_SERVER, type, payload, reliable, channel)


## Sends to every connected peer (host only). Optionally skips one peer.
func broadcast(type: CollabProtocol.MessageType, payload: Dictionary, reliable: bool = true, channel: int = 0, except_peer: int = -1) -> void:
	if _peer == null or not _is_host:
		return
	var bytes := CollabProtocol.encode(type, payload)
	if bytes.is_empty():
		_log_error("Refused to broadcast oversized/uncodable %s." % CollabProtocol.MessageType.keys()[type])
		return
	if _relay_mode:
		if except_peer < 0:
			_relay_put(CollabRelayProtocol.encode_data(0, MultiplayerPeer.TARGET_PEER_BROADCAST, bytes), reliable, channel)
			return
		for peer_id in _peer_ids():
			if peer_id == except_peer or peer_id == CollabRelayProtocol.HOST_APP_ID:
				continue
			_relay_put(CollabRelayProtocol.encode_data(0, peer_id, bytes), reliable, channel)
		return
	var mode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
	_peer.set_transfer_mode(mode)
	_peer.set_transfer_channel(channel)
	if except_peer < 0:
		_peer.set_target_peer(MultiplayerPeer.TARGET_PEER_BROADCAST)
		_peer.put_packet(bytes)
		return
	for peer_id in _peer_ids():
		if peer_id == except_peer:
			continue
		_peer.set_target_peer(peer_id)
		_peer.put_packet(bytes)


func get_remote_address(peer_id: int) -> String:
	if _peer == null or _relay_mode:
		return ""
	var enet_peer: ENetPacketPeer = _peer.get_peer(peer_id)
	if enet_peer == null:
		return ""
	return enet_peer.get_remote_address()


func get_remote_port(peer_id: int) -> int:
	if _peer == null or _relay_mode:
		return 0
	var enet_peer: ENetPacketPeer = _peer.get_peer(peer_id)
	if enet_peer == null:
		return 0
	return enet_peer.get_remote_port()


## Pumps the network. Must be called every frame by the plugin.
func poll() -> void:
	if _peer == null:
		return
	_in_poll = true
	_peer.poll()
	if _peer != null and _state == CollabConstants.ConnectionState.CONNECTING:
		if _relay_mode:
			# The state only advances once the relay confirms registration.
			if not _relay_registered and Time.get_ticks_msec() - _connect_started_ms > _connect_timeout_ms:
				_log_error("Relay registration timed out.")
				_teardown_peer()
				_set_state(CollabConstants.ConnectionState.DISCONNECTED)
				_in_poll = false
				connection_failed.emit("relay registration timed out")
				return
		elif _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			_set_state(CollabConstants.ConnectionState.CONNECTED)
		elif Time.get_ticks_msec() - _connect_started_ms > _connect_timeout_ms:
			_log_error("Connection attempt timed out.")
			_teardown_peer()
			_set_state(CollabConstants.ConnectionState.DISCONNECTED)
			_in_poll = false
			connection_failed.emit("connection timed out")
			return
	if _peer != null:
		_drain_packets()
	_in_poll = false
	if _close_requested:
		_close_requested = false
		_teardown_peer()
		_set_state(CollabConstants.ConnectionState.DISCONNECTED)
		_is_host = false


func _drain_packets() -> void:
	while _peer != null and _peer.get_available_packet_count() > 0:
		# NOTE: the peer/channel/mode accessors describe the *next* packet and
		# must be read before get_packet() consumes it.
		var from_peer: int = _peer.get_packet_peer()
		var raw: PackedByteArray = _peer.get_packet()
		if _relay_mode:
			_handle_relay_packet(raw)
			continue
		var decoded := CollabProtocol.decode(raw)
		if not decoded["ok"]:
			_log_warn("Dropped invalid packet from %d: %s" % [from_peer, decoded["error"]])
			continue
		message_received.emit(from_peer, decoded["type"] as CollabProtocol.MessageType, decoded["payload"] as Dictionary)


func _handle_relay_packet(raw: PackedByteArray) -> void:
	var relay := CollabRelayProtocol.decode(raw)
	if not relay["ok"]:
		_log_warn("Dropped invalid relay packet: %s" % relay["error"])
		return
	match int(relay["kind"]):
		CollabRelayProtocol.Kind.REGISTERED:
			_relay_app_id = int(relay["peer_id"])
			_relay_host_id = int(relay["host_id"])
			_relay_registered = true
			_flush_relay_outbox()
			if _relay_host_role:
				_log_info("Relay accepted host as app id %d." % _relay_app_id)
				_set_state(CollabConstants.ConnectionState.HOSTING)
			else:
				_log_info("Relay accepted client as app id %d; host is %d." % [_relay_app_id, _relay_host_id])
				_set_state(CollabConstants.ConnectionState.CONNECTED)
				if not _connected_peers.has(_relay_host_id):
					_connected_peers.append(_relay_host_id)
				peer_connected.emit(_relay_host_id)
		CollabRelayProtocol.Kind.MEMBER_JOIN:
			_relay_member_joined(int(relay["peer_id"]))
		CollabRelayProtocol.Kind.MEMBER_LEAVE:
			_relay_member_left(int(relay["peer_id"]))
		CollabRelayProtocol.Kind.DATA:
			var origin: int = int(relay["origin"])
			var decoded := CollabProtocol.decode(relay["data"] as PackedByteArray)
			if not decoded["ok"]:
				_log_warn("Dropped invalid relayed packet from %d: %s" % [origin, decoded["error"]])
				return
			message_received.emit(origin, decoded["type"] as CollabProtocol.MessageType, decoded["payload"] as Dictionary)
		CollabRelayProtocol.Kind.ERROR:
			if _state == CollabConstants.ConnectionState.DISCONNECTED:
				return
			var message: String = str(relay["message"])
			_log_error("Relay error: %s" % message)
			_teardown_peer()
			_set_state(CollabConstants.ConnectionState.DISCONNECTED)
			_is_host = false
			connection_failed.emit(message)
		CollabRelayProtocol.Kind.KICK:
			if _state == CollabConstants.ConnectionState.DISCONNECTED:
				return
			_log_warn("Removed from the relay session by the host.")
			_teardown_peer()
			_set_state(CollabConstants.ConnectionState.DISCONNECTED)
			host_disconnected.emit()
		_:
			pass


func _relay_member_joined(peer_id: int) -> void:
	if peer_id == _relay_app_id:
		return
	# Only the app host cares about client arrivals; a client only needs to know
	# about the host (which arrives with REGISTERED).
	if not _relay_host_role and peer_id != _relay_host_id:
		return
	if _connected_peers.has(peer_id):
		return
	_connected_peers.append(peer_id)
	_log_info("Relay peer %d joined." % peer_id)
	peer_connected.emit(peer_id)


func _relay_member_left(peer_id: int) -> void:
	_connected_peers.erase(peer_id)
	if not _relay_host_role and peer_id != _relay_host_id:
		return
	_log_info("Relay peer %d left." % peer_id)
	peer_disconnected.emit(peer_id)


func _relay_put(bytes: PackedByteArray, reliable: bool = true, channel: int = 0) -> Error:
	if _peer == null:
		return ERR_UNCONFIGURED
	if not _relay_registered:
		if _relay_outbox.size() >= _relay_outbox_limit:
			_log_warn("Relay outbox full; dropping a queued packet.")
			return ERR_OUT_OF_MEMORY
		_relay_outbox.append({"bytes": bytes, "reliable": reliable, "channel": channel})
		return OK
	return _relay_put_now(bytes, reliable, channel)


func _relay_put_now(bytes: PackedByteArray, reliable: bool = true, channel: int = 0) -> Error:
	_peer.set_target_peer(MultiplayerPeer.TARGET_PEER_SERVER)
	_peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED)
	_peer.set_transfer_channel(channel)
	return _peer.put_packet(bytes)


func _flush_relay_outbox() -> void:
	var queued: Array[Dictionary] = _relay_outbox
	_relay_outbox = []
	for entry in queued:
		_relay_put_now(entry["bytes"] as PackedByteArray, bool(entry["reliable"]), int(entry["channel"]))


func _relay_send_register() -> void:
	if _peer == null:
		return
	var role: int = CollabRelayProtocol.Role.HOST if _relay_host_role else CollabRelayProtocol.Role.CLIENT
	# Registration must bypass the outbox: it is what unlocks sending.
	_relay_put_now(CollabRelayProtocol.encode_register(_relay_room, role, _relay_token, _relay_max_peers))


func _peer_ids() -> Array[int]:
	return _connected_peers.duplicate()


func _on_peer_connected(peer_id: int) -> void:
	if _relay_mode:
		# The transport peer is the relay server itself; register the room and
		# wait for REGISTERED before treating the session as joined.
		_relay_send_register()
		return
	if not _connected_peers.has(peer_id):
		_connected_peers.append(peer_id)
	if not _is_host:
		_set_state(CollabConstants.ConnectionState.CONNECTED)
	_log_info("Peer %d connected." % peer_id)
	peer_connected.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if _relay_mode:
		# The connection to the relay dropped: the whole session is gone. This
		# signal fires from inside ENetMultiplayerPeer.poll(), so we must not
		# close the peer re-entrantly; defer teardown to the end of poll().
		if _state != CollabConstants.ConnectionState.DISCONNECTED:
			_close_requested = true
			if _relay_registered:
				_log_warn("Lost connection to the relay.")
				host_disconnected.emit()
			else:
				# The relay dropped us before REGISTERED (e.g. room full, bad
				# token, no host). If it already sent an ERROR we will have
				# processed it; this covers the disconnect arriving first.
				_log_warn("Relay closed the connection before registration completed.")
				_set_state(CollabConstants.ConnectionState.DISCONNECTED)
				connection_failed.emit("relay connection closed before registration")
		return
	_connected_peers.erase(peer_id)
	_log_info("Peer %d disconnected." % peer_id)
	peer_disconnected.emit(peer_id)


func _set_state(new_state: CollabConstants.ConnectionState) -> void:
	if _state == new_state:
		return
	_state = new_state
	connection_state_changed.emit(_state)


func _teardown_peer() -> void:
	if _peer == null:
		return
	if _peer.peer_connected.is_connected(_on_peer_connected):
		_peer.peer_connected.disconnect(_on_peer_connected)
	if _peer.peer_disconnected.is_connected(_on_peer_disconnected):
		_peer.peer_disconnected.disconnect(_on_peer_disconnected)
	_peer.close()
	_peer = null
	_connected_peers.clear()
	_close_requested = false
	_relay_mode = false
	_relay_host_role = false
	_relay_room = ""
	_relay_token = ""
	_relay_max_peers = 0
	_relay_registered = false
	_relay_app_id = 0
	_relay_host_id = CollabRelayProtocol.HOST_APP_ID
	_relay_outbox = []


func _log_info(message: String) -> void:
	if _logs != null:
		_logs.info(message)


func _log_warn(message: String) -> void:
	if _logs != null:
		_logs.warn(message)


func _log_error(message: String) -> void:
	if _logs != null:
		_logs.error(message)
