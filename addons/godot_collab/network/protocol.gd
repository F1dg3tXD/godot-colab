@tool
## Explicit wire protocol: message types, framing and validation.
##
## Every packet is a 10 byte header followed by a variant-encoded dictionary
## payload. Only plain data (numbers, strings, arrays, dictionaries,
## PackedByteArray, Vector types) is ever encoded; object encoding is disabled
## so a peer can never smuggle a serialized [Object] across the wire.
##
## Usage:
## [codeblock]
## var bytes := CollabProtocol.encode(CollabProtocol.MessageType.HELLO, payload)
## var decoded := CollabProtocol.decode(bytes)
## if not decoded.ok: ...
## [/codeblock]
class_name CollabProtocol
extends RefCounted

enum MessageType {
	INVALID = 0,
	# --- handshake / session control (reliable) ---
	HELLO = 1, ## client -> host: version + identity
	WELCOME = 2, ## host -> client: assigned id, session data
	REJECT = 3, ## host -> client: connection refused
	PING = 4,
	PONG = 5,
	# --- participant presence ---
	PARTICIPANT_LIST = 10,
	PARTICIPANT_JOIN = 11,
	PARTICIPANT_LEAVE = 12,
	PARTICIPANT_UPDATE = 13,
	# --- approval flow ---
	JOIN_PENDING = 20,
	JOIN_APPROVED = 21,
	JOIN_DENIED = 22,
	# --- presence / cursors ---
	CURSOR_UPDATE = 30,
	SCENE_FOCUS = 31,
	# --- scene operations (reliable) ---
	OPS = 40,
	OPS_ACK = 41,
	OPS_REJECT = 42,
	SNAPSHOT_REQUEST = 43,
	SNAPSHOT_RESPONSE = 44,
	RESYNC_REQUIRED = 45,
	CONFLICT_NOTICE = 46,
	# --- saving ---
	SAVE_REQUEST = 50,
	SAVE_RESULT = 51,
	# --- project transfer ---
	TRANSFER_MANIFEST = 60,
	TRANSFER_REQUEST = 61,
	TRANSFER_CHUNK = 62,
	TRANSFER_FILE_DONE = 63,
	TRANSFER_COMPLETE = 64,
	TRANSFER_CANCEL = 65,
	TRANSFER_ERROR = 66,
	# --- workspace (project file/scene) authoring ---
	WORKSPACE_REQUEST = 70, ## client -> host: create scene / add file
	WORKSPACE_RESULT = 71, ## host -> peers: accepted/rejected request
	FILE_APPLY = 72, ## host -> peers: write this file content locally
	SCENE_LIST = 73, ## host -> peers: known project scenes
	FILE_REMOVE = 74, ## host -> peers: delete this project file locally (rename/delete)
}

## Named reasons a peer can be rejected or an operation refused.
enum Reason {
	NONE = 0,
	PROTOCOL_MISMATCH = 1,
	SESSION_FULL = 2,
	HOST_DENIED = 3,
	NOT_APPROVED = 4,
	BAD_PAYLOAD = 5,
	STALE_REVISION = 6,
	UNSUPPORTED_OPERATION = 7,
	WRONG_SCENE = 8,
	WRONG_PROJECT = 9,
	RATE_LIMITED = 10,
	TRANSFER_REJECTED = 11,
	INTERNAL_ERROR = 12,
}

const _ENCODE_MAX: int = CollabConstants.MAX_PACKET_PAYLOAD


## Framed encode. Returns an empty array if the payload cannot be encoded or is
## too large, so callers can simply skip sending.
static func encode(type: MessageType, payload: Dictionary) -> PackedByteArray:
	var body: PackedByteArray = var_to_bytes(payload)
	if body.size() > CollabConstants.MAX_PACKET_PAYLOAD:
		return PackedByteArray()
	var out: PackedByteArray = PackedByteArray()
	out.append_array(CollabConstants.PACKET_MAGIC)
	out.append(CollabConstants.PROTOCOL_VERSION)
	out.append(type as int)
	_append_u32(out, body.size())
	out.append_array(body)
	return out


## Decode result dictionary:
## { ok: bool, error: String, reason: Reason, type: MessageType, payload: Dictionary }
static func decode(packet: PackedByteArray) -> Dictionary:
	var result: Dictionary = {
		"ok": false,
		"error": "empty",
		"reason": Reason.BAD_PAYLOAD,
		"type": MessageType.INVALID,
		"payload": {},
	}
	if packet.size() < CollabConstants.HEADER_SIZE:
		result["error"] = "packet shorter than header"
		return result
	for i in CollabConstants.PACKET_MAGIC.size():
		if packet[i] != CollabConstants.PACKET_MAGIC[i]:
			result["error"] = "bad magic"
			return result
	var version: int = packet[4]
	if version != CollabConstants.PROTOCOL_VERSION:
		result["error"] = "protocol version mismatch (%d != %d)" % [version, CollabConstants.PROTOCOL_VERSION]
		result["reason"] = Reason.PROTOCOL_MISMATCH
		return result
	var type: int = packet[5]
	if type <= MessageType.INVALID or type >= _type_count():
		result["error"] = "unknown message type %d" % type
		return result
	var body_len: int = _read_u32(packet, 6)
	if body_len > CollabConstants.MAX_PACKET_PAYLOAD:
		result["error"] = "payload too large (%d)" % body_len
		return result
	if packet.size() - CollabConstants.HEADER_SIZE != body_len:
		result["error"] = "payload length mismatch"
		return result
	var body: PackedByteArray = packet.slice(CollabConstants.HEADER_SIZE)
	var payload: Variant = bytes_to_var(body)
	if payload == null or typeof(payload) != TYPE_DICTIONARY:
		result["error"] = "payload is not a dictionary"
		return result
	var validation: String = _validate_payload(type as MessageType, payload)
	if not validation.is_empty():
		result["error"] = validation
		return result
	result["ok"] = true
	result["error"] = ""
	result["reason"] = Reason.NONE
	result["type"] = type as MessageType
	result["payload"] = payload
	return result


## Lightweight structural validation per message type. This is deliberately
## conservative: it verifies the fields an attacker could use to trigger a
## crash or unbounded work, not every business rule.
static func _validate_payload(type: MessageType, payload: Dictionary) -> String:
	match type:
		MessageType.HELLO:
			if not _has_keys(payload, ["protocol_version", "username", "project_id", "capabilities"]):
				return "HELLO missing fields"
			if not _check_str(payload, "username", 64):
				return "HELLO bad username"
		MessageType.WELCOME:
			if not _has_keys(payload, ["peer_id", "session_id", "host_username", "workspace_mode", "project_id"]):
				return "WELCOME missing fields"
		MessageType.REJECT:
			if not _has_keys(payload, ["reason"]):
				return "REJECT missing reason"
		MessageType.PARTICIPANT_JOIN, MessageType.PARTICIPANT_LIST:
			if not payload.has("participants") or typeof(payload["participants"]) != TYPE_ARRAY:
				return "PARTICIPANT missing array"
			var arr: Array = payload["participants"]
			if arr.size() > 256:
				return "PARTICIPANT list too large"
		MessageType.CURSOR_UPDATE:
			if not _has_keys(payload, ["camera_transform", "ray_origin", "ray_direction"]):
				return "CURSOR_UPDATE missing fields"
		MessageType.OPS:
			if not payload.has("operations") or typeof(payload["operations"]) != TYPE_ARRAY:
				return "OPS missing operations"
			var ops: Array = payload["operations"]
			if ops.size() > CollabConstants.MAX_OPS_PER_MESSAGE:
				return "OPS batch too large"
			for op in ops:
				if typeof(op) != TYPE_DICTIONARY:
					return "OPS entry not a dictionary"
		MessageType.TRANSFER_CHUNK:
			if not _has_keys(payload, ["transfer_id", "path", "offset", "data"]):
				return "TRANSFER_CHUNK missing fields"
			var data: Variant = payload["data"]
			if typeof(data) != TYPE_PACKED_BYTE_ARRAY:
				return "TRANSFER_CHUNK data not bytes"
			if (data as PackedByteArray).size() > CollabConstants.MAX_TRANSFER_CHUNK:
				return "TRANSFER_CHUNK exceeds chunk limit"
		MessageType.TRANSFER_REQUEST:
			if not _has_keys(payload, ["transfer_id", "path"]):
				return "TRANSFER_REQUEST missing fields"
			if not _check_str(payload, "path", 512):
				return "TRANSFER_REQUEST bad path"
		MessageType.TRANSFER_MANIFEST:
			if not payload.has("files") or typeof(payload["files"]) != TYPE_ARRAY:
				return "TRANSFER_MANIFEST missing files"
		MessageType.WORKSPACE_REQUEST:
			if not _has_keys(payload, ["request_id", "kind", "path"]):
				return "WORKSPACE_REQUEST missing fields"
			if not _check_int(payload, "request_id"):
				return "WORKSPACE_REQUEST bad request_id"
			if not _check_str(payload, "path", 512):
				return "WORKSPACE_REQUEST bad path"
			var wkind: Variant = payload["kind"]
			if typeof(wkind) != TYPE_INT:
				return "WORKSPACE_REQUEST bad kind"
			if payload.has("text"):
				if typeof(payload["text"]) != TYPE_STRING:
					return "WORKSPACE_REQUEST bad text"
				if (payload["text"] as String).to_utf8_buffer().size() > CollabConstants.MAX_WORKSPACE_FILE_BYTES:
					return "WORKSPACE_REQUEST text too large"
			if payload.has("data"):
				if typeof(payload["data"]) != TYPE_PACKED_BYTE_ARRAY:
					return "WORKSPACE_REQUEST bad data"
				if (payload["data"] as PackedByteArray).size() > CollabConstants.MAX_WORKSPACE_FILE_BYTES:
					return "WORKSPACE_REQUEST data too large"
			if payload.has("root_class") and typeof(payload["root_class"]) != TYPE_STRING:
				return "WORKSPACE_REQUEST bad root_class"
		MessageType.WORKSPACE_RESULT:
			if not _has_keys(payload, ["request_id", "ok", "path"]):
				return "WORKSPACE_RESULT missing fields"
			if not _check_str(payload, "path", 512):
				return "WORKSPACE_RESULT bad path"
		MessageType.FILE_APPLY:
			if not _has_keys(payload, ["path", "data"]):
				return "FILE_APPLY missing fields"
			if not _check_str(payload, "path", 512):
				return "FILE_APPLY bad path"
			var fdata: Variant = payload["data"]
			if typeof(fdata) != TYPE_PACKED_BYTE_ARRAY:
				return "FILE_APPLY data not bytes"
			if (fdata as PackedByteArray).size() > CollabConstants.MAX_WORKSPACE_FILE_BYTES:
				return "FILE_APPLY exceeds workspace file limit"
		MessageType.SCENE_LIST:
			if not payload.has("scenes") or typeof(payload["scenes"]) != TYPE_ARRAY:
				return "SCENE_LIST missing scenes"
			if (payload["scenes"] as Array).size() > CollabConstants.MAX_SCENE_LIST:
				return "SCENE_LIST too large"
		MessageType.FILE_REMOVE:
			if not _has_keys(payload, ["path"]):
				return "FILE_REMOVE missing fields"
			if not _check_str(payload, "path", 512):
				return "FILE_REMOVE bad path"
		_:
			pass
	return ""


static func _has_keys(payload: Dictionary, keys: Array) -> bool:
	for key in keys:
		if not payload.has(key):
			return false
	return true


static func _check_str(payload: Dictionary, key: String, max_len: int) -> bool:
	if not payload.has(key):
		return false
	var v: Variant = payload[key]
	if typeof(v) != TYPE_STRING:
		return false
	return (v as String).length() <= max_len


static func _check_int(payload: Dictionary, key: String) -> bool:
	if not payload.has(key):
		return false
	return typeof(payload[key]) == TYPE_INT


static func _type_count() -> int:
	return MessageType.FILE_REMOVE + 1


static func _append_u32(buf: PackedByteArray, value: int) -> void:
	var v: int = value & 0xFFFFFFFF
	buf.append((v >> 24) & 0xFF)
	buf.append((v >> 16) & 0xFF)
	buf.append((v >> 8) & 0xFF)
	buf.append(v & 0xFF)


static func _read_u32(buf: PackedByteArray, offset: int) -> int:
	if offset + 4 > buf.size():
		return -1
	return (buf[offset] << 24) | (buf[offset + 1] << 16) | (buf[offset + 2] << 8) | buf[offset + 3]
