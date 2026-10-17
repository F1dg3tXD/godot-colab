@tool
## Minimal HTTP client for the optional rendezvous service.
##
## The rendezvous maps a short invitation code to the host's direct endpoint.
## It is *not* a relay: once the client resolves a code it still connects
## directly over ENet. When rendezvous is unavailable the dock falls back to
## direct (embedded/`host:port`) invitations.
class_name CollabRendezvousClient
extends Node

signal registered(code: String, ok: bool, error: String)
signal lookup_completed(code: String, ok: bool, data: Dictionary, error: String)

var _base_url: String = ""
var _logs: CollabLog
var _http: HTTPRequest
var _queue: Array = [] # [{kind, code, body}]


func setup(logs: CollabLog) -> void:
	_logs = logs
	_http = HTTPRequest.new()
	_http.timeout = 10.0
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)


func set_base_url(url: String) -> void:
	_base_url = url.strip_edges().trim_suffix("/")


func base_url() -> String:
	return _base_url


func is_configured() -> bool:
	return not _base_url.is_empty()


## Registers a short code with the rendezvous service.
func register_code(code: String, host: String, port: int, token: String, ttl: int, project_id: String, mode: int) -> void:
	if not is_configured():
		registered.emit(code, false, "no rendezvous service configured")
		return
	_queue.append({
		"kind": "register", "code": code,
		"body": {
			"kind": "direct",
			"code": code, "host": host, "port": port, "token": token,
			"ttl": ttl, "project_id": project_id, "mode": mode,
		},
	})
	_pump()


## Registers a short code that resolves to a *relay* session. A client that
## looks the code up receives the relay endpoint, room and token, so a short code
## works for relay-hosted sessions too (the client still needs this rendezvous'
## URL configured, which the long relay code embeds).
func register_relay_code(code: String, relay_host: String, relay_port: int, room: String, token: String, ttl: int, project_id: String, mode: int) -> void:
	if not is_configured():
		registered.emit(code, false, "no rendezvous service configured")
		return
	_queue.append({
		"kind": "register", "code": code,
		"body": {
			"kind": "relay",
			"code": code, "relay_host": relay_host, "relay_port": relay_port,
			"room": room, "token": token,
			"ttl": ttl, "project_id": project_id, "mode": mode,
		},
	})
	_pump()


## Resolves a short code to a direct endpoint or a relay room.
func lookup(code: String) -> void:
	if not is_configured():
		lookup_completed.emit(code, false, {}, "no rendezvous service configured")
		return
	_queue.append({"kind": "lookup", "code": code, "body": {}})
	_pump()


func _pump() -> void:
	if _queue.is_empty() or _http == null:
		return
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return # a request is already in flight
	var job: Dictionary = _queue[0]
	var url: String = ""
	var method: int = HTTPClient.METHOD_GET
	var body: String = ""
	if str(job["kind"]) == "register":
		url = "%s/register" % _base_url
		method = HTTPClient.METHOD_POST
		body = JSON.stringify(job["body"])
	else:
		url = "%s/lookup?code=%s" % [_base_url, str(job["code"]).uri_encode()]
	if _http.request(url, PackedStringArray(["Content-Type: application/json"]), method, body) != OK:
		_emit(str(job["kind"]), str(job["code"]), false, {}, "could not start request")
		_queue.pop_front()


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _queue.is_empty():
		return
	var job: Dictionary = _queue.pop_front()
	var ok: bool = result == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300
	var data: Dictionary = {}
	var error: String = ""
	if not ok:
		error = "rendezvous request failed (result=%d http=%d)" % [result, response_code]
	else:
		var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
		if typeof(parsed) == TYPE_DICTIONARY:
			data = parsed
		else:
			ok = false
			error = "invalid rendezvous response"
	_emit(str(job["kind"]), str(job["code"]), ok, data, error)
	_pump()


func _emit(kind: String, code: String, ok: bool, data: Dictionary, error: String) -> void:
	if kind == "register":
		registered.emit(code, ok, error)
	else:
		lookup_completed.emit(code, ok, data, error)
