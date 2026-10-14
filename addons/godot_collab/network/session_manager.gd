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


func _init(logs: CollabLog = null) -> void:
	_logs = logs


func set_logger(logs: CollabLog) -> void:
	_logs = logs


func get_state() -> CollabConstants.ConnectionState:
	return _state


func is_host() -> bool:
	return _is_host


func is_active() -> bool:
	return _state == CollabConstants.ConnectionState.HOSTING \
		or _state == CollabConstants.ConnectionState.CONNECTING \
		or _state == CollabConstants.ConnectionState.CONNECTED


func local_peer_id() -> int:
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


## Tears down any active peer and resets to [constant CollabConstants.ConnectionState.DISCONNECTED].
## When called from inside [method poll] (e.g. a signal handler reacting to a
## disconnect) the actual teardown is deferred to the end of the poll so the
## native ENet peer is never freed while it is still on the call stack.
func close() -> void:
	if _peer != null and _state != CollabConstants.ConnectionState.DISCONNECTED:
		if _is_host:
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
	if _peer != null and _is_host:
		_peer.set_refuse_new_connections(not accepting)


func disconnect_peer(peer_id: int, now: bool = false) -> void:
	if _peer == null:
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
	_peer.set_target_peer(peer_id)
	_peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED)
	_peer.set_transfer_channel(channel)
	return _peer.put_packet(bytes)


func send_to_server(type: CollabProtocol.MessageType, payload: Dictionary, reliable: bool = true, channel: int = 0) -> Error:
	return send_to(MultiplayerPeer.TARGET_PEER_SERVER, type, payload, reliable, channel)


## Sends to every connected peer (host only). Optionally skips one peer.
func broadcast(type: CollabProtocol.MessageType, payload: Dictionary, reliable: bool = true, channel: int = 0, except_peer: int = -1) -> void:
	if _peer == null or not _is_host:
		return
	var bytes := CollabProtocol.encode(type, payload)
	if bytes.is_empty():
		_log_error("Refused to broadcast oversized/uncodable %s." % CollabProtocol.MessageType.keys()[type])
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
	if _peer == null:
		return ""
	var enet_peer: ENetPacketPeer = _peer.get_peer(peer_id)
	if enet_peer == null:
		return ""
	return enet_peer.get_remote_address()


func get_remote_port(peer_id: int) -> int:
	if _peer == null:
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
		if _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
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
		var decoded := CollabProtocol.decode(raw)
		if not decoded["ok"]:
			_log_warn("Dropped invalid packet from %d: %s" % [from_peer, decoded["error"]])
			continue
		message_received.emit(from_peer, decoded["type"] as CollabProtocol.MessageType, decoded["payload"] as Dictionary)


func _peer_ids() -> Array[int]:
	return _connected_peers.duplicate()


func _on_peer_connected(peer_id: int) -> void:
	if not _connected_peers.has(peer_id):
		_connected_peers.append(peer_id)
	if not _is_host:
		_set_state(CollabConstants.ConnectionState.CONNECTED)
	_log_info("Peer %d connected." % peer_id)
	peer_connected.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
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


func _log_info(message: String) -> void:
	if _logs != null:
		_logs.info(message)


func _log_warn(message: String) -> void:
	if _logs != null:
		_logs.warn(message)


func _log_error(message: String) -> void:
	if _logs != null:
		_logs.error(message)
