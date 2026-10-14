@tool
## Debounced diff watcher for supported scene edits.
##
## Godot has no single reliable editor signal for "a user changed a property",
## so we snapshot the supported subset of the edited scene and emit structured
## operations when it changes. Scans are cheap and rate limited, and the
## baseline is refreshed immediately after remote operations so applying a
## remote change never echoes back as a new local operation.
class_name CollabDiffWatcher
extends RefCounted

signal operations_detected(ops: Array)

const SCAN_INTERVAL: float = 0.25
const MAX_NODES: int = 4000
const TRANSFORM_EPSILON: float = 0.0001

var enabled: bool = false
var is_host: bool = false
var local_peer_id: int = 0
var scene_id: String = ""
var base_revision: int = 0
var op_counter: int = 0
var max_nodes: int = MAX_NODES

var _node_ids: CollabNodeIdMap
var _baseline: Dictionary = {} # instance_id -> Dictionary
var _last_scan_ms: int = 0
var _root: Node = null
var _suspended: bool = false
var _over_budget_warned: bool = false
var _root_id: int = -1


func setup(node_ids: CollabNodeIdMap) -> void:
	_node_ids = node_ids


func set_root(root: Node) -> void:
	_root = root
	_baseline.clear()
	_over_budget_warned = false
	if root != null:
		_capture_baseline(root)


## Re-reads the current tree without emitting anything. Call immediately after
## applying remote operations.
func refresh_baseline() -> void:
	if _root == null or not is_instance_valid(_root):
		return
	_baseline.clear()
	_capture_baseline(_root)


func suspend() -> void:
	_suspended = true


func resume() -> void:
	_suspended = false
	refresh_baseline()


func poll() -> void:
	if not enabled or _suspended or _root == null or not is_instance_valid(_root):
		return
	var now := Time.get_ticks_msec()
	if now - _last_scan_ms < int(SCAN_INTERVAL * 1000.0):
		return
	_last_scan_ms = now
	_scan()


func _scan() -> void:
	var current: Dictionary = {}
	var counter: Array[int] = [0]
	_collect(_root, current, counter)
	if counter[0] > max_nodes:
		if not _over_budget_warned:
			_over_budget_warned = true
			push_warning("Godot Collab: scene exceeds %d nodes; live diff sync is paused for this scene." % max_nodes)
			operations_detected.emit([{"__budget__": true}])
		_baseline.clear()
		_capture_baseline(_root)
		return
	var ops: Array = []
	var next_baseline: Dictionary = {}
	for iid in current.keys():
		var node: Node = current[iid]
		var entry: Dictionary = _describe(node)
		if _baseline.has(iid):
			_compare(_baseline[iid], entry, ops)
		else:
			var op: Dictionary = _new_node_op(node, entry)
			if not op.is_empty():
				ops.append(op)
		next_baseline[iid] = entry
	for iid in _baseline.keys():
		if not current.has(iid):
			var old: Dictionary = _baseline[iid]
			var node_id: int = int(old.get("node_id", 0))
			if node_id != 0:
				ops.append(CollabSceneOperations.make_remove_op(local_peer_id, _next_op_id(), scene_id, base_revision, node_id))
	_baseline = next_baseline
	if not ops.is_empty():
		operations_detected.emit(ops)


func _collect(node: Node, out: Dictionary, counter: Array) -> void:
	if node == null:
		return
	out[node.get_instance_id()] = node
	counter[0] += 1
	if counter[0] > max_nodes:
		return
	for child in node.get_children():
		_collect(child, out, counter)


func _capture_baseline(node: Node) -> void:
	if node == null:
		return
	_baseline[node.get_instance_id()] = _describe(node)
	for child in node.get_children():
		_capture_baseline(child)


func _describe(node: Node) -> Dictionary:
	var node_id: int = _ensure_id(node)
	var parent: Node = node.get_parent()
	var parent_id: int = -1
	if parent != null and parent != _root:
		parent_id = _ensure_id(parent)
	var entry: Dictionary = {
		"node_id": node_id,
		"parent_id": parent_id,
		"name": node.name,
		"is_node3d": node is Node3D,
		"transform": (node as Node3D).transform if node is Node3D else Transform3D.IDENTITY,
		"props": _watched_props(node),
	}
	return entry


func _ensure_id(node: Node) -> int:
	var node_id: int = _node_ids.id_for(node)
	if node_id != -1:
		return node_id
	node_id = _node_ids.allocate_id() if is_host else _node_ids.allocate_temp_id()
	_node_ids.register(node, node_id)
	return node_id


func _new_node_op(node: Node, entry: Dictionary) -> Dictionary:
	if node == _root:
		return {}
	var node_id: int = int(entry["node_id"])
	var parent_id: int = int(entry["parent_id"])
	var op := CollabSceneOperations.make_create_op(
		local_peer_id, _next_op_id(), scene_id, base_revision,
		parent_id, node.get_class(), node.name, node_id if not is_host else -1)
	op["node_id"] = node_id
	if entry["is_node3d"]:
		var t: Transform3D = entry["transform"]
		op["position"] = t.origin
		op["rotation"] = t.basis.get_euler()
		op["scale"] = t.basis.get_scale()
	return op


func _compare(old: Dictionary, new_entry: Dictionary, ops: Array) -> void:
	var node_id: int = int(new_entry["node_id"])
	if int(old["parent_id"]) != int(new_entry["parent_id"]):
		ops.append(CollabSceneOperations.make_reparent_op(local_peer_id, _next_op_id(), scene_id, base_revision, node_id, int(new_entry["parent_id"])))
	if str(old["name"]) != str(new_entry["name"]):
		ops.append(CollabSceneOperations.make_rename_op(local_peer_id, _next_op_id(), scene_id, base_revision, node_id, str(new_entry["name"])))
	if bool(old["is_node3d"]) and bool(new_entry["is_node3d"]):
		var a: Transform3D = old["transform"]
		var b: Transform3D = new_entry["transform"]
		if not a.is_equal_approx(b) and _transform_delta(a, b) > TRANSFORM_EPSILON:
			var node: Node = _node_ids.node_for(node_id)
			if node is Node3D:
				ops.append(CollabSceneOperations.make_transform_op(local_peer_id, _next_op_id(), scene_id, base_revision, node_id, node as Node3D))
	var old_props: Dictionary = old["props"]
	var new_props: Dictionary = new_entry["props"]
	for prop in new_props.keys():
		if not old_props.has(prop):
			continue
		if old_props[prop] != new_props[prop]:
			ops.append({
				"op_id": _next_op_id(),
				"source_peer": local_peer_id,
				"scene_id": scene_id,
				"base_revision": base_revision,
				"type": CollabSceneOperations.OP_PROPERTY,
				"node_id": node_id,
				"property": prop,
				"value_kind": new_props[prop]["kind"],
				"value": new_props[prop]["value"],
			})


func _watched_props(node: Node) -> Dictionary:
	var out: Dictionary = {}
	var check_class: String = node.get_class()
	while not check_class.is_empty() and check_class != "Object":
		if CollabSceneOperations.PROPERTY_WHITELIST.has(check_class):
			for prop in CollabSceneOperations.PROPERTY_WHITELIST[check_class]:
				if _should_skip_prop(prop):
					continue
				if not (prop in node):
					continue
				var encoded := CollabSceneOperations.encode_value(node.get(prop))
				if encoded["kind"] == CollabSceneOperations.VALUE_UNSUPPORTED:
					continue
				out[prop] = encoded
		check_class = ClassDB.get_parent_class(check_class)
	return out


func _should_skip_prop(prop: String) -> bool:
	# Transform is tracked separately; name is tracked separately.
	return prop == "name" or prop == "position" or prop == "rotation" or prop == "scale"


func _transform_delta(a: Transform3D, b: Transform3D) -> float:
	return (a.origin - b.origin).length() + (a.basis.get_euler() - b.basis.get_euler()).length() + (a.basis.get_scale() - b.basis.get_scale()).length()


func _next_op_id() -> int:
	op_counter += 1
	return op_counter
