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

## Properties that are never synchronised as plain property operations. Most
## are handled by a dedicated operation (name, transform) or would let a peer
## change node identity/behaviour in unsafe ways (script, owner).
const RESERVED_PROPERTIES: Array[String] = [
	"name", "script", "owner", "transform", "global_transform",
]

## Node3D exposes both `transform` (stored) and the derived editor-only
## `position`/`rotation`/`scale`. All of them are covered by the dedicated
## transform operation, so they are skipped here to avoid duplicate traffic.
const NODE3D_TRANSFORM_PROPERTIES: Array[String] = [
	"position", "rotation", "rotation_degrees", "quaternion", "scale", "basis",
]

## Value kinds sendable over the wire.
const VALUE_NULL: String = "null"
const VALUE_FLOAT: String = "float"
const VALUE_INT: String = "int"
const VALUE_BOOL: String = "bool"
const VALUE_VECTOR2: String = "vector2"
const VALUE_VECTOR2I: String = "vector2i"
const VALUE_VECTOR3: String = "vector3"
const VALUE_VECTOR3I: String = "vector3i"
const VALUE_VECTOR4: String = "vector4"
const VALUE_VECTOR4I: String = "vector4i"
const VALUE_QUATERNION: String = "quaternion"
const VALUE_BASIS: String = "basis"
const VALUE_TRANSFORM2D: String = "transform2d"
const VALUE_TRANSFORM3D: String = "transform3d"
const VALUE_RECT2: String = "rect2"
const VALUE_RECT2I: String = "rect2i"
const VALUE_PLANE: String = "plane"
const VALUE_AABB: String = "aabb"
const VALUE_PROJECTION: String = "projection"
const VALUE_COLOR: String = "color"
const VALUE_STRING: String = "string"
const VALUE_STRING_NAME: String = "string_name"
const VALUE_NODE_PATH: String = "node_path"
const VALUE_ARRAY: String = "array"
const VALUE_DICTIONARY: String = "dictionary"
const VALUE_PACKED_INT32: String = "packed_int32"
const VALUE_PACKED_INT64: String = "packed_int64"
const VALUE_PACKED_FLOAT32: String = "packed_float32"
const VALUE_PACKED_FLOAT64: String = "packed_float64"
const VALUE_PACKED_STRING: String = "packed_string"
const VALUE_PACKED_VECTOR2: String = "packed_vector2"
const VALUE_PACKED_VECTOR3: String = "packed_vector3"
const VALUE_PACKED_COLOR: String = "packed_color"
const VALUE_RESOURCE: String = "resource_path"
## An embedded sub-resource (for example a material created on the fly when a
## texture is dropped onto a mesh) serialised to text. Sent because it has no
## `res://` path the receiver could load independently.
const VALUE_RESOURCE_INLINE: String = "resource_inline"
const VALUE_UNSUPPORTED: String = "unsupported"

const MAX_STRING_VALUE: int = 8192
## Upper bound for an inline-serialised resource payload. Larger resources must
## be saved as project files (which sync through the file-sync path) instead.
const MAX_INLINE_RESOURCE_TEXT: int = 65536

## Substrings that must never appear in an inline-serialised resource. They
## indicate embedded or referenced executable content (scripts, packed scenes)
## which the add-on must never distribute or instantiate on a remote peer.
const UNSAFE_INLINE_MARKERS: Array[String] = [
	'type="script"', 'type="gdscript"', 'type="csharpscript"', 'type="packedscene"',
	'script = extresource', 'script=extresource', 'type="script_extension"',
]
## Maximum number of elements accepted in an array/dictionary/packed-array
## property. Keeps a malicious peer from forcing large allocations.
const MAX_CONTAINER_ELEMENTS: int = 4096
const MAX_CONTAINER_DEPTH: int = 6


static func is_supported_op(type: String) -> bool:
	return SUPPORTED_TYPES.has(type)


static func is_creatable(node_class: String) -> bool:
	return CREATABLE_CLASSES.has(node_class)


## True when [param property] may be synchronised as an ordinary property of
## [param node]. This is deliberately general (any stored/editable property
## whose value is safely serialisable) but refuses names that would change node
## identity, attach code, or address sub-resources.
static func is_property_syncable(node: Object, property: String) -> bool:
	if node == null or not _is_syncable_name(node, property):
		return false
	for info in node.get_property_list():
		if str(info.get("name", "")) != property:
			continue
		var usage: int = int(info.get("usage", 0))
		if (usage & PROPERTY_USAGE_INTERNAL) != 0:
			return false
		return (usage & PROPERTY_USAGE_STORAGE) != 0 or (usage & PROPERTY_USAGE_EDITOR) != 0
	return false


## True when [param property] is a name a peer may set. Sub-properties that use a
## slash (`surface_material_override/0`, `theme_override_colors/font_color`) are
## allowed because they are ordinary storable properties, but editor-internal
## metadata, names beginning with `_`, and reserved identity/behaviour
## properties are refused.
static func is_syncable_property_name(property: String) -> bool:
	if property.is_empty() or property.begins_with("_") or property.begins_with("metadata/"):
		return false
	if RESERVED_PROPERTIES.has(property):
		return false
	return true


## Collects every safe, serialisable property of [param node] as
## { property: { kind, value } }. Used for snapshots and for building operations.
## When [param cheap] is true, embedded resources are reduced to a comparison-only
## signature instead of being serialised (used by the diff watcher's per-scan
## baseline so serialising every resource every scan stays off the hot path).
static func collect_syncable_props(node: Node, cheap: bool = false) -> Dictionary:
	var out: Dictionary = {}
	if node == null:
		return out
	for info in node.get_property_list():
		var prop: String = str(info.get("name", ""))
		if not _is_syncable_name(node, prop):
			continue
		var usage: int = int(info.get("usage", 0))
		if (usage & PROPERTY_USAGE_INTERNAL) != 0:
			continue
		if (usage & PROPERTY_USAGE_STORAGE) == 0 and (usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		var encoded: Dictionary = signature_value(node.get(prop)) if cheap else encode_value(node.get(prop))
		if encoded["kind"] != VALUE_UNSUPPORTED:
			out[prop] = encoded
	return out


static func _is_syncable_name(node: Object, property: String) -> bool:
	if not is_syncable_property_name(property):
		return false
	if node is Node3D and NODE3D_TRANSFORM_PROPERTIES.has(property):
		return false
	return true


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
		TYPE_STRING:
			var s: String = value
			if s.length() > MAX_STRING_VALUE:
				return _unsupported()
			return {"kind": VALUE_STRING, "value": s}
		TYPE_STRING_NAME:
			var sn: String = str(value)
			if sn.length() > MAX_STRING_VALUE:
				return _unsupported()
			return {"kind": VALUE_STRING_NAME, "value": sn}
		TYPE_VECTOR2:
			return {"kind": VALUE_VECTOR2, "value": value}
		TYPE_VECTOR2I:
			return {"kind": VALUE_VECTOR2I, "value": value}
		TYPE_VECTOR3:
			return {"kind": VALUE_VECTOR3, "value": value}
		TYPE_VECTOR3I:
			return {"kind": VALUE_VECTOR3I, "value": value}
		TYPE_VECTOR4:
			return {"kind": VALUE_VECTOR4, "value": value}
		TYPE_VECTOR4I:
			return {"kind": VALUE_VECTOR4I, "value": value}
		TYPE_QUATERNION:
			return {"kind": VALUE_QUATERNION, "value": value}
		TYPE_BASIS:
			return {"kind": VALUE_BASIS, "value": value}
		TYPE_TRANSFORM2D:
			return {"kind": VALUE_TRANSFORM2D, "value": value}
		TYPE_TRANSFORM3D:
			return {"kind": VALUE_TRANSFORM3D, "value": value}
		TYPE_RECT2:
			return {"kind": VALUE_RECT2, "value": value}
		TYPE_RECT2I:
			return {"kind": VALUE_RECT2I, "value": value}
		TYPE_PLANE:
			return {"kind": VALUE_PLANE, "value": value}
		TYPE_AABB:
			return {"kind": VALUE_AABB, "value": value}
		TYPE_PROJECTION:
			return {"kind": VALUE_PROJECTION, "value": value}
		TYPE_COLOR:
			return {"kind": VALUE_COLOR, "value": value}
		TYPE_NODE_PATH:
			return {"kind": VALUE_NODE_PATH, "value": str(value)}
		TYPE_OBJECT:
			var resource := value as Resource
			if resource == null:
				# A cleared object property reports TYPE_OBJECT with a null value.
				# Treat it as null so the property stays in the collected set and a
				# later null -> resource (or resource -> null) change is detected.
				if value == null:
					return {"kind": VALUE_NULL, "value": null}
				return _unsupported()
			if not resource.resource_path.is_empty():
				# File-backed resource: send the path, the receiver loads its copy.
				return {"kind": VALUE_RESOURCE, "value": resource.resource_path}
			# Embedded resource: serialise it so the receiver can rebuild it.
			return _encode_inline_resource(resource)
		TYPE_ARRAY:
			if not _is_plain_container(value, 0):
				return _unsupported()
			return {"kind": VALUE_ARRAY, "value": value}
		TYPE_DICTIONARY:
			if not _is_plain_container(value, 0):
				return _unsupported()
			return {"kind": VALUE_DICTIONARY, "value": value}
		TYPE_PACKED_INT32_ARRAY:
			return _packed(value, VALUE_PACKED_INT32)
		TYPE_PACKED_INT64_ARRAY:
			return _packed(value, VALUE_PACKED_INT64)
		TYPE_PACKED_FLOAT32_ARRAY:
			return _packed(value, VALUE_PACKED_FLOAT32)
		TYPE_PACKED_FLOAT64_ARRAY:
			return _packed(value, VALUE_PACKED_FLOAT64)
		TYPE_PACKED_STRING_ARRAY:
			return _packed(value, VALUE_PACKED_STRING)
		TYPE_PACKED_VECTOR2_ARRAY:
			return _packed(value, VALUE_PACKED_VECTOR2)
		TYPE_PACKED_VECTOR3_ARRAY:
			return _packed(value, VALUE_PACKED_VECTOR3)
		TYPE_PACKED_COLOR_ARRAY:
			return _packed(value, VALUE_PACKED_COLOR)
		_:
			return _unsupported()


static func is_encodable(value: Variant) -> bool:
	return encode_value(value)["kind"] != VALUE_UNSUPPORTED


## True when [param kind] represents a resource reference that could fail to
## resolve locally (missing file or refused inline payload).
static func is_resource_kind(kind: String) -> bool:
	return kind == VALUE_RESOURCE or kind == VALUE_RESOURCE_INLINE


## Comparison-only projection of a value used by the diff watcher's baseline.
## Identical to [method encode_value] except that an embedded resource is
## represented by its instance id rather than by its serialised text, so the
## per-scan comparison never pays the serialisation cost. The full encoding is
## produced lazily only when a change actually needs to be sent.
static func signature_value(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_OBJECT:
		var resource := value as Resource
		if resource == null:
			if value == null:
				return {"kind": VALUE_NULL, "value": null}
			return _unsupported()
		if not resource.resource_path.is_empty():
			return {"kind": VALUE_RESOURCE, "value": resource.resource_path}
		return {"kind": VALUE_RESOURCE_INLINE, "value": resource.get_instance_id()}
	return encode_value(value)


## Serialises an embedded resource to Godot text via a temporary `.tres` file.
## Returns an empty string when the resource cannot be saved, is too large, or
## contains executable/reference content that must not be distributed.
static func _encode_inline_resource(resource: Resource) -> Dictionary:
	var text: String = _resource_to_text(resource)
	if text.is_empty():
		return _unsupported()
	return {"kind": VALUE_RESOURCE_INLINE, "value": text}


static func _resource_to_text(resource: Resource) -> String:
	var path: String = "user://godot_collab_inline_%d.tres" % resource.get_instance_id()
	var err: Error = ResourceSaver.save(resource, path)
	if err != OK:
		return ""
	var text: String = ""
	if FileAccess.file_exists(path):
		text = FileAccess.get_file_as_string(path)
	var absolute: String = ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(absolute)
	if text.is_empty() or text.length() > MAX_INLINE_RESOURCE_TEXT:
		return ""
	if _contains_unsafe_inline(text):
		return ""
	return text


## Rebuilds a resource from inline text by writing it to a temporary `.tres`
## file and loading it. Content that could carry code is refused.
static func _load_inline_resource(text: String) -> Resource:
	if text.is_empty() or text.length() > MAX_INLINE_RESOURCE_TEXT:
		return null
	if _contains_unsafe_inline(text):
		return null
	var path: String = "user://godot_collab_recv_%d_%d.tres" % [Time.get_ticks_usec(), _receive_counter]
	_receive_counter += 1
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return null
	file.store_string(text)
	file.close()
	var loaded: Variant = ResourceLoader.load(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return loaded as Resource


static func _contains_unsafe_inline(text: String) -> bool:
	var lower: String = text.to_lower()
	for marker in UNSAFE_INLINE_MARKERS:
		if lower.contains(marker):
			return true
	return false


static var _receive_counter: int = 0


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
		VALUE_STRING_NAME:
			return StringName(str(value))
		VALUE_VECTOR2:
			return value if typeof(value) == TYPE_VECTOR2 else Vector2.ZERO
		VALUE_VECTOR2I:
			return value if typeof(value) == TYPE_VECTOR2I else Vector2i.ZERO
		VALUE_VECTOR3:
			return value if typeof(value) == TYPE_VECTOR3 else Vector3.ZERO
		VALUE_VECTOR3I:
			return value if typeof(value) == TYPE_VECTOR3I else Vector3i.ZERO
		VALUE_VECTOR4:
			return value if typeof(value) == TYPE_VECTOR4 else Vector4()
		VALUE_VECTOR4I:
			return value if typeof(value) == TYPE_VECTOR4I else Vector4i()
		VALUE_QUATERNION:
			return value if typeof(value) == TYPE_QUATERNION else Quaternion()
		VALUE_BASIS:
			return value if typeof(value) == TYPE_BASIS else Basis()
		VALUE_TRANSFORM2D:
			return value if typeof(value) == TYPE_TRANSFORM2D else Transform2D()
		VALUE_TRANSFORM3D:
			return value if typeof(value) == TYPE_TRANSFORM3D else Transform3D()
		VALUE_RECT2:
			return value if typeof(value) == TYPE_RECT2 else Rect2()
		VALUE_RECT2I:
			return value if typeof(value) == TYPE_RECT2I else Rect2i()
		VALUE_PLANE:
			return value if typeof(value) == TYPE_PLANE else Plane()
		VALUE_AABB:
			return value if typeof(value) == TYPE_AABB else AABB()
		VALUE_PROJECTION:
			return value if typeof(value) == TYPE_PROJECTION else Projection()
		VALUE_COLOR:
			return value if typeof(value) == TYPE_COLOR else Color.WHITE
		VALUE_NODE_PATH:
			return NodePath(str(value))
		VALUE_ARRAY:
			return value if typeof(value) == TYPE_ARRAY else []
		VALUE_DICTIONARY:
			return value if typeof(value) == TYPE_DICTIONARY else {}
		VALUE_PACKED_INT32:
			return value if typeof(value) == TYPE_PACKED_INT32_ARRAY else PackedInt32Array()
		VALUE_PACKED_INT64:
			return value if typeof(value) == TYPE_PACKED_INT64_ARRAY else PackedInt64Array()
		VALUE_PACKED_FLOAT32:
			return value if typeof(value) == TYPE_PACKED_FLOAT32_ARRAY else PackedFloat32Array()
		VALUE_PACKED_FLOAT64:
			return value if typeof(value) == TYPE_PACKED_FLOAT64_ARRAY else PackedFloat64Array()
		VALUE_PACKED_STRING:
			return value if typeof(value) == TYPE_PACKED_STRING_ARRAY else PackedStringArray()
		VALUE_PACKED_VECTOR2:
			return value if typeof(value) == TYPE_PACKED_VECTOR2_ARRAY else PackedVector2Array()
		VALUE_PACKED_VECTOR3:
			return value if typeof(value) == TYPE_PACKED_VECTOR3_ARRAY else PackedVector3Array()
		VALUE_PACKED_COLOR:
			return value if typeof(value) == TYPE_PACKED_COLOR_ARRAY else PackedColorArray()
		VALUE_RESOURCE:
			var path: String = str(value)
			if path.is_empty() or not ResourceLoader.exists(path):
				return fallback
			return ResourceLoader.load(path)
		VALUE_RESOURCE_INLINE:
			var loaded: Resource = _load_inline_resource(str(value))
			return loaded if loaded != null else fallback
		_:
			return fallback


static func _unsupported() -> Dictionary:
	return {"kind": VALUE_UNSUPPORTED, "value": null}


static func _packed(value: Variant, kind: String) -> Dictionary:
	# Packed arrays are flat, engine-typed buffers; size-check and pass through.
	if _packed_size(value) > MAX_CONTAINER_ELEMENTS:
		return _unsupported()
	return {"kind": kind, "value": value}


static func _packed_size(value: Variant) -> int:
	match typeof(value):
		TYPE_PACKED_INT32_ARRAY:
			return (value as PackedInt32Array).size()
		TYPE_PACKED_INT64_ARRAY:
			return (value as PackedInt64Array).size()
		TYPE_PACKED_FLOAT32_ARRAY:
			return (value as PackedFloat32Array).size()
		TYPE_PACKED_FLOAT64_ARRAY:
			return (value as PackedFloat64Array).size()
		TYPE_PACKED_STRING_ARRAY:
			return (value as PackedStringArray).size()
		TYPE_PACKED_VECTOR2_ARRAY:
			return (value as PackedVector2Array).size()
		TYPE_PACKED_VECTOR3_ARRAY:
			return (value as PackedVector3Array).size()
		TYPE_PACKED_COLOR_ARRAY:
			return (value as PackedColorArray).size()
	return 0


## True when [param value] is a container made only of wire-safe plain data (no
## objects/resources, bounded size and depth). Such containers are passed
## through verbatim because the variant encoder already round-trips them.
static func _is_plain_container(value: Variant, depth: int) -> bool:
	if depth > MAX_CONTAINER_DEPTH:
		return false
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME, \
		TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4, \
		TYPE_VECTOR4I, TYPE_QUATERNION, TYPE_BASIS, TYPE_TRANSFORM2D, \
		TYPE_TRANSFORM3D, TYPE_RECT2, TYPE_RECT2I, TYPE_PLANE, TYPE_AABB, \
		TYPE_PROJECTION, TYPE_COLOR, TYPE_NODE_PATH:
			return true
		TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, \
		TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, \
		TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			return _packed_size(value) <= MAX_CONTAINER_ELEMENTS
		TYPE_ARRAY:
			var arr: Array = value
			if arr.size() > MAX_CONTAINER_ELEMENTS:
				return false
			for item in arr:
				if not _is_plain_container(item, depth + 1):
					return false
			return true
		TYPE_DICTIONARY:
			var dict: Dictionary = value
			if dict.size() > MAX_CONTAINER_ELEMENTS:
				return false
			for key in dict.keys():
				if not _is_plain_container(key, depth + 1):
					return false
				if not _is_plain_container(dict[key], depth + 1):
					return false
			return true
		_:
			return false


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
			var script: String = str(d.get("script", ""))
			if not script.is_empty() and (not script.begins_with("res://") or script.contains("..")):
				return "invalid script path"
		OP_REMOVE, OP_RENAME, OP_REPARENT, OP_TRANSFORM:
			if not resolver.is_valid():
				return "no node resolver"
			if resolver.call(int(d.get("node_id", -1)), true) == null:
				return "target node %s unknown" % str(d.get("node_id", -1))
			if type == OP_RENAME and str(d.get("name", "")).length() > 128:
				return "node name too long"
		OP_PROPERTY:
			var property: String = str(d.get("property", ""))
			if not is_syncable_property_name(property):
				return "invalid property name"
			var kind: String = str(d.get("value_kind", ""))
			if kind == VALUE_UNSUPPORTED or kind.is_empty():
				return "unsupported property value"
			if not resolver.is_valid():
				return "no node resolver"
			if resolver.call(int(d.get("node_id", -1)), true) == null:
				return "target node %s unknown" % str(d.get("node_id", -1))
	return ""


## Returns the operation type taxonomy used by the diff watcher.
static func transform_from_op(op: Dictionary) -> Transform3D:
	var t := Transform3D.IDENTITY
	t.origin = op.get("position", Vector3.ZERO)
	var rot: Vector3 = op.get("rotation", Vector3.ZERO)
	t.basis = Basis.from_euler(rot)
	t.basis = t.basis.scaled(op.get("scale", Vector3.ONE))
	return t
