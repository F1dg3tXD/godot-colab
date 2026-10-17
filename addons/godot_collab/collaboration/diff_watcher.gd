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
## How often embedded (path-less) resources are re-serialised to catch in-place
## edits. Most Resource subclasses (materials, environments, meshes) do NOT emit
## their "changed" signal for ordinary property edits, so a content comparison on
## a slow cadence is the only reliable trigger. Kept slower than the node scan so
## the serialisation cost stays off the hot path.
const DEEP_RESOURCE_INTERVAL: float = 1.5

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
## Deep-scanned properties of the current scan, keyed by "<node instance id>|<property>":
## { key: { node: Node, property: String } }. Rebuilt every scan so in-place
## resource edits can be caught by a content comparison (a reference-only
## signature would miss them). Covers embedded resources, file-backed resources
## and containers that hold resources.
var _deep_bindings: Dictionary = {}
## Last full-content fingerprint of each deep-scanned property: key -> String.
## Compared on [_deep_scan_resources] to detect in-place edits.
var _res_sigs: Dictionary = {}
var _deep_last_ms: int = 0


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
	if now - _last_scan_ms >= int(SCAN_INTERVAL * 1000.0):
		_last_scan_ms = now
		_scan()
	if now - _deep_last_ms >= int(DEEP_RESOURCE_INTERVAL * 1000.0):
		_deep_last_ms = now
		_deep_scan_resources()


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
	_deep_bindings = {}
	var ops: Array = []
	var next_baseline: Dictionary = {}
	for iid in current.keys():
		var node: Node = current[iid]
		var entry: Dictionary = _describe(node)
		_record_bindings(node)
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


## Records properties whose value can change without the cheap signature
## noticing: resources and containers holding resources. Their full content is
## compared on a slow cadence because most Resource subclasses (materials,
## environments, meshes) never emit their "changed" signal for ordinary edits.
func _record_bindings(node: Node) -> void:
	for info in node.get_property_list():
		var prop: String = str(info.get("name", ""))
		if not CollabSceneOperations.is_syncable_property_name(prop):
			continue
		var usage: int = int(info.get("usage", 0))
		if (usage & PROPERTY_USAGE_INTERNAL) != 0:
			continue
		if (usage & PROPERTY_USAGE_STORAGE) == 0 and (usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		var value: Variant = node.get(prop)
		if not CollabSceneOperations.requires_deep_scan(value):
			continue
		var key: String = "%d|%s" % [node.get_instance_id(), prop]
		_deep_bindings[key] = {"node": node, "property": prop}
		# Anchor the content signature the moment the property is first seen. If
		# this were left to the periodic deep scan, an edit made before that scan
		# runs would be folded into the baseline and silently lost.
		if not _res_sigs.has(key):
			_res_sigs[key] = CollabSceneOperations.deep_signature(value)


## Re-serialises every deep-scanned property and emits property operations for
## any whose content changed since the previous pass. This replaces relying on
## [signal Resource.changed], which most Resource subclasses never emit for
## ordinary property edits. The first pass for a property only records its
## signature so it does not re-send on bind.
func _deep_scan_resources() -> void:
	if _deep_bindings.is_empty():
		_res_sigs.clear()
		return
	var next_sigs: Dictionary = {}
	var ops: Array = []
	for key in _deep_bindings.keys():
		var binding: Dictionary = _deep_bindings[key]
		var node: Node = binding.get("node")
		if not is_instance_valid(node):
			continue
		var prop: String = str(binding.get("property", ""))
		var value: Variant = node.get(prop)
		var signature: String = CollabSceneOperations.deep_signature(value)
		next_sigs[key] = signature
		if not _res_sigs.has(key):
			continue
		if str(_res_sigs[key]) == signature:
			continue
		var encoded: Dictionary = CollabSceneOperations.encode_value(value)
		if encoded["kind"] == CollabSceneOperations.VALUE_UNSUPPORTED:
			continue
		ops.append(CollabSceneOperations.make_property_op(local_peer_id, _next_op_id(), scene_id, base_revision, _ensure_id(node), prop, encoded))
	_res_sigs = next_sigs
	if not ops.is_empty():
		operations_detected.emit(ops)


func _clear_resource_tracking() -> void:
	_res_sigs.clear()
	_deep_bindings.clear()


func _transform_delta(a: Transform3D, b: Transform3D) -> float:
	return (a.origin - b.origin).length() + (a.basis.get_euler() - b.basis.get_euler()).length() + (a.basis.get_scale() - b.basis.get_scale()).length()


func _next_op_id() -> int:
	op_counter += 1
	return op_counter
