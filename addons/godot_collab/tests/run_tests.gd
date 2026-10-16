@tool
## Headless smoke tests for the Godot Collab add-on.
##
## Run with:
##   ~/.apps/Godot/Godot_v4.7.2/bin/godot --headless \
##     --script res://addons/godot_collab/tests/run_tests.gd
##
## These cover the pure/data layers (protocol framing, invitation codes, path
## validation, rate limiting) and a real ENet loopback handshake between a host
## and client coordinator. GUI-only behaviour (3D overlay drawing) still needs
## the manual procedure documented in docs/TESTING.md.
extends SceneTree

var _checks: int = 0
var _failures: Array[String] = []


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(label)
		print("  FAIL: ", label)


func _count_prefixed(root: Node, prefix: String) -> int:
	var count: int = 0
	for child in root.get_children():
		if str(child.name).begins_with(prefix):
			count += 1
	return count


func _test_node_id_map() -> void:
	print("[node id map]")
	var map := CollabNodeIdMap.new()
	var a := Node.new()
	var first: int = map.allocate_id()
	_check(first > 0, "authoritative ids are positive")
	var temp: int = map.allocate_temp_id()
	_check(temp != -1, "temporary ids never use the -1 'no id' sentinel")
	map.register(a, first)
	# clear() must not hand out ids that live nodes still hold, otherwise a node
	# created right after a snapshot overwrites the reverse mapping.
	map.clear()
	var after: int = map.allocate_id()
	_check(after > first, "authoritative ids never repeat after clear()")
	var temp2: int = map.allocate_temp_id()
	_check(temp2 != temp, "temporary ids never repeat after clear()")
	a.free()


func _test_property_values() -> void:
	print("[property values]")
	# Round-trip every newly supported value shape.
	var cases: Array = [
		["vector2i", Vector2i(3, 4)],
		["vector3i", Vector3i(1, 2, 3)],
		["rect2", Rect2(1, 2, 3, 4)],
		["transform3d", Transform3D(Basis.from_euler(Vector3(1, 2, 3)), Vector3(4, 5, 6))],
		["aabb", AABB(Vector3.ONE, Vector3(2, 2, 2))],
		["packed_string", PackedStringArray(["a", "b", "c"])],
		["array", [1, "two", Vector3.ONE]],
		["dictionary", {"k": 1, "v": Vector2(0.5, 0.5)}],
		["string_name", "a_name"],
	]
	for case in cases:
		var encoded: Dictionary = CollabSceneOperations.encode_value(case[1])
		_check(encoded["kind"] != CollabSceneOperations.VALUE_UNSUPPORTED, "encode %s supported" % case[0])
		var decoded: Variant = CollabSceneOperations.decode_value(encoded["kind"], encoded["value"])
		_check(typeof(decoded) == typeof(case[1]), "decode %s preserves type" % case[0])
		_check(decoded == case[1], "decode %s preserves value" % case[0])

	# Containers holding live objects must be refused rather than silently lossy.
	var with_node: Array = [Node.new()]
	_check(CollabSceneOperations.encode_value(with_node)["kind"] == CollabSceneOperations.VALUE_UNSUPPORTED, "array containing an Object is refused")
	(with_node[0] as Node).free()

	var node := Node.new()
	_check(CollabSceneOperations.is_property_syncable(node, "process_priority"), "process_priority is syncable")
	_check(CollabSceneOperations.is_property_syncable(node, "editor_description"), "editor_description is syncable")
	_check(not CollabSceneOperations.is_property_syncable(node, "name"), "name is reserved")
	_check(not CollabSceneOperations.is_property_syncable(node, "script"), "script is reserved")
	var props: Dictionary = CollabSceneOperations.collect_syncable_props(node)
	_check(props.has("process_priority") and props.has("process_mode"), "collect includes general Node properties")
	node.free()

	var n3d := Node3D.new()
	_check(not CollabSceneOperations.is_property_syncable(n3d, "position"), "Node3D position handled by transform op")
	_check(not CollabSceneOperations.is_property_syncable(n3d, "transform"), "Node3D transform is reserved")
	var n3d_props: Dictionary = CollabSceneOperations.collect_syncable_props(n3d)
	_check(n3d_props.has("visible") and n3d_props.has("process_priority"), "collect includes Node3D editor properties")
	_check(not n3d_props.has("transform") and not n3d_props.has("position"), "collect excludes handled transform properties")
	n3d.free()

	# Sub-properties (material overrides, theme overrides) use '/' and are ordinary
	# storable properties, so they must be syncable; identity/behaviour names must not.
	_check(CollabSceneOperations.is_syncable_property_name("surface_material_override/0"), "material override sub-property is syncable")
	_check(CollabSceneOperations.is_syncable_property_name("theme_override_colors/font_color"), "theme override sub-property is syncable")
	_check(not CollabSceneOperations.is_syncable_property_name("_editor_only"), "underscore-prefixed property rejected")
	_check(not CollabSceneOperations.is_syncable_property_name("metadata/custom"), "metadata property rejected")
	_check(not CollabSceneOperations.is_syncable_property_name(""), "empty property name rejected")

	# Embedded (path-less) resources are serialized inline and must survive a
	# round-trip; the cheap signature only needs to notice they changed.
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.2, 0.4, 0.9)
	material.roughness = 0.25
	var encoded_res: Dictionary = CollabSceneOperations.encode_value(material)
	_check(encoded_res["kind"] == CollabSceneOperations.VALUE_RESOURCE_INLINE, "path-less resource encoded inline")
	var encoded_text: Variant = encoded_res["value"]
	_check(typeof(encoded_text) == TYPE_STRING and not (encoded_text as String).is_empty(), "inline payload is non-empty text")
	var decoded_res: Variant = CollabSceneOperations.decode_value(encoded_res["kind"], encoded_text)
	_check(decoded_res is StandardMaterial3D, "inline resource decodes back to a resource")
	if decoded_res is StandardMaterial3D:
		var restored: StandardMaterial3D = decoded_res
		_check(restored.albedo_color.is_equal_approx(Color(0.2, 0.4, 0.9)), "inline resource preserves colour")
		_check(is_equal_approx(restored.roughness, 0.25), "inline resource preserves roughness")
	# A cleared object property reports TYPE_OBJECT with a null value; it must
	# encode as null (not unsupported) so a later null -> resource change is
	# detected by the diff watcher instead of being silently ignored.
	var empty_mesh := MeshInstance3D.new()
	var cleared: Variant = empty_mesh.get("material_override")
	_check(typeof(cleared) == TYPE_OBJECT, "cleared object property is typed as Object")
	var cleared_encoded: Dictionary = CollabSceneOperations.encode_value(cleared)
	_check(cleared_encoded["kind"] == CollabSceneOperations.VALUE_NULL, "cleared object property encodes as null")
	_check(CollabSceneOperations.signature_value(cleared)["kind"] == CollabSceneOperations.VALUE_NULL, "cleared object property signature is null")
	_check(CollabSceneOperations.collect_syncable_props(empty_mesh).has("material_override"), "collection keeps a null object property")
	empty_mesh.free()

	_check(CollabSceneOperations.is_resource_kind(CollabSceneOperations.VALUE_RESOURCE_INLINE), "inline kind is a resource kind")
	_check(CollabSceneOperations.is_resource_kind(CollabSceneOperations.VALUE_RESOURCE), "path resource kind is a resource kind")
	_check(not CollabSceneOperations.is_resource_kind(CollabSceneOperations.VALUE_VECTOR3), "plain value kind is not a resource kind")
	var sig: Dictionary = CollabSceneOperations.signature_value(material)
	_check(sig["kind"] == CollabSceneOperations.VALUE_RESOURCE_INLINE, "signature of embedded resource is inline kind")
	_check(typeof(sig["value"]) == TYPE_INT, "signature of embedded resource carries its instance id, not serialized text")
	material = null


func _test_filesync_paths() -> void:
	print("[file sync paths]")
	_check(CollabWorkspaceService.is_source_file("scripts/player.gd"), "gd source file watched")
	_check(CollabWorkspaceService.is_source_file("materials/sky.tres"), "tres resource watched")
	_check(CollabWorkspaceService.is_source_file("project.godot"), "project.godot watched")
	_check(CollabWorkspaceService.is_source_file("shaders/thing.gdshader"), "shader watched")
	# The add-on's own files are never relayed: live-editing an active add-on can
	# crash a client and corrupt its project copy.
	_check(not CollabWorkspaceService.is_source_file("addons/godot_collab/plugin.gd"), "addon files excluded from sync")
	_check(not CollabWorkspaceService.is_source_file(".godot/imported/x.gd"), "generated cache excluded")
	_check(not CollabWorkspaceService.is_source_file(".git/hooks/x.gd"), "git metadata excluded")
	# Dropped binary assets are relayed so a client can add art/models/audio.
	_check(CollabWorkspaceService.is_source_file("art/hero.png"), "png asset watched")
	_check(CollabWorkspaceService.is_source_file("models/rock.glb"), "glb model watched")
	_check(CollabWorkspaceService.is_source_file("audio/hit.wav"), "wav audio watched")
	# A dropped scene travels as a file unless it is open (protected separately).
	_check(CollabWorkspaceService.is_source_file("scenes/main.tscn"), "tscn tracked for drop-sync")
	_check(not CollabWorkspaceService.is_source_file("../escape.gd"), "traversal excluded")

	# A real scan must pick up watched files and skip addons/ + caches.
	var ws_root: String = "/tmp/opencode/filesync_ws"
	DirAccess.make_dir_recursive_absolute(ws_root.path_join("scripts"))
	DirAccess.make_dir_recursive_absolute(ws_root.path_join("addons/godot_collab"))
	DirAccess.make_dir_recursive_absolute(ws_root.path_join(".godot"))
	_write_text(ws_root.path_join("project.godot"), "config_version=5\n")
	_write_text(ws_root.path_join("scripts/player.gd"), "extends Node\n")
	_write_text(ws_root.path_join("addons/godot_collab/plugin.gd"), "extends Object\n")
	_write_text(ws_root.path_join(".godot/cache.gd"), "cached\n")

	var logs := CollabLog.new()
	var manager := CollabSessionManager.new(logs)
	var coordinator := CollabSessionCoordinator.new()
	coordinator.setup(manager, logs)
	var workspace := CollabWorkspaceService.new()
	workspace.setup(coordinator, CollabSettings.new(), logs, func() -> String: return ws_root, {})
	workspace.prime_file_baseline()
	var watched: Array = workspace.watched_paths()
	_check(watched.has("project.godot"), "baseline tracks project.godot")
	_check(watched.has("scripts/player.gd"), "baseline tracks a project script")
	_check(not watched.has("addons/godot_collab/plugin.gd"), "baseline never tracks addon files")
	_check(not watched.has(".godot/cache.gd"), "baseline never tracks generated caches")

	# A scene open in the editor is driven by the operation stream, so its file
	# must not also be relayed/written over the raw file path.
	workspace.open_scene_paths = func() -> Array: return ["res://scenes/main.tscn"]
	_check(workspace._is_protected_scene("scenes/main.tscn"), "open scene is protected from raw file sync")
	_check(not workspace._is_protected_scene("scenes/other.tscn"), "closed scene is not protected")
	_check(not workspace._is_protected_scene("scripts/player.gd"), "non-scene files are never protected")

	workspace.free()
	coordinator.free()
	manager.free()


func _write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()


func _test_id_reconciliation() -> void:
	print("[id reconciliation]")
	var logs := CollabLog.new()
	var manager := CollabSessionManager.new(logs)
	var coordinator := CollabSessionCoordinator.new()
	coordinator.setup(manager, logs)
	coordinator.get_project_id = func() -> String: return "proj"
	coordinator.get_scene_id = func() -> String: return "res://r.tscn"
	coordinator.get_username = func() -> String: return "peer"

	var sync := CollabSceneSyncService.new()
	sync.setup(coordinator, logs, {"get_edited_root": func() -> Node: return null, "mark_unsaved": func() -> void: pass})
	sync.auto_apply_snapshot = false

	var root := Node3D.new()
	root.name = "Root"
	var box := Node3D.new()
	box.name = "Box"
	root.add_child(box)
	var decoy := Node3D.new()
	decoy.name = "Decoy"
	root.add_child(decoy)

	sync.bind_scene(root, "res://r.tscn", true)
	# A non-host must never allocate the authoritative positive id space, so a
	# local node can never collide with a same-numbered host node.
	_check(sync.node_id_for_scene("res://r.tscn", box) < 0, "pre-session client ids are non-authoritative (negative)")
	_check(sync.node_id_for_scene("res://r.tscn", decoy) < 0, "every pre-session client id is non-authoritative")

	var snapshot: Dictionary = {
		"scene_id": "res://r.tscn",
		"revision": 5,
		"nodes": [
			{"node_id": 10, "parent_id": -1, "class": "Node3D", "name": "Root", "props": {}},
			{"node_id": 20, "parent_id": 10, "class": "Node3D", "name": "Box", "props": {}},
		],
	}
	var matched: int = sync.reconcile_ids_from_snapshot(snapshot)
	_check(matched == 2, "reconcile matches root and box by path (got %d)" % matched)
	_check(sync.node_id_for_scene("res://r.tscn", box) == 20, "box adopts the host's authoritative id")
	_check(sync.node_id_for_scene("res://r.tscn", decoy) != 20, "unmatched local node never adopts the host's id for a different node")

	sync.detach_scene()
	root.free()
	sync.free()
	coordinator.free()
	manager.free()


func _init() -> void:
	print("== Godot Collab headless tests ==")
	_test_protocol()
	_test_invite_codes()
	_test_path_guard()
	_test_rate_limiter()
	_test_node_id_map()
	_test_property_values()
	_test_inline_resource_safety()
	_test_pending_resource_resolution()
	_test_settings_defaults()
	_test_filesync_paths()
	_test_id_reconciliation()
	_test_loopback_session()
	_test_scene_sync_loopback()
	_test_general_property_sync()
	_test_workspace_rename_delete_loopback()
	_test_rejoin_desync()
	_test_multi_scene_isolation()
	_test_marker_manager()
	# The marker test needs a live frame so the node's ready/deferred calls run.
	_run_marker_test_then_finish()


func _run_marker_test_then_finish() -> void:
	await process_frame
	_test_marker_visuals()
	_finish()


func _finish() -> void:
	print("")
	print("%d checks, %d failures" % [_checks, _failures.size()])
	if _failures.is_empty():
		print("RESULT: PASS")
		quit(0)
	else:
		for failure in _failures:
			print("  - ", failure)
		print("RESULT: FAIL")
		quit(1)


func _test_inline_resource_safety() -> void:
	print("[inline resource safety]")
	# Inline payloads must never rebuild executable content, whatever a peer
	# sends, and oversized or empty payloads must be refused rather than loaded.
	var kind: String = CollabSceneOperations.VALUE_RESOURCE_INLINE
	_check(CollabSceneOperations.decode_value(kind, "[gd_resource type=\"GDScript\" format=3]") == null, "inline GDScript is refused")
	_check(CollabSceneOperations.decode_value(kind, "[gd_resource type=\"PackedScene\" format=3]") == null, "inline PackedScene is refused")
	_check(CollabSceneOperations.decode_value(kind, "[ext_resource type=\"Script\" path=\"res://x.gd\" id=\"1\"]\nscript = ExtResource(\"1\")") == null, "inline payload referencing an ext script is refused")
	_check(CollabSceneOperations.decode_value(kind, "") == null, "empty inline payload is refused")
	var oversized: String = "x".repeat(CollabSceneOperations.MAX_INLINE_RESOURCE_TEXT + 1)
	_check(CollabSceneOperations.decode_value(kind, oversized) == null, "oversized inline payload is refused")


## A path-backed resource reference that arrives before its file (the classic
## rename ordering) must be queued and applied once the file exists, not dropped.
func _test_pending_resource_resolution() -> void:
	print("[pending resource resolution]")
	var logs := CollabLog.new()
	var manager := CollabSessionManager.new(logs)
	var coordinator := CollabSessionCoordinator.new()
	coordinator.setup(manager, logs)
	var noop := func() -> void: pass
	var sync := CollabSceneSyncService.new()
	var conflicts: Dictionary = {"count": 0}
	sync.conflict.connect(func(_text: String) -> void: conflicts["count"] += 1)
	sync.setup(coordinator, logs, {"get_edited_root": func() -> Node: return null, "mark_unsaved": noop})

	var root := Node3D.new()
	root.name = "Root"
	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	root.add_child(mesh)
	sync.attach_scene(root, "res://pending.tscn")
	var ctx: Variant = sync._scenes.get("res://pending.tscn")
	_check(ctx != null, "pending test scene context exists")
	if ctx == null:
		sync.free()
		coordinator.free()
		manager.free()
		root.free()
		return
	var node_id: int = sync.node_id_for_scene("res://pending.tscn", mesh)
	_check(node_id != -1, "pending test node has an id")

	var missing_path: String = "user://collab_pending_%d.tres" % Time.get_ticks_usec()
	var queued: bool = sync._queue_pending_resource(ctx, node_id, "material_override", CollabSceneOperations.VALUE_RESOURCE, missing_path)
	_check(queued, "unresolved path resource is queued")
	_check(sync._pending_resources.size() == 1, "one pending reference held")

	# Retrying before the file exists keeps it queued and emits no conflict yet.
	sync._resolve_pending_resources(Time.get_ticks_msec())
	_check(sync._pending_resources.size() == 1, "pending reference survives while unresolved")
	_check(int(conflicts["count"]) == 0, "no conflict emitted before the timeout")

	# Once the file exists the reference resolves and is applied.
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.1, 0.8, 0.4)
	ResourceSaver.save(material, missing_path)
	sync._resolve_pending_resources(Time.get_ticks_msec())
	_check(sync._pending_resources.is_empty(), "pending reference clears once the file arrives")
	var applied := mesh.material_override as StandardMaterial3D
	_check(applied != null and applied.albedo_color.is_equal_approx(Color(0.1, 0.8, 0.4)), "deferred resource was applied to the node")

	# A reference that never arrives is reported and dropped after the timeout.
	_check(sync._queue_pending_resource(ctx, node_id, "material_override", CollabSceneOperations.VALUE_RESOURCE, "user://never_arrives_%d.tres" % Time.get_ticks_usec()), "second unresolved resource is queued")
	for entry in sync._pending_resources:
		entry["since_ms"] = Time.get_ticks_msec() - CollabSceneSyncService.PENDING_RESOURCE_TIMEOUT_MS - 1
	sync._resolve_pending_resources(Time.get_ticks_msec())
	_check(sync._pending_resources.is_empty(), "timed-out reference is dropped")
	_check(int(conflicts["count"]) >= 1, "timed-out reference is reported as a conflict")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(missing_path))
	sync.detach_scene()
	root.free()
	sync.free()
	coordinator.free()
	manager.free()


func _test_settings_defaults() -> void:
	print("[settings defaults]")
	# A fresh install must be usable on a LAN without any service or approval
	# step; both are opt-in.
	_check(CollabConstants.DEFAULT_RENDEZVOUS_URL.is_empty(), "rendezvous defaults to empty (LAN/direct connect)")
	_check(not CollabSettings.new().get_bool(CollabSettings.KEY_APPROVE_JOINS, false), "host approval defaults to off")
	# A single dropped file is delivered in one workspace packet, so the per-file
	# cap must not exceed the packet cap.
	_check(CollabConstants.MAX_WORKSPACE_FILE_BYTES <= CollabConstants.MAX_PACKET_PAYLOAD, "per-file cap fits within one packet")


func _test_protocol() -> void:
	print("[protocol]")
	var payload: Dictionary = {"time_ms": 123, "label": "hello"}
	var bytes: PackedByteArray = CollabProtocol.encode(CollabProtocol.MessageType.PING, payload)
	_check(bytes.size() > CollabConstants.HEADER_SIZE, "encoded packet has header + body")
	var decoded: Dictionary = CollabProtocol.decode(bytes)
	_check(bool(decoded.get("ok", false)), "packet decodes")
	_check(int(decoded.get("type", -1)) == CollabProtocol.MessageType.PING, "type preserved")
	_check(int((decoded.get("payload", {}) as Dictionary).get("time_ms", 0)) == 123, "payload preserved")

	var corrupted: PackedByteArray = bytes.duplicate()
	corrupted[0] = 0x00
	_check(not bool(CollabProtocol.decode(corrupted).get("ok", true)), "bad magic rejected")

	var truncated: PackedByteArray = bytes.slice(0, CollabConstants.HEADER_SIZE - 2)
	_check(not bool(CollabProtocol.decode(truncated).get("ok", true)), "truncated packet rejected")

	# CURSOR_UPDATE requires transform fields.
	var bad_cursor: PackedByteArray = CollabProtocol.encode(CollabProtocol.MessageType.CURSOR_UPDATE, {"time_ms": 1})
	var bad_decoded: Dictionary = CollabProtocol.decode(bad_cursor)
	_check(not bool(bad_decoded.get("ok", true)), "cursor payload validated")

	# Workspace authoring messages are accepted with a valid shape...
	var workspace: PackedByteArray = CollabProtocol.encode(CollabProtocol.MessageType.WORKSPACE_REQUEST, {
		"request_id": 3,
		"kind": CollabConstants.WorkspaceOp.ADD_FILE,
		"path": "scripts/thing.gd",
		"text": "extends Node\n",
	})
	var workspace_decoded: Dictionary = CollabProtocol.decode(workspace)
	_check(bool(workspace_decoded.get("ok", false)), "workspace request validated")
	_check(int(workspace_decoded.get("type", -1)) == CollabProtocol.MessageType.WORKSPACE_REQUEST, "workspace request type preserved")
	# ...and rejected when the text payload is not a string.
	var bad_workspace: PackedByteArray = CollabProtocol.encode(CollabProtocol.MessageType.WORKSPACE_REQUEST, {
		"request_id": 3,
		"kind": CollabConstants.WorkspaceOp.ADD_FILE,
		"path": "scripts/thing.gd",
		"text": 42,
	})
	_check(not bool(CollabProtocol.decode(bad_workspace).get("ok", true)), "workspace request rejects non-string text")
	# A dropped binary file travels as raw bytes alongside (or instead of) text.
	var workspace_bytes: PackedByteArray = CollabProtocol.encode(CollabProtocol.MessageType.WORKSPACE_REQUEST, {
		"request_id": 4,
		"kind": CollabConstants.WorkspaceOp.ADD_FILE,
		"path": "art/hero.png",
		"data": PackedByteArray([0x89, 0x50, 0x4e, 0x47]),
	})
	_check(bool(CollabProtocol.decode(workspace_bytes).get("ok", false)), "workspace request accepts byte payload")
	var bad_workspace_bytes: PackedByteArray = CollabProtocol.encode(CollabProtocol.MessageType.WORKSPACE_REQUEST, {
		"request_id": 5,
		"kind": CollabConstants.WorkspaceOp.ADD_FILE,
		"path": "art/hero.png",
		"data": "not bytes",
	})
	_check(not bool(CollabProtocol.decode(bad_workspace_bytes).get("ok", true)), "workspace request rejects non-byte data")

	# New message types must be inside the valid type range.
	var scene_list: PackedByteArray = CollabProtocol.encode(CollabProtocol.MessageType.SCENE_LIST, {"scenes": ["res://a.tscn"], "revision": 4})
	_check(bool(CollabProtocol.decode(scene_list).get("ok", false)), "scene list validated")
	var file_apply: PackedByteArray = CollabProtocol.encode(CollabProtocol.MessageType.FILE_APPLY, {
		"path": "a.tscn", "data": PackedByteArray([1, 2, 3]), "scene": true,
	})
	_check(bool(CollabProtocol.decode(file_apply).get("ok", false)), "file apply validated")
	var bad_file_apply: PackedByteArray = CollabProtocol.encode(CollabProtocol.MessageType.FILE_APPLY, {
		"path": "a.tscn", "data": "not bytes", "scene": true,
	})
	_check(not bool(CollabProtocol.decode(bad_file_apply).get("ok", true)), "file apply rejects non-byte data")
	var file_remove: PackedByteArray = CollabProtocol.encode(CollabProtocol.MessageType.FILE_REMOVE, {"path": "old.tres"})
	var remove_decoded: Dictionary = CollabProtocol.decode(file_remove)
	_check(bool(remove_decoded.get("ok", false)), "file remove validated")
	_check(int(remove_decoded.get("type", -1)) == CollabProtocol.MessageType.FILE_REMOVE, "file remove type preserved")
	var bad_file_remove: PackedByteArray = CollabProtocol.encode(CollabProtocol.MessageType.FILE_REMOVE, {"path": 12})
	_check(not bool(CollabProtocol.decode(bad_file_remove).get("ok", true)), "file remove rejects non-string path")


func _test_invite_codes() -> void:
	print("[invite codes]")
	var invite: String = CollabInviteCode.encode_direct("192.168.1.5", 45899, "tok123", "proj-1", CollabConstants.WorkspaceMode.GIT_PRESENCE)
	_check(invite.begins_with("gc1."), "direct invite prefixed")
	var parsed: Dictionary = CollabInviteCode.decode(invite)
	_check(str(parsed.get("kind", "")) == "direct", "direct kind")
	_check(str(parsed.get("host", "")) == "192.168.1.5", "host round-trips")
	_check(int(parsed.get("port", 0)) == 45899, "port round-trips")
	_check(str(parsed.get("token", "")) == "tok123", "token round-trips")
	_check(int(parsed.get("mode", -1)) == CollabConstants.WorkspaceMode.GIT_PRESENCE, "mode round-trips")

	var short: Dictionary = CollabInviteCode.decode("K7P2QX")
	_check(str(short.get("kind", "")) == "short" and str(short.get("code", "")) == "K7P2QX", "short code parsed")

	var address: Dictionary = CollabInviteCode.decode("10.0.0.2:45899")
	_check(str(address.get("kind", "")) == "address", "address kind")
	_check(str(address.get("host", "")) == "10.0.0.2" and int(address.get("port", 0)) == 45899, "address parsed")

	_check(str(CollabInviteCode.decode("!!!nonsense!!!").get("kind", "")) == "invalid", "garbage rejected")

	var generated: String = CollabInviteCode.generate_short_code()
	_check(generated.length() == 6, "generated short code has length 6")
	_check(str(CollabInviteCode.decode(generated).get("kind", "")) == "short", "generated code parses as short")

	var info: Dictionary = CollabConnectivity.evaluate("", "", false)
	_check(info.has("state") and info.has("detail"), "connectivity evaluate returns state + detail")


func _test_path_guard() -> void:
	print("[path guard]")
	_check(CollabPathGuard.is_safe_relative("res://a/b.txt".replace("res://", "")), "plain relative path safe")
	_check(not CollabPathGuard.is_safe_relative("../secrets.txt"), "parent traversal rejected")
	_check(not CollabPathGuard.is_safe_relative("a/../../b"), "nested traversal rejected")
	_check(not CollabPathGuard.is_safe_relative("/etc/passwd"), "absolute path rejected")
	_check(not CollabPathGuard.is_safe_relative("C:/Windows/system32"), "drive path rejected")
	var resolved: String = CollabPathGuard.resolve_within("/tmp/opencode/ws", "sub/file.txt")
	_check(resolved.begins_with("/tmp/opencode/ws"), "resolve stays inside root")
	_check(CollabPathGuard.resolve_within("/tmp/opencode/ws", "../../etc/passwd").is_empty(), "escape resolve rejected")


func _test_rate_limiter() -> void:
	print("[rate limiter]")
	var limiter := CollabRateLimiter.new(3.0, 0.0)
	var allowed: int = 0
	for i in 6:
		if limiter.try_consume():
			allowed += 1
	_check(allowed == 3, "burst limited to capacity (got %d)" % allowed)


func _test_marker_manager() -> void:
	print("[marker manager]")
	var logs := CollabLog.new()
	var viewport := SubViewport.new()
	root.add_child(viewport)

	var manager_node := CollabSessionManager.new(logs)
	var coordinator := CollabSessionCoordinator.new()
	coordinator.setup(manager_node, logs)
	coordinator.get_project_id = func() -> String: return "proj"
	coordinator.get_scene_id = func() -> String: return "res://scene.tscn"
	coordinator.get_username = func() -> String: return "host"

	var state := CollabCursorState.new()
	var markers := CollabMarkerManager.new()
	markers.setup(coordinator, CollabSettings.new(), logs, state)
	markers.set_viewport_provider(func() -> SubViewport: return viewport)
	root.add_child(markers)

	var err: Error = coordinator.start_host(45980, 4, CollabConstants.WorkspaceMode.HOST_WORKSPACE, false)
	_check(err == OK, "marker host starts (%s)" % error_string(err))
	coordinator.registry.upsert(CollabParticipant.make(2, "Bob", false, true))
	markers.set_local_scene_id("res://scene.tscn")

	var camera := Transform3D(Basis(), Vector3(0.0, 5.0, 10.0))
	state.update(2, camera, Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector2(0.5, 0.5), "res://scene.tscn")
	markers.poll()
	_check(markers.has_marker(2), "a marker is created for a remote cursor")
	_check(markers.marker_count() == 1, "exactly one marker per remote peer")
	var created: Node = viewport.get_node_or_null("CollabUserMarkers/CollabPeer_2")
	_check(created != null, "marker is parented into the editor viewport container")
	if created is Node3D:
		_check((created as Node3D).position.is_equal_approx(Vector3(0.0, 0.0, -12.0)), "marker sits at the configured depth along the remote ray")

	state.remove(2)
	markers.poll()
	_check(not markers.has_marker(2), "marker is removed when the remote cursor is gone")

	state.update(2, camera, Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector2(0.5, 0.5), "res://other.tscn")
	markers.poll()
	_check(not markers.has_marker(2), "marker hidden when the peer is editing another scene")

	coordinator.stop("cleanup")
	markers.free()
	viewport.free()
	coordinator.free()
	manager_node.free()


func _test_marker_visuals() -> void:
	print("[marker visuals]")
	var packed: PackedScene = load("res://addons/godot_collab/assets/editorNodeVis.tscn") as PackedScene
	_check(packed != null, "marker scene loads")
	if packed == null:
		return
	var marker: CollabUserMarker = packed.instantiate() as CollabUserMarker
	_check(marker != null, "marker scene instantiates as CollabUserMarker")
	if marker == null:
		return
	root.add_child(marker)
	_check(marker.is_node_ready(), "marker runs _ready when added to the tree")

	var label: Label = marker.find_child("$user", true, false) as Label
	var sphere: CSGSphere3D = marker.get_node_or_null("CSGSphere3D") as CSGSphere3D
	_check(label != null, "marker exposes its username label")
	_check(sphere != null, "marker exposes its sphere")

	# Applying the default colour must be a no-op so loading the scene in the
	# editor does not duplicate resources / mark it modified.
	var original_material: Material = null
	if sphere != null:
		original_material = sphere.material_override
	marker.marker_color = Color(1, 0, 0, 0.6)
	_check(
		sphere != null and sphere.material_override == original_material,
		"re-applying the default colour keeps the shared material"
	)

	var blue := Color(0.2, 0.4, 1.0, 0.8)
	marker.username = "Alice"
	marker.marker_color = blue
	_check(label != null and label.text == "Alice", "username is applied to the label")
	if label != null and label.label_settings != null:
		_check(label.label_settings.font_color.is_equal_approx(blue), "marker colour is applied to the label")
	if sphere != null and sphere.material_override is StandardMaterial3D:
		var mat: StandardMaterial3D = sphere.material_override as StandardMaterial3D
		_check(mat.albedo_color.is_equal_approx(blue) and mat.emission.is_equal_approx(blue), "marker colour is applied to the material")

	root.remove_child(marker)
	marker.free()


func _test_loopback_session() -> void:
	print("[loopback session]")
	var logs := CollabLog.new()
	var port: int = 45977

	var host_manager := CollabSessionManager.new(logs)
	var host := CollabSessionCoordinator.new()
	host.setup(host_manager, logs)

	var client_manager := CollabSessionManager.new(logs)
	var client := CollabSessionCoordinator.new()
	client.setup(client_manager, logs)

	# Dictionaries are reference types, so lambdas can mutate this shared state
	# (GDScript lambdas capture plain locals by value).
	var state: Dictionary = {
		"client_joined": false,
		"client_saw_host": false,
		"host_cursor_from_peer": -1,
		"host_stopped": false,
	}

	client.session_started.connect(func(_is_host: bool) -> void: state["client_joined"] = true)
	client.participants_changed.connect(func() -> void:
		for p in client.registry.all():
			if p.is_host:
				state["client_saw_host"] = true)
	host.cursor_received.connect(func(peer_id: int, _payload: Dictionary) -> void: state["host_cursor_from_peer"] = peer_id)

	var err: Error = host.start_host(port, 4, CollabConstants.WorkspaceMode.HOST_WORKSPACE, false)
	_check(err == OK, "host starts (%s)" % error_string(err))
	err = client.join("127.0.0.1", port, "")
	_check(err == OK, "client join call starts (%s)" % error_string(err))

	var deadline: int = Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < deadline:
		host.poll()
		client.poll()
		if bool(state["client_joined"]) and host.registry.count() >= 2 and client.registry.count() >= 2:
			break
		OS.delay_msec(5)

	_check(bool(state["client_joined"]), "client received WELCOME")
	_check(host.registry.count() == 2, "host registry has 2 participants (got %d)" % host.registry.count())
	_check(client.registry.count() >= 2, "client registry has 2 participants (got %d)" % client.registry.count())
	_check(bool(state["client_saw_host"]), "client sees the host in its registry")

	if bool(state["client_joined"]):
		client.send_cursor({
			"camera_transform": Transform3D.IDENTITY,
			"ray_origin": Vector3.ZERO,
			"ray_direction": Vector3.FORWARD,
			"viewport_pos": Vector2(0.5, 0.5),
			"scene_id": "",
			"time_ms": Time.get_ticks_msec(),
		})
		var cursor_deadline: int = Time.get_ticks_msec() + 3000
		while Time.get_ticks_msec() < cursor_deadline and int(state["host_cursor_from_peer"]) < 0:
			host.poll()
			client.poll()
			OS.delay_msec(5)
		_check(int(state["host_cursor_from_peer"]) >= 0, "host received a relayed cursor")

	# Disconnect and verify the client observes the host leaving.
	client.session_stopped.connect(func(_reason: String) -> void: state["host_stopped"] = true)
	host.stop("test end")
	var stop_deadline: int = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < stop_deadline and not bool(state["host_stopped"]):
		client.poll()
		OS.delay_msec(5)
	_check(bool(state["host_stopped"]), "client saw the host disconnect")

	client.stop("cleanup")
	host.free()
	client.free()
	host_manager.free()
	client_manager.free()


## Drives two in-process peers until [param done] returns true or the timeout
## elapses. Returns true if the condition was met.
func _pump(host: CollabSessionCoordinator, client: CollabSessionCoordinator, host_sync: CollabSceneSyncService, client_sync: CollabSceneSyncService, timeout_ms: int, done: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		host.poll()
		client.poll()
		host_sync.poll()
		client_sync.poll()
		if done.call():
			return true
		OS.delay_msec(5)
	return bool(done.call())


## Reproduces the reported bug: the host has scene A open in the background but
## is focused on scene B. A client editing A must reach A and must not be undone
## or applied to B.
func _test_multi_scene_isolation() -> void:
	print("[multi-scene isolation]")
	var logs := CollabLog.new()
	var port: int = 45981

	var host_a := Node3D.new()
	host_a.name = "RootA"
	var a_box := Node3D.new()
	a_box.name = "A_Box"
	a_box.position = Vector3(1, 1, 1)
	host_a.add_child(a_box)

	var host_b := Node3D.new()
	host_b.name = "RootB"
	var b_box := Node3D.new()
	b_box.name = "B_Box"
	b_box.position = Vector3(2, 2, 2)
	host_b.add_child(b_box)

	var client_a := Node3D.new()
	client_a.name = "RootA"

	var host_manager := CollabSessionManager.new(logs)
	var host := CollabSessionCoordinator.new()
	host.setup(host_manager, logs)
	var client_manager := CollabSessionManager.new(logs)
	var client := CollabSessionCoordinator.new()
	client.setup(client_manager, logs)

	host.get_project_id = func() -> String: return "proj"
	host.get_scene_id = func() -> String: return "res://b.tscn"
	host.get_username = func() -> String: return "host"
	client.get_project_id = func() -> String: return "proj"
	client.get_scene_id = func() -> String: return "res://a.tscn"
	client.get_username = func() -> String: return "peer"

	var noop := func() -> void: pass
	var host_sync := CollabSceneSyncService.new()
	host_sync.setup(host, logs, {"get_edited_root": func() -> Node: return host_b, "mark_unsaved": noop})
	var client_sync := CollabSceneSyncService.new()
	client_sync.setup(client, logs, {"get_edited_root": func() -> Node: return client_a, "mark_unsaved": noop})
	client_sync.auto_apply_snapshot = true

	# The host has BOTH scenes open; B is the focused tab. The old implementation
	# bound only the focused tab, so A's context disappeared whenever B got focus.
	host_sync.bind_scene(host_a, "res://a.tscn", false)
	host_sync.bind_scene(host_b, "res://b.tscn", true)
	client_sync.bind_scene(client_a, "res://a.tscn", true)

	var err: Error = host.start_host(port, 4, CollabConstants.WorkspaceMode.HOST_WORKSPACE, false)
	_check(err == OK, "multi-scene host starts (%s)" % error_string(err))
	err = client.join("127.0.0.1", port, "")
	_check(err == OK, "multi-scene client join starts (%s)" % error_string(err))

	# The host sends A's snapshot (the client's scene), not the focused B.
	var synced: bool = _pump(host, client, host_sync, client_sync, 6000, func() -> bool:
		return client_a.get_node_or_null("A_Box") != null)
	_check(synced, "client received scene A snapshot while the host was focused on B")

	var client_box: Node3D = client_a.get_node_or_null("A_Box") as Node3D
	if client_box != null:
		client_box.position = Vector3(9, 9, 9)
	var applied: bool = _pump(host, client, host_sync, client_sync, 5000, func() -> bool:
		var hb: Node3D = host_a.get_node_or_null("A_Box") as Node3D
		return hb != null and hb.position.is_equal_approx(Vector3(9, 9, 9)))
	_check(applied, "host applied the client's edit to the background scene A")

	var host_b_box: Node3D = host_b.get_node_or_null("B_Box") as Node3D
	_check(host_b_box != null and host_b_box.position.is_equal_approx(Vector3(2, 2, 2)), "focused scene B was not modified")
	_check(host_sync.scene_id == "res://b.tscn", "host still reports its focused scene as B")

	client_sync.detach_scene()
	host_sync.detach_scene()
	client.stop("cleanup")
	host.stop("cleanup")
	host_a.free()
	host_b.free()
	client_a.free()
	host.free()
	client.free()
	host_manager.free()
	client_manager.free()


func _test_scene_sync_loopback() -> void:
	print("[scene sync loopback]")
	var logs := CollabLog.new()
	var port: int = 45978

	# Host scene: Root -> Box at (1,2,3).
	var host_root := Node3D.new()
	host_root.name = "Root"
	var host_box := Node3D.new()
	host_box.name = "Box"
	host_box.position = Vector3(1.0, 2.0, 3.0)
	host_root.add_child(host_box)

	# Client starts with a different scene content that the host snapshot must replace.
	var client_root := Node3D.new()
	client_root.name = "Root"
	var client_stale := Node3D.new()
	client_stale.name = "Stale"
	client_root.add_child(client_stale)

	var host_manager := CollabSessionManager.new(logs)
	var host := CollabSessionCoordinator.new()
	host.setup(host_manager, logs)
	var client_manager := CollabSessionManager.new(logs)
	var client := CollabSessionCoordinator.new()
	client.setup(client_manager, logs)

	host.get_project_id = func() -> String: return "proj"
	host.get_scene_id = func() -> String: return "res://scene.tscn"
	host.get_username = func() -> String: return "host"
	client.get_project_id = func() -> String: return "proj"
	client.get_scene_id = func() -> String: return "res://scene.tscn"
	client.get_username = func() -> String: return "peer"

	var get_host_root := func() -> Node: return host_root
	var get_client_root := func() -> Node: return client_root
	var noop := func() -> void: pass
	var host_sync := CollabSceneSyncService.new()
	host_sync.setup(host, logs, {"get_edited_root": get_host_root, "mark_unsaved": noop})
	var client_sync := CollabSceneSyncService.new()
	client_sync.setup(client, logs, {"get_edited_root": get_client_root, "mark_unsaved": noop})
	client_sync.auto_apply_snapshot = true

	# The plugin attaches the edited scene when the plugin enables, before any
	# session exists, so reproduce that ordering here.
	host_sync.attach_scene(host_root, "res://scene.tscn")
	client_sync.attach_scene(client_root, "res://scene.tscn")

	var err: Error = host.start_host(port, 4, CollabConstants.WorkspaceMode.HOST_WORKSPACE, false)
	_check(err == OK, "sync host starts (%s)" % error_string(err))
	err = client.join("127.0.0.1", port, "")
	_check(err == OK, "sync client join starts (%s)" % error_string(err))

	# The host sends its scene on peer_ready; the client must auto-apply it.
	var synced: bool = _pump(host, client, host_sync, client_sync, 6000, func() -> bool:
		return client_root.get_node_or_null("Box") != null)
	_check(synced, "client received the host scene snapshot")
	_check(client_root.get_node_or_null("Stale") == null, "client's previous content replaced by snapshot")

	var client_box: Node3D = client_root.get_node_or_null("Box") as Node3D
	_check(client_box != null and client_box.position.is_equal_approx(Vector3(1.0, 2.0, 3.0)), "snapshot preserved the node transform")

	# A peer edit must reach the host and remain visible on the peer.
	if client_box != null:
		client_box.position = Vector3(4.0, 5.0, 6.0)
	var applied: bool = _pump(host, client, host_sync, client_sync, 4000, func() -> bool:
		var hb: Node3D = host_root.get_node_or_null("Box") as Node3D
		return hb != null and hb.position.is_equal_approx(Vector3(4.0, 5.0, 6.0)))
	var host_box_after: Node3D = host_root.get_node_or_null("Box") as Node3D
	_check(applied, "host applied the peer transform edit (got %s)" % str(host_box_after.position if host_box_after != null else "missing"))
	_check(client_box != null and client_box.position.is_equal_approx(Vector3(4.0, 5.0, 6.0)), "peer edit stayed visible locally")

	# A host edit must reach the peer.
	var host_only := Node3D.new()
	host_only.name = "HostOnly"
	host_only.position = Vector3(7.0, 8.0, 9.0)
	host_root.add_child(host_only)
	var host_propagated: bool = _pump(host, client, host_sync, client_sync, 4000, func() -> bool:
		var cb: Node3D = client_root.get_node_or_null("HostOnly") as Node3D
		return cb != null and cb.position.is_equal_approx(Vector3(7.0, 8.0, 9.0)))
	_check(host_propagated, "host-created node propagated to the peer")

	# A peer-created node must reach the host and stay on the peer.
	var peer_box := Node3D.new()
	peer_box.name = "PeerBox"
	peer_box.position = Vector3(10.0, 11.0, 12.0)
	client_root.add_child(peer_box)
	var created: bool = _pump(host, client, host_sync, client_sync, 5000, func() -> bool:
		var hb: Node3D = host_root.get_node_or_null("PeerBox") as Node3D
		return hb != null and hb.position.is_equal_approx(Vector3(10.0, 11.0, 12.0)))
	_check(created, "host received the peer-created node")
	_check(client_root.get_node_or_null("PeerBox") != null, "peer-created node stayed visible locally")
	_check(_count_prefixed(host_root, "PeerBox") == 1, "host has exactly one copy of the peer-created node")
	_check(_count_prefixed(client_root, "PeerBox") == 1, "client has exactly one copy of its created node")

	# A peer edit to its own created node must target that node on the host and
	# must never collide with another node's id (e.g. the scene root).
	var peer_box_node: Node3D = client_root.get_node_or_null("PeerBox")
	if peer_box_node != null:
		peer_box_node.position = Vector3(7.5, 7.5, 7.5)
	var peer_edit: bool = _pump(host, client, host_sync, client_sync, 5000, func() -> bool:
		var hb: Node = host_root.get_node_or_null("PeerBox")
		return hb is Node3D and (hb as Node3D).position.is_equal_approx(Vector3(7.5, 7.5, 7.5)))
	_check(peer_edit, "peer edit to its created node reached that node on the host")
	_check(host_root.position.is_zero_approx(), "host scene root was not moved by a peer node edit")

	# The host must also observe a peer removal.
	if client_box != null:
		client_root.remove_child(client_box)
		client_box.free()
	var removed: bool = _pump(host, client, host_sync, client_sync, 5000, func() -> bool:
		return host_root.get_node_or_null("Box") == null)
	_check(removed, "host observed the peer removal")

	# Simulate the client requesting a snapshot after editing: the host's scene
	# already contains the peer's edits, so a pull must not undo them.
	client_sync.request_snapshot()
	var survives_pull: bool = _pump(host, client, host_sync, client_sync, 6000, func() -> bool:
		return client_root.get_node_or_null("PeerBox") != null and client_root.get_node_or_null("HostOnly") != null)
	_check(survives_pull, "peer edits survived a snapshot request round-trip")
	_check(client_root.get_node_or_null("Box") == null, "removed node stayed removed after snapshot")

	client_sync.detach_scene()
	host_sync.detach_scene()
	client.stop("cleanup")
	host.stop("cleanup")
	host_root.free()
	client_root.free()
	host.free()
	client.free()
	host_manager.free()
	client_manager.free()


## Verifies that ordinary inspector properties (not just the old hard-coded
## whitelist) reach the host in both directions.
func _test_general_property_sync() -> void:
	print("[general property sync]")
	var logs := CollabLog.new()
	var port: int = 45982

	var host_root := Node3D.new()
	host_root.name = "Root"
	var host_box := Node3D.new()
	host_box.name = "Box"
	host_root.add_child(host_box)
	var host_mesh := MeshInstance3D.new()
	host_mesh.name = "Mesh"
	host_root.add_child(host_mesh)

	var client_root := Node3D.new()
	client_root.name = "Root"

	var host_manager := CollabSessionManager.new(logs)
	var host := CollabSessionCoordinator.new()
	host.setup(host_manager, logs)
	var client_manager := CollabSessionManager.new(logs)
	var client := CollabSessionCoordinator.new()
	client.setup(client_manager, logs)

	host.get_project_id = func() -> String: return "proj"
	host.get_scene_id = func() -> String: return "res://g.tscn"
	host.get_username = func() -> String: return "host"
	client.get_project_id = func() -> String: return "proj"
	client.get_scene_id = func() -> String: return "res://g.tscn"
	client.get_username = func() -> String: return "peer"

	var noop := func() -> void: pass
	var host_sync := CollabSceneSyncService.new()
	host_sync.setup(host, logs, {"get_edited_root": func() -> Node: return host_root, "mark_unsaved": noop})
	var client_sync := CollabSceneSyncService.new()
	client_sync.setup(client, logs, {"get_edited_root": func() -> Node: return client_root, "mark_unsaved": noop})
	client_sync.auto_apply_snapshot = true

	host_sync.attach_scene(host_root, "res://g.tscn")
	client_sync.attach_scene(client_root, "res://g.tscn")

	var err: Error = host.start_host(port, 4, CollabConstants.WorkspaceMode.HOST_WORKSPACE, false)
	_check(err == OK, "property host starts (%s)" % error_string(err))
	err = client.join("127.0.0.1", port, "")
	_check(err == OK, "property client joins (%s)" % error_string(err))

	var synced: bool = _pump(host, client, host_sync, client_sync, 6000, func() -> bool:
		return client_root.get_node_or_null("Box") != null)
	_check(synced, "client received the host snapshot")

	# These two properties were absent from the old whitelist.
	host_box.editor_description = "greetings"
	host_box.process_priority = 7
	var host_to_client: bool = _pump(host, client, host_sync, client_sync, 5000, func() -> bool:
		var cb: Node = client_root.get_node_or_null("Box")
		return cb != null and cb.editor_description == "greetings" and cb.process_priority == 7)
	_check(host_to_client, "host inspector property change (editor_description/process_priority) reached the client")

	var client_box: Node3D = client_root.get_node_or_null("Box") as Node3D
	if client_box != null:
		client_box.visible = false
	var client_to_host: bool = _pump(host, client, host_sync, client_sync, 5000, func() -> bool:
		return not host_box.visible)
	_check(client_to_host, "client inspector property change (visible) reached the host")

	# Dragging a brand-new material from the filesystem (or assigning one in the
	# inspector) produces a path-less/embedded resource on the host that must
	# travel inline and be rebuilt on the client.
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.9, 0.1, 0.3)
	host_mesh.material_override = material
	var resource_synced: bool = _pump(host, client, host_sync, client_sync, 5000, func() -> bool:
		var client_mesh: MeshInstance3D = client_root.get_node_or_null("Mesh") as MeshInstance3D
		if client_mesh == null:
			return false
		var received := client_mesh.material_override as StandardMaterial3D
		return received != null and received.albedo_color.is_equal_approx(Color(0.9, 0.1, 0.3)))
	_check(resource_synced, "host inline material_override reached the client as a rebuilt resource")

	# Editing that embedded material in place (change its colour) changes no node
	# reference, and StandardMaterial3D never emits its "changed" signal for this,
	# so it is only caught by the watcher's periodic content re-serialisation.
	# This is the "nested node properties" case: no file exists, yet the edit must
	# travel.
	if material != null:
		material.albedo_color = Color(0.05, 0.95, 0.15)
	var nested_edit: bool = _pump(host, client, host_sync, client_sync, 6000, func() -> bool:
		var client_mesh: MeshInstance3D = client_root.get_node_or_null("Mesh") as MeshInstance3D
		if client_mesh == null:
			return false
		var received := client_mesh.material_override as StandardMaterial3D
		return received != null and received.albedo_color.is_equal_approx(Color(0.05, 0.95, 0.15)))
	_check(nested_edit, "in-place edit of an embedded material propagated to the client")

	# A sub-resource owned by a node (a BoxShape3D on a CollisionShape3D) is also
	# embedded; both its initial value and its later nested edits must travel.
	var host_shape := CollisionShape3D.new()
	host_shape.name = "Hull"
	var box := BoxShape3D.new()
	box.size = Vector3(1, 2, 3)
	host_shape.shape = box
	host_root.add_child(host_shape)
	var shape_synced: bool = _pump(host, client, host_sync, client_sync, 6000, func() -> bool:
		var cs: CollisionShape3D = client_root.get_node_or_null("Hull") as CollisionShape3D
		if cs == null or not (cs.shape is BoxShape3D):
			return false
		return (cs.shape as BoxShape3D).size.is_equal_approx(Vector3(1, 2, 3)))
	_check(shape_synced, "nested BoxShape3D sub-resource reached the client with its size")

	box.size = Vector3(4, 5, 6)
	var shape_edit: bool = _pump(host, client, host_sync, client_sync, 6000, func() -> bool:
		var cs: CollisionShape3D = client_root.get_node_or_null("Hull") as CollisionShape3D
		if cs == null or not (cs.shape is BoxShape3D):
			return false
		return (cs.shape as BoxShape3D).size.is_equal_approx(Vector3(4, 5, 6)))
	_check(shape_edit, "in-place edit of a nested sub-resource reached the client")

	client_sync.detach_scene()
	host_sync.detach_scene()
	client.stop("cleanup")
	host.stop("cleanup")
	host_root.free()
	client_root.free()
	host.free()
	client.free()
	host_manager.free()
	client_manager.free()


## Drives two peers plus their workspace services until [param done] is true.
func _pump_workspaces(host: CollabSessionCoordinator, client: CollabSessionCoordinator, host_ws: CollabWorkspaceService, client_ws: CollabWorkspaceService, timeout_ms: int, done: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		host.poll()
		client.poll()
		host_ws.poll()
		client_ws.poll()
		if done.call():
			return true
		OS.delay_msec(5)
	return bool(done.call())


func _reset_dir(path: String) -> void:
	if DirAccess.dir_exists_absolute(path):
		_remove_tree(path)
	DirAccess.make_dir_recursive_absolute(path)


func _remove_tree(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		var abs: String = path.path_join(entry)
		if dir.current_is_dir():
			_remove_tree(abs)
		else:
			DirAccess.remove_absolute(abs)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


## Reproduces the reported rename desync: a client renames a resource file (or
## deletes a file) and the host must converge to the new name and drop the old
## copy, instead of keeping both.
func _test_workspace_rename_delete_loopback() -> void:
	print("[workspace rename/delete loopback]")
	var logs := CollabLog.new()
	var port: int = 45984

	var host_root: String = "/tmp/opencode/wsrename_host"
	var client_root: String = "/tmp/opencode/wsrename_client"
	_reset_dir(host_root)
	_reset_dir(client_root)

	var material_text: String = "[gd_resource type=\"StandardMaterial3D\" format=3]\n\n[resource]\nalbedo_color = Color(0.2, 0.4, 0.8, 1)\n"
	_write_text(host_root.path_join("mat_old.tres"), material_text)
	_write_text(client_root.path_join("mat_old.tres"), material_text)
	_write_text(host_root.path_join("scripts/util.gd"), "extends Node\n")
	_write_text(client_root.path_join("scripts/util.gd"), "extends Node\n")

	var host_manager := CollabSessionManager.new(logs)
	var host := CollabSessionCoordinator.new()
	host.setup(host_manager, logs)
	var client_manager := CollabSessionManager.new(logs)
	var client := CollabSessionCoordinator.new()
	client.setup(client_manager, logs)

	host.get_project_id = func() -> String: return "proj"
	host.get_scene_id = func() -> String: return "res://w.tscn"
	host.get_username = func() -> String: return "host"
	client.get_project_id = func() -> String: return "proj"
	client.get_scene_id = func() -> String: return "res://w.tscn"
	client.get_username = func() -> String: return "peer"

	var host_ws := CollabWorkspaceService.new()
	host_ws.setup(host, CollabSettings.new(), logs, func() -> String: return host_root, {})
	var client_ws := CollabWorkspaceService.new()
	client_ws.setup(client, CollabSettings.new(), logs, func() -> String: return client_root, {})

	var err: Error = host.start_host(port, 4, CollabConstants.WorkspaceMode.HOST_WORKSPACE, false)
	_check(err == OK, "rename host starts (%s)" % error_string(err))
	err = client.join("127.0.0.1", port, "")
	_check(err == OK, "rename client joins (%s)" % error_string(err))

	var ready: bool = _pump_workspaces(host, client, host_ws, client_ws, 6000, func() -> bool:
		return host.registry.count() >= 2 and client.registry.count() >= 2)
	_check(ready, "rename peers connected")

	# Prime baselines only after both peers already have the same files, so the
	# initial state is not treated as a change.
	host_ws.prime_file_baseline()
	client_ws.prime_file_baseline()
	host_ws.file_sync_enabled = true
	client_ws.file_sync_enabled = true
	host_ws._watch_last_ms = 0
	client_ws._watch_last_ms = 0

	# The client renames the resource and deletes the script.
	DirAccess.rename_absolute(client_root.path_join("mat_old.tres"), client_root.path_join("mat_new.tres"))
	DirAccess.remove_absolute(client_root.path_join("scripts/util.gd"))

	var host_mat: String = host_root.path_join("mat_new.tres")
	var host_old: String = host_root.path_join("mat_old.tres")
	var host_util: String = host_root.path_join("scripts/util.gd")
	var converged: bool = _pump_workspaces(host, client, host_ws, client_ws, 9000, func() -> bool:
		return FileAccess.file_exists(host_mat) and not FileAccess.file_exists(host_old) and not FileAccess.file_exists(host_util))
	_check(FileAccess.file_exists(host_mat), "renamed file arrived on the host")
	_check(not FileAccess.file_exists(host_old), "renamed-away file was removed on the host (no stale duplicate)")
	_check(not FileAccess.file_exists(host_util), "deleted file was removed on the host")
	_check(converged, "host converged to the renamed file and the deletion")
	# The client's own copy must remain the renamed one.
	_check(FileAccess.file_exists(client_root.path_join("mat_new.tres")), "client kept the renamed file")
	_check(not FileAccess.file_exists(client_root.path_join("mat_old.tres")), "client dropped the old name")

	client_ws.free()
	host_ws.free()
	client.stop("cleanup")
	host.stop("cleanup")
	client.free()
	host.free()
	client_manager.free()
	host_manager.free()


## Reproduces the reported post-crash bug: a client whose local scene does not
## match the host (because it restarted / reopened a stale scene) must never
## toggle a same-numbered but different local node on the host, and after a
## reconnect its edits must address the right nodes again.
func _test_rejoin_desync() -> void:
	print("[rejoin desync]")
	var logs := CollabLog.new()
	var port: int = 45983

	var host_root := Node3D.new()
	host_root.name = "Root"
	var host_box := Node3D.new()
	host_box.name = "Box"
	host_box.visible = true
	host_root.add_child(host_box)

	# The client has a differently-named node that would previously have been
	# allocated the same positive id as the host's Box.
	var client_root := Node3D.new()
	client_root.name = "Root"
	var decoy := Node3D.new()
	decoy.name = "Decoy"
	client_root.add_child(decoy)

	var host_manager := CollabSessionManager.new(logs)
	var host := CollabSessionCoordinator.new()
	host.setup(host_manager, logs)
	var client_manager := CollabSessionManager.new(logs)
	var client := CollabSessionCoordinator.new()
	client.setup(client_manager, logs)

	host.get_project_id = func() -> String: return "proj"
	host.get_scene_id = func() -> String: return "res://rejoin.tscn"
	host.get_username = func() -> String: return "host"
	client.get_project_id = func() -> String: return "proj"
	client.get_scene_id = func() -> String: return "res://rejoin.tscn"
	client.get_username = func() -> String: return "peer"

	var noop := func() -> void: pass
	var host_sync := CollabSceneSyncService.new()
	host_sync.setup(host, logs, {"get_edited_root": func() -> Node: return host_root, "mark_unsaved": noop})
	var client_sync := CollabSceneSyncService.new()
	client_sync.setup(client, logs, {"get_edited_root": func() -> Node: return client_root, "mark_unsaved": noop})
	client_sync.auto_apply_snapshot = true

	host_sync.attach_scene(host_root, "res://rejoin.tscn")
	client_sync.attach_scene(client_root, "res://rejoin.tscn")

	var err: Error = host.start_host(port, 4, CollabConstants.WorkspaceMode.HOST_WORKSPACE, false)
	_check(err == OK, "rejoin host starts (%s)" % error_string(err))
	err = client.join("127.0.0.1", port, "")
	_check(err == OK, "rejoin client joins (%s)" % error_string(err))

	var synced: bool = _pump(host, client, host_sync, client_sync, 6000, func() -> bool:
		return client_root.get_node_or_null("Box") != null and client_root.get_node_or_null("Decoy") == null)
	_check(synced, "rejoining client's stale node replaced by the host snapshot")

	var client_box: Node3D = client_root.get_node_or_null("Box") as Node3D
	if client_box != null:
		client_box.visible = false
	var toggled_correct: bool = _pump(host, client, host_sync, client_sync, 5000, func() -> bool:
		return not host_box.visible)
	_check(toggled_correct, "client visibility toggle reaches the host's Box")
	_check(host_root.get_node_or_null("Decoy") == null, "no phantom node appeared on the host")

	# Disconnect and reconnect with a fresh client: its local ids must be
	# re-keyed to the host's again, not left stale.
	client_sync.detach_scene()
	client.stop("simulated crash")
	var drain: int = Time.get_ticks_msec() + 300
	while Time.get_ticks_msec() < drain:
		host.poll()
		host_sync.poll()
		OS.delay_msec(5)

	var client2_manager := CollabSessionManager.new(logs)
	var client2 := CollabSessionCoordinator.new()
	client2.setup(client2_manager, logs)
	client2.get_project_id = func() -> String: return "proj"
	client2.get_scene_id = func() -> String: return "res://rejoin.tscn"
	client2.get_username = func() -> String: return "peer2"
	var client2_sync := CollabSceneSyncService.new()
	client2_sync.setup(client2, logs, {"get_edited_root": func() -> Node: return client_root, "mark_unsaved": noop})
	client2_sync.auto_apply_snapshot = true
	client2_sync.attach_scene(client_root, "res://rejoin.tscn")

	err = client2.join("127.0.0.1", port, "")
	_check(err == OK, "client reconnects (%s)" % error_string(err))
	var resynced: bool = _pump(host, client2, host_sync, client2_sync, 6000, func() -> bool:
		var cb: Node = client_root.get_node_or_null("Box")
		return client2.local_peer_id() > 0 and cb != null and client2_sync.node_id_for_scene("res://rejoin.tscn", cb) > 0)
	_check(resynced, "client resynced and re-keyed to host ids after reconnect")

	var client_box2: Node3D = client_root.get_node_or_null("Box") as Node3D
	if client_box2 != null:
		client_box2.visible = true
	var toggled_after: bool = _pump(host, client2, host_sync, client2_sync, 5000, func() -> bool:
		return host_box.visible)
	_check(toggled_after, "post-reconnect toggle targets the correct node")
	_check(host_root.get_node_or_null("Decoy") == null, "no phantom node appeared after reconnect")

	client2_sync.detach_scene()
	host_sync.detach_scene()
	client2.stop("cleanup")
	host.stop("cleanup")
	host_root.free()
	client_root.free()
	host.free()
	client.free()
	client2.free()
	host_manager.free()
	client_manager.free()
	client2_manager.free()
