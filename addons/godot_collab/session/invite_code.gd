@tool
## Invitation code encoding / decoding.
##
## Two kinds of invitation are supported and always resolve to a *real*
## endpoint (never a random string that assumes reachability):
##
## - direct: [code]gc1.<base64url>[/code] embeds host IP, port, session token,
##   project id and workspace mode. Works on LAN/loopback offline.
## - short: a 6 character code such as [code]K7P2QX[/code] registered with the
##   configured rendezvous service, which maps it to the host's direct endpoint.
##
## Use [method decode] to classify and parse an invitation string.
class_name CollabInviteCode
extends RefCounted

const DIRECT_PREFIX: String = "gc1."
const RELAY_PREFIX: String = "gc2."
const SHORT_ALPHABET: String = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" # no I/O/0/1
const SHORT_LENGTH: int = 6


static func encode_direct(host: String, port: int, token: String, project_id: String, workspace_mode: int) -> String:
	var payload: Dictionary = {
		"v": CollabConstants.PROTOCOL_VERSION,
		"h": host,
		"p": port,
		"t": token,
		"pid": project_id,
		"m": workspace_mode,
	}
	var json: String = JSON.stringify(payload)
	var b64: String = Marshalls.utf8_to_base64(json)
	return DIRECT_PREFIX + _base64_to_urlsafe(b64)


## Encodes a relay invitation: the client must connect to [param relay_host]:[param relay_port]
## and register in [param room] with [param token]. The relay forwards to the host.
## [param rendezvous_url] (optional) is the rendezvous service bundled with the
## relay; embedding it lets a client auto-configure the service URL when it pastes
## this long code, so short codes work afterwards without manual configuration.
static func encode_relay(relay_host: String, relay_port: int, room: String, token: String, project_id: String, workspace_mode: int, rendezvous_url: String = "") -> String:
	var payload: Dictionary = {
		"v": CollabConstants.PROTOCOL_VERSION,
		"rh": relay_host,
		"rp": relay_port,
		"room": room,
		"t": token,
		"pid": project_id,
		"m": workspace_mode,
		"rv": rendezvous_url,
	}
	var json: String = JSON.stringify(payload)
	var b64: String = Marshalls.utf8_to_base64(json)
	return RELAY_PREFIX + _base64_to_urlsafe(b64)


## Generates a short human-shareable code (to be registered with a rendezvous).
static func generate_short_code() -> String:
	var crypto := Crypto.new()
	var out: String = ""
	while out.length() < 6:
		var bytes: PackedByteArray = crypto.generate_random_bytes(8)
		for b in bytes:
			var c: String = SHORT_ALPHABET[b % SHORT_ALPHABET.length()]
			out += c
			if out.length() >= 6:
				break
	return out


## Classifies and parses an invitation string.
## Returns { kind: "direct"|"short"|"address"|"invalid", error, host, port, token,
## project_id, mode, code }.
static func decode(invite: String) -> Dictionary:
	var text: String = invite.strip_edges().replace("\n", "").replace(" ", "")
	if text.is_empty():
		return {"kind": "invalid", "error": "empty invitation"}
	if text.begins_with(DIRECT_PREFIX):
		return _decode_direct(text)
	if text.begins_with(RELAY_PREFIX):
		return _decode_relay(text)
	if _looks_like_address(text):
		return _decode_address(text)
	var upper: String = text.to_upper()
	if upper.length() == 6 and _valid_short(upper):
		return {"kind": "short", "code": upper, "host": "", "port": 0, "token": "", "project_id": "", "mode": 0}
	return {"kind": "invalid", "error": "unrecognised invitation format"}


static func _decode_direct(text: String) -> Dictionary:
	var payload_b64: String = text.substr(DIRECT_PREFIX.length())
	var standard: String = payload_b64.replace("-", "+").replace("_", "/")
	while standard.length() % 4 != 0:
		standard += "="
	var json_text: String = Marshalls.base64_to_utf8(standard)
	if json_text.is_empty():
		return {"kind": "invalid", "error": "corrupt invitation"}
	var parsed: Variant = JSON.parse_string(json_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"kind": "invalid", "error": "corrupt invitation payload"}
	var data: Dictionary = parsed
	if int(data.get("v", -1)) != CollabConstants.PROTOCOL_VERSION:
		return {"kind": "invalid", "error": "invitation protocol version mismatch"}
	return {
		"kind": "direct",
		"host": str(data.get("h", "")),
		"port": int(data.get("p", 0)),
		"token": str(data.get("t", "")),
		"project_id": str(data.get("pid", "")),
		"mode": int(data.get("m", 0)),
	}


static func _decode_relay(text: String) -> Dictionary:
	var payload_b64: String = text.substr(RELAY_PREFIX.length())
	var data: Dictionary = _decode_payload(payload_b64)
	if data.is_empty():
		return {"kind": "invalid", "error": "corrupt relay invitation"}
	if str(data.get("room", "")).is_empty():
		return {"kind": "invalid", "error": "relay invitation is missing a room code"}
	return {
		"kind": "relay",
		"host": str(data.get("rh", "")),
		"port": int(data.get("rp", 0)),
		"room": str(data.get("room", "")),
		"token": str(data.get("t", "")),
		"project_id": str(data.get("pid", "")),
		"mode": int(data.get("m", 0)),
		"rendezvous_url": str(data.get("rv", "")),
	}


## Decodes and version-checks a base64url payload, returning {} on any problem.
static func _decode_payload(payload_b64: String) -> Dictionary:
	var standard: String = payload_b64.replace("-", "+").replace("_", "/")
	while standard.length() % 4 != 0:
		standard += "="
	var json_text: String = Marshalls.base64_to_utf8(standard)
	if json_text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(json_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var data: Dictionary = parsed
	if int(data.get("v", -1)) != CollabConstants.PROTOCOL_VERSION:
		return {}
	return data


static func _decode_address(text: String) -> Dictionary:
	if text.count(":") != 1:
		return {"kind": "invalid", "error": "address must be host:port"}
	var parts: PackedStringArray = text.split(":")
	var port: int = int(parts[1])
	if port <= 0 or port > 65535:
		return {"kind": "invalid", "error": "invalid port"}
	return {"kind": "address", "host": parts[0], "port": port, "token": "", "project_id": "", "mode": 0}


static func _looks_like_address(text: String) -> bool:
	if text.count(":") != 1:
		return false
	var parts: PackedStringArray = text.split(":")
	if parts[0].is_empty() or parts[1].is_empty():
		return false
	return parts[1].is_valid_int()


static func _valid_short(code: String) -> bool:
	for i in code.length():
		if not SHORT_ALPHABET.contains(code[i]):
			return false
	return true


static func _base64_to_urlsafe(b64: String) -> String:
	return b64.replace("+", "-").replace("/", "_").replace("=", "")
