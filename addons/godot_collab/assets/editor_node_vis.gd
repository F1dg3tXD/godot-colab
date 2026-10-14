@tool
## 3D marker that represents a collaborator in the editor's 3D view.
##
## The marker's forward direction is +Z: the cylinder/cone "nose" built into the
## scene points along +Z. Callers can either orient it from a remote editor
## camera with [method set_from_camera] or provide an explicit look direction
## with [method set_look_direction]. The username sprite always billboards
## toward the viewing camera so it stays readable from any angle.
class_name CollabUserMarker
extends Node3D

## Local forward axis of the marker. Godot's [constant Vector3.FORWARD] is +Z.
const FORWARD_AXIS: Vector3 = Vector3.FORWARD

## The username SubViewport is fixed at this width; its height grows just enough
## to fit a wrapped name so long names are not clipped.
const VIEWPORT_WIDTH: int = 480
const VIEWPORT_MIN_HEIGHT: int = 64
const VIEWPORT_MAX_HEIGHT: int = 512
const VIEWPORT_V_PADDING: float = 12.0

## Display name shown in the floating label.
@export var username: String = "": set = set_username
## Marker colour (applied to the material and the label).
@export var marker_color: Color = Color(1, 0, 0, 0.6): set = set_marker_color
## Whether the floating username label is shown.
@export var label_visible: bool = true: set = set_label_visible

@onready var _sphere: CSGSphere3D = $CSGSphere3D
@onready var _name_label: Label = %"$user"
@onready var _username_ui: SubViewport = $usernameUI
@onready var _name_sprite: Sprite3D = $UserNameDisplay


func _ready() -> void:
	# The label must keep rendering even when nothing else changes.
	if _username_ui != null:
		_username_ui.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if _name_sprite != null:
		_name_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_name_sprite.visible = label_visible
	if _name_label != null:
		# The scene centers the label with a CenterContainer and wraps it with
		# autowrap; keep the alignment flags explicit so it stays centered if
		# the node is reused in a different layout.
		_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_apply_username()
	_apply_color()


## Orients the marker so its +Z axis matches a remote editor camera's view
## direction. Cameras in Godot look down -Z, so the view direction is
## [code]-camera_transform.basis.z[/code].
func set_from_camera(camera_transform: Transform3D) -> void:
	set_look_direction(-camera_transform.basis.z)


## Points the marker's +Z axis along [param direction].
func set_look_direction(direction: Vector3, up: Vector3 = Vector3.UP) -> void:
	if direction.length_squared() < 0.000001:
		return
	var dir: Vector3 = direction.normalized()
	var up_axis: Vector3 = up
	if absf(dir.dot(up_axis)) > 0.999:
		up_axis = Vector3.RIGHT
	if is_inside_tree():
		# look_at aims -Z at the target, so aim opposite to make +Z face `dir`.
		look_at(global_position - dir, up_axis)
	else:
		var basis_z: Vector3 = dir
		var basis_x: Vector3 = up_axis.cross(basis_z)
		if basis_x.length_squared() < 0.000001:
			basis_x = Vector3.RIGHT
		basis_x = basis_x.normalized()
		var basis_y: Vector3 = basis_z.cross(basis_x).normalized()
		basis = Basis(basis_x, basis_y, basis_z)


## Sets the marker position from a world-space point.
func set_world_position(world_position: Vector3) -> void:
	if is_inside_tree():
		global_position = world_position
	else:
		position = world_position


func set_username(value: String) -> void:
	username = value
	if is_node_ready():
		_apply_username()


func set_marker_color(value: Color) -> void:
	marker_color = value
	if is_node_ready():
		_apply_color()


func set_label_visible(value: bool) -> void:
	label_visible = value
	if is_node_ready() and _name_sprite != null:
		_name_sprite.visible = value


func _apply_username() -> void:
	# Only overwrite the label when there is a real name to show; otherwise the
	# authored placeholder is left untouched so loading the scene in the editor
	# does not mark it modified.
	if _name_label != null and not username.is_empty() and _name_label.text != username:
		_name_label.text = username
	_update_viewport_height.call_deferred()


## Grows (or shrinks) the username viewport height so a wrapped name fits,
## keeping the fixed width and centering the label via the CenterContainer.
func _update_viewport_height() -> void:
	if _username_ui == null or _name_label == null:
		return
	# get_combined_minimum_size() reflects the wrapped height for the label's
	# current (fixed) width, so a short name keeps the minimum height.
	var needed: int = int(ceil(_name_label.get_combined_minimum_size().y + VIEWPORT_V_PADDING))
	var height: int = clampi(needed, VIEWPORT_MIN_HEIGHT, VIEWPORT_MAX_HEIGHT)
	if _username_ui.size.y != height:
		_username_ui.size = Vector2i(VIEWPORT_WIDTH, height)


func _apply_color() -> void:
	# Only touch the (shared) resources when the desired colour actually differs
	# from what is already stored. On load the authored colour equals the default
	# marker colour, so this stays a no-op and does not mark the scene modified.
	if _sphere != null:
		var base: Material = _sphere.material_override
		if base is StandardMaterial3D:
			var existing: StandardMaterial3D = base as StandardMaterial3D
			if not _material_matches(existing, marker_color):
				var mat: StandardMaterial3D = existing.duplicate() as StandardMaterial3D
				mat.albedo_color = marker_color
				mat.emission = marker_color
				_sphere.material_override = mat
	if _name_label != null and _name_label.label_settings != null:
		var current: LabelSettings = _name_label.label_settings
		if not current.font_color.is_equal_approx(marker_color):
			var settings: LabelSettings = current.duplicate() as LabelSettings
			settings.font_color = marker_color
			_name_label.label_settings = settings


func _material_matches(mat: StandardMaterial3D, color: Color) -> bool:
	return (
		mat.albedo_color.is_equal_approx(color)
		and mat.emission_enabled
		and mat.emission.is_equal_approx(color)
	)
