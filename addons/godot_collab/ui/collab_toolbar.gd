@tool
## Top-toolbar controls for the Godot Collab add-on.
##
## Presentation only: it emits intent signals and renders state pushed by the
## plugin. The session inputs (username, port, mode, invitation code) still live
## in the dock; the toolbar buttons drive those actions so a running session can
## be started, joined, snapshotted, shared and stopped without opening the dock.
class_name CollabToolbar
extends HBoxContainer

signal host_requested()
signal join_requested()
## Paste an invitation code from the clipboard and join in one action.
signal paste_join_requested()
signal copy_requested()
signal snapshot_requested()
signal disconnect_requested()

var _host_button: Button
var _join_button: Button
var _paste_join_button: Button
var _copy_button: Button
var _snapshot_button: Button
var _disconnect_button: Button
var _session_active: bool = false
var _invite_available: bool = false


func _init() -> void:
	name = "GodotCollabToolbar"
	add_theme_constant_override("separation", 4)
	tooltip_text = "Godot Collab"

	_host_button = _make_button("Host", "Start hosting a collaborative session using the dock's settings.", func() -> void: host_requested.emit())
	_join_button = _make_button("Join", "Join a session using the invitation code entered in the dock.", func() -> void: join_requested.emit())
	_paste_join_button = _make_button("Paste & Join", "Paste an invitation code from the clipboard and join the session.", func() -> void: paste_join_requested.emit())
	add_child(VSeparator.new())
	_copy_button = _make_button("Copy Code", "Copy the current invitation code to the clipboard.", func() -> void: copy_requested.emit())
	_snapshot_button = _make_button("Request Snapshot", "Ask the host for a fresh authoritative snapshot of the current scene.", func() -> void: snapshot_requested.emit())
	_disconnect_button = _make_button("Disconnect", "Leave the current collaboration session.", func() -> void: disconnect_requested.emit())
	_refresh()


func _make_button(text: String, tip: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tip
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(handler)
	add_child(button)
	return button


## Enables/disables the session-scoped buttons for the current connection state.
func set_session_active(active: bool) -> void:
	_session_active = active
	_refresh()


## Enables the "Copy Code" button when an invitation code has been generated.
func set_invite_available(available: bool) -> void:
	_invite_available = available
	_refresh()


func _refresh() -> void:
	if _host_button == null:
		return
	_host_button.disabled = _session_active
	_join_button.disabled = _session_active
	_paste_join_button.disabled = _session_active
	_disconnect_button.disabled = not _session_active
	_snapshot_button.disabled = not _session_active
	_copy_button.disabled = not _invite_available
