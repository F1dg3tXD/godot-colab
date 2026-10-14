@tool
## Presence service: captures the local 3D cursor, throttles/sends it, stores
## remote cursors and paints them onto the editor's 3D viewport overlay.
class_name CollabPresenceService
extends Node

signal status(text: String)

var cursor_state: CollabCursorState

var _coordinator: CollabSessionCoordinator
var _settings: CollabSettings
var _logs: CollabLog
var _last_send_ms: int = 0
var _visible: bool = true
var _show_labels: bool = true
var _marker_size: float = 8.0
var _local_scene_id: String = ""
var _local_has_cursor: bool = false
var _local_world: Vector3 = Vector3.ZERO
var _font: Font = null


func _init() -> void:
	cursor_state = CollabCursorState.new()


func setup(coordinator: CollabSessionCoordinator, settings: CollabSettings, logs: CollabLog) -> void:
	_coordinator = coordinator
	_settings = settings
	_logs = logs
	_apply_settings()
	coordinator.cursor_received.connect(_on_remote_cursor)
	coordinator.session_stopped.connect(_on_session_stopped)
	if _font == null:
		_font = ThemeDB.fallback_font


func _apply_settings() -> void:
	if _settings == null:
		return
	_show_labels = _settings.get_bool(CollabSettings.KEY_CURSOR_LABEL_KEY, true)
	_marker_size = _settings.get_float(CollabSettings.KEY_CURSOR_SIZE_KEY, 8.0)
	cursor_state.set_marker_depth(_settings.get_float(CollabSettings.KEY_CURSOR_DEPTH_KEY, 12.0))


func set_local_scene_id(scene_id: String) -> void:
	_local_scene_id = scene_id


func set_visible(visible: bool) -> void:
	_visible = visible


func set_show_labels(show: bool) -> void:
	_show_labels = show


func set_marker_size(size: float) -> void:
	_marker_size = size


func set_marker_depth(depth: float) -> void:
	cursor_state.set_marker_depth(depth)


func local_world_position() -> Vector3:
	return _local_world


# --- local capture --------------------------------------------------------

## Called by the plugin from _forward_3d_gui_input on mouse motion.
func sample_local_cursor(camera: Camera3D, mouse_pos: Vector2, viewport_size: Vector2, scene_id: String) -> void:
	if camera == null:
		return
	var origin: Vector3 = camera.project_ray_origin(mouse_pos)
	var direction: Vector3 = camera.project_ray_normal(mouse_pos)
	var normalized: Vector2 = Vector2(
		clampf(mouse_pos.x / maxf(1.0, viewport_size.x), 0.0, 1.0),
		clampf(mouse_pos.y / maxf(1.0, viewport_size.y), 0.0, 1.0)
	)
	_local_world = origin + direction.normalized() * cursor_state.marker_depth
	_local_has_cursor = true
	_local_scene_id = scene_id
	if _coordinator == null or not _coordinator.session_manager.is_active():
		return
	var now: int = Time.get_ticks_msec()
	var interval_ms: int = int(1000.0 / CollabConstants.CURSOR_SEND_HZ)
	if now - _last_send_ms < interval_ms:
		return
	_last_send_ms = now
	_coordinator.send_cursor({
		"camera_transform": camera.global_transform,
		"ray_origin": origin,
		"ray_direction": direction,
		"viewport_pos": normalized,
		"scene_id": scene_id,
		"time_ms": now,
	})


func _on_remote_cursor(peer_id: int, payload: Dictionary) -> void:
	if _coordinator == null or peer_id == _coordinator.local_peer_id():
		return
	var origin: Variant = payload.get("ray_origin", null)
	var direction: Variant = payload.get("ray_direction", null)
	if typeof(origin) != TYPE_VECTOR3 or typeof(direction) != TYPE_VECTOR3:
		return
	var camera_transform: Transform3D = Transform3D.IDENTITY
	var ct: Variant = payload.get("camera_transform", null)
	if typeof(ct) == TYPE_TRANSFORM3D:
		camera_transform = ct
	var vp: Variant = payload.get("viewport_pos", Vector2(0.5, 0.5))
	var viewport_pos: Vector2 = vp if typeof(vp) == TYPE_VECTOR2 else Vector2(0.5, 0.5)
	cursor_state.update(peer_id, camera_transform, origin, direction, viewport_pos, str(payload.get("scene_id", "")))


func _on_session_stopped(_reason: String) -> void:
	cursor_state.clear()
	_local_has_cursor = false


# --- drawing --------------------------------------------------------------

## Paints remote cursors. [param overlay] is the control provided by
## EditorPlugin._forward_3d_draw_over_viewport.
func draw_overlay(overlay: Control) -> void:
	if not _visible or _coordinator == null or not _coordinator.session_manager.is_active():
		return
	var viewport_3d: SubViewport = _editor_viewport_3d()
	if viewport_3d == null:
		return
	var camera: Camera3D = viewport_3d.get_camera_3d()
	if camera == null:
		return
	var now: int = Time.get_ticks_msec()
	for participant in _coordinator.registry.all():
		if participant.peer_id == _coordinator.local_peer_id():
			continue
		if not cursor_state.has(participant.peer_id):
			continue
		if cursor_state.is_stale(participant.peer_id, now):
			continue
		var remote_scene: String = cursor_state.scene_id(participant.peer_id)
		if not remote_scene.is_empty() and not _local_scene_id.is_empty() and remote_scene != _local_scene_id:
			continue
		var world: Vector3 = cursor_state.world_position(participant.peer_id, now)
		if camera.is_position_behind(world):
			continue
		var screen: Vector2 = camera.unproject_position(world)
		if screen.x < 0.0 or screen.y < 0.0 or screen.x > overlay.size.x or screen.y > overlay.size.y:
			continue
		_draw_marker(overlay, screen, participant.color(), participant.display_name())


func _draw_marker(overlay: Control, screen: Vector2, color: Color, label: String) -> void:
	var radius: float = _marker_size
	overlay.draw_circle(screen, radius + 2.0, Color(0, 0, 0, 0.65))
	overlay.draw_circle(screen, radius, Color(color.r, color.g, color.b, 0.35))
	overlay.draw_arc(screen, radius, 0.0, TAU, 32, color, 2.0, true)
	overlay.draw_line(screen + Vector2(-radius - 4.0, 0.0), screen + Vector2(radius + 4.0, 0.0), color, 1.0)
	overlay.draw_line(screen + Vector2(0.0, -radius - 4.0), screen + Vector2(0.0, radius + 4.0), color, 1.0)
	if _show_labels and _font != null:
		overlay.draw_string(_font, screen + Vector2(radius + 6.0, -radius), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)


func _editor_viewport_3d() -> SubViewport:
	var editor_interface: EditorInterface = _get_editor_interface()
	if editor_interface == null:
		return null
	return editor_interface.get_editor_viewport_3d()


var _editor_interface_provider: Callable = Callable()


func set_editor_interface_provider(provider: Callable) -> void:
	_editor_interface_provider = provider


func _get_editor_interface() -> EditorInterface:
	if _editor_interface_provider.is_valid():
		return _editor_interface_provider.call()
	return null
