@tool
## Entry point for the Godot Collab editor add-on.
##
## Wires the isolated ENet transport, the session coordinator, presence, scene
## collaboration, saving and project transfer into the editor dock and the 3D
## viewport overlays. Everything is created here and destroyed in
## [method _exit_tree]; the add-on never touches the editor's global
## [MultiplayerAPI] peer.
extends EditorPlugin

const DOCK_SLOT: int = EditorPlugin.DOCK_SLOT_LEFT_UR

var _logs: CollabLog
var _settings: CollabSettings
var _editor: EditorInterface

var _session_manager: CollabSessionManager
var _coordinator: CollabSessionCoordinator
var _presence: CollabPresenceService
var _markers: CollabMarkerManager
var _scene_sync: CollabSceneSyncService
var _save_service: CollabSaveService
var _workspace: CollabWorkspaceService
var _transfer: CollabTransferManager
var _rendezvous: CollabRendezvousClient
var _upnp: CollabUpnpForwarder

var _dock: CollabDock
var _toolbar: CollabToolbar

## Guards against reacting to the editor's own `scene_saved` signal when the
## add-on saves programmatically, which would otherwise recurse.
var _suppress_save_signal: bool = false

var _attached_scene_id: String = ""
var _bound_scene_ids: Dictionary = {}
var _last_focus_sent: String = ""
var _project_id_cache: String = ""
var _scene_dirty: bool = false
var _upnp_attempted: bool = false
var _upnp_external: String = ""
var _short_code: String = ""
var _pending_lookup: bool = false
var _last_connectivity_state: int = -1


func _enter_tree() -> void:
	_editor = get_editor_interface()
	_logs = CollabLog.new()
	_settings = CollabSettings.new(_editor.get_editor_settings() if _editor != null else null)
	_settings.register_defaults()

	_project_id_cache = ""

	_session_manager = CollabSessionManager.new()
	_session_manager.name = "CollabSessionManager"
	_session_manager.set_logger(_logs)
	add_child(_session_manager)

	_coordinator = CollabSessionCoordinator.new()
	_coordinator.name = "CollabCoordinator"
	add_child(_coordinator)
	_coordinator.session_manager = _session_manager
	_coordinator.setup(_session_manager, _logs)
	_coordinator.get_project_id = Callable(self, "_project_id")
	_coordinator.get_scene_id = Callable(self, "_edited_scene_path")
	_coordinator.get_username = Callable(self, "_username")
	_coordinator.capabilities = {
		"cursor": true,
		"scene_ops": true,
		"project_transfer": true,
		"save": true,
	}
	_coordinator.workspace_mode = CollabConstants.WorkspaceMode.HOST_WORKSPACE
	_wire_coordinator()

	var editor_callables: Dictionary = {
		"get_edited_root": Callable(self, "_edited_root"),
		"mark_unsaved": Callable(self, "_mark_scene_unsaved"),
		"refresh_inspector": Callable(self, "_refresh_inspector"),
		"save_scene": Callable(self, "_save_scene"),
		"get_edited_scene_path": Callable(self, "_edited_scene_path"),
		"is_scene_modified": Callable(self, "_is_scene_modified"),
		"refresh_resource_file": Callable(self, "_refresh_resource_file"),
	}

	_presence = CollabPresenceService.new()
	_presence.setup(_coordinator, _settings, _logs)
	_presence.set_editor_interface_provider(Callable(self, "get_editor_interface"))
	add_child(_presence)

	_markers = CollabMarkerManager.new()
	_markers.setup(_coordinator, _settings, _logs, _presence.cursor_state)
	_markers.set_viewport_provider(Callable(self, "_editor_viewport_3d"))
	add_child(_markers)

	_scene_sync = CollabSceneSyncService.new()
	_scene_sync.setup(_coordinator, _logs, editor_callables)
	add_child(_scene_sync)
	_scene_sync.status.connect(_on_sync_status)
	_scene_sync.error_raised.connect(_on_sync_error)
	_scene_sync.conflict.connect(_on_conflict)
	_scene_sync.snapshot_offered.connect(_on_snapshot_offered)
	_scene_sync.revision_changed.connect(_on_revision_changed)

	_save_service = CollabSaveService.new()
	_save_service.setup(_coordinator, _settings, _logs, editor_callables)
	_save_service.on_remote_save = Callable(self, "_on_save_requested")
	add_child(_save_service)
	_save_service.saved.connect(_on_saved)
	_save_service.save_failed.connect(_on_save_failed)
	_save_service.status.connect(_on_save_status)

	_workspace = CollabWorkspaceService.new()
	_workspace.setup(_coordinator, _settings, _logs, Callable(self, "_project_root"), editor_callables)
	_workspace.open_scene_paths = Callable(self, "_open_scene_paths")
	add_child(_workspace)
	_workspace.status.connect(_on_workspace_status)
	_workspace.error_raised.connect(_on_error)
	_workspace.request_result.connect(_on_workspace_result)
	_workspace.scene_list_received.connect(_on_scene_list)

	_transfer = CollabTransferManager.new()
	_transfer.setup(_coordinator, _settings, _logs, Callable(self, "_project_root"))
	add_child(_transfer)
	_transfer.status.connect(_on_project_status)
	_transfer.progress.connect(_on_transfer_progress)
	_transfer.completed.connect(_on_transfer_completed)
	_transfer.failed.connect(_on_transfer_failed)
	_transfer.manifest_ready.connect(_on_manifest_ready)
	_transfer.approval_required.connect(_on_transfer_approval_required)

	_rendezvous = CollabRendezvousClient.new()
	_rendezvous.setup(_logs)
	_rendezvous.set_base_url(_settings.get_string(CollabSettings.KEY_RENDEZVOUS_URL, ""))
	add_child(_rendezvous)
	_rendezvous.registered.connect(_on_rendezvous_registered)
	_rendezvous.lookup_completed.connect(_on_rendezvous_lookup)

	_upnp = CollabUpnpForwarder.new()

	_build_dock()
	_build_toolbar()
	scene_saved.connect(_on_scene_saved)

	# Receive mouse motion even when no 3D control is dragging, and keep
	# painting overlays every frame so remote cursors stay smooth.
	set_input_event_forwarding_always_enabled()
	set_force_draw_over_forwarding_enabled()

	if _editor != null:
		_ensure_scene_binding()


func _exit_tree() -> void:
	if _transfer != null:
		_transfer.cancel()
	if _coordinator != null:
		_coordinator.stop("plugin disabled")
	if _upnp != null:
		_upnp.close()
	if scene_saved.is_connected(_on_scene_saved):
		scene_saved.disconnect(_on_scene_saved)
	if _toolbar != null:
		remove_control_from_container(EditorPlugin.CONTAINER_TOOLBAR, _toolbar)
		_toolbar.queue_free()
		_toolbar = null
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
	for node in [_presence, _markers, _scene_sync, _save_service, _workspace, _transfer, _rendezvous, _coordinator, _session_manager]:
		if node != null and is_instance_valid(node):
			remove_child(node)
			node.free()
	_presence = null
	_markers = null
	_scene_sync = null
	_save_service = null
	_workspace = null
	_transfer = null
	_rendezvous = null
	_coordinator = null
	_session_manager = null
	_editor = null


func _process(delta: float) -> void:
	if _coordinator == null:
		return
	_times += 1
	_ensure_scene_binding()
	_coordinator.poll()
	_scene_sync.poll()
	_save_service.poll()
	_workspace.poll()
	_transfer.poll()
	if _coordinator.session_manager.is_active():
		update_overlays()
		_markers.poll()
	# Keep the dock's participant list and connectivity reasonably fresh.
	if _coordinator.session_manager.is_active() and _times % 15 == 0:
		_dock.set_participants(_coordinator.registry.all())


var _times: int = 0


# ---------------------------------------------------------------------------
# Dock wiring
# ---------------------------------------------------------------------------

func _build_dock() -> void:
	_dock = CollabDock.new()
	_dock.name = "GodotCollab"
	add_control_to_dock(DOCK_SLOT, _dock)
	_dock.host_requested.connect(_on_host_requested)
	_dock.join_requested.connect(_on_join_requested)
	_dock.disconnect_requested.connect(_on_disconnect_requested)
	_dock.approve_requested.connect(_on_approve_requested)
	_dock.reject_requested.connect(_on_reject_requested)
	_dock.kick_requested.connect(_on_kick_requested)
	_dock.save_requested.connect(_on_save_requested)
	_dock.download_requested.connect(_on_download_requested)
	_dock.cancel_transfer_requested.connect(_on_cancel_transfer_requested)
	_dock.snapshot_requested.connect(_on_snapshot_requested)
	_dock.snapshot_apply_requested.connect(_on_snapshot_apply_requested)
	_dock.snapshot_discard_requested.connect(_on_snapshot_discard_requested)
	_dock.new_scene_requested.connect(_on_new_scene_requested)
	_dock.add_file_requested.connect(_on_add_file_requested)
	_dock.open_scene_requested.connect(_on_open_scene_requested)
	_dock.refresh_scenes_requested.connect(_on_refresh_scenes_requested)
	_dock.username_changed.connect(_on_username_changed)
	_dock.setup(_settings)
	_dock.set_connection_status(CollabConstants.ConnectionState.DISCONNECTED, "Not connected")


## Places the session controls in the editor's top toolbar (next to the
## playtest buttons / Asset Store tab) so they are reachable without opening the
## dock. The dock keeps the settings and invitation code these buttons operate on.
func _build_toolbar() -> void:
	_toolbar = CollabToolbar.new()
	add_control_to_container(EditorPlugin.CONTAINER_TOOLBAR, _toolbar)
	_toolbar.host_requested.connect(_dock.request_host)
	_toolbar.join_requested.connect(_dock.request_join)
	_toolbar.paste_join_requested.connect(_dock.request_paste_join)
	_toolbar.copy_requested.connect(_dock.request_copy)
	_toolbar.snapshot_requested.connect(_on_snapshot_requested)
	_toolbar.disconnect_requested.connect(_on_disconnect_requested)
	_toolbar.set_session_active(false)
	_toolbar.set_invite_available(false)


## Updates the invitation code in the dock and the toolbar's copy button state.
func _set_invite(invite: String) -> void:
	if _dock != null:
		_dock.set_invite(invite)
	if _toolbar != null:
		_toolbar.set_invite_available(not invite.strip_edges().is_empty())


func _on_host_requested(username: String, port: int, mode: int, use_rendezvous: bool) -> void:
	if _coordinator.session_manager.is_active():
		_dock.push_message("Already in a session. Disconnect first.", true)
		return
	_settings.set_value(CollabSettings.KEY_USERNAME, username)
	_coordinator.username = username
	_coordinator.workspace_mode = mode
	_coordinator.capabilities = {"scene_ops": true, "cursors": true, "transfer": true, "save": mode == CollabConstants.WorkspaceMode.HOST_WORKSPACE}
	_coordinator.approve_joins = _settings.get_bool(CollabSettings.KEY_APPROVE_JOINS, false)
	_coordinator.require_token = _settings.get_bool(CollabSettings.KEY_REQUIRE_TOKEN, true)
	var max_peers: int = clampi(_settings.get_int(CollabSettings.KEY_MAX_PEERS, CollabConstants.DEFAULT_MAX_PEERS), 1, 64)
	var err: Error = _coordinator.start_host(port, max_peers, mode, _coordinator.approve_joins)
	if err != OK:
		_dock.push_message("Failed to host: %s" % error_string(err), true)
		return
	_upnp_attempted = false
	_upnp_external = ""
	if _settings.get_bool(CollabSettings.KEY_ENABLE_UPNP, false):
		_upnp_attempted = true
		var result: Dictionary = _upnp.forward_udp(port)
		if bool(result.get("ok", false)):
			_upnp_external = str(result.get("external_address", ""))
		else:
			_dock.push_message("UPnP failed: %s. Use manual port forwarding or LAN." % str(result.get("error", "")), true)
	_establish_invite(use_rendezvous, port, mode)
	_update_connectivity()


func _establish_invite(use_rendezvous: bool, port: int, mode: int) -> void:
	_short_code = ""
	var advertise: String = _settings.get_string(CollabSettings.KEY_DIRECT_ADVERTISE_HOST, "")
	if use_rendezvous and _rendezvous.is_configured():
		_short_code = CollabInviteCode.generate_short_code()
		var host_for_reg: String = advertise if not advertise.is_empty() else _primary_lan_address()
		_rendezvous.register_code(_short_code, host_for_reg, port, _coordinator.session_token, CollabConstants.INVITE_TTL_SECONDS, _project_id(), mode)
		_set_invite(_short_code)
		_dock.push_message("Registering invitation code with rendezvous service...", false)
	else:
		if use_rendezvous and not _rendezvous.is_configured():
			_dock.push_message("No rendezvous URL configured; falling back to a direct invitation code.", false)
		_fallback_to_direct_invite(advertise, port, mode)


func _fallback_to_direct_invite(advertise: String, port: int, mode: int) -> void:
	var host_ip: String = advertise if not advertise.is_empty() else _primary_lan_address()
	var invite: String = CollabInviteCode.encode_direct(host_ip, port, _coordinator.session_token, _project_id(), mode)
	_set_invite(invite)


func _on_rendezvous_registered(code: String, ok: bool, error: String) -> void:
	if _dock == null:
		return
	if ok:
		_set_invite(code)
		_dock.push_message("Invitation code '%s' registered." % code, false)
	else:
		_dock.push_message("Rendezvous registration failed (%s). Using a direct invitation code." % error, true)
		_fallback_to_direct_invite(_settings.get_string(CollabSettings.KEY_DIRECT_ADVERTISE_HOST, ""), _coordinator.host_port, _coordinator.workspace_mode)


func _on_join_requested(invite: String) -> void:
	if _coordinator.session_manager.is_active():
		_dock.push_message("Already in a session. Disconnect first.", true)
		return
	var parsed: Dictionary = CollabInviteCode.decode(invite)
	var kind: String = str(parsed.get("kind", "invalid"))
	if kind == "invalid":
		_dock.push_message("Invalid invitation code '%s': %s" % [invite, str(parsed.get("error", "unknown"))], true)
		return
	_coordinator.username = _settings.get_string(CollabSettings.KEY_USERNAME, "peer")
	if kind == "short":
		if not _rendezvous.is_configured():
			_dock.push_message("Code '%s' is a short code but no rendezvous service is configured." % str(parsed.get("code", "")), true)
			return
		_coordinator.require_token = true
		_pending_lookup = true
		_dock.push_message("Resolving short code %s via the rendezvous service..." % str(parsed.get("code", "")), false)
		_rendezvous.lookup(str(parsed.get("code", "")))
		return
	_pending_lookup = false
	var host: String = str(parsed.get("host", ""))
	var port: int = int(parsed.get("port", 0))
	var token: String = str(parsed.get("token", ""))
	_coordinator.require_token = not token.is_empty()
	_join_endpoint(host, port, token, int(parsed.get("mode", CollabConstants.WorkspaceMode.HOST_WORKSPACE)))


func _on_rendezvous_lookup(code: String, ok: bool, data: Dictionary, error: String) -> void:
	if not _pending_lookup:
		return
	_pending_lookup = false
	if not ok:
		_dock.push_message("Could not resolve '%s': %s" % [code, error], true)
		return
	_join_endpoint(str(data.get("host", "")), int(data.get("port", 0)), str(data.get("token", "")), int(data.get("mode", CollabConstants.WorkspaceMode.HOST_WORKSPACE)))


func _join_endpoint(host: String, port: int, token: String, mode: int) -> void:
	if host.is_empty() or port <= 0:
		_dock.push_message("Invitation is missing a host or port (got '%s:%d')." % [host, port], true)
		return
	_coordinator.workspace_mode = mode
	_dock.set_connection_status(CollabConstants.ConnectionState.CONNECTING, "Connecting to %s:%d" % [host, port])
	_dock.push_message("Connecting to host at %s:%d..." % [host, port], false)
	var err: Error = _coordinator.join(host, port, token)
	if err != OK:
		_dock.set_connection_status(CollabConstants.ConnectionState.DISCONNECTED, "Not connected")
		_dock.push_message("Failed to connect to %s:%d: %s" % [host, port, error_string(err)], true)


func _on_join_pending() -> void:
	_dock.set_connection_status(CollabConstants.ConnectionState.CONNECTING, "Waiting for host approval")
	_dock.push_message("Connected to the host. Waiting for the host to approve your join request...", false)


func _on_disconnect_requested() -> void:
	_coordinator.stop("disconnected by user")
	_coordinator.registry.clear()
	_dock.set_participants([])
	_dock.set_scenes([])
	_set_invite("")
	_dock.set_connection_status(CollabConstants.ConnectionState.DISCONNECTED, "Not connected")
	_dock.set_connectivity(CollabConstants.ConnectivityState.UNKNOWN, "Not hosting")
	_dock.set_hosting_controls(false)
	if _toolbar != null:
		_toolbar.set_session_active(false)
		_toolbar.set_invite_available(false)


func _on_approve_requested(peer_id: int) -> void:
	_coordinator.approve_peer(peer_id)


func _on_reject_requested(peer_id: int) -> void:
	_coordinator.deny_peer(peer_id)


func _on_kick_requested(peer_id: int) -> void:
	_coordinator.kick(peer_id)


func _on_save_requested() -> void:
	# Persist remote edits applied to scenes the host is not currently viewing
	# first, then save the focused scene through the editor's own save API.
	var persisted: int = _scene_sync.persist_host_scenes()
	if persisted > 0:
		_dock.push_message("Persisted remote edits in %d scene(s)." % persisted, false)
	_suppress_save_signal = true
	_save_service.save_now()
	_suppress_save_signal = false


## Fires whenever the editor saves a scene (for example on the user's Ctrl+S).
## In a live session a host save is promoted to a full shared save (persisting
## every scene with remote edits) and a client save is forwarded to the host, so a
## normal Ctrl+S behaves the same for everyone.
func _on_scene_saved(_filepath: String) -> void:
	if _suppress_save_signal:
		return
	if _coordinator == null or not _coordinator.session_manager.is_active():
		return
	if _coordinator.workspace_mode == CollabConstants.WorkspaceMode.GIT_PRESENCE:
		return
	if _coordinator.is_host():
		_on_save_requested()
	else:
		# The client's own scene file was just written by the editor; ask the
		# authoritative host to persist the shared workspace and notify everyone.
		_suppress_save_signal = true
		_save_service.save_now()
		_suppress_save_signal = false


func _on_download_requested(root: String) -> void:
	if _coordinator.workspace_mode == CollabConstants.WorkspaceMode.GIT_PRESENCE:
		_dock.push_message("Project download is disabled in Git presence mode.", true)
		return
	var error: String = _transfer.start_download(root)
	if not error.is_empty():
		_dock.push_message(error, true)


func _on_cancel_transfer_requested() -> void:
	_transfer.cancel()


func _on_snapshot_requested() -> void:
	_scene_sync.request_snapshot()


func _on_snapshot_apply_requested() -> void:
	_scene_sync.apply_pending_snapshot()


func _on_snapshot_discard_requested() -> void:
	_scene_sync.discard_pending_snapshot()


func _on_username_changed(username: String) -> void:
	_settings.set_value(CollabSettings.KEY_USERNAME, username)
	_coordinator.username = username


# ---------------------------------------------------------------------------
# Coordinator callbacks
# ---------------------------------------------------------------------------

func _wire_coordinator() -> void:
	_coordinator.session_started.connect(_on_session_started)
	_coordinator.session_stopped.connect(_on_session_stopped)
	_coordinator.participants_changed.connect(_on_participants_changed)
	_coordinator.join_request.connect(_on_join_request)
	_coordinator.join_resolved.connect(_on_join_resolved)
	_coordinator.join_pending.connect(_on_join_pending)
	_coordinator.compatibility_warning.connect(_on_compatibility_warning)
	_coordinator.notice.connect(_on_notice)
	_coordinator.error_raised.connect(_on_error)


func _on_session_started(is_host: bool) -> void:
	if is_host:
		_dock.set_connection_status(CollabConstants.ConnectionState.HOSTING, "Hosting session")
	else:
		_dock.set_connection_status(CollabConstants.ConnectionState.CONNECTED, "Connected to host")
	_dock.set_hosting_controls(true)
	_dock.set_mode(_coordinator.workspace_mode)
	_dock.set_participants(_coordinator.registry.all())
	if _toolbar != null:
		_toolbar.set_session_active(true)
	_dock.push_message("Note: editing files under addons/ while a session is live is not supported and can crash clients.", true)
	_ensure_scene_binding()
	_last_focus_sent = ""
	_coordinator.send_scene_focus(_attached_scene_id)
	if _workspace.enabled and _settings.get_bool(CollabSettings.KEY_FILE_SYNC, true):
		_workspace.file_sync_enabled = true
		_workspace.prime_file_baseline()
	else:
		_workspace.file_sync_enabled = false
	if is_host and _workspace.enabled:
		_workspace.broadcast_scene_list()
		_dock.set_scenes(_workspace.scan_scenes())
	elif not is_host and _scene_sync.enabled:
		# Ask for the authoritative snapshot so node ids are reconciled with the
		# host even before the first edit. Without this a rejoining client could
		# target a same-numbered but different local node.
		_scene_sync.request_snapshot()


func _on_session_stopped(reason: String) -> void:
	_workspace.file_sync_enabled = false
	_presence.cursor_state.clear()
	_dock.set_participants([])
	_dock.set_scenes([])
	_dock.set_connection_status(CollabConstants.ConnectionState.DISCONNECTED, "Disconnected: %s" % reason)
	_dock.set_hosting_controls(false)
	if _toolbar != null:
		_toolbar.set_session_active(false)
	_set_invite("")
	_short_code = ""
	if _upnp != null:
		_upnp.close()
	_upnp_external = ""


func _on_participants_changed() -> void:
	_dock.set_participants(_coordinator.registry.all())


func _on_join_request(peer_id: int, username: String, _project_id: String) -> void:
	_dock.add_join_request(peer_id, username)


func _on_join_resolved(peer_id: int, approved: bool) -> void:
	_dock.remove_join_request(peer_id)
	if not approved:
		_dock.push_message("Rejected join request from peer %d." % peer_id, false)


func _on_compatibility_warning(text: String) -> void:
	_dock.push_message("Compatibility: %s" % text, true)


func _on_notice(text: String) -> void:
	_dock.push_message(text, false)


func _on_error(text: String) -> void:
	_dock.push_message(text, true)


func _on_sync_status(text: String) -> void:
	_dock.set_sync_status(text)


func _on_sync_error(text: String) -> void:
	_dock.set_sync_status("Sync error: %s" % text)


func _on_conflict(text: String) -> void:
	_dock.push_message("Conflict: %s" % text, true)


func _on_snapshot_offered(node_count: int, revision: int) -> void:
	_dock.push_message("Snapshot (%d nodes, revision %d) awaits confirmation." % [node_count, revision], false)


func _on_revision_changed(_revision: int) -> void:
	_scene_dirty = true


func _on_saved(path: String) -> void:
	_scene_dirty = false
	_dock.set_save_status("Saved to %s" % path)


func _on_save_failed(text: String) -> void:
	_dock.set_save_status("Save failed: %s" % text)


func _on_save_status(text: String) -> void:
	_dock.set_save_status(text)


func _on_project_status(text: String) -> void:
	_dock.set_project_status(text)


func _on_transfer_progress(transfer_id: int, path: String, received: int, total: int) -> void:
	if total > 0:
		_dock.set_transfer_progress("%s %d/%d" % [path.get_file(), received, total])
	else:
		_dock.set_transfer_progress(path.get_file())


func _on_transfer_completed(files_written: int, bytes: int, root: String) -> void:
	_dock.set_transfer_progress("")
	_dock.push_message("Project downloaded: %d files (%d bytes) to %s" % [files_written, bytes, root], false)


func _on_transfer_failed(text: String) -> void:
	_dock.push_message("Project transfer failed: %s" % text, true)


func _on_manifest_ready(files: Array, project_id: String) -> void:
	_dock.push_message("Host manifest ready: %d files (project %s)." % [files.size(), project_id], false)


func _on_transfer_approval_required(peer_id: int, transfer_id: int) -> void:
	_dock.push_message("Peer %d requested a project download (transfer %d)." % [peer_id, transfer_id], false)


# ---------------------------------------------------------------------------
# Editor callables
# ---------------------------------------------------------------------------

func _project_root() -> String:
	return ProjectSettings.globalize_path("res://").simplify_path()


func _project_id() -> String:
	if _project_id_cache.is_empty():
		_project_id_cache = CollabIdentity.project_id_from_root(_project_root())
	return _project_id_cache


func _edited_scene_path() -> String:
	var root: Node = _edited_root()
	if root != null:
		return root.scene_file_path
	return ""


func _edited_root() -> Node:
	if _editor == null:
		return null
	return _editor.get_edited_scene_root()


func _editor_viewport_3d() -> SubViewport:
	if _editor == null:
		return null
	return _editor.get_editor_viewport_3d()


func _save_scene() -> int:
	if _editor == null:
		return FAILED
	return _editor.save_scene()


func _mark_scene_unsaved() -> void:
	if _editor != null:
		_editor.mark_scene_as_unsaved()


func _refresh_inspector(node: Node) -> void:
	if _editor == null:
		return
	var inspector: EditorInspector = _editor.get_inspector()
	if inspector == null:
		return
	var edited: Object = inspector.get_edited_object()
	if edited == node or edited == null:
		inspector.edit(node)


func _is_scene_modified() -> bool:
	return _scene_dirty


func _refresh_resource_file(res_path: String) -> void:
	if _editor == null:
		return
	var filesystem: EditorFileSystem = _editor.get_resource_filesystem()
	if filesystem == null:
		return
	filesystem.update_file(res_path)


# ---------------------------------------------------------------------------
# Workspace authoring (new scenes / added files)
# ---------------------------------------------------------------------------

func _on_new_scene_requested(path: String, root_class: String) -> void:
	var err: String = _workspace.request_new_scene(path, root_class)
	if not err.is_empty():
		_dock.push_message(err, true)


func _on_add_file_requested(path: String, content: String) -> void:
	var err: String = _workspace.request_add_file(path, content, true)
	if not err.is_empty():
		_dock.push_message(err, true)


func _on_open_scene_requested(path: String) -> void:
	if _editor == null or path.is_empty():
		return
	if not ResourceLoader.exists(path):
		_dock.push_message("Scene '%s' is not available locally yet." % path, true)
		return
	_editor.open_scene_from_path(path, false)


func _on_refresh_scenes_requested() -> void:
	if _coordinator.is_host():
		_workspace.broadcast_scene_list()
	else:
		_workspace.request_scene_list()


func _on_workspace_status(text: String) -> void:
	_dock.push_message(text, false)


func _on_workspace_result(_request_id: int, ok: bool, path: String, message: String) -> void:
	if not ok:
		_dock.push_message("Workspace: %s (%s)" % [message, path], true)


func _on_scene_list(scenes: Array, host_revision: int) -> void:
	_dock.set_scenes(scenes)
	_dock.push_message("Host lists %d scene(s) (workspace revision %d)." % [scenes.size(), host_revision], false)


# ---------------------------------------------------------------------------
# Scene binding
# ---------------------------------------------------------------------------

## Binds every open scene root (not just the focused tab) so collaboration is
## scoped to a scene path rather than to whichever tab the host happens to be
## looking at. This is what stops a client's work from being undone when the
## host switches to another scene.
func _ensure_scene_binding() -> void:
	var host_mode: bool = _coordinator.workspace_mode == CollabConstants.WorkspaceMode.HOST_WORKSPACE
	# Git presence mode is presence-only: scene operations, authoring and
	# transfers stay off.
	_scene_sync.enabled = host_mode
	_scene_sync.auto_apply_snapshot = host_mode and _settings.get_bool(CollabSettings.KEY_AUTO_APPLY_SNAPSHOT, true)
	_workspace.enabled = host_mode

	var roots: Array = _open_scene_roots()
	var active_root: Node = _edited_root()
	var active_path: String = ""
	var seen: Dictionary = {}
	for root in roots:
		if root == null or not is_instance_valid(root):
			continue
		var path: String = root.scene_file_path
		if path.is_empty():
			continue
		seen[path] = true
		var is_active: bool = root == active_root
		if is_active:
			active_path = path
		_scene_sync.bind_scene(root, path, is_active)
	if roots.is_empty():
		if not _bound_scene_ids.is_empty():
			_scene_sync.detach_scene()
	else:
		for path in _bound_scene_ids.keys():
			if not seen.has(path):
				_scene_sync.unbind_scene(path)
	_bound_scene_ids = seen

	if active_path != _attached_scene_id:
		_attached_scene_id = active_path
		_presence.set_local_scene_id(active_path)
		_markers.set_local_scene_id(active_path)
		if _coordinator.is_host():
			_coordinator.refresh_host_scene_id()
		if _coordinator.session_manager.is_active() and active_path != _last_focus_sent:
			_last_focus_sent = active_path
			_coordinator.send_scene_focus(active_path)


func _open_scene_roots() -> Array:
	if _editor == null:
		return []
	var roots: Array = _editor.get_open_scene_roots()
	if roots.is_empty():
		var active: Node = _edited_root()
		if active != null:
			return [active]
	return roots


## `res://` paths of every scene currently open, so the workspace service can
## protect them from raw file relay/overwrite.
func _open_scene_paths() -> Array:
	var out: Array = []
	for root in _open_scene_roots():
		if root == null or not is_instance_valid(root):
			continue
		var path: String = root.scene_file_path
		if not path.is_empty():
			out.append(path)
	return out


func _update_connectivity() -> void:
	var advertise: String = _settings.get_string(CollabSettings.KEY_DIRECT_ADVERTISE_HOST, "")
	var info: Dictionary = CollabConnectivity.evaluate(advertise, _upnp_external, _upnp_attempted)
	_last_connectivity_state = int(info["state"])
	_dock.set_connectivity(_last_connectivity_state, str(info["detail"]))


func _primary_lan_address() -> String:
	var addresses: Array[String] = CollabConnectivity.lan_addresses()
	return addresses[0] if not addresses.is_empty() else "127.0.0.1"


# ---------------------------------------------------------------------------
# 3D viewport forwarding
# ---------------------------------------------------------------------------

## Receives mouse/keyboard events aimed at the 3D viewport. We only observe
## mouse motion to derive the local cursor ray and always return
## [constant EditorPlugin.AFTER_GUI_INPUT_PASS] so normal editor interaction is
## untouched.
func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	if _presence == null or _coordinator == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if not _coordinator.session_manager.is_active():
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var viewport_3d: SubViewport = _editor_viewport_3d()
	if viewport_3d == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	_presence.sample_local_cursor(viewport_camera, motion.position, Vector2(viewport_3d.size), _attached_scene_id)
	return EditorPlugin.AFTER_GUI_INPUT_PASS


## Paints remote cursors over the 3D viewport.
func _forward_3d_draw_over_viewport(viewport_control: Control) -> void:
	if _presence != null:
		_presence.draw_overlay(viewport_control)
