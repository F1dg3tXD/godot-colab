@tool
## Spawns and drives a live [CollabUserMarker] in the editor's 3D viewport for
## every remote participant, so each peer sees the others moving in real time.
##
## Markers are parented to the editor's 3D viewport (not the edited scene), so
## they share the edited scene's [World3D] while never being serialised into the
## scene, never appearing in the Scene dock and never marking the scene dirty.
## Positions come from [CollabCursorState]'s interpolated world ray point, so the
## markers move as smoothly as the 2D overlay cursors.
class_name CollabMarkerManager
extends Node

const MARKER_SCENE_PATH: String = "res://addons/godot_collab/assets/editorNodeVis.tscn"
const CONTAINER_NAME: String = "CollabUserMarkers"

var _coordinator: CollabSessionCoordinator
var _settings: CollabSettings
var _logs: CollabLog
var _cursor_state: CollabCursorState
var _viewport_provider: Callable = Callable()
var _marker_scene: PackedScene

var _container: Node3D = null
var _markers: Dictionary = {} # peer_id:int -> CollabUserMarker
var _enabled: bool = true
var _show_labels: bool = true
var _marker_scale: float = 1.0
var _local_scene_id: String = ""


func setup(coordinator: CollabSessionCoordinator, settings: CollabSettings, logs: CollabLog, cursor_state: CollabCursorState) -> void:
	_coordinator = coordinator
	_settings = settings
	_logs = logs
	_cursor_state = cursor_state
	if _marker_scene == null:
		_marker_scene = load(MARKER_SCENE_PATH) as PackedScene
	_apply_settings()
	coordinator.session_stopped.connect(_on_session_stopped)
	coordinator.participants_changed.connect(_reap)


func set_viewport_provider(provider: Callable) -> void:
	_viewport_provider = provider


func set_local_scene_id(scene_id: String) -> void:
	_local_scene_id = scene_id


func _apply_settings() -> void:
	if _settings == null:
		return
	_enabled = _settings.get_bool(CollabSettings.KEY_CURSOR_3D_MARKERS, true)
	_show_labels = _settings.get_bool(CollabSettings.KEY_CURSOR_LABEL_KEY, true)
	_marker_scale = _settings.get_float(CollabSettings.KEY_CURSOR_3D_SCALE, 1.0)


## Called every frame by the plugin while a session is active.
func poll() -> void:
	if not _enabled:
		if not _markers.is_empty():
			_clear()
		return
	if _coordinator == null or not _coordinator.session_manager.is_active():
		return
	var container: Node3D = _ensure_container()
	if container == null:
		return
	var now: int = Time.get_ticks_msec()
	var local_id: int = _coordinator.local_peer_id()
	var seen: Dictionary = {}
	for participant in _coordinator.registry.all():
		var peer_id: int = participant.peer_id
		if peer_id == local_id:
			continue
		if not _cursor_state.has(peer_id) or _cursor_state.is_stale(peer_id, now):
			continue
		var remote_scene: String = _cursor_state.scene_id(peer_id)
		if not remote_scene.is_empty() and not _local_scene_id.is_empty() and remote_scene != _local_scene_id:
			continue
		seen[peer_id] = true
		var marker: CollabUserMarker = _marker_for(container, peer_id)
		if marker == null:
			continue
		marker.position = _cursor_state.world_position(peer_id, now)
		marker.set_from_camera(_cursor_state.camera_transform(peer_id))
		var wanted_scale: Vector3 = Vector3.ONE * _marker_scale
		if not marker.scale.is_equal_approx(wanted_scale):
			marker.scale = wanted_scale
		var display: String = participant.display_name()
		if marker.username != display:
			marker.username = display
		var tint: Color = participant.color()
		if not marker.marker_color.is_equal_approx(tint):
			marker.marker_color = tint
		if marker.label_visible != _show_labels:
			marker.label_visible = _show_labels
	# Drop markers for peers that left, went stale or changed scene.
	for peer_id in _markers.keys():
		if not seen.has(peer_id):
			_remove_marker(peer_id)


func _on_session_stopped(_reason: String) -> void:
	_clear()


func _reap() -> void:
	if _coordinator == null:
		return
	var now: int = Time.get_ticks_msec()
	var local_id: int = _coordinator.local_peer_id()
	for peer_id in _markers.keys():
		if not _coordinator.registry.has(peer_id):
			_remove_marker(peer_id)
			continue
		if _cursor_state.is_stale(peer_id, now) and peer_id != local_id:
			_remove_marker(peer_id)


func _ensure_container() -> Node3D:
	var viewport: SubViewport = _editor_viewport_3d()
	if viewport == null:
		return null
	if _container != null and is_instance_valid(_container) and _container.get_parent() == viewport:
		return _container
	if _container != null and is_instance_valid(_container):
		_container.free()
	_container = Node3D.new()
	_container.name = CONTAINER_NAME
	_container.set_meta("godot_collab_internal", true)
	viewport.add_child(_container)
	return _container


func _marker_for(container: Node3D, peer_id: int) -> CollabUserMarker:
	var existing: Variant = _markers.get(peer_id, null)
	if existing is CollabUserMarker and is_instance_valid(existing):
		return existing as CollabUserMarker
	if _marker_scene == null:
		return null
	var marker: CollabUserMarker = _marker_scene.instantiate() as CollabUserMarker
	if marker == null:
		return null
	marker.name = "CollabPeer_%d" % peer_id
	container.add_child(marker)
	_markers[peer_id] = marker
	return marker


func _remove_marker(peer_id: int) -> void:
	var marker: Variant = _markers.get(peer_id, null)
	_markers.erase(peer_id)
	if marker is Node and is_instance_valid(marker):
		(marker as Node).queue_free()


func _clear() -> void:
	for peer_id in _markers.keys():
		var marker: Variant = _markers[peer_id]
		if marker is Node and is_instance_valid(marker):
			(marker as Node).queue_free()
	_markers.clear()
	if _container != null and is_instance_valid(_container):
		_container.queue_free()
	_container = null


func marker_count() -> int:
	return _markers.size()


func has_marker(peer_id: int) -> bool:
	var marker: Variant = _markers.get(peer_id, null)
	return marker is Node and is_instance_valid(marker)


func _editor_viewport_3d() -> SubViewport:
	if not _viewport_provider.is_valid():
		return null
	return _viewport_provider.call() as SubViewport
