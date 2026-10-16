@tool
## Save coordination for the host-owned workspace.
##
## The host is the only peer that writes to disk. Clients send a
## [constant CollabProtocol.MessageType.SAVE_REQUEST] and receive a
## [constant CollabProtocol.MessageType.SAVE_RESULT]. Auto-save runs only after
## a period of inactivity so rapid edits do not thrash the disk.
class_name CollabSaveService
extends Node

signal saved(path: String)
signal save_failed(text: String)
signal status(text: String)

var _coordinator: CollabSessionCoordinator
var _settings: CollabSettings
var _logs: CollabLog
var _editor: Dictionary = {}
var _last_activity_ms: int = 0
var _save_status_cache: String = "No save yet."
var _last_saved_ms: int = 0
var _dirty_since_ms: int = -1
var _auto_save_enabled: bool = false
var _auto_save_delay: float = 8.0
var _last_save_status: String = "No save yet."

## Optional plugin hook invoked when a client asks the host to save. It should
## persist every scene holding remote edits and then save the active scene. When
## unset the service falls back to saving only the active scene.
var on_remote_save: Callable = Callable()


func setup(coordinator: CollabSessionCoordinator, settings: CollabSettings, logs: CollabLog, editor: Dictionary) -> void:
	_coordinator = coordinator
	_settings = settings
	_logs = logs
	_editor = editor
	coordinator.save_message.connect(_on_save_message)
	_apply_settings()


func _apply_settings() -> void:
	if _settings != null:
		_settings.get_bool(CollabSettings.KEY_AUTOSAVE, false)
		_auto_save_enabled = false # read fresh on each poll


func set_auto_save(enabled: bool) -> void:
	if _settings != null:
		_settings.set_value(CollabSettings.KEY_AUTOSAVE, enabled)


func set_autosave_delay(seconds: float) -> void:
	if _settings != null:
		_settings.set_value(CollabSettings.KEY_AUTOSAVE_DELAY, seconds)


func last_save_status() -> String:
	return _save_status_cache


func notify_activity() -> void:
	_last_activity_ms = Time.get_ticks_msec()


func poll() -> void:
	if _coordinator == null or not _coordinator.session_manager.is_active():
		return
	if _settings == null or not _settings.get_bool(CollabSettings.KEY_AUTOSAVE, false):
		return
	var now := Time.get_ticks_msec()
	var delay_ms: int = int(_settings.get_float(CollabSettings.KEY_AUTOSAVE_DELAY, 8.0) * 1000.0)
	if now - _last_activity_ms < delay_ms:
		return
	if not _coordinator.is_host():
		# Clients cannot save the host workspace; they may only request it.
		return
	if not _scene_is_dirty():
		return
	_last_activity_ms = now
	save_now()


## Host: saves the edited scene. Client: asks the host to save.
func save_now() -> void:
	if _coordinator == null or not _coordinator.session_manager.is_active():
		# Local-only save still allowed so users can commit before hosting.
		_do_save(true)
		return
	if _coordinator.is_host():
		_do_save(false)
	else:
		_coordinator.send_save(CollabProtocol.MessageType.SAVE_REQUEST, {})
		status.emit("Requested host to save the shared scene.")


func _do_save(_local: bool) -> void:
	if not _editor.has("save_scene") or not _editor["save_scene"].is_valid():
		_fail("Save API unavailable.")
		return
	var result: Variant = _editor["save_scene"].call()
	if typeof(result) != TYPE_INT or int(result) != OK:
		_fail("save_scene returned %s" % str(result))
		return
	var path: String = ""
	if _editor.has("get_edited_scene_path") and _editor["get_edited_scene_path"].is_valid():
		path = str(_editor["get_edited_scene_path"].call())
	_save_status_cache = "Last saved at %s to %s" % [Time.get_time_string_from_system(), path]
	saved.emit(path)
	status.emit("Shared scene saved (%s)." % path)
	if _coordinator != null and _coordinator.is_host():
		_coordinator.send_save(CollabProtocol.MessageType.SAVE_RESULT, {"ok": true, "path": path, "revision": 0})


func _fail(text: String) -> void:
	_save_status_cache = "Save failed: %s" % text
	save_failed.emit(text)
	status.emit("Save failed: %s" % text)
	if _coordinator != null and _coordinator.is_host():
		_coordinator.send_save(CollabProtocol.MessageType.SAVE_RESULT, {"ok": false, "message": text})


func _scene_is_dirty() -> bool:
	if not _editor.has("is_scene_modified") or not _editor["is_scene_modified"].is_valid():
		return true
	return bool(_editor["is_scene_modified"].call())


func _on_save_message(from_peer: int, type: int, payload: Dictionary) -> void:
	if type == CollabProtocol.MessageType.SAVE_REQUEST and _coordinator.is_host():
		if on_remote_save.is_valid():
			on_remote_save.call()
		else:
			_do_save(false)
	elif type == CollabProtocol.MessageType.SAVE_RESULT:
		var ok: bool = bool(payload.get("ok", false))
		if ok:
			_save_status_cache = "Host saved the shared scene to %s." % str(payload.get("path", ""))
			status.emit(_save_status_cache)
		else:
			_save_status_cache = "Host save failed: %s" % str(payload.get("message", ""))
			save_failed.emit(_save_status_cache)
