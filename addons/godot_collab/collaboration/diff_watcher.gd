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
## Embedded resources referenced by the current scan, keyed by instance id:
## { res_id: { resource: Resource, targets: [{node, property}] } }. Rebuilt every
## scan so a resource's "changed" signal can be used to catch in-place edits
## (which a reference-only signature would miss).
var _scan_bindings: Dictionary = {}
## Live "changed" connections: res_id -> { resource: Resource, callable: Callable }.
var _res_conns: Dictionary = {}


func setup(node_ids: CollabNodeIdMap) -> void:
	_node_ids = node_ids


func set_root(root: Node) -> void:
	_clear_resource_tracking()
	_root = root
	_baseline.clear()
	_over_budget_warned = false
	if root != null:
		_capture_baseline(root)


## Re-reads the current tree without emitting anything. Call immediately after
## applying remote operations.
func refresh_baseline() -> void:
	# Drop stale resource bindings/connections; the next scan rebuilds them
	# against the post-apply tree so an echoed apply can never ping-pong.
	_clear_resource_tracking()
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
	_scan_bindings = {}
	var ops: Array = []
	var next_baseline: Dictionary = {}
	for iid in current.keys():
		var node: Node = current[iid]
		var entry: Dictionary = _describe(node)
		_record_bindings(node, entry)
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
	_sync_resource_connections()
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
	# Only the host owns the authoritative positive id space. Every non-host,
	# including an editor that is not yet in a session, uses negative temporary
	# ids. This guarantees a peer can never emit an operation that resolves to a
	# *different* node on the host (its ids are re-keyed to the host's on the
	# first snapshot / create echo), which is what previously caused rejoining
	# clients to toggle the wrong node.
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
	op["script"] = _script_path(node)
	# A create carries the full property set (inline resources included), not the
	# cheap comparison signatures the baseline uses.
	op["props"] = CollabSceneOperations.collect_syncable_props(node)
	if entry["is_node3d"]:
		var t: Transform3D = entry["transform"]
		op["position"] = t.origin
		op["rotation"] = t.basis.get_euler()
		op["scale"] = t.basis.get_scale()
	return op


func _script_path(node: Node) -> String:
	var script: Script = node.get_script()
	if script == null:
		return ""
	var path: String = script.resource_path
	if path.is_empty() or not path.begins_with("res://") or path.contains(".."):
		return ""
	return path


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
		if old_props[prop] == new_props[prop]:
			continue
		var node: Node = _node_ids.node_for(node_id)
		if node == null:
			continue
		# The baseline stores cheap signatures, so the full wire value is
		# produced here, once, only for properties that actually changed.
		var encoded: Dictionary = CollabSceneOperations.encode_value(node.get(prop))
		if encoded["kind"] == CollabSceneOperations.VALUE_UNSUPPORTED:
			continue
		ops.append(CollabSceneOperations.make_property_op(
			local_peer_id, _next_op_id(), scene_id, base_revision, node_id, prop, encoded))


## Collects a comparison-only projection of [param node]'s properties. The
## policy lives in [CollabSceneOperations]; `cheap = true` reduces embedded
## resources to an instance-id token so the per-scan baseline stays inexpensive.
func _watched_props(node: Node) -> Dictionary:
	return CollabSceneOperations.collect_syncable_props(node, true)


## Records embedded resources referenced by [param entry] so their "changed"
## signal can trigger a targeted property operation for in-place edits.
func _record_bindings(node: Node, entry: Dictionary) -> void:
	var props: Dictionary = entry.get("props", {})
	for prop in props.keys():
		var encoded: Dictionary = props[prop]
		if str(encoded.get("kind", "")) != CollabSceneOperations.VALUE_RESOURCE_INLINE:
			continue
		var res_id: int = int(encoded.get("value", 0))
		if res_id == 0:
			continue
		var resource: Resource = node.get(prop) as Resource
		if resource == null:
			continue
		if not _scan_bindings.has(res_id):
			_scan_bindings[res_id] = {"resource": resource, "targets": []}
		(_scan_bindings[res_id]["targets"] as Array).append({"node": node, "property": str(prop)})


func _sync_resource_connections() -> void:
	for res_id in _res_conns.keys():
		if _scan_bindings.has(res_id):
			continue
		var tracked: Dictionary = _res_conns[res_id]
		var resource: Resource = tracked.get("resource")
		var callback: Callable = tracked.get("callable")
		if resource != null and callback.is_valid() and resource.changed.is_connected(callback):
			resource.changed.disconnect(callback)
		_res_conns.erase(res_id)
	for res_id in _scan_bindings.keys():
		if _res_conns.has(res_id):
			continue
		var resource: Resource = _scan_bindings[res_id].get("resource")
		if resource == null:
			continue
		var callback: Callable = _on_resource_changed.bind(res_id)
		resource.changed.connect(callback)
		_res_conns[res_id] = {"resource": resource, "callable": callback}


## Emits property operations for an embedded resource edited in place. The
## reference-based signature does not change for these, so the resource's
## "changed" signal is the only reliable trigger.
func _on_resource_changed(res_id: int) -> void:
	if not enabled or _suspended:
		return
	var binding: Variant = _scan_bindings.get(res_id)
	if binding == null:
		return
	var ops: Array = []
	for target in (binding["targets"] as Array):
		var node: Node = target.get("node")
		if not is_instance_valid(node):
			continue
		var prop: String = str(target.get("property", ""))
		var encoded: Dictionary = CollabSceneOperations.encode_value(node.get(prop))
		if encoded["kind"] == CollabSceneOperations.VALUE_UNSUPPORTED:
			continue
		ops.append(CollabSceneOperations.make_property_op(local_peer_id, _next_op_id(), scene_id, base_revision, _ensure_id(node), prop, encoded))
	if not ops.is_empty():
		operations_detected.emit(ops)


func _clear_resource_tracking() -> void:
	for res_id in _res_conns.keys():
		var tracked: Dictionary = _res_conns[res_id]
		var resource: Resource = tracked.get("resource")
		var callback: Callable = tracked.get("callable")
		if resource != null and callback.is_valid() and resource.changed.is_connected(callback):
			resource.changed.disconnect(callback)
	_res_conns.clear()
	_scan_bindings.clear()


func _transform_delta(a: Transform3D, b: Transform3D) -> float:
	return (a.origin - b.origin).length() + (a.basis.get_euler() - b.basis.get_euler()).length() + (a.basis.get_scale() - b.basis.get_scale()).length()


func _next_op_id() -> int:
	op_counter += 1
	return op_counter
