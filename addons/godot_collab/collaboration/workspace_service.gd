@tool
## Host-authoritative project authoring.
##
## In host-owned-workspace mode the host is the only peer that writes to disk.
## Clients ask the host to create a scene or add a project file
## ([constant CollabProtocol.MessageType.WORKSPACE_REQUEST]); the host validates
## the request against [CollabPathGuard] and a strict extension/size policy,
## writes it, and broadcasts the exact content
## ([constant CollabProtocol.MessageType.FILE_APPLY]) so every peer writes its
## own local copy and the file becomes available in everyone's editor.
##
## The host also advertises the project's scenes
## ([constant CollabProtocol.MessageType.SCENE_LIST]) so clients can discover and
## open scenes created by others. Nothing here executes transferred content.
##
## The same service also performs host-authoritative *source file* sync: scripts,
## shaders, resources and project configuration are watched for changes and
## relayed to the host (files under [code]addons/[/code] are deliberately
## excluded - editing the add-on's own files while it is running can crash a
## client and corrupt its project copy).
class_name CollabWorkspaceService
extends Node

signal status(text: String)
signal error_raised(text: String)
signal request_result(request_id: int, ok: bool, path: String, message: String)
signal scene_list_received(scenes: Array, host_revision: int)

## Prefixes that are never writable, regardless of extension.
## [code]addons/[/code] is included because live-editing an active add-on (and
## syncing that edit to a client) can crash the client and corrupt its project.
const EXCLUDED_PREFIXES: Array[String] = [".godot/", ".git/", "addons/"]

## Prefixes excluded from the source-file watcher only (never from scene lists).
const FILESYNC_EXCLUDED_PREFIXES: Array[String] = [".godot/", ".git/", "addons/", ".vscode/", ".idea/", ".import/", "android/"]

## Extensions relayed by the file watcher: source text plus binary assets a user
## may drag into the project (images, models, audio, fonts, video). `.tscn`/`.scn`
## are included so a dropped scene also travels, but a scene that is currently
## open in the editor is protected: it is synchronised as structured operations
## instead, and its file is never overwritten underneath the editor.
const FILESYNC_EXTENSIONS: Array[String] = [
	".gd", ".gdshader", ".shader", ".gdshaderinc", ".tres", ".res",
	".json", ".cfg", ".txt", ".csv", ".xml", ".md", ".po", ".svg", ".ini", ".toml",
	".tscn", ".scn", ".escn",
	".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tga", ".gif", ".hdr", ".exr", ".dds", ".ktx",
	".obj", ".mtl", ".gltf", ".glb", ".fbx", ".dae", ".blend",
	".wav", ".ogg", ".mp3", ".oggstr",
	".ttf", ".otf", ".woff", ".woff2", ".fnt",
	".ogv",
]

## Scene-file extensions. A file with one of these extensions that is currently
## open in the editor is never relayed or overwritten as a raw file.
const SCENE_EXTENSIONS: Array[String] = [".tscn", ".scn", ".escn"]

## Exact file names (with no useful extension) that are still watched.
const FILESYNC_FILES: Array[String] = ["project.godot", "export_presets.cfg"]

## How often the file watcher scans the project for changes.
const FILESYNC_INTERVAL_MS: int = 1200

## Upper bound on the number of files the watcher tracks.
const FILESYNC_MAX_FILES: int = 8000

var enabled: bool = true
## When true the service watches project source files and relays changes.
var file_sync_enabled: bool = false

var _coordinator: CollabSessionCoordinator
var _settings: CollabSettings
var _logs: CollabLog
var _project_root: Callable = Callable()
var _editor: Dictionary = {}
## Supplied by the plugin: returns the `res://` paths of scenes currently open in
## the editor. Those files are protected from raw file relay/overwrite because
## they are synchronised as structured operations.
var open_scene_paths: Callable = Callable()
var _host_revision: int = 0
var _request_counter: int = 0
var _watch_baseline: Dictionary = {} # rel -> {size:int, mtime:int, sha:String}
var _watch_last_ms: int = 0
var _watch_primed: bool = false


func setup(coordinator: CollabSessionCoordinator, settings: CollabSettings, logs: CollabLog, project_root: Callable, editor: Dictionary) -> void:
	_coordinator = coordinator
	_settings = settings
	_logs = logs
	_project_root = project_root
	_editor = editor
	coordinator.workspace_message.connect(_on_workspace_message)
	coordinator.peer_ready.connect(_on_peer_ready)


# ---------------------------------------------------------------------------
# Public requests (any peer)
# ---------------------------------------------------------------------------

## Requests creation of a new empty scene at [param path]. Returns an error
## string when the request cannot be made locally, otherwise "".
func request_new_scene(path: String, root_class: String) -> String:
	if not _can_request():
		return "Workspace authoring is unavailable in this mode or session."
	var rel: String = CollabPathGuard.normalize_relative(path)
	if rel.is_empty():
		return "Invalid scene path."
	if not rel.ends_with(".tscn"):
		return "Scene path must end with .tscn."
	if not CollabConstants.SCENE_ROOT_CLASSES.has(root_class):
		return "Unsupported scene root class '%s'." % root_class
	if _coordinator.is_host():
		_host_create_scene(_next_request_id(), rel, root_class, _coordinator.local_peer_id())
	else:
		var request_id: int = _next_request_id()
		_coordinator.send_workspace(CollabProtocol.MessageType.WORKSPACE_REQUEST, {
			"request_id": request_id,
			"kind": CollabConstants.WorkspaceOp.CREATE_SCENE,
			"path": rel,
			"root_class": root_class,
		})
		status.emit("Requested new scene '%s' from the host." % rel)
	return ""


## Requests adding (or overwriting) a text project file. Returns an error string
## when the request cannot be made locally, otherwise "".
func request_add_file(path: String, text: String, overwrite: bool = true) -> String:
	if not _can_request():
		return "Workspace authoring is unavailable in this mode or session."
	var rel: String = CollabPathGuard.normalize_relative(path)
	if rel.is_empty():
		return "Invalid file path."
	if not _is_writable_path(rel):
		return "Extension not allowed: %s" % ("." + rel.get_extension())
	if text.to_utf8_buffer().size() > CollabConstants.MAX_WORKSPACE_FILE_BYTES:
		return "File exceeds the %d KiB authoring limit." % (CollabConstants.MAX_WORKSPACE_FILE_BYTES / 1024)
	if _coordinator.is_host():
		_host_add_file(_next_request_id(), rel, text.to_utf8_buffer(), overwrite, _coordinator.local_peer_id())
	else:
		var request_id: int = _next_request_id()
		_coordinator.send_workspace(CollabProtocol.MessageType.WORKSPACE_REQUEST, {
			"request_id": request_id,
			"kind": CollabConstants.WorkspaceOp.ADD_FILE,
			"path": rel,
			"overwrite": overwrite,
			"text": text,
		})
		status.emit("Requested to add file '%s' on the host." % rel)
	return ""


## Host only: advertise the project's scenes to every peer.
func broadcast_scene_list() -> void:
	if not _can_request() or not _coordinator.is_host():
		return
	var scenes: Array = _scan_scenes()
	_coordinator.send_workspace(CollabProtocol.MessageType.SCENE_LIST, {
		"scenes": scenes,
		"revision": _host_revision,
	})


## Client: ask the host to re-advertise its scene list.
func request_scene_list() -> void:
	if not _can_request() or _coordinator.is_host():
		return
	_coordinator.send_workspace(CollabProtocol.MessageType.WORKSPACE_REQUEST, {
		"request_id": _next_request_id(),
		"kind": CollabConstants.WorkspaceOp.LIST_SCENES,
		"path": "",
	})


func scan_scenes() -> Array:
	return _scan_scenes()


# ---------------------------------------------------------------------------
# Inbound routing
# ---------------------------------------------------------------------------

func _on_workspace_message(from_peer: int, type: int, payload: Dictionary) -> void:
	if not enabled:
		return
	match type:
		CollabProtocol.MessageType.WORKSPACE_REQUEST:
			if _coordinator.is_host() and _coordinator.is_admitted(from_peer):
				_host_handle_request(from_peer, payload)
		CollabProtocol.MessageType.WORKSPACE_RESULT:
			if not _coordinator.is_host():
				var ok: bool = bool(payload.get("ok", false))
				var path: String = str(payload.get("path", ""))
				var message: String = str(payload.get("message", ""))
				request_result.emit(int(payload.get("request_id", 0)), ok, path, message)
				if ok:
					status.emit("Host accepted '%s'." % path)
				else:
					error_raised.emit("Host rejected '%s': %s" % [path, message])
		CollabProtocol.MessageType.FILE_APPLY:
			# Only the host may distribute file content to a client.
			if not _coordinator.is_host() and from_peer == CollabSessionCoordinator.HOST_PEER_ID:
				_apply_incoming_file(payload)
		CollabProtocol.MessageType.FILE_REMOVE:
			if not _coordinator.is_host() and from_peer == CollabSessionCoordinator.HOST_PEER_ID:
				_apply_incoming_remove(payload)
		CollabProtocol.MessageType.SCENE_LIST:
			if not _coordinator.is_host():
				var scenes: Variant = payload.get("scenes", [])
				scene_list_received.emit(scenes if typeof(scenes) == TYPE_ARRAY else [], int(payload.get("revision", 0)))


func _on_peer_ready(peer_id: int) -> void:
	if _coordinator == null or not _coordinator.is_host():
		return
	if _can_request():
		_send_scene_list_to(peer_id)


# ---------------------------------------------------------------------------
# Host handling
# ---------------------------------------------------------------------------

func _host_handle_request(from_peer: int, payload: Dictionary) -> void:
	var request_id: int = int(payload.get("request_id", 0))
	var kind: int = int(payload.get("kind", -1))
	var path: String = str(payload.get("path", ""))
	match kind:
		CollabConstants.WorkspaceOp.CREATE_SCENE:
			_host_create_scene(request_id, path, str(payload.get("root_class", "")), from_peer)
		CollabConstants.WorkspaceOp.ADD_FILE:
			var bytes: PackedByteArray
			var raw_data: Variant = payload.get("data")
			if typeof(raw_data) == TYPE_PACKED_BYTE_ARRAY:
				bytes = raw_data
			else:
				bytes = str(payload.get("text", "")).to_utf8_buffer()
			_host_add_file(request_id, path, bytes, bool(payload.get("overwrite", true)), from_peer)
		CollabConstants.WorkspaceOp.DELETE_FILE:
			_host_delete_file(request_id, path, from_peer)
		CollabConstants.WorkspaceOp.LIST_SCENES:
			_send_scene_list_to(from_peer)
		_:
			_send_result(from_peer, request_id, false, path, "Unknown workspace request kind.")


func _host_create_scene(request_id: int, path: String, root_class: String, from_peer: int) -> void:
	var rel: String = CollabPathGuard.normalize_relative(path)
	if rel.is_empty() or not rel.ends_with(".tscn"):
		_send_result(from_peer, request_id, false, path, "Invalid scene path.")
		return
	if not CollabConstants.SCENE_ROOT_CLASSES.has(root_class) or not ClassDB.class_exists(root_class):
		_send_result(from_peer, request_id, false, path, "Unsupported scene root class.")
		return
	if ResourceLoader.exists(rel) or FileAccess.file_exists(_absolute(rel)):
		_send_result(from_peer, request_id, false, rel, "A file already exists at '%s'." % rel)
		return
	var root: Node = ClassDB.instantiate(root_class) as Node
	if root == null:
		_send_result(from_peer, request_id, false, rel, "Could not instantiate scene root.")
		return
	root.name = rel.get_file().get_basename()
	var packed := PackedScene.new()
	var err: Error = packed.pack(root)
	root.free()
	if err != OK:
		_send_result(from_peer, request_id, false, rel, "Could not pack the new scene: %s" % error_string(err))
		return
	var absolute: String = _absolute(rel)
	if absolute.is_empty() or not _ensure_parent_dir(absolute):
		_send_result(from_peer, request_id, false, rel, "Could not create the scene directory.")
		return
	err = ResourceSaver.save(packed, rel)
	if err != OK:
		_send_result(from_peer, request_id, false, rel, "Could not write the scene: %s" % error_string(err))
		return
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(absolute)
	_revision_bump()
	_broadcast_file_apply(rel, bytes, true)
	_refresh_filesystem(rel)
	_send_result(from_peer, request_id, true, rel, "Scene created.")
	status.emit("Created scene '%s'." % rel)
	broadcast_scene_list()


func _host_add_file(request_id: int, path: String, bytes: PackedByteArray, overwrite: bool, from_peer: int) -> void:
	var rel: String = CollabPathGuard.normalize_relative(path)
	if rel.is_empty():
		_send_result(from_peer, request_id, false, path, "Invalid file path.")
		return
	if not _is_writable_path(rel):
		_send_result(from_peer, request_id, false, rel, "Extension not allowed.")
		return
	if bytes.size() > CollabConstants.MAX_WORKSPACE_FILE_BYTES:
		_send_result(from_peer, request_id, false, rel, "File exceeds the authoring size limit.")
		return
	var absolute: String = _absolute(rel)
	if absolute.is_empty() or not CollabPathGuard.no_symlink_escape(_project_root.call(), rel):
		_send_result(from_peer, request_id, false, rel, "Unsafe path.")
		return
	if FileAccess.file_exists(absolute) and not overwrite:
		_send_result(from_peer, request_id, false, rel, "File already exists (overwrite disabled).")
		return
	if not _ensure_parent_dir(absolute):
		_send_result(from_peer, request_id, false, rel, "Could not create the file directory.")
		return
	var file: FileAccess = FileAccess.open(absolute, FileAccess.WRITE)
	if file == null:
		_send_result(from_peer, request_id, false, rel, "Could not open the file for writing.")
		return
	file.store_buffer(bytes)
	file.close()
	_revision_bump()
	_broadcast_file_apply(rel, bytes, rel.ends_with(".tscn"))
	_refresh_filesystem(rel)
	_refresh_baseline_entry(rel)
	_send_result(from_peer, request_id, true, rel, "File added.")
	status.emit("Added file '%s'." % rel)


func _host_delete_file(request_id: int, path: String, from_peer: int) -> void:
	var rel: String = CollabPathGuard.normalize_relative(path)
	if rel.is_empty():
		_send_result(from_peer, request_id, false, path, "Invalid file path.")
		return
	if not _is_writable_path(rel):
		_send_result(from_peer, request_id, false, rel, "Extension not allowed.")
		return
	var absolute: String = _absolute(rel)
	if absolute.is_empty() or not CollabPathGuard.no_symlink_escape(_project_root.call(), rel):
		_send_result(from_peer, request_id, false, rel, "Unsafe path.")
		return
	if FileAccess.file_exists(absolute):
		var err: Error = DirAccess.remove_absolute(absolute)
		if err != OK and err != ERR_FILE_NOT_FOUND:
			_send_result(from_peer, request_id, false, rel, "Could not delete the file: %s" % error_string(err))
			return
	_watch_baseline.erase(rel)
	_revision_bump()
	_broadcast_file_remove(rel)
	_refresh_filesystem(rel)
	_send_result(from_peer, request_id, true, rel, "File removed.")
	status.emit("Removed file '%s'." % rel)


# ---------------------------------------------------------------------------
# Applying file content on non-host peers (and the host's own create path)
# ---------------------------------------------------------------------------

## Deletes a project file that the host has removed (rename source or delete).
## Only files inside the approved workspace and with allowed extensions are
## touched; an open scene's file is never deleted underneath the editor.
func _apply_incoming_remove(payload: Dictionary) -> void:
	var rel: String = CollabPathGuard.normalize_relative(str(payload.get("path", "")))
	if rel.is_empty() or not _is_writable_path(rel):
		error_raised.emit("Refused unsafe file removal from host: %s" % str(payload.get("path", "")))
		return
	if _is_protected_scene(rel):
		return
	var root: String = str(_project_root.call())
	var absolute: String = CollabPathGuard.resolve_within(root, rel)
	if absolute.is_empty():
		error_raised.emit("Refused file removal that would escape the workspace: %s" % rel)
		return
	if FileAccess.file_exists(absolute):
		var err: Error = DirAccess.remove_absolute(absolute)
		if err != OK and err != ERR_FILE_NOT_FOUND:
			error_raised.emit("Could not remove '%s': %s" % [rel, error_string(err)])
			return
	_watch_baseline.erase(rel)
	_refresh_filesystem(rel)
	status.emit("Removed file '%s' from host." % rel)


func _apply_incoming_file(payload: Dictionary) -> void:
	var rel: String = CollabPathGuard.normalize_relative(str(payload.get("path", "")))
	if rel.is_empty() or not _is_writable_path(rel):
		error_raised.emit("Refused unsafe file from host: %s" % str(payload.get("path", "")))
		return
	if _is_protected_scene(rel):
		# Never overwrite an open scene's file underneath the editor; the
		# operation stream is already keeping its in-memory state in sync.
		return
	var data: Variant = payload.get("data", PackedByteArray())
	if typeof(data) != TYPE_PACKED_BYTE_ARRAY:
		return
	var bytes: PackedByteArray = data
	if bytes.size() > CollabConstants.MAX_WORKSPACE_FILE_BYTES:
		error_raised.emit("Refused oversized file from host: %s" % rel)
		return
	var root: String = str(_project_root.call())
	if not CollabPathGuard.no_symlink_escape(root, rel):
		error_raised.emit("Refused file that would escape the workspace: %s" % rel)
		return
	var absolute: String = CollabPathGuard.resolve_within(root, rel)
	if absolute.is_empty():
		error_raised.emit("Refused unsafe path from host: %s" % rel)
		return
	if not _ensure_parent_dir(absolute):
		error_raised.emit("Could not create directory for '%s'." % rel)
		return
	var file: FileAccess = FileAccess.open(absolute, FileAccess.WRITE)
	if file == null:
		error_raised.emit("Could not write '%s'." % rel)
		return
	file.store_buffer(bytes)
	file.close()
	_refresh_filesystem(rel)
	_refresh_baseline_entry(rel)
	status.emit("Applied file '%s' from host." % rel)


# ---------------------------------------------------------------------------
# Scene listing
# ---------------------------------------------------------------------------

func _scan_scenes() -> Array:
	var out: Array = []
	var root: String = str(_project_root.call())
	_scan_dir(root, "", out)
	out.sort()
	return out


func _scan_dir(absolute: String, rel_prefix: String, out: Array) -> void:
	if out.size() >= CollabConstants.MAX_SCENE_LIST:
		return
	var dir: DirAccess = DirAccess.open(absolute)
	if dir == null:
		return
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var rel: String = (rel_prefix + "/" + name) if not rel_prefix.is_empty() else name
		if dir.current_is_dir():
			if not EXCLUDED_PREFIXES.has(rel + "/"):
				_scan_dir(absolute.path_join(name), rel, out)
		elif name.ends_with(".tscn"):
			out.append("res://" + rel)
		name = dir.get_next()
	dir.list_dir_end()


func _send_scene_list_to(peer_id: int) -> void:
	var scenes: Array = _scan_scenes()
	_coordinator.send_workspace_to(peer_id, CollabProtocol.MessageType.SCENE_LIST, {
		"scenes": scenes,
		"revision": _host_revision,
	})


# ---------------------------------------------------------------------------
# Source-file sync (scripts, shaders, resources, project configuration)
# ---------------------------------------------------------------------------

## Records the current on-disk state as the baseline without syncing anything.
## Called when a session starts so pre-existing differences are not blasted at
## the host (project transfer / snapshots reconcile those instead).
func prime_file_baseline() -> void:
	_watch_baseline.clear()
	_watch_primed = false
	var root: String = str(_project_root.call())
	if root.is_empty():
		return
	var current: Dictionary = {}
	_walk_files(root, "", current)
	_watch_baseline = current
	_watch_primed = true
	status.emit("File sync baseline: %d source file(s)." % current.size())


## Scans tracked source files for local changes and relays them
## host-authoritatively. Host changes broadcast directly; client changes are
## submitted to the host as ADD_FILE requests.
func poll() -> void:
	if not file_sync_enabled or not enabled:
		return
	if _coordinator == null or not _coordinator.session_manager.is_active():
		return
	if _coordinator.workspace_mode == CollabConstants.WorkspaceMode.GIT_PRESENCE:
		return
	var now: int = Time.get_ticks_msec()
	if now - _watch_last_ms < FILESYNC_INTERVAL_MS:
		return
	_watch_last_ms = now
	_scan_and_sync()


func _scan_and_sync() -> void:
	var root: String = str(_project_root.call())
	if root.is_empty():
		return
	var current: Dictionary = {}
	_walk_files(root, "", current)
	# Additions/changes are relayed first so that when a file is renamed the new
	# name exists on every peer before the old name is removed. This keeps a
	# path-backed resource reference (sent by the operation stream) resolvable
	# throughout the rename instead of dangling.
	var seen: Dictionary = {}
	for rel in current.keys():
		var info: Dictionary = current[rel]
		var previous: Variant = _watch_baseline.get(rel)
		if previous == null:
			_watch_baseline[rel] = info
			if _watch_primed:
				_relay_local_change(rel, root)
			continue
		var prev: Dictionary = previous
		if int(prev.get("size", -1)) == int(info.get("size", -2)) and int(prev.get("mtime", -1)) == int(info.get("mtime", -2)):
			continue
		var digest: String = CollabIdentity.sha256_file(root.path_join(rel))
		info["sha"] = digest
		_watch_baseline[rel] = info
		if digest != str(prev.get("sha", "")):
			_relay_local_change(rel, root)
	# Removals: a file that was tracked but is now gone is either the source half
	# of a rename (handled as add + delete) or a genuine delete. Relay a delete so
	# the host does not keep a stale copy alongside the new file.
	for rel in _watch_baseline.keys():
		if not current.has(rel):
			seen[rel] = true
	for rel in seen.keys():
		_watch_baseline.erase(rel)
		if _watch_primed:
			_relay_local_removal(rel)
	_watch_primed = true


func _relay_local_change(rel: String, root: String) -> void:
	if not _is_filesync_path(rel):
		return
	if _is_protected_scene(rel):
		# Open scenes travel as structured operations; never ship the raw file.
		return
	if not _can_request():
		return
	var absolute: String = CollabPathGuard.resolve_within(root, rel)
	if absolute.is_empty():
		return
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(absolute)
	if bytes.is_empty() and not FileAccess.file_exists(absolute):
		return
	if bytes.size() > CollabConstants.MAX_WORKSPACE_FILE_BYTES:
		status.emit("Skipping '%s': exceeds the live-sync size limit." % rel)
		return
	if _coordinator.is_host():
		_host_add_file(_next_request_id(), rel, bytes, true, _coordinator.local_peer_id())
	else:
		# Send the exact bytes so binary assets (images, models, audio) survive;
		# a UTF-8 round trip would corrupt them.
		_coordinator.send_workspace(CollabProtocol.MessageType.WORKSPACE_REQUEST, {
			"request_id": _next_request_id(),
			"kind": CollabConstants.WorkspaceOp.ADD_FILE,
			"path": rel,
			"overwrite": true,
			"data": bytes,
		})
		status.emit("Synced '%s' to the host." % rel)


func _relay_local_removal(rel: String) -> void:
	if not _is_filesync_path(rel):
		return
	if _is_protected_scene(rel):
		# An open scene is owned by the operation stream; never delete its file.
		return
	if not _can_request():
		return
	if _coordinator.is_host():
		_host_delete_file(_next_request_id(), rel, _coordinator.local_peer_id())
	else:
		_coordinator.send_workspace(CollabProtocol.MessageType.WORKSPACE_REQUEST, {
			"request_id": _next_request_id(),
			"kind": CollabConstants.WorkspaceOp.DELETE_FILE,
			"path": rel,
		})
		status.emit("Requested deletion of '%s' on the host." % rel)


## Walks the project, collecting watched source files as rel -> {size, mtime, sha}.
func _walk_files(absolute: String, rel_prefix: String, out: Dictionary) -> void:
	if out.size() >= FILESYNC_MAX_FILES:
		return
	var dir: DirAccess = DirAccess.open(absolute)
	if dir == null:
		return
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if name.begins_with(".") and name != "." and name != "..":
			name = dir.get_next()
			continue
		var rel: String = (rel_prefix + "/" + name) if not rel_prefix.is_empty() else name
		var abs: String = absolute.path_join(name)
		if dir.current_is_dir():
			if not dir.is_link(name) and not _filesync_dir_excluded(rel):
				_walk_files(abs, rel, out)
		elif _is_filesync_path(rel):
			out[rel] = _file_stat(abs)
		name = dir.get_next()
	dir.list_dir_end()


func _filesync_dir_excluded(rel: String) -> bool:
	for prefix in FILESYNC_EXCLUDED_PREFIXES:
		if (rel + "/").begins_with(prefix):
			return true
	return false


func _is_filesync_path(rel: String) -> bool:
	return is_source_file(rel)


## True when [param rel] is a scene file that is currently open in the editor and
## must therefore be handled by the operation stream rather than as a raw file.
func _is_protected_scene(rel: String) -> bool:
	if not open_scene_paths.is_valid():
		return false
	var ext: String = "." + rel.get_extension().to_lower()
	if not SCENE_EXTENSIONS.has(ext):
		return false
	var res_path: String = rel if rel.begins_with("res://") else "res://" + rel
	var paths: Array = open_scene_paths.call()
	return paths.has(res_path)


## True when [param rel] is a project source file the watcher may relay. Excludes
## generated/vendor directories and, critically, [code]addons/[/code].
static func is_source_file(rel: String) -> bool:
	var normalized: String = CollabPathGuard.normalize_relative(rel)
	if normalized.is_empty():
		return false
	for prefix in FILESYNC_EXCLUDED_PREFIXES:
		if normalized.begins_with(prefix):
			return false
	if FILESYNC_FILES.has(normalized):
		return true
	var ext: String = "." + normalized.get_extension().to_lower()
	return FILESYNC_EXTENSIONS.has(ext)


## Relative paths currently tracked by the file watcher. Exposed for tests.
func watched_paths() -> Array:
	var out: Array = _watch_baseline.keys()
	out.sort()
	return out


func _file_stat(abs: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(abs, FileAccess.READ)
	var size: int = 0
	if file != null:
		size = file.get_length()
		file.close()
	return {"size": size, "mtime": FileAccess.get_modified_time(abs), "sha": ""}


## Updates the watcher baseline for [param rel] from its current on-disk state so
## writing a file (locally or from the host) never echoes back as a change.
func _refresh_baseline_entry(rel: String) -> void:
	if not file_sync_enabled:
		return
	var root: String = str(_project_root.call())
	if root.is_empty():
		return
	var absolute: String = CollabPathGuard.resolve_within(root, rel)
	if absolute.is_empty() or not FileAccess.file_exists(absolute):
		# The file is gone (applied removal or rename source). Erase the baseline
		# entry so the next scan does not replay the removal back at the host.
		_watch_baseline.erase(rel)
		return
	var info: Dictionary = _file_stat(absolute)
	info["sha"] = CollabIdentity.sha256_file(absolute)
	_watch_baseline[rel] = info


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _can_request() -> bool:
	if not enabled:
		return false
	if _coordinator == null or not _coordinator.session_manager.is_active():
		return false
	if _coordinator.workspace_mode == CollabConstants.WorkspaceMode.GIT_PRESENCE:
		return false
	if _settings != null and not _settings.get_bool(CollabSettings.KEY_ALLOW_WORKSPACE_AUTHORING, true):
		return false
	if not _coordinator.is_host() and not _coordinator.is_admitted(CollabSessionCoordinator.HOST_PEER_ID):
		return false
	return true


func _is_writable_path(rel: String) -> bool:
	for prefix in EXCLUDED_PREFIXES:
		if rel.begins_with(prefix):
			return false
	# Project configuration is host-authoritative and small enough to relay.
	if FILESYNC_FILES.has(rel):
		return true
	var ext: String = "." + rel.get_extension().to_lower()
	return CollabConstants.WRITABLE_EXTENSIONS.has(ext)


func _absolute(rel: String) -> String:
	if _project_root.is_valid():
		return CollabPathGuard.resolve_within(str(_project_root.call()), rel)
	return ""


func _ensure_parent_dir(absolute: String) -> bool:
	var parent: String = absolute.get_base_dir()
	if DirAccess.dir_exists_absolute(parent):
		return true
	return DirAccess.make_dir_recursive_absolute(parent) == OK


func _broadcast_file_apply(rel: String, bytes: PackedByteArray, is_scene: bool) -> void:
	if not _coordinator.is_host():
		return
	_coordinator.send_workspace(CollabProtocol.MessageType.FILE_APPLY, {
		"path": rel,
		"data": bytes,
		"scene": is_scene,
	})


func _broadcast_file_remove(rel: String) -> void:
	if not _coordinator.is_host():
		return
	_coordinator.send_workspace(CollabProtocol.MessageType.FILE_REMOVE, {
		"path": rel,
	})


func _send_result(peer_id: int, request_id: int, ok: bool, path: String, message: String) -> void:
	if not _coordinator.is_host():
		return
	# Local (host-originated) requests are never sent over the wire.
	if peer_id != 0 and peer_id != _coordinator.local_peer_id():
		_coordinator.send_workspace_to(peer_id, CollabProtocol.MessageType.WORKSPACE_RESULT, {
			"request_id": request_id,
			"ok": ok,
			"path": path,
			"message": message,
			"revision": _host_revision,
		})
	if ok:
		request_result.emit(request_id, true, path, message)
	else:
		request_result.emit(request_id, false, path, message)
		error_raised.emit(message)


func _revision_bump() -> void:
	_host_revision += 1


func _next_request_id() -> int:
	_request_counter += 1
	return _request_counter


func _refresh_filesystem(rel: String) -> void:
	if _editor.has("refresh_resource_file") and _editor["refresh_resource_file"].is_valid():
		_editor["refresh_resource_file"].call("res://" + rel if not rel.begins_with("res://") else rel)
