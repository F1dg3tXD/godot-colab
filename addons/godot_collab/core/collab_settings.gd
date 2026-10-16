@tool
## Persisted user preferences for the add-on.
##
## Values live in [EditorSettings] (per-user, never committed to the project),
## so session secrets and usernames never end up in project files. When no
## [EditorSettings] instance is available (headless tests, early boot) an
## in-memory fallback is used so the class stays usable everywhere.
class_name CollabSettings
extends RefCounted

const SETTING_ROOT: String = "godot_collab"

const KEY_USERNAME: String = SETTING_ROOT + "/identity/username"
const KEY_AUTO_CONNECT_LAST: String = SETTING_ROOT + "/identity/auto_connect_last"
const KEY_PORT: String = SETTING_ROOT + "/network/udp_port"
const KEY_MAX_PEERS: String = SETTING_ROOT + "/network/max_peers"
const KEY_RENDEZVOUS_URL: String = SETTING_ROOT + "/network/rendezvous_url"
const KEY_DIRECT_ADVERTISE_HOST: String = SETTING_ROOT + "/network/advertise_host"
const KEY_ENABLE_UPNP: String = SETTING_ROOT + "/network/enable_upnp"
const KEY_CURSOR_LABEL_KEY: String = SETTING_ROOT + "/cursors/show_labels"
const KEY_CURSOR_SIZE_KEY: String = SETTING_ROOT + "/cursors/marker_size"
const KEY_CURSOR_DEPTH_KEY: String = SETTING_ROOT + "/cursors/marker_depth"
const KEY_CURSOR_3D_MARKERS: String = SETTING_ROOT + "/cursors/show_3d_markers"
const KEY_CURSOR_3D_SCALE: String = SETTING_ROOT + "/cursors/marker_3d_scale"
const KEY_AUTOSAVE: String = SETTING_ROOT + "/saving/auto_save"
const KEY_AUTOSAVE_DELAY: String = SETTING_ROOT + "/saving/auto_save_delay"
const KEY_AUTO_APPLY_SNAPSHOT: String = SETTING_ROOT + "/collaboration/auto_apply_snapshot"
const KEY_TRANSFER_DIR: String = SETTING_ROOT + "/transfer/download_dir"
const KEY_MAX_FILE_MB: String = SETTING_ROOT + "/transfer/max_file_mb"
const KEY_MAX_TOTAL_MB: String = SETTING_ROOT + "/transfer/max_total_mb"
const KEY_APPROVE_JOINS: String = SETTING_ROOT + "/security/approve_joins"
const KEY_REQUIRE_TOKEN: String = SETTING_ROOT + "/security/require_invite_token"
const KEY_ALLOW_WORKSPACE_AUTHORING: String = SETTING_ROOT + "/collaboration/allow_workspace_authoring"
const KEY_FILE_SYNC: String = SETTING_ROOT + "/collaboration/sync_source_files"

var _settings: Object = null # EditorSettings when available, else null.
var _memory: Dictionary = {}


func _init(editor_settings: Object = null) -> void:
	_settings = editor_settings


## Registers defaults and property hints. Safe to call multiple times.
func register_defaults() -> void:
	if _settings == null:
		return
	_register(KEY_USERNAME, "", TYPE_STRING, "Your display name shown to other collaborators.")
	_register(KEY_AUTO_CONNECT_LAST, false, TYPE_BOOL, "Reconnect to the last session on editor start.")
	_register(KEY_PORT, CollabConstants.DEFAULT_PORT, TYPE_INT, "UDP port used when hosting.")
	_register(KEY_MAX_PEERS, CollabConstants.DEFAULT_MAX_PEERS, TYPE_INT, "Maximum number of remote peers.", 1, 64)
	_register(KEY_RENDEZVOUS_URL, CollabConstants.DEFAULT_RENDEZVOUS_URL, TYPE_STRING, "Rendezvous service used to resolve invitation codes.")
	_register(KEY_DIRECT_ADVERTISE_HOST, "", TYPE_STRING, "Public IP/hostname advertised in invitation codes (blank = auto).")
	_register(KEY_ENABLE_UPNP, false, TYPE_BOOL, "Attempt automatic UPnP UDP port forwarding when hosting.")
	_register(KEY_CURSOR_LABEL_KEY, true, TYPE_BOOL, "Draw usernames next to remote cursors.")
	_register(KEY_CURSOR_SIZE_KEY, 8.0, TYPE_FLOAT, "Remote cursor marker size in pixels.", 2.0, 64.0)
	_register(KEY_CURSOR_DEPTH_KEY, 12.0, TYPE_FLOAT, "Distance along the remote camera ray (world units) at which the marker is drawn.", 0.1, 500.0)
	_register(KEY_CURSOR_3D_MARKERS, true, TYPE_BOOL, "Show a live 3D marker for each remote participant in the editor viewport.")
	_register(KEY_CURSOR_3D_SCALE, 1.0, TYPE_FLOAT, "Scale of the remote participant 3D markers.", 0.1, 20.0)
	_register(KEY_AUTOSAVE, false, TYPE_BOOL, "Automatically save the shared scene after inactivity.")
	_register(KEY_AUTOSAVE_DELAY, 8.0, TYPE_FLOAT, "Seconds of inactivity before auto-saving the shared scene.", 2.0, 120.0)
	_register(KEY_AUTO_APPLY_SNAPSHOT, true, TYPE_BOOL, "Automatically mirror the host scene when joining a host-workspace session.")
	_register(KEY_TRANSFER_DIR, "", TYPE_STRING, "Directory used for downloaded project snapshots.")
	_register(KEY_MAX_FILE_MB, 64, TYPE_INT, "Maximum size of a single transferred file (MiB).", 1, 4096)
	_register(KEY_MAX_TOTAL_MB, 512, TYPE_INT, "Maximum total size of a project download (MiB).", 1, 32768)
	_register(KEY_APPROVE_JOINS, false, TYPE_BOOL, "Require the host to approve each participant before granting workspace access. Off by default; enable for untrusted networks.")
	_register(KEY_REQUIRE_TOKEN, true, TYPE_BOOL, "Require the session token embedded in the invitation code. Disable only for trusted LAN testing.")
	_register(KEY_ALLOW_WORKSPACE_AUTHORING, true, TYPE_BOOL, "Allow collaborators to create scenes and add files to the host workspace.")
	_register(KEY_FILE_SYNC, true, TYPE_BOOL, "Relay source-file changes (scripts, shaders, resources, project.godot) to the host. Files under addons/ are never synced.")


func get_string(key: String, default: String = "") -> String:
	return get_value(key, default) as String


func get_int(key: String, default: int = 0) -> int:
	return int(get_value(key, default))


func get_float(key: String, default: float = 0.0) -> float:
	return float(get_value(key, default))


func get_bool(key: String, default: bool = false) -> bool:
	return bool(get_value(key, default))


func get_value(key: String, default: Variant) -> Variant:
	if _settings != null and _settings.has_setting(key):
		return _settings.get_setting(key)
	if _memory.has(key):
		return _memory[key]
	return default


func set_value(key: String, value: Variant) -> void:
	if _settings != null:
		_settings.set_setting(key, value)
	else:
		_memory[key] = value


func _register(key: String, default: Variant, type: int, hint: String, min_value: Variant = null, max_value: Variant = null) -> void:
	if not _settings.has_setting(key):
		_settings.set_setting(key, default)
	var info: Dictionary = {"name": key, "type": type, "hint_string": ""}
	if type == TYPE_INT and min_value != null and max_value != null:
		info["hint"] = PROPERTY_HINT_RANGE
		info["hint_string"] = "%d,%d,1" % [int(min_value), int(max_value)]
	elif type == TYPE_FLOAT and min_value != null and max_value != null:
		info["hint"] = PROPERTY_HINT_RANGE
		info["hint_string"] = "%s,%s,0.1" % [str(min_value), str(max_value)]
	_settings.add_property_info(info)
