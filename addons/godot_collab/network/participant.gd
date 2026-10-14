@tool
## Serializable description of a connected collaborator.
##
## A participant is plain data so it can be copied into network payloads and
## passed between the network and UI layers without leaking editor objects.
class_name CollabParticipant
extends RefCounted

## Distinct, deterministic palette so each peer keeps the same colour across
## every client and across reconnects (the server assigns stable peer ids).
const PALETTE: Array[Color] = [
	Color("e6194b"), Color("3cb44b"), Color("ffe119"), Color("4363d8"),
	Color("f58231"), Color("911eb4"), Color("46f0f0"), Color("f032e6"),
	Color("bcf60c"), Color("fabebe"), Color("008080"), Color("e6beff"),
	Color("9a6324"), Color("fffac8"), Color("800000"), Color("aaffc3"),
]

var peer_id: int = 0
var username: String = ""
var is_host: bool = false
var approved: bool = false
var joined_at_ms: int = 0
var last_seen_ms: int = 0
var project_id: String = ""
var scene_id: String = ""
var capabilities: Dictionary = {}


static func make(p_peer_id: int, p_username: String, p_is_host: bool, p_approved: bool = true) -> CollabParticipant:
	var participant := CollabParticipant.new()
	participant.peer_id = p_peer_id
	participant.username = p_username
	participant.is_host = p_is_host
	participant.approved = p_approved
	participant.joined_at_ms = Time.get_ticks_msec()
	participant.last_seen_ms = participant.joined_at_ms
	return participant


func color() -> Color:
	if peer_id >= 0:
		return PALETTE[peer_id % PALETTE.size()]
	return PALETTE[0]


func display_name() -> String:
	var name: String = username if not username.is_empty() else "peer %d" % peer_id
	return "%s (host)" % name if is_host else name


func to_dict() -> Dictionary:
	return {
		"peer_id": peer_id,
		"username": username,
		"is_host": is_host,
		"approved": approved,
		"project_id": project_id,
		"scene_id": scene_id,
		"capabilities": capabilities,
	}


static func from_dict(data: Dictionary) -> CollabParticipant:
	var participant := CollabParticipant.new()
	participant.peer_id = int(data.get("peer_id", 0))
	participant.username = str(data.get("username", ""))
	participant.is_host = bool(data.get("is_host", false))
	participant.approved = bool(data.get("approved", true))
	participant.project_id = str(data.get("project_id", ""))
	participant.scene_id = str(data.get("scene_id", ""))
	var caps: Variant = data.get("capabilities", {})
	participant.capabilities = caps if typeof(caps) == TYPE_DICTIONARY else {}
	participant.last_seen_ms = Time.get_ticks_msec()
	return participant


func touch() -> void:
	last_seen_ms = Time.get_ticks_msec()
