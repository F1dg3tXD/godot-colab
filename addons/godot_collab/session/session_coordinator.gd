@tool
## Session protocol state machine sitting on top of [CollabSessionManager].
##
## Responsibilities: the HELLO/WELCOME handshake, host approval of new peers,
## the authoritative participant list, presence/cursor relay, keepalives and
## routing of higher-level messages (scene ops, saving, transfers) to the
## registered services. The UI never speaks the wire protocol directly.
class_name CollabSessionCoordinator
extends Node

signal session_started(is_host: bool)
signal session_stopped(reason: String)
signal participants_changed()
signal peer_ready(peer_id: int)
signal join_request(peer_id: int, username: String, project_id: String)
signal join_resolved(peer_id: int, approved: bool)
## Client side: the host received our request and is waiting for the operator to
## approve or reject it.
signal join_pending()
signal cursor_received(peer_id: int, payload: Dictionary)
signal scene_message(peer_id: int, type: int, payload: Dictionary)
signal save_message(peer_id: int, type: int, payload: Dictionary)
signal transfer_message(peer_id: int, type: int, payload: Dictionary)
signal workspace_message(peer_id: int, type: int, payload: Dictionary)
signal scene_focus_changed(peer_id: int, scene_id: String)
signal compatibility_warning(text: String)
signal notice(text: String)
signal error_raised(text: String)

const HOST_PEER_ID: int = 1

const SCENE_MESSAGE_TYPES: Array[int] = [
	CollabProtocol.MessageType.OPS,
	CollabProtocol.MessageType.OPS_ACK,
	CollabProtocol.MessageType.OPS_REJECT,
	CollabProtocol.MessageType.SNAPSHOT_REQUEST,
	CollabProtocol.MessageType.SNAPSHOT_RESPONSE,
	CollabProtocol.MessageType.RESYNC_REQUIRED,
	CollabProtocol.MessageType.CONFLICT_NOTICE,
]

const TRANSFER_MESSAGE_TYPES: Array[int] = [
	CollabProtocol.MessageType.TRANSFER_MANIFEST,
	CollabProtocol.MessageType.TRANSFER_REQUEST,
	CollabProtocol.MessageType.TRANSFER_CHUNK,
	CollabProtocol.MessageType.TRANSFER_FILE_DONE,
	CollabProtocol.MessageType.TRANSFER_COMPLETE,
	CollabProtocol.MessageType.TRANSFER_CANCEL,
	CollabProtocol.MessageType.TRANSFER_ERROR,
]

const WORKSPACE_MESSAGE_TYPES: Array[int] = [
	CollabProtocol.MessageType.WORKSPACE_REQUEST,
	CollabProtocol.MessageType.WORKSPACE_RESULT,
	CollabProtocol.MessageType.FILE_APPLY,
	CollabProtocol.MessageType.SCENE_LIST,
	CollabProtocol.MessageType.FILE_REMOVE,
]

var session_manager: CollabSessionManager
var registry: CollabParticipantRegistry

# Identity / configuration (identity providers are callables so they always
# reflect the currently edited scene).
var username: String = ""
var workspace_mode: int = CollabConstants.WorkspaceMode.HOST_WORKSPACE
var capabilities: Dictionary = {}
var session_id: String = ""
var session_token: String = ""
var require_token: bool = false
var approve_joins: bool = true
var revision: int = 0
var host_port: int = 0

var get_project_id: Callable = Callable()
var get_scene_id: Callable = Callable()
var get_username: Callable = Callable()

var _logs: CollabLog
var _pending: Dictionary = {} # peer_id -> HELLO payload
var _admitted: Dictionary = {} # peer_id -> true
var _is_host: bool = false
var _local_peer_id: int = 0
var _last_ping_ms: int = 0


func _init(logs: CollabLog = null) -> void:
	_logs = logs
	registry = CollabParticipantRegistry.new()


func setup(manager: CollabSessionManager, logs: CollabLog) -> void:
	session_manager = manager
	_logs = logs
	session_manager.message_received.connect(_on_message)
	session_manager.peer_connected.connect(_on_peer_connected)
	session_manager.peer_disconnected.connect(_on_peer_disconnected)
	session_manager.connection_failed.connect(_on_connection_failed)


func is_host() -> bool:
	return _is_host


func local_peer_id() -> int:
	return _local_peer_id


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func start_host(port: int, max_peers: int, mode: int, p_approve_joins: bool) -> Error:
	workspace_mode = mode
	approve_joins = p_approve_joins
	host_port = port
	session_id = _random_hex(16)
	session_token = _random_hex(24)
	var err: Error = session_manager.host(port, max_peers)
	if err != OK:
		return err
	_is_host = true
	_local_peer_id = session_manager.local_peer_id()
	registry.set_local(_local_peer_id, true)
	var host := CollabParticipant.make(_local_peer_id, _username(), true, true)
	host.project_id = _project_id()
	host.scene_id = _scene_id()
	host.capabilities = capabilities
	registry.upsert(host)
	registry.changed.emit()
	session_started.emit(true)
	_notice("Hosting session %s on UDP %d." % [session_id.substr(0, 6), port])
	return OK


func join(address: String, port: int, token: String = "") -> Error:
	session_token = token
	var err: Error = session_manager.join(address, port)
	if err != OK:
		return err
	_is_host = false
	return OK


func stop(reason: String = "disconnected") -> void:
	if session_manager != null and _is_host and session_manager.is_active():
		session_manager.broadcast(CollabProtocol.MessageType.PARTICIPANT_LEAVE, {"peer_id": _local_peer_id})
	session_manager.close()
	_pending.clear()
	_admitted.clear()
	registry.clear()
	_is_host = false
	_local_peer_id = 0
	session_stopped.emit(reason)


# ---------------------------------------------------------------------------
# Approval
# ---------------------------------------------------------------------------

func approve_peer(peer_id: int) -> void:
	var hello: Dictionary = _pending.get(peer_id, {})
	if hello.is_empty():
		return
	_admit_peer(peer_id, hello)


func deny_peer(peer_id: int, message: String = "Host denied the join request.") -> void:
	if not _pending.has(peer_id):
		return
	_pending.erase(peer_id)
	session_manager.send_to(peer_id, CollabProtocol.MessageType.REJECT, {
		"reason": CollabProtocol.Reason.HOST_DENIED,
		"message": message,
	})
	session_manager.disconnect_peer(peer_id)
	join_resolved.emit(peer_id, false)


func kick(peer_id: int, reason: String = "Removed by host.") -> void:
	if peer_id == HOST_PEER_ID or not _is_host:
		return
	session_manager.send_to(peer_id, CollabProtocol.MessageType.REJECT, {
		"reason": CollabProtocol.Reason.HOST_DENIED,
		"message": reason,
	})
	session_manager.disconnect_peer(peer_id)


func pending_peers() -> Array[int]:
	var out: Array[int] = []
	for key in _pending.keys():
		out.append(key)
	return out


func pending_info(peer_id: int) -> Dictionary:
	return _pending.get(peer_id, {})


func is_admitted(peer_id: int) -> bool:
	return _admitted.has(peer_id) or peer_id == HOST_PEER_ID


# ---------------------------------------------------------------------------
# Poll / keepalive
# ---------------------------------------------------------------------------

func poll() -> void:
	if session_manager == null:
		return
	session_manager.poll()
	if not session_manager.is_active():
		return
	var now := Time.get_ticks_msec()
	if now - _last_ping_ms > 2000:
		_last_ping_ms = now
		_send_ping()


func _send_ping() -> void:
	var payload := {"time_ms": Time.get_ticks_msec()}
	if _is_host:
		session_manager.broadcast(CollabProtocol.MessageType.PING, payload, false)
	else:
		session_manager.send_to_server(CollabProtocol.MessageType.PING, payload, false)


# ---------------------------------------------------------------------------
# Inbound routing
# ---------------------------------------------------------------------------

func _on_message(from_peer: int, type: CollabProtocol.MessageType, payload: Dictionary) -> void:
	if type == CollabProtocol.MessageType.PING or type == CollabProtocol.MessageType.PONG:
		if from_peer != _local_peer_id:
			registry.touch(from_peer)
		return
	if _is_host and from_peer != HOST_PEER_ID:
		registry.touch(from_peer)
	var t: int = type
	if t == CollabProtocol.MessageType.HELLO:
		_on_hello(from_peer, payload)
	elif t == CollabProtocol.MessageType.WELCOME:
		_on_welcome(from_peer, payload)
	elif t == CollabProtocol.MessageType.REJECT:
		_on_reject(payload)
	elif t == CollabProtocol.MessageType.JOIN_PENDING:
		if not _is_host:
			join_pending.emit()
	elif t == CollabProtocol.MessageType.PARTICIPANT_JOIN:
		_on_participant_join(payload)
	elif t == CollabProtocol.MessageType.PARTICIPANT_LEAVE:
		_on_participant_leave(payload)
	elif t == CollabProtocol.MessageType.PARTICIPANT_LIST:
		if not _is_host:
			registry.replace_all(payload.get("participants", []))
		participants_changed.emit()
	elif t == CollabProtocol.MessageType.CURSOR_UPDATE:
		_on_cursor(from_peer, payload)
	elif t == CollabProtocol.MessageType.SCENE_FOCUS:
		_on_scene_focus(from_peer, payload)
	elif SCENE_MESSAGE_TYPES.has(t):
		scene_message.emit(from_peer, t, payload)
	elif t == CollabProtocol.MessageType.SAVE_REQUEST or t == CollabProtocol.MessageType.SAVE_RESULT:
		save_message.emit(from_peer, t, payload)
	elif TRANSFER_MESSAGE_TYPES.has(t):
		transfer_message.emit(from_peer, t, payload)
	elif WORKSPACE_MESSAGE_TYPES.has(t):
		workspace_message.emit(from_peer, t, payload)


func _on_hello(peer_id: int, payload: Dictionary) -> void:
	if not _is_host or _admitted.has(peer_id) or _pending.has(peer_id):
		return
	var version: int = int(payload.get("protocol_version", -1))
	if version != CollabConstants.PROTOCOL_VERSION:
		session_manager.send_to(peer_id, CollabProtocol.MessageType.REJECT, {
			"reason": CollabProtocol.Reason.PROTOCOL_MISMATCH,
			"message": "Protocol version mismatch (peer %d, host %d)." % [version, CollabConstants.PROTOCOL_VERSION],
		})
		session_manager.disconnect_peer(peer_id)
		return
	if require_token and not _constant_time_equal(str(payload.get("token", "")), session_token):
		session_manager.send_to(peer_id, CollabProtocol.MessageType.REJECT, {
			"reason": CollabProtocol.Reason.HOST_DENIED,
			"message": "Invalid session token.",
		})
		session_manager.disconnect_peer(peer_id)
		return
	_pending[peer_id] = payload
	var name := _sanitize_name(str(payload.get("username", "")))
	if approve_joins:
		session_manager.send_to(peer_id, CollabProtocol.MessageType.JOIN_PENDING, {})
		join_request.emit(peer_id, name, str(payload.get("project_id", "")))
		_notice("Join request from '%s' (%d) - awaiting approval." % [name, peer_id])
	else:
		_admit_peer(peer_id, payload)


func _admit_peer(peer_id: int, hello: Dictionary) -> void:
	_pending.erase(peer_id)
	_admitted[peer_id] = true
	var participant := CollabParticipant.make(peer_id, _sanitize_name(str(hello.get("username", ""))), false, true)
	participant.project_id = str(hello.get("project_id", ""))
	participant.scene_id = str(hello.get("scene_id", ""))
	var caps: Variant = hello.get("capabilities", {})
	participant.capabilities = caps if typeof(caps) == TYPE_DICTIONARY else {}
	registry.upsert(participant)
	var warnings: Array = []
	if not participant.project_id.is_empty() and participant.project_id != _project_id():
		warnings.append("Peer '%s' is editing a different project revision." % participant.username)
	if not participant.scene_id.is_empty() and participant.scene_id != _scene_id():
		warnings.append("Peer '%s' has a different scene open." % participant.username)
	session_manager.send_to(peer_id, CollabProtocol.MessageType.WELCOME, {
		"protocol_version": CollabConstants.PROTOCOL_VERSION,
		"peer_id": peer_id,
		"session_id": session_id,
		"host_username": _username(),
		"workspace_mode": workspace_mode,
		"project_id": _project_id(),
		"scene_id": _scene_id(),
		"revision": revision,
		"warnings": warnings,
		"capabilities": capabilities,
	})
	# Tell the new peer about everyone (including itself and the host).
	session_manager.send_to(peer_id, CollabProtocol.MessageType.PARTICIPANT_LIST, {"participants": registry.to_payload()})
	# Tell existing peers about the newcomer.
	session_manager.broadcast(CollabProtocol.MessageType.PARTICIPANT_JOIN, {
		"participants": [participant.to_dict()],
	}, true, 0, peer_id)
	join_resolved.emit(peer_id, true)
	peer_ready.emit(peer_id)
	participants_changed.emit()
	_notice("'%s' joined the session." % participant.username)


func _on_welcome(_from_peer: int, payload: Dictionary) -> void:
	if _is_host:
		return
	_local_peer_id = int(payload.get("peer_id", session_manager.local_peer_id()))
	session_id = str(payload.get("session_id", ""))
	workspace_mode = int(payload.get("workspace_mode", CollabConstants.WorkspaceMode.HOST_WORKSPACE))
	revision = int(payload.get("revision", 0))
	registry.set_local(_local_peer_id, false)
	var host := CollabParticipant.make(HOST_PEER_ID, _sanitize_name(str(payload.get("host_username", "host"))), true, true)
	host.project_id = str(payload.get("project_id", ""))
	host.scene_id = str(payload.get("scene_id", ""))
	registry.upsert(host)
	var warnings: Array = payload.get("warnings", [])
	for warning in warnings:
		compatibility_warning.emit(str(warning))
	session_started.emit(false)
	_notice("Joined session %s." % session_id.substr(0, 6))


func _on_reject(payload: Dictionary) -> void:
	var reason: int = int(payload.get("reason", CollabProtocol.Reason.HOST_DENIED))
	var message: String = str(payload.get("message", "Join rejected."))
	error_raised.emit("%s (reason %d)" % [message, reason])
	session_manager.close()
	session_stopped.emit(message)


func _on_participant_join(payload: Dictionary) -> void:
	var list: Array = payload.get("participants", [])
	for entry in list:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var p := CollabParticipant.from_dict(entry)
		if p.peer_id == _local_peer_id:
			continue
		registry.upsert(p)
	participants_changed.emit()


func _on_participant_leave(payload: Dictionary) -> void:
	var peer_id: int = int(payload.get("peer_id", -1))
	if peer_id < 0:
		return
	registry.remove(peer_id)
	participants_changed.emit()


func _on_cursor(from_peer: int, payload: Dictionary) -> void:
	if _is_host:
		var relayed: Dictionary = payload.duplicate(true)
		relayed["source_peer"] = from_peer
		session_manager.broadcast(CollabProtocol.MessageType.CURSOR_UPDATE, relayed, false, 1, from_peer)
		cursor_received.emit(from_peer, relayed)
	else:
		cursor_received.emit(int(payload.get("source_peer", from_peer)), payload)


## Tracks which scene each participant is currently focused on so the host can
## route snapshots and report scene mismatches. The host relays client focus
## changes to the rest of the session.
func _on_scene_focus(from_peer: int, payload: Dictionary) -> void:
	if not is_admitted(from_peer):
		return
	var scene: String = str(payload.get("scene_id", ""))
	var participant: CollabParticipant = registry.get_participant(from_peer)
	if participant != null:
		participant.scene_id = scene
	if _is_host:
		session_manager.broadcast(CollabProtocol.MessageType.SCENE_FOCUS, {
			"peer_id": from_peer,
			"username": participant.username if participant != null else "",
			"scene_id": scene,
		}, true, 0, from_peer)
	scene_focus_changed.emit(from_peer, scene)
	participants_changed.emit()


func _on_peer_connected(peer_id: int) -> void:
	if _is_host:
		return # Wait for HELLO before admitting.
	var hello := {
		"protocol_version": CollabConstants.PROTOCOL_VERSION,
		"username": _username(),
		"project_id": _project_id(),
		"scene_id": _scene_id(),
		"capabilities": capabilities,
		"token": session_token,
		"engine_version": CollabIdentity.engine_version(),
	}
	var err: Error = session_manager.send_to_server(CollabProtocol.MessageType.HELLO, hello)
	if err != OK:
		error_raised.emit("Failed to send handshake: %s" % error_string(err))
		session_manager.close()


func _on_peer_disconnected(peer_id: int) -> void:
	_pending.erase(peer_id)
	var was_admitted: bool = _admitted.erase(peer_id)
	if was_admitted and _is_host:
		registry.remove(peer_id)
		session_manager.broadcast(CollabProtocol.MessageType.PARTICIPANT_LEAVE, {"peer_id": peer_id})
		participants_changed.emit()
	elif not _is_host and peer_id == HOST_PEER_ID:
		registry.clear()
		session_manager.close()
		session_stopped.emit("Host disconnected.")


func _on_connection_failed(reason: String) -> void:
	error_raised.emit("Connection failed: %s" % reason)
	session_stopped.emit("Connection failed: %s" % reason)


# ---------------------------------------------------------------------------
# Outbound helpers used by services
# ---------------------------------------------------------------------------

func send_cursor(payload: Dictionary) -> void:
	if session_manager == null or not session_manager.is_active():
		return
	if _is_host:
		var relayed: Dictionary = payload.duplicate(true)
		relayed["source_peer"] = _local_peer_id
		session_manager.broadcast(CollabProtocol.MessageType.CURSOR_UPDATE, relayed, false, 1)
	else:
		session_manager.send_to_server(CollabProtocol.MessageType.CURSOR_UPDATE, payload, false, 1)


func send_scene(type: CollabProtocol.MessageType, payload: Dictionary) -> void:
	if session_manager == null or not session_manager.is_active():
		return
	if _is_host:
		session_manager.broadcast(type, payload)
	else:
		session_manager.send_to_server(type, payload)


func send_scene_to(peer_id: int, type: CollabProtocol.MessageType, payload: Dictionary) -> void:
	if session_manager != null and session_manager.is_active():
		session_manager.send_to(peer_id, type, payload)


func send_save(type: CollabProtocol.MessageType, payload: Dictionary) -> void:
	send_scene(type, payload)


func send_transfer(type: CollabProtocol.MessageType, payload: Dictionary) -> void:
	send_scene(type, payload)


func send_transfer_to(peer_id: int, type: CollabProtocol.MessageType, payload: Dictionary) -> void:
	send_scene_to(peer_id, type, payload)


func send_workspace(type: CollabProtocol.MessageType, payload: Dictionary) -> void:
	send_scene(type, payload)


func send_workspace_to(peer_id: int, type: CollabProtocol.MessageType, payload: Dictionary) -> void:
	send_scene_to(peer_id, type, payload)


## Announces the scene this peer is focused on.
func send_scene_focus(p_scene_id: String) -> void:
	if session_manager == null or not session_manager.is_active():
		return
	var payload := {"peer_id": _local_peer_id, "username": _username(), "scene_id": p_scene_id}
	if _is_host:
		session_manager.broadcast(CollabProtocol.MessageType.SCENE_FOCUS, payload)
	else:
		session_manager.send_to_server(CollabProtocol.MessageType.SCENE_FOCUS, payload)


func refresh_host_scene_id() -> void:
	if not _is_host:
		return
	var me: CollabParticipant = registry.get_participant(_local_peer_id)
	if me != null:
		me.scene_id = _scene_id()
		session_manager.broadcast(CollabProtocol.MessageType.PARTICIPANT_LIST, {"participants": registry.to_payload()})


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

func _username() -> String:
	if get_username.is_valid():
		var name: String = str(get_username.call())
		if not name.is_empty():
			return name
	return username if not username.is_empty() else "peer"


func _project_id() -> String:
	return str(get_project_id.call()) if get_project_id.is_valid() else ""


func _scene_id() -> String:
	if get_scene_id.is_valid():
		return str(get_scene_id.call())
	return ""


func _sanitize_name(name: String) -> String:
	var clean: String = name.strip_edges().replace("\n", " ").substr(0, 64)
	return name if name.is_empty() else (clean if not clean.is_empty() else "peer")


func _constant_time_equal(a: String, b: String) -> bool:
	if a.length() != b.length():
		return false
	var diff: int = 0
	for i in a.length():
		diff |= (a.unicode_at(i) ^ b.unicode_at(i))
	return diff == 0


func _random_hex(bytes: int) -> String:
	var rng := Crypto.new()
	return (rng.generate_random_bytes(bytes) as PackedByteArray).hex_encode()


func _log_info(m: String) -> void:
	if _logs != null:
		_logs.info(m)


func _notice(m: String) -> void:
	_log_info(m)
	notice.emit(m)
