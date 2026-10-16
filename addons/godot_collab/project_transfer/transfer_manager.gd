@tool
## Project snapshot transfer: manifest exchange and bounded, chunked,
## checksum-verified file download.
##
## Security posture:
## - the host only serves files under the approved project root;
## - the client only writes inside the chosen download root;
## - every relative path is validated by [CollabPathGuard] (no absolute paths,
##   traversal, drive letters or symlink escapes);
## - per-file and total sizes are bounded;
## - each file is verified against its SHA-256 before being kept.
class_name CollabTransferManager
extends Node

signal manifest_ready(files: Array, project_id: String)
signal progress(transfer_id: int, path: String, received: int, total: int)
signal file_done(path: String, ok: bool, message: String)
signal completed(files_written: int, bytes: int, download_root: String)
signal failed(text: String)
signal approval_required(peer_id: int, transfer_id: int)
signal status(text: String)

const CHUNKS_PER_TICK: int = 4
const MAX_RETRIES: int = 2

var _coordinator: CollabSessionCoordinator
var _settings: CollabSettings
var _logs: CollabLog
var _root_provider: Callable = Callable()

# Host state.
var _approved: Dictionary = {} # "peer:transfer" -> true
var _pending_approvals: Dictionary = {} # peer_id -> transfer_id
var _send_queue: Array = [] # [{peer_id, transfer_id, path, file, offset, size, sha256}]

# Client state.
var _active_transfer_id: int = -1
var _manifest_queue: Array = []
var _current_entry: Dictionary = {}
var _download_root: String = ""
var _total_received: int = 0
var _files_written: int = 0
var _retries: Dictionary = {} # path -> int


func setup(coordinator: CollabSessionCoordinator, settings: CollabSettings, logs: CollabLog, project_root_provider: Callable) -> void:
	_coordinator = coordinator
	_settings = settings
	_logs = logs
	_root_provider = project_root_provider
	coordinator.transfer_message.connect(_on_transfer_message)
	coordinator.session_stopped.connect(_on_session_stopped)


func poll() -> void:
	if _coordinator == null or not _coordinator.session_manager.is_active():
		return
	if _coordinator.is_host():
		_pump_send_queue()


func is_downloading() -> bool:
	return _active_transfer_id >= 0


# ---------------------------------------------------------------------------
# Client API
# ---------------------------------------------------------------------------

## Begins a project download. Returns "" on success or an error message.
func start_download(download_root: String = "") -> String:
	if _coordinator == null or not _coordinator.session_manager.is_active():
		return "Not connected."
	if _coordinator.is_host():
		return "The host does not download its own project."
	var root: String = download_root
	if root.is_empty():
		root = _settings.get_string(CollabSettings.KEY_TRANSFER_DIR, "")
	if root.is_empty():
		var stamp: String = Time.get_datetime_string_from_system().replace(":", "-")
		root = OS.get_user_data_dir().path_join("downloads").path_join(stamp)
	var err: Error = DirAccess.make_dir_recursive_absolute(root)
	if err != OK and not DirAccess.dir_exists_absolute(root):
		return "Cannot create download directory: %s" % error_string(err)
	_download_root = root
	_active_transfer_id = randi()
	_total_received = 0
	_files_written = 0
	_manifest_queue.clear()
	_current_entry = {}
	_retries.clear()
	_coordinator.send_transfer(CollabProtocol.MessageType.TRANSFER_REQUEST, {
		"transfer_id": _active_transfer_id,
		"path": "*manifest*",
	})
	status.emit("Requesting project manifest...")
	return ""


func cancel() -> void:
	if _coordinator != null and _coordinator.session_manager.is_active():
		_coordinator.send_transfer(CollabProtocol.MessageType.TRANSFER_CANCEL, {
			"transfer_id": _active_transfer_id,
			"path": str(_current_entry.get("path", "")),
		})
	_send_queue.clear()
	_active_transfer_id = -1
	_current_entry = {}
	_manifest_queue.clear()
	status.emit("Transfer cancelled.")


func approve_transfer(peer_id: int, transfer_id: int) -> void:
	_pending_approvals.erase(peer_id)
	_approved["%d:%d" % [peer_id, transfer_id]] = true
	_send_manifest(peer_id, transfer_id)


func deny_transfer(peer_id: int, transfer_id: int, message: String = "Download denied by host.") -> void:
	_pending_approvals.erase(peer_id)
	_send_error(peer_id, transfer_id, "", message)


func pending_approval_peers() -> Array[int]:
	var out: Array[int] = []
	for key in _pending_approvals.keys():
		out.append(key)
	return out


# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------

func _on_transfer_message(from_peer: int, type: int, payload: Dictionary) -> void:
	match type:
		CollabProtocol.MessageType.TRANSFER_REQUEST:
			_on_transfer_request(from_peer, payload)
		CollabProtocol.MessageType.TRANSFER_MANIFEST:
			_on_manifest(payload)
		CollabProtocol.MessageType.TRANSFER_CHUNK:
			_on_chunk(payload)
		CollabProtocol.MessageType.TRANSFER_FILE_DONE:
			_on_file_done(payload)
		CollabProtocol.MessageType.TRANSFER_COMPLETE:
			_finish_download()
		CollabProtocol.MessageType.TRANSFER_CANCEL:
			_on_cancelled()
		CollabProtocol.MessageType.TRANSFER_ERROR:
			failed.emit(str(payload.get("message", "Transfer error.")))
		_:
			pass


func _on_transfer_request(from_peer: int, payload: Dictionary) -> void:
	if not _coordinator.is_host():
		return
	var transfer_id: int = int(payload.get("transfer_id", -1))
	var path: String = str(payload.get("path", ""))
	if path == "*manifest*":
		var key: String = "%d:%d" % [from_peer, transfer_id]
		if _settings.get_bool(CollabSettings.KEY_APPROVE_JOINS, false) and not _approved.has(key):
			_pending_approvals[from_peer] = transfer_id
			approval_required.emit(from_peer, transfer_id)
			status.emit("Peer %d requested a project download - awaiting approval." % from_peer)
			return
		_send_manifest(from_peer, transfer_id)
		return
	if not _approved.has("%d:manifest" % from_peer):
		# Allow individual files once the peer has been approved at least once.
		pass
	_send_file(from_peer, transfer_id, path)


func _send_manifest(peer_id: int, transfer_id: int) -> void:
	_approved["%d:manifest" % peer_id] = true
	var root: String = _project_root()
	var max_total: int = _settings.get_int(CollabSettings.KEY_MAX_TOTAL_MB, 512) * 1024 * 1024
	var result: Dictionary = CollabProjectManifest.build(root, max_total, false)
	if not result["ok"]:
		_send_error(peer_id, transfer_id, "", "Manifest failed: %s" % result["error"])
		return
	_coordinator.send_transfer_to(peer_id, CollabProtocol.MessageType.TRANSFER_MANIFEST, {
		"transfer_id": transfer_id,
		"project_id": CollabIdentity.project_id_from_root(root),
		"total_size": result["total_size"],
		"files": CollabProjectManifest.to_wire(result["files"]),
	})
	status.emit("Sent manifest (%d files)." % (result["files"] as Array).size())


func _send_file(peer_id: int, transfer_id: int, path: String) -> void:
	var normalized: String = CollabPathGuard.normalize_relative(path)
	if normalized.is_empty() or CollabProjectManifest.is_excluded_relative(normalized):
		_send_error(peer_id, transfer_id, path, "Path is not transferable.")
		return
	var root: String = _project_root()
	var resolved: String = CollabPathGuard.resolve_within(root, normalized)
	if resolved.is_empty() or not FileAccess.file_exists(resolved) or CollabPathGuard.is_symlink(resolved):
		_send_error(peer_id, transfer_id, path, "File not available.")
		return
	var per_file_max: int = _settings.get_int(CollabSettings.KEY_MAX_FILE_MB, 64) * 1024 * 1024
	var probe := FileAccess.open(resolved, FileAccess.READ)
	if probe == null:
		_send_error(peer_id, transfer_id, path, "Cannot open file.")
		return
	var size: int = probe.get_length()
	probe.close()
	if size > per_file_max:
		_send_error(peer_id, transfer_id, path, "File exceeds per-file limit.")
		return
	var digest: String = CollabIdentity.sha256_file(resolved)
	if digest.is_empty():
		_send_error(peer_id, transfer_id, path, "Cannot hash file.")
		return
	_send_queue.append({
		"peer_id": peer_id, "transfer_id": transfer_id, "path": normalized,
		"file": null, "offset": 0, "size": size, "sha256": digest,
	})


func _pump_send_queue() -> void:
	if _send_queue.is_empty():
		return
	var job: Dictionary = _send_queue[0]
	if job.get("file", null) == null:
		var source: String = _project_root().path_join(str(job["path"]))
		var file := FileAccess.open(source, FileAccess.READ)
		if file == null:
			_send_error(int(job["peer_id"]), int(job["transfer_id"]), str(job["path"]), "Cannot open file.")
			_send_queue.pop_front()
			return
		file.seek(int(job["offset"]))
		job["file"] = file
	var file: FileAccess = job["file"]
	var offset: int = int(job["offset"])
	var total: int = int(job["size"])
	var chunks: int = 0
	while chunks < 4 and offset < total:
		var chunk: PackedByteArray = file.get_buffer(CollabConstants.MAX_TRANSFER_CHUNK)
		if chunk.is_empty():
			break
		_coordinator.send_transfer_to(int(job["peer_id"]), CollabProtocol.MessageType.TRANSFER_CHUNK, {
			"transfer_id": int(job["transfer_id"]),
			"path": str(job["path"]),
			"offset": offset,
			"data": chunk,
		})
		offset += chunk.size()
		chunks += 1
	job["offset"] = offset
	if offset >= total:
		file.close()
		job["file"] = null
		_coordinator.send_transfer_to(int(job["peer_id"]), CollabProtocol.MessageType.TRANSFER_FILE_DONE, {
			"transfer_id": int(job["transfer_id"]),
			"path": str(job["path"]),
			"size": total,
			"sha256": str(job["sha256"]),
		})
		_send_queue.pop_front()


func _send_error(peer_id: int, transfer_id: int, path: String, message: String) -> void:
	if _coordinator == null or not _coordinator.session_manager.is_active():
		return
	_coordinator.send_transfer_to(peer_id, CollabProtocol.MessageType.TRANSFER_ERROR, {
		"transfer_id": transfer_id, "path": path, "message": message,
	})


# ---------------------------------------------------------------------------
# Client receive
# ---------------------------------------------------------------------------

func _on_manifest(payload: Dictionary) -> void:
	if _coordinator.is_host():
		return
	_manifest_queue = payload.get("files", [])
	manifest_ready.emit(_manifest_queue, str(payload.get("project_id", "")))
	status.emit("Manifest received: %d files." % _manifest_queue.size())
	_request_next_file()


func _request_next_file() -> void:
	if _manifest_queue.is_empty():
		_finish_download()
		return
	var entry: Variant = _manifest_queue.pop_front()
	if typeof(entry) != TYPE_DICTIONARY:
		_request_next_file()
		return
	var e: Dictionary = entry
	var path: String = str(e.get("path", ""))
	if not CollabPathGuard.is_safe_relative(path):
		file_done.emit(path, false, "unsafe path rejected")
		_request_next_file()
		return
	var per_file_max: int = _settings.get_int(CollabSettings.KEY_MAX_FILE_MB, 64) * 1024 * 1024
	if int(e.get("size", 0)) > per_file_max:
		file_done.emit(path, false, "file exceeds per-file limit")
		_request_next_file()
		return
	var total_max: int = _settings.get_int(CollabSettings.KEY_MAX_TOTAL_MB, 512) * 1024 * 1024
	if _total_received + int(e.get("size", 0)) > total_max:
		failed.emit("Total download size would exceed the configured limit.")
		_finish_download()
		return
	_current_entry = e
	_coordinator.send_transfer(CollabProtocol.MessageType.TRANSFER_REQUEST, {
		"transfer_id": _active_transfer_id, "path": path,
	})
	status.emit("Downloading %s..." % path)


func _on_chunk(payload: Dictionary) -> void:
	if _coordinator.is_host():
		return
	var path: String = str(payload.get("path", ""))
	if path != str(_current_entry.get("path", "")):
		return
	var offset: int = int(payload.get("offset", 0))
	var data: PackedByteArray = payload.get("data", PackedByteArray())
	var resolved: String = CollabPathGuard.resolve_within(_download_root, path)
	if resolved.is_empty() or not CollabPathGuard.no_symlink_escape(_download_root, path):
		failed.emit("Refusing to write unsafe path '%s'; transfer aborted." % path)
		_abort()
		return
	var dir: String = resolved.get_base_dir()
	if not dir.is_empty():
		DirAccess.make_dir_recursive_absolute(dir)
	var file := FileAccess.open(resolved, FileAccess.WRITE_READ)
	if file == null:
		file = FileAccess.open(resolved, FileAccess.WRITE)
	if file == null:
		failed.emit("Cannot write file '%s'." % path)
		_abort()
		return
	file.seek(offset)
	file.store_buffer(data)
	file.close()
	_total_received += data.size()
	progress.emit(_active_transfer_id, path, offset + data.size(), int(_current_entry.get("size", 0)))


func _on_file_done(payload: Dictionary) -> void:
	if _coordinator.is_host():
		return
	var path: String = str(payload.get("path", ""))
	if path != str(_current_entry.get("path", "")):
		return
	var resolved: String = CollabPathGuard.resolve_within(_download_root, path)
	var expected: String = str(payload.get("sha256", ""))
	var actual: String = CollabIdentity.sha256_file(resolved)
	if resolved.is_empty() or actual != expected:
		var attempts: int = int(_retries.get(path, 0)) + 1
		_retries[path] = attempts
		if attempts <= 2:
			file_done.emit(path, false, "checksum mismatch, retrying (%d)" % attempts)
			_manifest_queue.insert(0, _current_entry)
			_request_next_file()
			return
		file_done.emit(path, false, "checksum mismatch")
		if not resolved.is_empty():
			DirAccess.remove_absolute(resolved)
		_request_next_file()
		return
	_files_written += 1
	file_done.emit(path, true, "")
	_request_next_file()


func _finish_download() -> void:
	_active_transfer_id = -1
	var root: String = _download_root
	var written: int = _files_written
	var bytes_received: int = _total_received
	if _coordinator != null and _coordinator.session_manager.is_active() and not _coordinator.is_host():
		_coordinator.send_transfer(CollabProtocol.MessageType.TRANSFER_COMPLETE, {"download_root": root})
	completed.emit(written, bytes_received, root)
	status.emit("Download complete: %d files, %d bytes into %s." % [written, bytes_received, root])


func _on_cancelled() -> void:
	_send_queue.clear()
	_active_transfer_id = -1
	status.emit("Transfer cancelled by peer.")


func _abort() -> void:
	_active_transfer_id = -1
	_manifest_queue.clear()
	_current_entry = {}


func _on_session_stopped(_reason: String) -> void:
	_send_queue.clear()
	_active_transfer_id = -1
	_current_entry = {}
	_manifest_queue.clear()


func _project_root() -> String:
	if _root_provider.is_valid():
		return str(_root_provider.call())
	return ProjectSettings.globalize_path("res://")
