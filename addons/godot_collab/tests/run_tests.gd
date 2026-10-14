@tool
## Headless smoke tests for the Godot Collab add-on.
##
## Run with:
##   ~/.apps/Godot/Godot_v4.7.2/bin/godot --headless \
##     --script res://addons/godot_collab/tests/run_tests.gd
##
## These cover the pure/data layers (protocol framing, invitation codes, path
## validation, rate limiting) and a real ENet loopback handshake between a host
## and client coordinator. GUI-only behaviour (3D overlay drawing) still needs
## the manual procedure documented in docs/TESTING.md.
extends SceneTree

var _checks: int = 0
var _failures: Array[String] = []


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(label)
		print("  FAIL: ", label)


func _init() -> void:
	print("== Godot Collab headless tests ==")
	_test_protocol()
	_test_invite_codes()
	_test_path_guard()
	_test_rate_limiter()
	_test_loopback_session()

	print("")
	print("%d checks, %d failures" % [_checks, _failures.size()])
	if _failures.is_empty():
		print("RESULT: PASS")
		quit(0)
	else:
		for failure in _failures:
			print("  - ", failure)
		print("RESULT: FAIL")
		quit(1)


func _test_protocol() -> void:
	print("[protocol]")
	var payload: Dictionary = {"time_ms": 123, "label": "hello"}
	var bytes: PackedByteArray = CollabProtocol.encode(CollabProtocol.MessageType.PING, payload)
	_check(bytes.size() > CollabConstants.HEADER_SIZE, "encoded packet has header + body")
	var decoded: Dictionary = CollabProtocol.decode(bytes)
	_check(bool(decoded.get("ok", false)), "packet decodes")
	_check(int(decoded.get("type", -1)) == CollabProtocol.MessageType.PING, "type preserved")
	_check(int((decoded.get("payload", {}) as Dictionary).get("time_ms", 0)) == 123, "payload preserved")

	var corrupted: PackedByteArray = bytes.duplicate()
	corrupted[0] = 0x00
	_check(not bool(CollabProtocol.decode(corrupted).get("ok", true)), "bad magic rejected")

	var truncated: PackedByteArray = bytes.slice(0, CollabConstants.HEADER_SIZE - 2)
	_check(not bool(CollabProtocol.decode(truncated).get("ok", true)), "truncated packet rejected")

	# CURSOR_UPDATE requires transform fields.
	var bad_cursor: PackedByteArray = CollabProtocol.encode(CollabProtocol.MessageType.CURSOR_UPDATE, {"time_ms": 1})
	var bad_decoded: Dictionary = CollabProtocol.decode(bad_cursor)
	_check(not bool(bad_decoded.get("ok", true)), "cursor payload validated")


func _test_invite_codes() -> void:
	print("[invite codes]")
	var invite: String = CollabInviteCode.encode_direct("192.168.1.5", 45899, "tok123", "proj-1", CollabConstants.WorkspaceMode.GIT_PRESENCE)
	_check(invite.begins_with("gc1."), "direct invite prefixed")
	var parsed: Dictionary = CollabInviteCode.decode(invite)
	_check(str(parsed.get("kind", "")) == "direct", "direct kind")
	_check(str(parsed.get("host", "")) == "192.168.1.5", "host round-trips")
	_check(int(parsed.get("port", 0)) == 45899, "port round-trips")
	_check(str(parsed.get("token", "")) == "tok123", "token round-trips")
	_check(int(parsed.get("mode", -1)) == CollabConstants.WorkspaceMode.GIT_PRESENCE, "mode round-trips")

	var short: Dictionary = CollabInviteCode.decode("K7P2QX")
	_check(str(short.get("kind", "")) == "short" and str(short.get("code", "")) == "K7P2QX", "short code parsed")

	var address: Dictionary = CollabInviteCode.decode("10.0.0.2:45899")
	_check(str(address.get("kind", "")) == "address", "address kind")
	_check(str(address.get("host", "")) == "10.0.0.2" and int(address.get("port", 0)) == 45899, "address parsed")

	_check(str(CollabInviteCode.decode("!!!nonsense!!!").get("kind", "")) == "invalid", "garbage rejected")

	var generated: String = CollabInviteCode.generate_short_code()
	_check(generated.length() == 6, "generated short code has length 6")
	_check(str(CollabInviteCode.decode(generated).get("kind", "")) == "short", "generated code parses as short")

	var info: Dictionary = CollabConnectivity.evaluate("", "", false)
	_check(info.has("state") and info.has("detail"), "connectivity evaluate returns state + detail")


func _test_path_guard() -> void:
	print("[path guard]")
	_check(CollabPathGuard.is_safe_relative("res://a/b.txt".replace("res://", "")), "plain relative path safe")
	_check(not CollabPathGuard.is_safe_relative("../secrets.txt"), "parent traversal rejected")
	_check(not CollabPathGuard.is_safe_relative("a/../../b"), "nested traversal rejected")
	_check(not CollabPathGuard.is_safe_relative("/etc/passwd"), "absolute path rejected")
	_check(not CollabPathGuard.is_safe_relative("C:/Windows/system32"), "drive path rejected")
	var resolved: String = CollabPathGuard.resolve_within("/tmp/opencode/ws", "sub/file.txt")
	_check(resolved.begins_with("/tmp/opencode/ws"), "resolve stays inside root")
	_check(CollabPathGuard.resolve_within("/tmp/opencode/ws", "../../etc/passwd").is_empty(), "escape resolve rejected")


func _test_rate_limiter() -> void:
	print("[rate limiter]")
	var limiter := CollabRateLimiter.new(3.0, 0.0)
	var allowed: int = 0
	for i in 6:
		if limiter.try_consume():
			allowed += 1
	_check(allowed == 3, "burst limited to capacity (got %d)" % allowed)


func _test_loopback_session() -> void:
	print("[loopback session]")
	var logs := CollabLog.new()
	var port: int = 45977

	var host_manager := CollabSessionManager.new(logs)
	var host := CollabSessionCoordinator.new()
	host.setup(host_manager, logs)

	var client_manager := CollabSessionManager.new(logs)
	var client := CollabSessionCoordinator.new()
	client.setup(client_manager, logs)

	# Dictionaries are reference types, so lambdas can mutate this shared state
	# (GDScript lambdas capture plain locals by value).
	var state: Dictionary = {
		"client_joined": false,
		"client_saw_host": false,
		"host_cursor_from_peer": -1,
		"host_stopped": false,
	}

	client.session_started.connect(func(_is_host: bool) -> void: state["client_joined"] = true)
	client.participants_changed.connect(func() -> void:
		for p in client.registry.all():
			if p.is_host:
				state["client_saw_host"] = true)
	host.cursor_received.connect(func(peer_id: int, _payload: Dictionary) -> void: state["host_cursor_from_peer"] = peer_id)

	var err: Error = host.start_host(port, 4, CollabConstants.WorkspaceMode.HOST_WORKSPACE, false)
	_check(err == OK, "host starts (%s)" % error_string(err))
	err = client.join("127.0.0.1", port, "")
	_check(err == OK, "client join call starts (%s)" % error_string(err))

	var deadline: int = Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < deadline:
		host.poll()
		client.poll()
		if bool(state["client_joined"]) and host.registry.count() >= 2 and client.registry.count() >= 2:
			break
		OS.delay_msec(5)

	_check(bool(state["client_joined"]), "client received WELCOME")
	_check(host.registry.count() == 2, "host registry has 2 participants (got %d)" % host.registry.count())
	_check(client.registry.count() >= 2, "client registry has 2 participants (got %d)" % client.registry.count())
	_check(bool(state["client_saw_host"]), "client sees the host in its registry")

	if bool(state["client_joined"]):
		client.send_cursor({
			"camera_transform": Transform3D.IDENTITY,
			"ray_origin": Vector3.ZERO,
			"ray_direction": Vector3.FORWARD,
			"viewport_pos": Vector2(0.5, 0.5),
			"scene_id": "",
			"time_ms": Time.get_ticks_msec(),
		})
		var cursor_deadline: int = Time.get_ticks_msec() + 3000
		while Time.get_ticks_msec() < cursor_deadline and int(state["host_cursor_from_peer"]) < 0:
			host.poll()
			client.poll()
			OS.delay_msec(5)
		_check(int(state["host_cursor_from_peer"]) >= 0, "host received a relayed cursor")

	# Disconnect and verify the client observes the host leaving.
	client.session_stopped.connect(func(_reason: String) -> void: state["host_stopped"] = true)
	host.stop("test end")
	var stop_deadline: int = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < stop_deadline and not bool(state["host_stopped"]):
		client.poll()
		OS.delay_msec(5)
	_check(bool(state["host_stopped"]), "client saw the host disconnect")

	client.stop("cleanup")
	host.free()
	client.free()
	host_manager.free()
	client_manager.free()
