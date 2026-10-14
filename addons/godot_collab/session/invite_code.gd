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
