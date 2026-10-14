@tool
## Scene edit operation schema, supported-node/property policy and safe value
## conversion.
##
## Operations are explicit serializable dictionaries. This class is the single
## place that decides what a peer is allowed to change, so validation lives
## here rather than in the network or UI layers.
class_name CollabSceneOperations
extends RefCounted

## Supported structural operation types.
const OP_CREATE: String = "create"
const OP_REMOVE: String = "remove"
const OP_RENAME: String = "rename"
const OP_REPARENT: String = "reparent"
const OP_TRANSFORM: String = "transform"
const OP_PROPERTY: String = "property"

const SUPPORTED_TYPES: Array[String] = [
	OP_CREATE, OP_REMOVE, OP_RENAME, OP_REPARENT, OP_TRANSFORM, OP_PROPERTY,
]

## Node classes a peer may create. Deliberately small and data-oriented;
## scripts are never attached remotely.
const CREATABLE_CLASSES: Array[String] = [
	"Node", "Node3D", "MeshInstance3D", "Camera3D", "DirectionalLight3D",
	"OmniLight3D", "SpotLight3D", "CollisionShape3D", "Area3D", "StaticBody3D",
	"CharacterBody3D", "RigidBody3D", "Marker3D", "Label3D", "CSGSphere3D",
	"CSGBox3D", "CSGCylinder3D", "GridMap", "MultiMeshInstance3D", "Control",
	"Label", "Panel", "Button", "CanvasLayer",
]

## A restricted inspector property whitelist. Only plain, serializable values
## and resource *paths* are accepted.
const PROPERTY_WHITELIST: Dictionary = {
	"Node3D": ["position", "rotation", "scale", "visible"],
	"Node": ["name"],
	"CanvasItem": ["visible", "modulate", "self_modulate"],
	"MeshInstance3D": ["mesh", "cast_shadow", "material_override", "material_overlay"],
	"Camera3D": ["fov", "near", "far", "projection", "current", "size", "keep_aspect"],
	"Light3D": ["light_color", "light_energy", "shadow_enabled", "light_bake_mode"],
	"DirectionalLight3D": ["directional_shadow_max_distance", "sky_mode"],
	"CollisionShape3D": ["shape", "disabled"],
	"Area3D": ["monitoring", "monitorable", "gravity"],
	"RigidBody3D": ["mass", "gravity_scale", "linear_velocity", "angular_velocity"],
	"CharacterBody3D": ["motion_mode", "up_direction"],
	"Label3D": ["text", "font_size", "modulate", "outline_size", "pixel_size"],
	"Label": ["text", "horizontal_alignment", "vertical_alignment"],
	"Control": ["position", "size", "size_flags_horizontal", "size_flags_vertical"],
	"GridMap": ["cell_size", "mesh_library"],
	"MultiMeshInstance3D": ["multimesh"],
}

## Value kinds sendable over the wire.
const VALUE_NULL: String = "null"
const VALUE_FLOAT: String = "float"
const VALUE_INT: String = "int"
const VALUE_BOOL: String = "bool"
const VALUE_VECTOR3: String = "vector3"
const VALUE_COLOR: String = "color"
const VALUE_STRING: String = "string"
const VALUE_NODE_PATH: String = "node_path"
const VALUE_RESOURCE: String = "resource_path"
const VALUE_UNSUPPORTED: String = "unsupported"

const MAX_STRING_VALUE: int = 8192


static func is_supported_op(type: String) -> bool:
	return SUPPORTED_TYPES.has(type)


static func is_creatable(node_class: String) -> bool:
	return CREATABLE_CLASSES.has(node_class)


## True when [param property] is allowed for [param node_class] (checked
## against the class and its ancestors present in the whitelist).
static func is_property_allowed(node: Object, property: String) -> bool:
	if node == null:
		return false
	var check_class: String = node.get_class()
	while true:
		if PROPERTY_WHITELIST.has(check_class) and (PROPERTY_WHITELIST[check_class] as Array).has(property):
			return true
		check_class = _parent_class(check_class)
		if check_class.is_empty() or check_class == "Object":
			break
	return false


## Converts a Godot value to a safe wire representation. Returns a dictionary
## { kind: String, value: Variant }; kind == unsupported means "reject".
static func encode_value(value: Variant) -> Dictionary:
	match typeof(value):
		TYPE_NIL:
			return {"kind": VALUE_NULL, "value": null}
		TYPE_BOOL:
			return {"kind": VALUE_BOOL, "value": value}
		TYPE_INT:
			return {"kind": VALUE_INT, "value": value}
		TYPE_FLOAT:
			return {"kind": VALUE_FLOAT, "value": value}
		TYPE_STRING, TYPE_STRING_NAME:
			var s: String = str(value)
			if s.length() > MAX_STRING_VALUE:
				return {"kind": VALUE_UNSUPPORTED, "value": null}
			return {"kind": VALUE_STRING, "value": s}
		TYPE_VECTOR3:
			return {"kind": VALUE_VECTOR3, "value": value}
		TYPE_VECTOR2:
			return {"kind": "vector2", "value": value}
		TYPE_COLOR:
			return {"kind": VALUE_COLOR, "value": value}
		TYPE_NODE_PATH:
			return {"kind": VALUE_NODE_PATH, "value": str(value)}
		TYPE_OBJECT:
			var resource := value as Resource
			if resource != null and not resource.resource_path.is_empty():
				# Only send the path; the client loads it from its own copy.
				return {"kind": VALUE_RESOURCE, "value": resource.resource_path}
			return {"kind": VALUE_UNSUPPORTED, "value": null}
		_:
			return {"kind": VALUE_UNSUPPORTED, "value": null}


static func is_encodable(value: Variant) -> bool:
	return encode_value(value)["kind"] != VALUE_UNSUPPORTED


## Reconstructs a Godot value from a wire representation, or returns
## [param fallback] when unsupported.
static func decode_value(kind: String, value: Variant, fallback: Variant = null) -> Variant:
	match kind:
		VALUE_NULL:
			return null
		VALUE_BOOL:
			return bool(value)
		VALUE_INT:
			return int(value)
		VALUE_FLOAT:
			return float(value)
		VALUE_STRING:
			return str(value)
		VALUE_VECTOR3:
			return value if typeof(value) == TYPE_VECTOR3 else Vector3.ZERO
		"vector2":
			return value if typeof(value) == TYPE_VECTOR2 else Vector2.ZERO
		VALUE_COLOR:
			return value if typeof(value) == TYPE_COLOR else Color.WHITE
		VALUE_NODE_PATH:
			return NodePath(str(value))
		VALUE_RESOURCE:
			var path: String = str(value)
			if path.is_empty() or not ResourceLoader.exists(path):
				return fallback
			return ResourceLoader.load(path)
		_:
			return fallback


## Builds a transform operation for a [Node3D].
static func make_transform_op(source_peer: int, op_id: int, scene_id: String, base_revision: int, node_id: int, node: Node3D) -> Dictionary:
	return {
		"op_id": op_id,
		"source_peer": source_peer,
		"scene_id": scene_id,
		"base_revision": base_revision,
		"type": OP_TRANSFORM,
		"node_id": node_id,
		"position": node.position,
		"rotation": node.rotation,
		"scale": node.scale,
	}


static func make_property_op(source_peer: int, op_id: int, scene_id: String, base_revision: int, node_id: int, property: String, encoded: Dictionary) -> Dictionary:
	return {
		"op_id": op_id,
		"source_peer": source_peer,
		"scene_id": scene_id,
		"base_revision": base_revision,
		"type": OP_PROPERTY,
		"node_id": node_id,
		"property": property,
		"value_kind": encoded["kind"],
		"value": encoded["value"],
	}


static func make_create_op(source_peer: int, op_id: int, scene_id: String, base_revision: int, parent_id: int, node_class: String, name: String, client_temp_id: int) -> Dictionary:
	return {
		"op_id": op_id,
		"source_peer": source_peer,
		"scene_id": scene_id,
		"base_revision": base_revision,
		"type": OP_CREATE,
		"node_id": client_temp_id, # host replaces with an authoritative id
		"client_temp_id": client_temp_id,
		"parent_id": parent_id,
		"node_class": node_class,
		"name": name,
	}


static func make_remove_op(source_peer: int, op_id: int, scene_id: String, base_revision: int, node_id: int) -> Dictionary:
	return {
		"op_id": op_id, "source_peer": source_peer, "scene_id": scene_id,
		"base_revision": base_revision, "type": OP_REMOVE, "node_id": node_id,
	}


static func make_rename_op(source_peer: int, op_id: int, scene_id: String, base_revision: int, node_id: int, new_name: String) -> Dictionary:
	return {
		"op_id": op_id, "source_peer": source_peer, "scene_id": scene_id,
		"base_revision": base_revision, "type": OP_RENAME, "node_id": node_id, "name": new_name,
	}


static func make_reparent_op(source_peer: int, op_id: int, scene_id: String, base_revision: int, node_id: int, parent_id: int) -> Dictionary:
	return {
		"op_id": op_id, "source_peer": source_peer, "scene_id": scene_id,
		"base_revision": base_revision, "type": OP_REPARENT, "node_id": node_id, "parent_id": parent_id,
	}


## Validates an inbound operation from a peer. Returns an empty string when the
## operation is acceptable, otherwise a human readable rejection reason.
static func validate_op(op: Variant, resolver: Callable) -> String:
	if typeof(op) != TYPE_DICTIONARY:
		return "operation is not a dictionary"
	var d: Dictionary = op
	for key in ["op_id", "source_peer", "scene_id", "base_revision", "type", "node_id"]:
		if not d.has(key):
			return "operation missing '%s'" % key
	var type: String = str(d.get("type", ""))
	if not is_supported_op(type):
		return "unsupported operation type '%s'" % type
	if int(d.get("base_revision", -1)) < 0:
		return "invalid base revision"
	match type:
		OP_CREATE:
			var node_class: String = str(d.get("node_class", ""))
			if not is_creatable(node_class):
				return "node class '%s' is not creatable" % node_class
			if str(d.get("name", "")).length() > 128:
				return "node name too long"
		OP_REMOVE, OP_RENAME, OP_REPARENT, OP_TRANSFORM:
			if not resolver.is_valid():
				return "no node resolver"
			if resolver.call(int(d.get("node_id", -1)), true) == null:
				return "target node %s unknown" % str(d.get("node_id", -1))
			if type == OP_RENAME and str(d.get("name", "")).length() > 128:
				return "node name too long"
		OP_PROPERTY:
			var property: String = str(d.get("property", ""))
			if property.is_empty() or property.contains("/") or property.begins_with("_"):
				return "invalid property name"
			var kind: String = str(d.get("value_kind", ""))
			if kind == VALUE_UNSUPPORTED or kind.is_empty():
				return "unsupported property value"
	return ""


static func _parent_class(cls: String) -> String:
	return ClassDB.get_parent_class(cls)


## Returns the operation type taxonomy used by the diff watcher.
static func transform_from_op(op: Dictionary) -> Transform3D:
	var t := Transform3D.IDENTITY
	t.origin = op.get("position", Vector3.ZERO)
	var rot: Vector3 = op.get("rotation", Vector3.ZERO)
	t.basis = Basis.from_euler(rot)
	t.basis = t.basis.scaled(op.get("scale", Vector3.ONE))
	return t
