@tool
## Host-authoritative scene synchronisation.
##
## Local edits are captured by [CollabDiffWatcher] and sent as structured
## operations. The host is the single authority: it validates and applies
## client operations, assigns authoritative node ids, bumps the scene revision
## and broadcasts the accepted operation back to every peer (including the
## originator) so all peers converge with no rebroadcast loops.
##
## Conflict policy: the host accepts operations in arrival order and the last
## accepted write to a property wins. A stale [code]base_revision[/code] is
## reported as an informational conflict notice but never silently drops the
## edit. Peers can request a fresh snapshot to resynchronise.
class_name CollabSceneSyncService
extends Node

signal status(text: String)
signal conflict(text: String)
signal error_raised(text: String)
signal snapshot_offered(node_count: int, revision: int)
signal snapshot_applied()
signal revision_changed(revision: int)

var node_ids: CollabNodeIdMap
var diff_watcher: CollabDiffWatcher

var revision: int = 0
var scene_id: String = ""
## When false the service is presence-only (Git presence mode): it neither
## broadcasts nor applies scene operations, and it never sends or accepts
## snapshots.
var enabled: bool = true
## When true a non-host automatically applies an incoming snapshot. In
## host-workspace mode the host owns the authoritative scene, so a peer should
## immediately mirror whatever the host currently has instead of waiting for a
## manual confirmation.
var auto_apply_snapshot: bool = true

var _coordinator: CollabSessionCoordinator
var _logs: CollabLog
var _editor: Dictionary = {}
var _aliases: Dictionary = {} # source_peer -> {temp_id: authoritative_id}
var _applying: bool = false
var _pending_snapshot: Dictionary = {}


func _init() -> void:
	node_ids = CollabNodeIdMap.new()
	diff_watcher = CollabDiffWatcher.new()


func setup(coordinator: CollabSessionCoordinator, logs: CollabLog, editor: Dictionary) -> void:
	_coordinator = coordinator
	_logs = logs
	_editor = editor
	diff_watcher.setup(node_ids)
	diff_watcher.operations_detected.connect(_on_local_operations)
	coordinator.scene_message.connect(_on_scene_message)
	coordinator.session_stopped.connect(_on_session_stopped)
	coordinator.peer_ready.connect(_on_peer_ready)


## Binds the service to the currently edited scene. Safe to call repeatedly.
func attach_scene(root: Node, p_scene_id: String) -> void:
	if root == null:
		diff_watcher.enabled = false
		return
	scene_id = p_scene_id
	node_ids.clear()
	_aliases.clear()
	diff_watcher.set_root(root)
	diff_watcher.refresh_baseline()
	diff_watcher.is_host = _coordinator.is_host()
	diff_watcher.local_peer_id = _coordinator.local_peer_id()
	diff_watcher.scene_id = scene_id
	diff_watcher.base_revision = revision
	diff_watcher.enabled = enabled
	status.emit("Scene sync active (%d nodes tracked)." % node_ids.live_ids().size())
	# A host that rebinds its scene while peers are connected must hand them the
	# new authoritative content immediately; otherwise their cached node ids
	# would no longer resolve. New peers still receive a snapshot on peer_ready.
	if _coordinator.is_host() and _coordinator.session_manager != null and _coordinator.session_manager.is_active():
		_send_snapshot_to(MultiplayerPeer.TARGET_PEER_BROADCAST)


func detach_scene() -> void:
	diff_watcher.enabled = false
	diff_watcher.set_root(null)
	node_ids.clear()
	_aliases.clear()
	_pending_snapshot.clear()


func poll() -> void:
	if not enabled:
		return
	if _coordinator == null or not _coordinator.session_manager.is_active():
		return
	diff_watcher.is_host = _coordinator.is_host()
	diff_watcher.local_peer_id = _coordinator.local_peer_id()
	diff_watcher.base_revision = revision
	diff_watcher.poll()


func has_pending_snapshot() -> bool:
	return not _pending_snapshot.is_empty()


# ---------------------------------------------------------------------------
# Local operations
# ---------------------------------------------------------------------------

func _on_local_operations(ops: Array) -> void:
	if _applying or not enabled:
		return
	if ops.size() == 1 and typeof(ops[0]) == TYPE_DICTIONARY and (ops[0] as Dictionary).has("__budget__"):
		error_raised.emit("Scene too large for live sync; use a manual snapshot instead.")
		return
	if _coordinator.is_host():
		revision += 1
		diff_watcher.base_revision = revision
		_coordinator.send_scene(CollabProtocol.MessageType.OPS, {"revision": revision, "operations": ops})
		revision_changed.emit(revision)
	else:
		_coordinator.send_scene(CollabProtocol.MessageType.OPS, {"revision": revision, "operations": ops})


# ---------------------------------------------------------------------------
# Inbound routing
# ---------------------------------------------------------------------------

func _on_scene_message(from_peer: int, type: int, payload: Dictionary) -> void:
	if not enabled:
		return
	match type:
		CollabProtocol.MessageType.OPS:
			if _coordinator.is_host():
				_on_ops_to_host(from_peer, payload)
			else:
				_on_ops_from_host(payload)
		CollabProtocol.MessageType.OPS_ACK:
			revision = int(payload.get("revision", revision))
			diff_watcher.base_revision = revision
			revision_changed.emit(revision)
		CollabProtocol.MessageType.OPS_REJECT:
			var reason: int = int(payload.get("reason", CollabProtocol.Reason.UNSUPPORTED_OPERATION))
			conflict.emit("Operation rejected: %s (reason %d)" % [str(payload.get("message", "")), reason])
		CollabProtocol.MessageType.SNAPSHOT_REQUEST:
			if _coordinator.is_host():
				_send_snapshot_to(from_peer)
		CollabProtocol.MessageType.SNAPSHOT_RESPONSE:
			_pending_snapshot = payload
			if auto_apply_snapshot and not _coordinator.is_host():
				apply_pending_snapshot()
			else:
				snapshot_offered.emit((payload.get("nodes", []) as Array).size(), int(payload.get("revision", 0)))
		CollabProtocol.MessageType.RESYNC_REQUIRED:
			if not _coordinator.is_host():
				conflict.emit("Host requested a resync: %s" % str(payload.get("message", "")))
				request_snapshot()
		CollabProtocol.MessageType.CONFLICT_NOTICE:
			conflict.emit(str(payload.get("message", "Conflict reported by host.")))
		_:
			pass


func _on_ops_to_host(from_peer: int, payload: Dictionary) -> void:
	if not _coordinator.is_admitted(from_peer):
		return
	var ops: Array = payload.get("operations", [])
	var applied: Array = []
	var rejected: Array = []
	for raw in ops:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var op: Dictionary = _resolve_aliases(from_peer, raw)
		var validation: String = CollabSceneOperations.validate_op(op, Callable(self, "_resolve_node"))
		if not validation.is_empty():
			rejected.append({"op_id": op.get("op_id", -1), "reason": validation})
			continue
		if str(op.get("type", "")) == CollabSceneOperations.OP_CREATE:
			applied.append(_host_apply_create(from_peer, op))
		else:
			_apply_operation(op)
			applied.append(op)
	revision += 1
	diff_watcher.base_revision = revision
	if not applied.is_empty():
		_coordinator.send_scene(CollabProtocol.MessageType.OPS, {"revision": revision, "operations": applied})
		revision_changed.emit(revision)
	_coordinator.send_scene_to(from_peer, CollabProtocol.MessageType.OPS_ACK, {"revision": revision, "applied": applied.size()})
	if not rejected.is_empty():
		_coordinator.send_scene_to(from_peer, CollabProtocol.MessageType.OPS_REJECT, {
			"reason": CollabProtocol.Reason.UNSUPPORTED_OPERATION,
			"message": "Rejected: %s" % str(rejected[0].get("reason", "")),
			"operations": rejected,
		})
	# Refresh baseline so our own application is not echoed as a new local edit.
	diff_watcher.refresh_baseline()


func _host_apply_create(from_peer: int, op: Dictionary) -> Dictionary:
	var authoritative_id: int = node_ids.allocate_id()
	var temp_id: int = int(op.get("client_temp_id", -1))
	if temp_id != -1:
		if not _aliases.has(from_peer):
			_aliases[from_peer] = {}
		_aliases[from_peer][temp_id] = authoritative_id
	var resolved: Dictionary = _resolve_aliases(from_peer, op)
	resolved["node_id"] = authoritative_id
	resolved["client_temp_id"] = temp_id
	_apply_operation(resolved)
	return resolved


func _on_ops_from_host(payload: Dictionary) -> void:
	var ops: Array = payload.get("operations", [])
	_applying = true
	for raw in ops:
		if typeof(raw) == TYPE_DICTIONARY:
			_apply_operation(raw)
	_applying = false
	revision = int(payload.get("revision", revision))
	diff_watcher.refresh_baseline()
	diff_watcher.base_revision = revision
	revision_changed.emit(revision)


# ---------------------------------------------------------------------------
# Applying operations
# ---------------------------------------------------------------------------

func _apply_operation(op: Dictionary) -> void:
	match str(op.get("type", "")):
		CollabSceneOperations.OP_CREATE:
			_apply_create(op)
		CollabSceneOperations.OP_REMOVE:
			_apply_remove(op)
		CollabSceneOperations.OP_RENAME:
			_apply_rename(op)
		CollabSceneOperations.OP_REPARENT:
			_apply_reparent(op)
		CollabSceneOperations.OP_TRANSFORM:
			_apply_transform(op)
		CollabSceneOperations.OP_PROPERTY:
			_apply_property(op)


func _apply_create(op: Dictionary) -> void:
	var temp_id: int = int(op.get("client_temp_id", -1))
	var authoritative_id: int = int(op.get("node_id", -1))
	var is_originator: bool = int(op.get("source_peer", -1)) == _coordinator.local_peer_id()
	if temp_id != -1 and temp_id != authoritative_id and is_originator and node_ids.node_for(temp_id, false) != null:
		node_ids.rebind(temp_id, authoritative_id)
		return
	if node_ids.node_for(authoritative_id, false) != null:
		return
	var node: Node = _instantiate_class(str(op.get("node_class", "")))
	if node == null:
		error_raised.emit("Cannot create unsupported node type '%s'." % str(op.get("node_class", "")))
		return
	node.name = _safe_name(str(op.get("name", node.get_class())))
	_apply_script(node, op)
	var parent: Node = _find_parent(int(op.get("parent_id", -1)))
	if parent == null:
		parent = _edited_root()
	if parent == null:
		error_raised.emit("Cannot create node: no parent available.")
		node.free()
		return
	parent.add_child(node)
	_own_recursive(node)
	if node is Node3D:
		var t := Transform3D.IDENTITY
		t.origin = op.get("position", Vector3.ZERO)
		t.basis = Basis.from_euler(op.get("rotation", Vector3.ZERO)).scaled(op.get("scale", Vector3.ONE))
		(node as Node3D).transform = t
	node_ids.register(node, authoritative_id)
	_mark_unsaved()


func _apply_remove(op: Dictionary) -> void:
	var node: Node = node_ids.node_for(int(op.get("node_id", -1)), false)
	if node == null:
		node_ids.node_for(int(op.get("node_id", -1)), true)
		return
	node_ids.unregister(node)
	var parent: Node = node.get_parent()
	if parent != null:
		parent.remove_child(node)
	node.queue_free()
	_mark_unsaved()


func _apply_rename(op: Dictionary) -> void:
	var node: Node = node_ids.node_for(int(op.get("node_id", -1)), false)
	if node == null:
		return
	node.name = _safe_name(str(op.get("name", node.name)))
	_mark_unsaved()


func _apply_reparent(op: Dictionary) -> void:
	var node: Node = node_ids.node_for(int(op.get("node_id", -1)), false)
	var parent: Node = _find_parent(int(op.get("parent_id", -1)))
	if node == null or parent == null or node == parent:
		return
	var walker: Node = parent
	while walker != null:
		if walker == node:
			return # refuse cycles
		walker = walker.get_parent()
	var current_parent: Node = node.get_parent()
	if current_parent != null:
		current_parent.remove_child(node)
	parent.add_child(node)
	_own_recursive(node)
	_mark_unsaved()


func _apply_transform(op: Dictionary) -> void:
	var node: Node = node_ids.node_for(int(op.get("node_id", -1)), false)
	if not (node is Node3D):
		return
	var n3d: Node3D = node
	n3d.position = op.get("position", n3d.position)
	n3d.rotation = op.get("rotation", n3d.rotation)
	n3d.scale = op.get("scale", n3d.scale)
	_mark_unsaved()


func _apply_property(op: Dictionary) -> void:
	var node: Node = node_ids.node_for(int(op.get("node_id", -1)), false)
	if node == null:
		return
	var property: String = str(op.get("property", ""))
	if not CollabSceneOperations.is_property_allowed(node, property):
		return
	var kind: String = str(op.get("value_kind", ""))
	var value: Variant = CollabSceneOperations.decode_value(kind, op.get("value", null))
	if kind == CollabSceneOperations.VALUE_RESOURCE and value == null:
		conflict.emit("Resource '%s' for '%s' is missing locally." % [str(op.get("value", "")), property])
		return
	_apply_property_editor_safe(node, property, value)


# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

func request_snapshot() -> void:
	if not enabled:
		return
	if _coordinator == null or not _coordinator.session_manager.is_active():
		return
	if _coordinator.is_host():
		_send_snapshot_to(MultiplayerPeer.TARGET_PEER_BROADCAST)
	else:
		_coordinator.send_scene(CollabProtocol.MessageType.SNAPSHOT_REQUEST, {})
		status.emit("Requested scene snapshot from host.")


func apply_pending_snapshot() -> void:
	if _pending_snapshot.is_empty():
		return
	if _apply_snapshot(_pending_snapshot):
		_pending_snapshot = {}


func discard_pending_snapshot() -> void:
	_pending_snapshot.clear()


func _send_snapshot_to(peer_id: int) -> void:
	var root: Node = _edited_root()
	if root == null:
		error_raised.emit("No edited scene to snapshot.")
		return
	var snapshot := _serialize_scene(root)
	if peer_id == MultiplayerPeer.TARGET_PEER_BROADCAST:
		_coordinator.send_scene(CollabProtocol.MessageType.SNAPSHOT_RESPONSE, snapshot)
	else:
		_coordinator.send_scene_to(peer_id, CollabProtocol.MessageType.SNAPSHOT_RESPONSE, snapshot)
	status.emit("Sent snapshot (%d nodes, revision %d)." % [(snapshot["nodes"] as Array).size(), revision])


func _serialize_scene(root: Node) -> Dictionary:
	var nodes: Array = []
	_serialize_node(root, -1, nodes, true)
	return {"scene_id": scene_id, "revision": revision, "nodes": nodes}


func _serialize_node(node: Node, parent_id: int, out: Array, is_root: bool) -> void:
	var node_id: int = _id_for(node)
	var entry: Dictionary = {
		"node_id": node_id,
		"parent_id": parent_id,
		"class": node.get_class(),
		"name": node.name,
		"script": _script_path(node),
		"props": _serialize_props(node),
	}
	if node is Node3D:
		entry["position"] = (node as Node3D).position
		entry["rotation"] = (node as Node3D).rotation
		entry["scale"] = (node as Node3D).scale
	out.append(entry)
	for child in node.get_children():
		_serialize_node(child, node_id, out, false)


## Returns the stable session id for [param node], allocating one when needed.
func _id_for(node: Node) -> int:
	var existing: int = node_ids.id_for(node)
	if existing >= 0:
		return existing
	var allocated: int = node_ids.allocate_id()
	node_ids.register(node, allocated)
	return allocated


func _apply_snapshot(snapshot: Dictionary) -> bool:
	var root: Node = _edited_root()
	if root == null:
		error_raised.emit("No edited scene to apply the snapshot to. Open the shared scene first.")
		return false
	var remote_scene: String = str(snapshot.get("scene_id", ""))
	if not remote_scene.is_empty() and not scene_id.is_empty() and remote_scene != scene_id:
		conflict.emit("Snapshot is for scene '%s' but '%s' is open. Open the same scene first." % [remote_scene, scene_id])
		return false
	var nodes: Array = snapshot.get("nodes", [])
	if nodes.is_empty():
		return false
	_applying = true
	node_ids.clear()
	_aliases.clear()
	var root_entry: Dictionary = nodes[0]
	var root_snapshot_id: int = int(root_entry.get("node_id", -1))
	# Destructive by design: the host scene replaces local content.
	for child in root.get_children():
		root.remove_child(child)
		child.queue_free()
	node_ids.register(root, root_snapshot_id)
	for i in range(1, nodes.size()):
		if typeof(nodes[i]) == TYPE_DICTIONARY:
			_apply_snapshot_node(nodes[i])
	_apply_snapshot_props(root_entry, root)
	revision = int(snapshot.get("revision", revision))
	diff_watcher.refresh_baseline()
	diff_watcher.base_revision = revision
	_applying = false
	_mark_unsaved()
	snapshot_applied.emit()
	status.emit("Applied snapshot (%d nodes, revision %d)." % [nodes.size(), revision])
	return true


func _apply_snapshot_node(entry: Dictionary) -> void:
	var node_id: int = int(entry.get("node_id", -1))
	if node_ids.node_for(node_id, false) != null:
		return
	var node: Node = _instantiate_class(str(entry.get("class", "")))
	if node == null:
		return
	node.name = _safe_name(str(entry.get("name", node.get_class())))
	_apply_script(node, entry)
	var parent: Node = node_ids.node_for(int(entry.get("parent_id", -1)), false)
	if parent == null:
		parent = _edited_root()
	if parent == null:
		node.free()
		return
	parent.add_child(node)
	_own_recursive(node)
	if node is Node3D:
		var t := Transform3D.IDENTITY
		t.origin = entry.get("position", Vector3.ZERO)
		t.basis = Basis.from_euler(entry.get("rotation", Vector3.ZERO)).scaled(entry.get("scale", Vector3.ONE))
		(node as Node3D).transform = t
	node_ids.register(node, node_id)
	_apply_snapshot_props(entry, node)


func _apply_snapshot_props(entry: Dictionary, node: Node) -> void:
	var props: Dictionary = entry.get("props", {})
	for prop in props.keys():
		if not CollabSceneOperations.is_property_allowed(node, prop):
			continue
		var encoded: Dictionary = props[prop]
		var kind: String = str(encoded.get("kind", ""))
		var value: Variant = CollabSceneOperations.decode_value(kind, encoded.get("value", null))
		if kind == CollabSceneOperations.VALUE_RESOURCE and value == null:
			continue
		_apply_property_editor_safe(node, prop, value)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _serialize_props(node: Node) -> Dictionary:
	return _collect_props(node)


func _collect_props(node: Node) -> Dictionary:
	var out: Dictionary = {}
	var check_class: String = node.get_class()
	while not check_class.is_empty() and check_class != "Object":
		if CollabSceneOperations.PROPERTY_WHITELIST.has(check_class):
			for prop in CollabSceneOperations.PROPERTY_WHITELIST[check_class]:
				if prop == "name" or prop == "position" or prop == "rotation" or prop == "scale":
					continue
				if not (prop in node):
					continue
				var encoded := CollabSceneOperations.encode_value(node.get(prop))
				if encoded["kind"] != CollabSceneOperations.VALUE_UNSUPPORTED:
					out[prop] = encoded
		check_class = ClassDB.get_parent_class(check_class)
	return out


func _resolve_aliases(source_peer: int, op: Dictionary) -> Dictionary:
	if not _aliases.has(source_peer):
		return op
	var aliases: Dictionary = _aliases[source_peer]
	var out: Dictionary = op.duplicate(true)
	for key in ["node_id", "parent_id"]:
		if out.has(key):
			var raw: int = int(out[key])
			if aliases.has(raw):
				out[key] = aliases[raw]
	return out


func _resolve_node(node_id: int, _existing_only: bool = false) -> Node:
	return node_ids.node_for(node_id, false)


func _find_parent(parent_id: int) -> Node:
	if parent_id == -1:
		return _edited_root()
	return node_ids.node_for(parent_id, true)


func _instantiate_class(class_name_str: String) -> Node:
	if not CollabSceneOperations.is_creatable(class_name_str):
		return null
	if not ClassDB.class_exists(class_name_str):
		return null
	var instance: Variant = ClassDB.instantiate(class_name_str)
	return instance as Node


## Returns the resource path of a node's script, or "" when it has none. Only
## project-local scripts (`res://`) are shared; both peers run the same project
## so the path resolves to the same file on each side.
func _script_path(node: Node) -> String:
	var script: Script = node.get_script()
	if script == null:
		return ""
	var path: String = script.resource_path
	if path.is_empty() or not path.begins_with("res://") or path.contains(".."):
		return ""
	return path


## Attaches a shared script path to a freshly created node, if the path is a
## safe project-local script that exists locally.
func _apply_script(node: Node, source: Dictionary) -> void:
	var path: String = str(source.get("script", ""))
	if path.is_empty() or not path.begins_with("res://") or path.contains(".."):
		return
	if not ResourceLoader.exists(path):
		return
	var script: Resource = load(path)
	if script is Script:
		node.set_script(script)


func _own_recursive(node: Node) -> void:
	var root: Node = _edited_root()
	if root == null or node == root:
		return
	node.owner = root
	for child in node.get_children():
		_own_recursive(child)


func _safe_name(requested: String) -> String:
	var name: String = requested.strip_edges()
	if name.is_empty():
		return "Node"
	if name.length() > 128:
		name = name.substr(0, 128)
	return name


func _apply_property_editor_safe(node: Node, property: String, value: Variant) -> void:
	if node.get(property) == value:
		return
	node.set(property, value)
	if _editor.has("refresh_inspector") and _editor["refresh_inspector"].is_valid():
		_editor["refresh_inspector"].call(node)
	if _editor.has("mark_unsaved") and _editor["mark_unsaved"].is_valid():
		_editor["mark_unsaved"].call()


func _edited_root() -> Node:
	if _editor.has("get_edited_root") and _editor["get_edited_root"].is_valid():
		return _editor["get_edited_root"].call()
	return null


func _mark_unsaved() -> void:
	if _editor.has("mark_unsaved") and _editor["mark_unsaved"].is_valid():
		_editor["mark_unsaved"].call()


func _on_peer_ready(peer_id: int) -> void:
	if _coordinator != null and _coordinator.is_host():
		_send_snapshot_to(peer_id)


func _on_session_stopped(_reason: String) -> void:
	detach_scene()
	revision = 0
