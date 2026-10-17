@tool
## Host-authoritative, multi-scene synchronisation.
##
## Local edits are captured per scene by [CollabDiffWatcher] and sent as
## structured operations tagged with their `res://` scene path. The host is the
## single authority: it validates and applies client operations to the correct
## scene context, assigns authoritative node ids, bumps that scene's revision
## and broadcasts the accepted operation so all peers converge with no
## rebroadcast loops.
##
## Scene contexts are independent of the editor's focused tab: binding uses
## every open scene root (the plugin supplies them), so a collaborator can keep
## editing scene A while the host is focused on scene B. If the host does not
## have a scene open at all, it loads a detached model from disk, applies the
## operation there and writes it back, so client work is never discarded merely
## because the host was looking elsewhere.
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

## Compatibility accessors for the scene currently focused in the editor.
var scene_id: String = ""
var revision: int = 0
## When false the service is presence-only (Git presence mode): it neither
## broadcasts nor applies scene operations, and it never sends or accepts
## snapshots.
var enabled: bool = true
## When true a non-host automatically applies an incoming snapshot. In
## host-workspace mode the host owns the authoritative scene, so a peer should
## immediately mirror whatever the host currently has instead of waiting for a
## manual confirmation.
var auto_apply_snapshot: bool = true

## Host contexts that received remote operations are written back to disk after
## this much idle time so client work survives even if the host never focuses
## the scene or clicks save.
const PERSIST_DEBOUNCE_MS: int = 1200

## A path-backed resource operation can arrive before the file that backs it
## (for example when a resource is renamed: the reference update and the file
## rename travel on separate channels). Instead of dropping the reference, keep
## it pending and retry until the file exists, giving up after this long.
const PENDING_RESOURCE_TIMEOUT_MS: int = 20000
## Upper bound on pending resource references held at once.
const MAX_PENDING_RESOURCES: int = 256

var _coordinator: CollabSessionCoordinator
var _logs: CollabLog
var _editor: Dictionary = {}
var _scenes: Dictionary = {} # scene_id:String -> CollabSceneContext
var _primary_scene_id: String = ""
var _aliases: Dictionary = {} # "peer:scene" -> {temp_id: authoritative_id}
var _applying: bool = false
var _pending_snapshot: Dictionary = {}
## Resource property operations whose backing file does not exist locally yet:
## [{ scene_id, node_id, property, value, since_ms }]. Retried every poll.
var _pending_resources: Array[Dictionary] = []


func setup(coordinator: CollabSessionCoordinator, logs: CollabLog, editor: Dictionary) -> void:
	_coordinator = coordinator
	_logs = logs
	_editor = editor
	coordinator.scene_message.connect(_on_scene_message)
	coordinator.session_stopped.connect(_on_session_stopped)
	coordinator.peer_ready.connect(_on_peer_ready)


# ---------------------------------------------------------------------------
# Scene binding
# ---------------------------------------------------------------------------

## Binds (or re-binds) a live editor scene root to a scene path. Safe to call
## every frame: re-binding the same root is a no-op, so node ids and the diff
## baseline are preserved.
func bind_scene(root: Node, p_scene_id: String, active: bool = false) -> CollabSceneContext:
	if root == null or p_scene_id.is_empty():
		return null
	var existing: CollabSceneContext = _scenes.get(p_scene_id)
	if existing != null and existing.root == root and not existing.detached:
		existing.is_active = active
		_configure(existing)
		if active:
			_set_primary(existing)
		return existing
	var carried_revision: int = existing.revision if existing != null else 0
	if existing != null:
		_release_context(existing)
	var ctx := CollabSceneContext.new(p_scene_id, root)
	ctx.revision = carried_revision
	ctx.is_active = active
	_scenes[p_scene_id] = ctx
	ctx.diff_watcher.set_root(root)
	_configure(ctx)
	ctx.diff_watcher.refresh_baseline()
	ctx.ops_callable = _on_context_ops.bind(ctx)
	ctx.diff_watcher.operations_detected.connect(ctx.ops_callable)
	if active or _primary_scene_id.is_empty():
		_set_primary(ctx)
	status.emit("Scene sync active for %s (%d nodes tracked)." % [p_scene_id, ctx.node_ids.live_ids().size()])
	return ctx


## Stops tracking a scene path (the editor tab was closed).
func unbind_scene(p_scene_id: String) -> void:
	var ctx: CollabSceneContext = _scenes.get(p_scene_id)
	if ctx == null:
		return
	_release_context(ctx)
	_scenes.erase(p_scene_id)
	if p_scene_id == _primary_scene_id:
		_primary_scene_id = ""
		revision = 0
		scene_id = ""
		if not _scenes.is_empty():
			_set_primary(_scenes.values()[0])


## Compatibility wrapper used by the plugin and tests: binds a root and marks it
## the focused scene.
func attach_scene(root: Node, p_scene_id: String) -> void:
	if root == null:
		return
	bind_scene(root, p_scene_id, true)


## Stops tracking every scene (session stop / plugin disable).
func detach_scene() -> void:
	for ctx in _scenes.values():
		_release_context(ctx)
	_scenes.clear()
	_aliases.clear()
	_pending_snapshot.clear()
	_pending_resources.clear()
	_primary_scene_id = ""
	scene_id = ""
	revision = 0


## Breaks the context's signal connection so the RefCounted context (and its
## node-id map and diff watcher) can be freed.
func _release_context(ctx: CollabSceneContext) -> void:
	if ctx == null:
		return
	ctx.diff_watcher.enabled = false
	if ctx.ops_callable.is_valid() and ctx.diff_watcher.operations_detected.is_connected(ctx.ops_callable):
		ctx.diff_watcher.operations_detected.disconnect(ctx.ops_callable)
	ctx.ops_callable = Callable()
	ctx.diff_watcher.set_root(null)


func has_scene(p_scene_id: String) -> bool:
	return _scenes.has(p_scene_id)


func known_scene_ids() -> Array[String]:
	var out: Array[String] = []
	for key in _scenes.keys():
		out.append(key)
	return out


func has_pending_snapshot() -> bool:
	return not _pending_snapshot.is_empty()


## Returns the stable id currently mapped to [param node] within
## [param p_scene_id], or -1 when the node is not tracked. Exposed for tests.
func node_id_for_scene(p_scene_id: String, node: Node) -> int:
	var ctx: CollabSceneContext = _scenes.get(p_scene_id)
	if ctx == null:
		return -1
	return ctx.node_ids.id_for(node)


func poll() -> void:
	if not enabled:
		return
	if _coordinator == null or not _coordinator.session_manager.is_active():
		return
	var now: int = Time.get_ticks_msec()
	_resolve_pending_resources(now)
	for ctx in _scenes.values():
		_configure(ctx)
		ctx.diff_watcher.poll()
		if _coordinator.is_host() and ctx.dirty and (now - ctx.last_change_ms) >= PERSIST_DEBOUNCE_MS:
			if ctx.detached or not ctx.is_active:
				_persist_context(ctx)


func _configure(ctx: CollabSceneContext) -> void:
	ctx.diff_watcher.enabled = enabled
	ctx.diff_watcher.is_host = _coordinator.is_host()
	ctx.diff_watcher.local_peer_id = _coordinator.local_peer_id()
	ctx.diff_watcher.scene_id = ctx.scene_id
	ctx.diff_watcher.base_revision = ctx.revision


func _set_primary(ctx: CollabSceneContext) -> void:
	_primary_scene_id = ctx.scene_id
	if scene_id != ctx.scene_id:
		scene_id = ctx.scene_id
	revision = ctx.revision


func _primary_context() -> CollabSceneContext:
	if _primary_scene_id.is_empty():
		return null
	return _scenes.get(_primary_scene_id)


# ---------------------------------------------------------------------------
# Local operations
# ---------------------------------------------------------------------------

func _on_context_ops(ops: Array, ctx: CollabSceneContext) -> void:
	if _applying or not enabled:
		return
	if ops.size() == 1 and typeof(ops[0]) == TYPE_DICTIONARY and (ops[0] as Dictionary).has("__budget__"):
		error_raised.emit("Scene '%s' is too large for live sync; use a manual snapshot instead." % ctx.scene_id)
		return
	if _coordinator.is_host():
		ctx.revision += 1
		ctx.diff_watcher.base_revision = ctx.revision
		if ctx.scene_id == _primary_scene_id:
			revision = ctx.revision
		_coordinator.send_scene(CollabProtocol.MessageType.OPS, {
			"scene_id": ctx.scene_id,
			"revision": ctx.revision,
			"operations": ops,
		})
		revision_changed.emit(ctx.revision)
	else:
		_coordinator.send_scene(CollabProtocol.MessageType.OPS, {
			"scene_id": ctx.scene_id,
			"revision": ctx.revision,
			"operations": ops,
		})


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
			_apply_ack(payload)
		CollabProtocol.MessageType.OPS_REJECT:
			var reason: int = int(payload.get("reason", CollabProtocol.Reason.UNSUPPORTED_OPERATION))
			conflict.emit("Operation rejected: %s (reason %d)" % [str(payload.get("message", "")), reason])
		CollabProtocol.MessageType.SNAPSHOT_REQUEST:
			if _coordinator.is_host():
				_send_reply_snapshot(from_peer, payload)
		CollabProtocol.MessageType.SNAPSHOT_RESPONSE:
			_pending_snapshot = payload
			if not _coordinator.is_host():
				if auto_apply_snapshot:
					apply_pending_snapshot()
				else:
					# The user chose to review the snapshot before replacing their
					# scene, but node identities must still be reconciled or a
					# later local edit could target a different node on the host.
					reconcile_ids_from_snapshot(payload)
				snapshot_offered.emit((payload.get("nodes", []) as Array).size(), int(payload.get("revision", 0)))
			else:
				snapshot_offered.emit((payload.get("nodes", []) as Array).size(), int(payload.get("revision", 0)))
		CollabProtocol.MessageType.RESYNC_REQUIRED:
			if not _coordinator.is_host():
				conflict.emit("Host requested a resync: %s" % str(payload.get("message", "")))
				request_snapshot(str(payload.get("scene_id", "")))
		CollabProtocol.MessageType.CONFLICT_NOTICE:
			conflict.emit(str(payload.get("message", "Conflict reported by host.")))
		_:
			pass


func _apply_ack(payload: Dictionary) -> void:
	var ack_scene: String = str(payload.get("scene_id", ""))
	var ack_rev: int = int(payload.get("revision", revision))
	if not ack_scene.is_empty():
		var ctx: CollabSceneContext = _scenes.get(ack_scene)
		if ctx != null:
			ctx.revision = ack_rev
			ctx.diff_watcher.base_revision = ack_rev
			if ack_scene == _primary_scene_id:
				revision = ack_rev
			revision_changed.emit(ack_rev)
			return
	revision = ack_rev
	revision_changed.emit(ack_rev)


func _on_ops_to_host(from_peer: int, payload: Dictionary) -> void:
	if not _coordinator.is_admitted(from_peer):
		return
	var ops: Array = payload.get("operations", [])
	var op_scene: String = _payload_scene_id(payload, ops)
	var ctx: CollabSceneContext = _ensure_host_context(op_scene)
	if ctx == null:
		var detail: String = "Host cannot apply edits for scene '%s' (not open and not loadable from disk)." % op_scene
		conflict.emit(detail)
		_coordinator.send_scene_to(from_peer, CollabProtocol.MessageType.OPS_REJECT, {
			"reason": CollabProtocol.Reason.WRONG_SCENE,
			"message": detail,
			"scene_id": op_scene,
			"operations": ops,
		})
		return
	var applied: Array = []
	var rejected: Array = []
	ctx.diff_watcher.suspend()
	for raw in ops:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var op: Dictionary = _resolve_aliases(ctx, from_peer, raw)
		if not str(op.get("scene_id", "")).is_empty() and str(op.get("scene_id", "")) != ctx.scene_id:
			rejected.append({"op_id": op.get("op_id", -1), "reason": "scene mismatch"})
			continue
		op["scene_id"] = ctx.scene_id
		var validation: String = CollabSceneOperations.validate_op(op, Callable(self, "_resolve_node").bind(ctx))
		if not validation.is_empty():
			rejected.append({"op_id": op.get("op_id", -1), "reason": validation})
			continue
		if str(op.get("type", "")) == CollabSceneOperations.OP_CREATE:
			applied.append(_host_apply_create(ctx, from_peer, op))
		else:
			_apply_operation(op, ctx)
			applied.append(op)
	ctx.revision += 1
	ctx.diff_watcher.resume()
	ctx.diff_watcher.base_revision = ctx.revision
	if ctx.scene_id == _primary_scene_id:
		revision = ctx.revision
	if ctx.detached:
		_save_context(ctx)
	else:
		ctx.dirty = true
		ctx.last_change_ms = Time.get_ticks_msec()
	if not applied.is_empty():
		_coordinator.send_scene(CollabProtocol.MessageType.OPS, {
			"scene_id": ctx.scene_id,
			"revision": ctx.revision,
			"operations": applied,
		})
		revision_changed.emit(ctx.revision)
	_coordinator.send_scene_to(from_peer, CollabProtocol.MessageType.OPS_ACK, {
		"scene_id": ctx.scene_id,
		"revision": ctx.revision,
		"applied": applied.size(),
	})
	if not rejected.is_empty():
		_coordinator.send_scene_to(from_peer, CollabProtocol.MessageType.OPS_REJECT, {
			"reason": CollabProtocol.Reason.UNSUPPORTED_OPERATION,
			"message": "Rejected: %s" % str(rejected[0].get("reason", "")),
			"scene_id": ctx.scene_id,
			"operations": rejected,
		})


func _host_apply_create(ctx: CollabSceneContext, from_peer: int, op: Dictionary) -> Dictionary:
	var authoritative_id: int = ctx.node_ids.allocate_id()
	var temp_id: int = int(op.get("client_temp_id", -1))
	if temp_id != -1:
		var key: String = _alias_key(from_peer, ctx.scene_id)
		if not _aliases.has(key):
			_aliases[key] = {}
		(_aliases[key] as Dictionary)[temp_id] = authoritative_id
	var resolved: Dictionary = _resolve_aliases(ctx, from_peer, op)
	resolved["node_id"] = authoritative_id
	resolved["client_temp_id"] = temp_id
	resolved["scene_id"] = ctx.scene_id
	_apply_operation(resolved, ctx)
	return resolved


func _on_ops_from_host(payload: Dictionary) -> void:
	var ops: Array = payload.get("operations", [])
	var op_scene: String = _payload_scene_id(payload, ops)
	var ctx: CollabSceneContext = _scenes.get(op_scene)
	if ctx == null:
		status.emit("Ignored edits for scene '%s' (not open locally)." % op_scene)
		return
	_applying = true
	ctx.diff_watcher.suspend()
	for raw in ops:
		if typeof(raw) == TYPE_DICTIONARY:
			_apply_operation(raw, ctx)
	ctx.diff_watcher.resume()
	_applying = false
	ctx.revision = int(payload.get("revision", ctx.revision))
	ctx.diff_watcher.base_revision = ctx.revision
	if ctx.scene_id == _primary_scene_id:
		revision = ctx.revision
	revision_changed.emit(ctx.revision)


# ---------------------------------------------------------------------------
# Applying operations
# ---------------------------------------------------------------------------

func _apply_operation(op: Dictionary, ctx: CollabSceneContext) -> void:
	match str(op.get("type", "")):
		CollabSceneOperations.OP_CREATE:
			_apply_create(op, ctx)
		CollabSceneOperations.OP_REMOVE:
			_apply_remove(op, ctx)
		CollabSceneOperations.OP_RENAME:
			_apply_rename(op, ctx)
		CollabSceneOperations.OP_REPARENT:
			_apply_reparent(op, ctx)
		CollabSceneOperations.OP_TRANSFORM:
			_apply_transform(op, ctx)
		CollabSceneOperations.OP_PROPERTY:
			_apply_property(op, ctx)


func _apply_create(op: Dictionary, ctx: CollabSceneContext) -> void:
	var temp_id: int = int(op.get("client_temp_id", -1))
	var authoritative_id: int = int(op.get("node_id", -1))
	var is_originator: bool = int(op.get("source_peer", -1)) == _coordinator.local_peer_id()
	if temp_id != -1 and temp_id != authoritative_id and is_originator and ctx.node_ids.node_for(temp_id, false) != null:
		ctx.node_ids.rebind(temp_id, authoritative_id)
		return
	if ctx.node_ids.node_for(authoritative_id, false) != null:
		return
	var node: Node = _instantiate_class(str(op.get("node_class", "")))
	if node == null:
		error_raised.emit("Cannot create unsupported node type '%s'." % str(op.get("node_class", "")))
		return
	node.name = _safe_name(str(op.get("name", node.get_class())))
	_apply_script(node, op)
	var parent: Node = _find_parent(ctx, int(op.get("parent_id", -1)))
	if parent == null:
		parent = ctx.root
	if parent == null:
		error_raised.emit("Cannot create node: no parent available.")
		node.free()
		return
	parent.add_child(node)
	_own_recursive(node, ctx.root)
	if node is Node3D:
		var t := Transform3D.IDENTITY
		t.origin = op.get("position", Vector3.ZERO)
		t.basis = Basis.from_euler(op.get("rotation", Vector3.ZERO)).scaled(op.get("scale", Vector3.ONE))
		(node as Node3D).transform = t
	# Register before applying properties so a deferred resource reference can
	# resolve against this node's stable id on a later poll.
	ctx.node_ids.register(node, authoritative_id)
	_apply_entry_props(node, op.get("props", {}), ctx)
	_mark_unsaved(ctx)


## Applies a { property: { kind, value } } dictionary to [param node], skipping
## anything that is no longer syncable on this node.
func _apply_entry_props(node: Node, props: Variant, ctx: CollabSceneContext) -> void:
	if typeof(props) != TYPE_DICTIONARY:
		return
	for prop in (props as Dictionary).keys():
		var name: String = str(prop)
		if not CollabSceneOperations.is_property_syncable(node, name):
			continue
		var encoded: Dictionary = (props as Dictionary)[prop]
		var kind: String = str(encoded.get("kind", ""))
		var value: Variant = CollabSceneOperations.decode_value(kind, encoded.get("value", null))
		if CollabSceneOperations.is_resource_kind(kind) and value == null:
			_queue_pending_resource(ctx, ctx.node_ids.id_for(node), name, kind, encoded.get("value"))
			continue
		_apply_property_editor_safe(node, name, value, ctx)


func _apply_remove(op: Dictionary, ctx: CollabSceneContext) -> void:
	var node: Node = ctx.node_ids.node_for(int(op.get("node_id", -1)), false)
	if node == null:
		ctx.node_ids.node_for(int(op.get("node_id", -1)), true)
		return
	ctx.node_ids.unregister(node)
	var parent: Node = node.get_parent()
	if parent != null:
		parent.remove_child(node)
	node.queue_free()
	_mark_unsaved(ctx)


func _apply_rename(op: Dictionary, ctx: CollabSceneContext) -> void:
	var node: Node = ctx.node_ids.node_for(int(op.get("node_id", -1)), false)
	if node == null:
		return
	node.name = _safe_name(str(op.get("name", node.name)))
	_mark_unsaved(ctx)


func _apply_reparent(op: Dictionary, ctx: CollabSceneContext) -> void:
	var node: Node = ctx.node_ids.node_for(int(op.get("node_id", -1)), false)
	var parent: Node = _find_parent(ctx, int(op.get("parent_id", -1)))
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
	_own_recursive(node, ctx.root)
	_mark_unsaved(ctx)


func _apply_transform(op: Dictionary, ctx: CollabSceneContext) -> void:
	var node: Node = ctx.node_ids.node_for(int(op.get("node_id", -1)), false)
	if not (node is Node3D):
		return
	var n3d: Node3D = node
	n3d.position = op.get("position", n3d.position)
	n3d.rotation = op.get("rotation", n3d.rotation)
	n3d.scale = op.get("scale", n3d.scale)
	_mark_unsaved(ctx)


func _apply_property(op: Dictionary, ctx: CollabSceneContext) -> void:
	var node: Node = ctx.node_ids.node_for(int(op.get("node_id", -1)), false)
	if node == null:
		return
	var property: String = str(op.get("property", ""))
	if not CollabSceneOperations.is_property_syncable(node, property):
		return
	var kind: String = str(op.get("value_kind", ""))
	if kind == CollabSceneOperations.VALUE_RESOURCE_CONTENT:
		_apply_resource_content(node, property, op.get("value", null), ctx)
		_drop_pending_resource(ctx.scene_id, int(op.get("node_id", -1)), property)
		return
	var value: Variant = CollabSceneOperations.decode_value(kind, op.get("value", null))
	if CollabSceneOperations.is_resource_kind(kind) and value == null:
		if _queue_pending_resource(ctx, int(op.get("node_id", -1)), property, kind, op.get("value")):
			return
		conflict.emit("Resource for '%s' could not be resolved locally." % property)
		return
	_drop_pending_resource(ctx.scene_id, int(op.get("node_id", -1)), property)
	_apply_property_editor_safe(node, property, value, ctx)


## Applies a content-bearing resource value, merging onto any equivalent local
## instance so shared references survive. Returns false (after reporting a
## conflict) when the payload cannot be rebuilt from its text.
func _apply_resource_content(node: Node, property: String, raw: Variant, ctx: CollabSceneContext) -> bool:
	if typeof(raw) != TYPE_DICTIONARY:
		conflict.emit("Resource content for '%s' was malformed." % property)
		return false
	var content: Dictionary = raw
	var existing: Resource = node.get(property) as Resource
	var resolved: Resource = CollabSceneOperations.apply_resource_content(
		str(content.get("path", "")), str(content.get("text", "")), existing)
	if resolved == null:
		conflict.emit("Resource content for '%s' could not be rebuilt locally." % property)
		return false
	_apply_property_editor_safe(node, property, resolved, ctx, true)
	return true


## Records a path-backed resource reference whose target file is not on disk yet
## so it can be retried once the file arrives. Returns true when the reference
## was queued; false for inline payloads (which cannot appear later) or when the
## queue is full, so the caller can report an immediate conflict instead.
func _queue_pending_resource(ctx: CollabSceneContext, node_id: int, property: String, kind: String, raw_value: Variant) -> bool:
	if kind != CollabSceneOperations.VALUE_RESOURCE:
		return false
	if node_id == -1 or ctx == null or _pending_resources.size() >= MAX_PENDING_RESOURCES:
		return false
	_drop_pending_resource(ctx.scene_id, node_id, property)
	_pending_resources.append({
		"scene_id": ctx.scene_id,
		"node_id": node_id,
		"property": property,
		"value": raw_value,
		"since_ms": Time.get_ticks_msec(),
	})
	status.emit("Waiting for resource '%s' referenced by '%s' to arrive." % [str(raw_value), property])
	return true


## Retries queued resource references. Entries that now resolve are applied
## without echoing back into the operation stream; entries that stay unresolved
## past the timeout are reported as conflicts and dropped.
func _resolve_pending_resources(now: int) -> void:
	if _pending_resources.is_empty():
		return
	var remaining: Array[Dictionary] = []
	for entry in _pending_resources:
		var ctx: CollabSceneContext = _scenes.get(str(entry.get("scene_id", "")))
		if ctx == null:
			continue
		var node: Node = ctx.node_ids.node_for(int(entry.get("node_id", -1)), false)
		if node == null:
			continue
		var property: String = str(entry.get("property", ""))
		if not CollabSceneOperations.is_property_syncable(node, property):
			continue
		var value: Variant = CollabSceneOperations.decode_value(CollabSceneOperations.VALUE_RESOURCE, entry.get("value"))
		if value != null:
			ctx.diff_watcher.suspend()
			_apply_property_editor_safe(node, property, value, ctx)
			ctx.diff_watcher.resume()
			status.emit("Resolved deferred resource for '%s'." % property)
			continue
		if now - int(entry.get("since_ms", now)) > PENDING_RESOURCE_TIMEOUT_MS:
			conflict.emit("Resource '%s' for '%s' never arrived; reference was not applied." % [str(entry.get("value")), property])
			continue
		remaining.append(entry)
	_pending_resources = remaining


## Drops a queued reference for one (scene, node, property) so a newer value for
## the same target never gets overwritten by a stale deferred one.
func _drop_pending_resource(p_scene_id: String, node_id: int, property: String) -> void:
	if _pending_resources.is_empty():
		return
	var kept: Array[Dictionary] = []
	for entry in _pending_resources:
		if str(entry.get("scene_id", "")) == p_scene_id and int(entry.get("node_id", 0)) == node_id and str(entry.get("property", "")) == property:
			continue
		kept.append(entry)
	_pending_resources = kept


# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

func request_snapshot(p_scene_id: String = "") -> void:
	if not enabled:
		return
	if _coordinator == null or not _coordinator.session_manager.is_active():
		return
	var scene: String = p_scene_id
	if scene.is_empty():
		scene = _primary_scene_id
	if _coordinator.is_host():
		_send_snapshot_to(MultiplayerPeer.TARGET_PEER_BROADCAST, scene)
	else:
		_coordinator.send_scene(CollabProtocol.MessageType.SNAPSHOT_REQUEST, {"scene_id": scene})
		status.emit("Requested scene snapshot from host.")


func apply_pending_snapshot() -> void:
	if _pending_snapshot.is_empty():
		return
	if _apply_snapshot(_pending_snapshot):
		_pending_snapshot = {}


func discard_pending_snapshot() -> void:
	_pending_snapshot.clear()


## Rebinds the local scene's node ids to the host's ids without replacing the
## scene content. Used when auto-apply is disabled so a subsequent local edit
## still targets the correct node instead of a same-numbered local node. Nodes
## that cannot be matched by path keep their provisional ids and their edits are
## safely rejected by the host rather than applied to the wrong node.
func reconcile_ids_from_snapshot(snapshot: Dictionary) -> int:
	var remote_scene: String = str(snapshot.get("scene_id", ""))
	var ctx: CollabSceneContext = _scenes.get(remote_scene)
	if ctx == null or ctx.root == null:
		return 0
	var nodes: Variant = snapshot.get("nodes", [])
	if typeof(nodes) != TYPE_ARRAY or (nodes as Array).is_empty():
		return 0
	var path_for: Dictionary = _snapshot_paths(nodes as Array)
	if path_for.is_empty():
		return 0
	ctx.node_ids.clear()
	_aliases.erase(_alias_key(0, remote_scene))
	_aliases.erase(_alias_key(_coordinator.local_peer_id(), remote_scene))
	var matched: Array[int] = [0]
	_reconcile_walk(ctx.root, "", path_for, ctx, matched)
	ctx.revision = int(snapshot.get("revision", ctx.revision))
	ctx.diff_watcher.refresh_baseline()
	ctx.diff_watcher.base_revision = ctx.revision
	if ctx.scene_id == _primary_scene_id:
		revision = ctx.revision
	if matched[0] > 0:
		status.emit("Reconciled %d node id(s) with the host for %s." % [matched[0], remote_scene])
	return matched[0]


## Builds a "Name/Child/Grandchild" -> node_id map from a snapshot's node list.
func _snapshot_paths(nodes: Array) -> Dictionary:
	var by_id: Dictionary = {}
	for entry in nodes:
		if typeof(entry) == TYPE_DICTIONARY:
			by_id[int((entry as Dictionary).get("node_id", -1))] = entry
	var path_for: Dictionary = {}
	for entry in nodes:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var id: int = int((entry as Dictionary).get("node_id", -1))
		var names: Array[String] = []
		var cur: int = id
		var guard: int = 0
		while by_id.has(cur) and guard < 4096:
			names.push_front(str((by_id[cur] as Dictionary).get("name", "")))
			cur = int((by_id[cur] as Dictionary).get("parent_id", -1))
			guard += 1
			if cur == -1:
				break
		path_for["/".join(names)] = id
	return path_for


func _reconcile_walk(node: Node, parent_path: String, path_for: Dictionary, ctx: CollabSceneContext, matched: Array) -> void:
	if node == null:
		return
	var path: String = node.name if parent_path.is_empty() else parent_path + "/" + node.name
	if path_for.has(path):
		ctx.node_ids.register(node, int(path_for[path]))
		matched[0] += 1
	for child in node.get_children():
		_reconcile_walk(child, path, path_for, ctx, matched)


func _send_reply_snapshot(peer_id: int, payload: Dictionary) -> void:
	var scene: String = str(payload.get("scene_id", ""))
	if scene.is_empty():
		scene = _peer_scene_id(peer_id)
	if scene.is_empty():
		scene = _primary_scene_id
	_send_snapshot_to(peer_id, scene)


func _send_snapshot_to(peer_id: int, p_scene_id: String) -> void:
	var ctx: CollabSceneContext = _scenes.get(p_scene_id)
	if ctx == null and _coordinator.is_host():
		ctx = _ensure_host_context(p_scene_id)
	if ctx == null:
		error_raised.emit("No scene '%s' available to snapshot." % p_scene_id)
		return
	var snapshot := _serialize_scene(ctx)
	if peer_id == MultiplayerPeer.TARGET_PEER_BROADCAST:
		_coordinator.send_scene(CollabProtocol.MessageType.SNAPSHOT_RESPONSE, snapshot)
	else:
		_coordinator.send_scene_to(peer_id, CollabProtocol.MessageType.SNAPSHOT_RESPONSE, snapshot)
	status.emit("Sent snapshot of %s (%d nodes, revision %d)." % [p_scene_id, (snapshot["nodes"] as Array).size(), ctx.revision])


func _serialize_scene(ctx: CollabSceneContext) -> Dictionary:
	var nodes: Array = []
	_serialize_node(ctx, ctx.root, -1, nodes, true)
	return {"scene_id": ctx.scene_id, "revision": ctx.revision, "nodes": nodes}


func _serialize_node(ctx: CollabSceneContext, node: Node, parent_id: int, out: Array, is_root: bool) -> void:
	var node_id: int = _id_for(ctx, node)
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
		_serialize_node(ctx, child, node_id, out, false)


## Returns the stable session id for [param node], allocating one when needed.
func _id_for(ctx: CollabSceneContext, node: Node) -> int:
	var existing: int = ctx.node_ids.id_for(node)
	if existing >= 0:
		return existing
	var allocated: int = ctx.node_ids.allocate_id()
	ctx.node_ids.register(node, allocated)
	return allocated


func _apply_snapshot(snapshot: Dictionary) -> bool:
	var remote_scene: String = str(snapshot.get("scene_id", ""))
	var ctx: CollabSceneContext = _scenes.get(remote_scene)
	if ctx == null:
		error_raised.emit("No open scene matches snapshot scene '%s'. Open it first (or create it)." % remote_scene)
		return false
	if ctx.root == null:
		error_raised.emit("No edited scene to apply the snapshot to.")
		return false
	var nodes: Array = snapshot.get("nodes", [])
	if nodes.is_empty():
		return false
	_applying = true
	ctx.diff_watcher.suspend()
	ctx.node_ids.clear()
	_aliases.erase(_alias_key(0, remote_scene))
	_aliases.erase(_alias_key(_coordinator.local_peer_id(), remote_scene))
	var root_entry: Dictionary = nodes[0]
	var root_snapshot_id: int = int(root_entry.get("node_id", -1))
	# Destructive by design: the host scene replaces local content.
	for child in ctx.root.get_children():
		ctx.root.remove_child(child)
		child.queue_free()
	ctx.node_ids.register(ctx.root, root_snapshot_id)
	for i in range(1, nodes.size()):
		if typeof(nodes[i]) == TYPE_DICTIONARY:
			_apply_snapshot_node(ctx, nodes[i])
	_apply_snapshot_props(ctx, root_entry, ctx.root)
	ctx.revision = int(snapshot.get("revision", ctx.revision))
	ctx.diff_watcher.resume()
	ctx.diff_watcher.base_revision = ctx.revision
	if ctx.scene_id == _primary_scene_id:
		revision = ctx.revision
	_applying = false
	_mark_unsaved(ctx)
	snapshot_applied.emit()
	status.emit("Applied snapshot of %s (%d nodes, revision %d)." % [remote_scene, nodes.size(), ctx.revision])
	return true


func _apply_snapshot_node(ctx: CollabSceneContext, entry: Dictionary) -> void:
	var node_id: int = int(entry.get("node_id", -1))
	if ctx.node_ids.node_for(node_id, false) != null:
		return
	var node: Node = _instantiate_class(str(entry.get("class", "")))
	if node == null:
		return
	node.name = _safe_name(str(entry.get("name", node.get_class())))
	_apply_script(node, entry)
	var parent: Node = ctx.node_ids.node_for(int(entry.get("parent_id", -1)), false)
	if parent == null:
		parent = ctx.root
	if parent == null:
		node.free()
		return
	parent.add_child(node)
	_own_recursive(node, ctx.root)
	if node is Node3D:
		var t := Transform3D.IDENTITY
		t.origin = entry.get("position", Vector3.ZERO)
		t.basis = Basis.from_euler(entry.get("rotation", Vector3.ZERO)).scaled(entry.get("scale", Vector3.ONE))
		(node as Node3D).transform = t
	ctx.node_ids.register(node, node_id)
	_apply_snapshot_props(ctx, entry, node)


func _apply_snapshot_props(ctx: CollabSceneContext, entry: Dictionary, node: Node) -> void:
	var props: Dictionary = entry.get("props", {})
	for prop in props.keys():
		if not CollabSceneOperations.is_property_syncable(node, prop):
			continue
		var encoded: Dictionary = props[prop]
		var kind: String = str(encoded.get("kind", ""))
		if kind == CollabSceneOperations.VALUE_RESOURCE_CONTENT:
			_apply_resource_content(node, prop, encoded.get("value"), ctx)
			continue
		var value: Variant = CollabSceneOperations.decode_value(kind, encoded.get("value", null))
		if CollabSceneOperations.is_resource_kind(kind) and value == null:
			_queue_pending_resource(ctx, ctx.node_ids.id_for(node), prop, kind, encoded.get("value"))
			continue
		_apply_property_editor_safe(node, prop, value, ctx)


# ---------------------------------------------------------------------------
# Host-side detached contexts
# ---------------------------------------------------------------------------

## Resolves a scene context for inbound client work. Uses a live open root when
## available; otherwise, on the host, loads a detached model from disk so the
## edit can still be applied and persisted.
func _ensure_host_context(p_scene_id: String) -> CollabSceneContext:
	if p_scene_id.is_empty():
		return null
	var ctx: CollabSceneContext = _scenes.get(p_scene_id)
	if ctx != null:
		return ctx
	if not _coordinator.is_host():
		return null
	if not ResourceLoader.exists(p_scene_id):
		return null
	var packed: PackedScene = load(p_scene_id) as PackedScene
	if packed == null:
		error_raised.emit("Could not load scene '%s' to apply remote edits." % p_scene_id)
		return null
	var instance: Node = packed.instantiate()
	if instance == null:
		return null
	ctx = CollabSceneContext.new(p_scene_id, instance)
	ctx.detached = true
	_scenes[p_scene_id] = ctx
	ctx.diff_watcher.set_root(instance)
	_configure(ctx)
	ctx.diff_watcher.refresh_baseline()
	status.emit("Loaded detached copy of %s to apply remote edits." % p_scene_id)
	return ctx


func _save_context(ctx: CollabSceneContext) -> void:
	if not ctx.detached or ctx.root == null:
		return
	_persist_context(ctx)


## Host only: writes every context holding unpersisted remote edits to disk.
## Used by the explicit "Save shared scene" action. Returns the number saved.
func persist_host_scenes() -> int:
	if _coordinator == null or not _coordinator.is_host():
		return 0
	var count: int = 0
	for ctx in _scenes.values():
		if ctx.dirty and ctx.root != null:
			_persist_context(ctx)
			count += 1
	return count


## Packs a context's root and writes it back to its scene path. Works for both
## detached models and live editor roots.
func _persist_context(ctx: CollabSceneContext) -> void:
	if ctx.root == null:
		return
	var packed := PackedScene.new()
	var err: Error = packed.pack(ctx.root)
	if err != OK:
		error_raised.emit("Failed to pack scene '%s': %s" % [ctx.scene_id, error_string(err)])
		return
	err = ResourceSaver.save(packed, ctx.scene_id)
	if err != OK:
		error_raised.emit("Failed to save scene '%s': %s" % [ctx.scene_id, error_string(err)])
		return
	ctx.dirty = false
	# Deliberately do not call EditorFileSystem.update_file here: the scene may
	# be open in a background tab, and refreshing an existing scene file is not
	# required. New files created through the workspace service refresh the
	# filesystem themselves.
	status.emit("Saved remote edits to %s." % ctx.scene_id)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _payload_scene_id(payload: Dictionary, ops: Array) -> String:
	var scene: String = str(payload.get("scene_id", ""))
	if not scene.is_empty():
		return scene
	if not ops.is_empty() and typeof(ops[0]) == TYPE_DICTIONARY:
		return str((ops[0] as Dictionary).get("scene_id", ""))
	return _primary_scene_id


func _peer_scene_id(peer_id: int) -> String:
	if _coordinator == null:
		return ""
	var participant: CollabParticipant = _coordinator.registry.get_participant(peer_id)
	if participant == null:
		return ""
	return participant.scene_id


func _alias_key(peer_id: int, p_scene_id: String) -> String:
	return "%d:%s" % [peer_id, p_scene_id]


func _serialize_props(node: Node) -> Dictionary:
	return CollabSceneOperations.collect_syncable_props(node)


func _resolve_aliases(ctx: CollabSceneContext, source_peer: int, op: Dictionary) -> Dictionary:
	var key: String = _alias_key(source_peer, ctx.scene_id)
	if not _aliases.has(key):
		return op
	var aliases: Dictionary = _aliases[key]
	var out: Dictionary = op.duplicate(true)
	for field in ["node_id", "parent_id"]:
		if out.has(field):
			var raw: int = int(out[field])
			if aliases.has(raw):
				out[field] = aliases[raw]
	return out


## Resolver passed to [method CollabSceneOperations.validate_op]. The context is
## bound to the callable, so it arrives after the arguments the validator
## supplies (node_id, existing_only).
func _resolve_node(node_id: int, existing_only: bool, ctx: CollabSceneContext) -> Node:
	return ctx.node_ids.node_for(node_id, existing_only)


func _find_parent(ctx: CollabSceneContext, parent_id: int) -> Node:
	if parent_id == -1:
		return ctx.root
	return ctx.node_ids.node_for(parent_id, true)


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


func _own_recursive(node: Node, root: Node) -> void:
	if root == null or node == root:
		return
	node.owner = root
	for child in node.get_children():
		_own_recursive(child, root)


func _safe_name(requested: String) -> String:
	var name: String = requested.strip_edges()
	if name.is_empty():
		return "Node"
	if name.length() > 128:
		name = name.substr(0, 128)
	return name


func _apply_property_editor_safe(node: Node, property: String, value: Variant, ctx: CollabSceneContext, force: bool = false) -> void:
	if not force and node.get(property) == value:
		return
	node.set(property, value)
	if _is_active_root(ctx):
		if _editor.has("refresh_inspector") and _editor["refresh_inspector"].is_valid():
			_editor["refresh_inspector"].call(node)
		_mark_unsaved(ctx)


func _is_active_root(ctx: CollabSceneContext) -> bool:
	return ctx != null and not ctx.detached and ctx.root == _edited_root()


func _edited_root() -> Node:
	if _editor.has("get_edited_root") and _editor["get_edited_root"].is_valid():
		return _editor["get_edited_root"].call()
	return null


func _mark_unsaved(ctx: CollabSceneContext) -> void:
	if not _is_active_root(ctx):
		return
	if _editor.has("mark_unsaved") and _editor["mark_unsaved"].is_valid():
		_editor["mark_unsaved"].call()


func _on_peer_ready(peer_id: int) -> void:
	if _coordinator == null or not _coordinator.is_host():
		return
	var peer_scene: String = _peer_scene_id(peer_id)
	if peer_scene.is_empty():
		peer_scene = _primary_scene_id
	if peer_scene.is_empty():
		return
	# _send_snapshot_to falls back to a detached load when the host does not have
	# the peer's scene open, so a client that opened a different scene still gets
	# the correct snapshot.
	_send_snapshot_to(peer_id, peer_scene)


func _on_session_stopped(_reason: String) -> void:
	detach_scene()
