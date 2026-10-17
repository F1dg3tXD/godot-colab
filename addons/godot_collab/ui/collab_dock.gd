@tool
## Editor dock for the Godot Collab add-on.
##
## The dock is deliberately presentation-only: it collects user intent, emits
## signals, and renders state pushed by the plugin. It never speaks the wire
## protocol or touches editor internals directly.
class_name CollabDock
extends VBoxContainer

signal host_requested(username: String, port: int, mode: int, use_rendezvous: bool, use_relay: bool)
signal join_requested(invite: String)
signal disconnect_requested()
signal approve_requested(peer_id: int)
signal reject_requested(peer_id: int)
signal kick_requested(peer_id: int)
signal save_requested()
signal download_requested(root: String)
signal cancel_transfer_requested()
signal snapshot_requested()
signal snapshot_apply_requested()
signal snapshot_discard_requested()
signal new_scene_requested(path: String, root_class: String)
signal add_file_requested(path: String, content: String)
signal open_scene_requested(path: String)
signal refresh_scenes_requested()
signal username_changed(username: String)

const MODE_HOST_WORKSPACE: int = 0
const MODE_GIT_PRESENCE: int = 1

var _settings: CollabSettings
var _built: bool = false
var _active: bool = false
var _scroll: ScrollContainer
var _content: VBoxContainer

var _username_edit: LineEdit
var _port_spin: SpinBox
var _mode_option: OptionButton
var _rendezvous_check: CheckBox
var _relay_check: CheckBox
var _relay_address_edit: LineEdit
var _approve_check: CheckBox
var _status_label: Label
var _connectivity_label: Label
var _mode_label: Label
var _invite_view: TextEdit
var _invite_input: LineEdit
var _participant_list: ItemList
var _request_list: ItemList
var _approve_button: Button
var _reject_button: Button
var _kick_button: Button
var _request_box: VBoxContainer
var _sync_label: Label
var _project_label: Label
var _save_label: Label
var _progress_label: Label
var _transfer_dir_edit: LineEdit
var _download_button: Button
var _cancel_button: Button
var _save_button: Button
var _scene_list: ItemList
var _open_scene_button: Button
var _refresh_scenes_button: Button
var _new_scene_button: Button
var _add_file_button: Button
var _new_scene_dialog: ConfirmationDialog
var _new_scene_path: LineEdit
var _new_scene_root: OptionButton
var _add_file_dialog: ConfirmationDialog
var _add_file_path: LineEdit
var _add_file_content: TextEdit
var _messages: RichTextLabel
var _requests: Array = [] # [{peer_id, name}]
var _participants: Array = []
var _scenes: Array = []


func setup(settings: CollabSettings) -> void:
	_settings = settings
	if not _built:
		_build()
	_username_edit.text = settings.get_string(CollabSettings.KEY_USERNAME, "")
	_port_spin.value = settings.get_int(CollabSettings.KEY_PORT, CollabConstants.DEFAULT_PORT)
	_rendezvous_check.button_pressed = settings.get_string(CollabSettings.KEY_RENDEZVOUS_URL, "").is_empty() == false
	_relay_check.button_pressed = settings.get_bool(CollabSettings.KEY_USE_RELAY, true)
	_relay_address_edit.text = settings.get_string(CollabSettings.KEY_RELAY_ADDRESS, "")
	_approve_check.button_pressed = settings.get_bool(CollabSettings.KEY_APPROVE_JOINS, false)
	_transfer_dir_edit.text = settings.get_string(CollabSettings.KEY_TRANSFER_DIR, "")


func _ready() -> void:
	if not _built:
		_build()


func _build() -> void:
	if _built:
		return
	_built = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	# All content lives inside a ScrollContainer so the dock stays usable when
	# the editor font/window scale is increased or the dock is short: options
	# scroll vertically instead of being cut off.
	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	add_child(_scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 6)
	_scroll.add_child(_content)

	var title := Label.new()
	title.text = "Godot Collab"
	title.add_theme_font_size_override("font_size", 15)
	_content.add_child(title)

	var identity_box := _section("Identity")
	_username_edit = LineEdit.new()
	_username_edit.placeholder_text = "Username"
	_username_edit.tooltip_text = "Your display name, shown to other collaborators."
	_username_edit.text_changed.connect(func(text: String) -> void: username_changed.emit(text))
	identity_box.add_child(_row("Username", _username_edit))

	var session_box := _section("Session")
	_status_label = Label.new()
	_status_label.text = "Status: not connected"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	session_box.add_child(_status_label)
	_connectivity_label = Label.new()
	_connectivity_label.text = "Connectivity: unknown"
	_connectivity_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	session_box.add_child(_connectivity_label)
	_mode_label = Label.new()
	_mode_label.text = "Mode: host-owned workspace"
	session_box.add_child(_mode_label)

	_mode_option = OptionButton.new()
	_mode_option.add_item("Host-owned workspace", MODE_HOST_WORKSPACE)
	_mode_option.add_item("Git presence only", MODE_GIT_PRESENCE)
	session_box.add_child(_row("Host mode", _mode_option))

	_port_spin = SpinBox.new()
	_port_spin.min_value = 1024
	_port_spin.max_value = 65535
	_port_spin.step = 1
	_port_spin.value = CollabConstants.DEFAULT_PORT
	session_box.add_child(_row("UDP port", _port_spin))

	_rendezvous_check = CheckBox.new()
	_rendezvous_check.text = "Register a short invite code (uses the bundled rendezvous)"
	_rendezvous_check.tooltip_text = "Asks the rendezvous service for a short code (like AB12CD). Clients using it must configure the rendezvous URL. Works with or without relay mode."
	session_box.add_child(_rendezvous_check)

	_relay_check = CheckBox.new()
	_relay_check.text = "Use a relay server (recommended for the internet)"
	_relay_check.tooltip_text = "Both sides connect outbound to a relay server, which forwards traffic. No port forwarding needed. Works behind NAT/CGNAT; can be combined with a short invite code."
	_relay_check.toggled.connect(func(_pressed: bool) -> void: _update_relay_controls())
	session_box.add_child(_relay_check)

	_relay_address_edit = LineEdit.new()
	_relay_address_edit.placeholder_text = "Relay address: host or host:port (default port %d)" % CollabConstants.DEFAULT_RELAY_PORT
	_relay_address_edit.tooltip_text = "Address of the bundled relay+rendezvous server (see tools/relay_server)."
	session_box.add_child(_relay_address_edit)
	_update_relay_controls()

	_approve_check = CheckBox.new()
	_approve_check.text = "Require host approval for new participants"
	session_box.add_child(_approve_check)

	session_box.add_child(_hint("Host, Join, Copy Code, Request Snapshot and Disconnect are in the top toolbar."))
	session_box.add_child(_hint("Relay mode: the invitation embeds the relay endpoint + room, so joining works without a reachable host port. A long code also embeds the rendezvous URL, so pasting it sets the client up for short codes."))
	session_box.add_child(_hint("Advanced: uncheck relay to host directly on a LAN (a reachable host port is required)."))

	var invite_box := _section("Invitation code")
	_invite_view = TextEdit.new()
	_invite_view.editable = false
	_invite_view.custom_minimum_size = Vector2(0, 54)
	_invite_view.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	invite_box.add_child(_invite_view)

	var join_box := _section("Join")
	_invite_input = LineEdit.new()
	_invite_input.placeholder_text = "Paste an invitation code or host:port, then press Paste & Join in the toolbar"
	_invite_input.text_submitted.connect(func(_text: String) -> void: _on_join_pressed())
	join_box.add_child(_invite_input)

	var participants_box := _section("Participants")
	_participant_list = ItemList.new()
	_participant_list.custom_minimum_size = Vector2(0, 90)
	participants_box.add_child(_participant_list)
	_kick_button = Button.new()
	_kick_button.text = "Remove selected"
	_kick_button.pressed.connect(_on_kick_pressed)
	participants_box.add_child(_kick_button)

	_request_box = _section("Join requests")
	_request_list = ItemList.new()
	_request_list.custom_minimum_size = Vector2(0, 60)
	_request_box.add_child(_request_list)
	var request_actions := HBoxContainer.new()
	_approve_button = Button.new()
	_approve_button.text = "Approve"
	_approve_button.pressed.connect(_on_approve_pressed)
	request_actions.add_child(_approve_button)
	_reject_button = Button.new()
	_reject_button.text = "Reject"
	_reject_button.pressed.connect(_on_reject_pressed)
	request_actions.add_child(_reject_button)
	_request_box.add_child(request_actions)
	_request_box.visible = false

	var scene_box := _section("Scene collaboration")
	_sync_label = Label.new()
	_sync_label.text = "Scene: idle"
	_sync_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	scene_box.add_child(_sync_label)
	var snapshot_row := HBoxContainer.new()
	var apply_button := Button.new()
	apply_button.text = "Apply pending"
	apply_button.pressed.connect(func() -> void: snapshot_apply_requested.emit())
	snapshot_row.add_child(apply_button)
	var discard_button := Button.new()
	discard_button.text = "Discard pending"
	discard_button.pressed.connect(func() -> void: snapshot_discard_requested.emit())
	snapshot_row.add_child(discard_button)
	scene_box.add_child(snapshot_row)
	_save_button = Button.new()
	_save_button.text = "Save shared scene"
	_save_button.pressed.connect(func() -> void: save_requested.emit())
	scene_box.add_child(_save_button)
	_save_label = Label.new()
	_save_label.text = "Save: no save yet"
	_save_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	scene_box.add_child(_save_label)

	var project_box := _section("Project transfer")
	_project_label = Label.new()
	_project_label.text = "Project: idle"
	_project_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	project_box.add_child(_project_label)
	_transfer_dir_edit = LineEdit.new()
	_transfer_dir_edit.placeholder_text = "Download directory (blank = user data)"
	project_box.add_child(_transfer_dir_edit)
	var transfer_row := HBoxContainer.new()
	_download_button = Button.new()
	_download_button.text = "Download project"
	_download_button.pressed.connect(_on_download_pressed)
	transfer_row.add_child(_download_button)
	_cancel_button = Button.new()
	_cancel_button.text = "Cancel"
	_cancel_button.pressed.connect(func() -> void: cancel_transfer_requested.emit())
	transfer_row.add_child(_cancel_button)
	project_box.add_child(transfer_row)
	_progress_label = Label.new()
	_progress_label.text = ""
	_progress_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	project_box.add_child(_progress_label)

	var workspace_box := _section("Project scenes & authoring")
	var scene_list_label := Label.new()
	scene_list_label.text = "Scenes advertised by the host"
	scene_list_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	workspace_box.add_child(scene_list_label)
	_scene_list = ItemList.new()
	_scene_list.custom_minimum_size = Vector2(0, 90)
	_scene_list.allow_reselect = true
	workspace_box.add_child(_scene_list)
	var scene_actions := HBoxContainer.new()
	_open_scene_button = Button.new()
	_open_scene_button.text = "Open selected"
	_open_scene_button.tooltip_text = "Open the selected scene locally (loads the local copy of the file)."
	_open_scene_button.pressed.connect(_on_open_scene_pressed)
	scene_actions.add_child(_open_scene_button)
	_refresh_scenes_button = Button.new()
	_refresh_scenes_button.text = "Refresh"
	_refresh_scenes_button.pressed.connect(func() -> void: refresh_scenes_requested.emit())
	scene_actions.add_child(_refresh_scenes_button)
	workspace_box.add_child(scene_actions)
	var author_row := HBoxContainer.new()
	_new_scene_button = Button.new()
	_new_scene_button.text = "New scene..."
	_new_scene_button.tooltip_text = "Ask the host to create a new empty scene in the shared workspace."
	_new_scene_button.pressed.connect(_on_new_scene_pressed)
	author_row.add_child(_new_scene_button)
	_add_file_button = Button.new()
	_add_file_button.text = "Add file..."
	_add_file_button.tooltip_text = "Ask the host to add a text file (script/resource) to the shared workspace."
	_add_file_button.pressed.connect(_on_add_file_pressed)
	author_row.add_child(_add_file_button)
	workspace_box.add_child(author_row)

	_build_new_scene_dialog()
	_build_add_file_dialog()

	var messages_box := _section("Messages")
	_messages = RichTextLabel.new()
	_messages.bbcode_enabled = true
	_messages.fit_content = true
	_messages.scroll_active = false
	_messages.custom_minimum_size = Vector2(0, 60)
	messages_box.add_child(_messages)


func _build_new_scene_dialog() -> void:
	_new_scene_dialog = ConfirmationDialog.new()
	_new_scene_dialog.title = "Create a new scene"
	_new_scene_dialog.ok_button_text = "Create scene"
	var box := VBoxContainer.new()
	var path_row := HBoxContainer.new()
	var path_label := Label.new()
	path_label.text = "Path"
	path_label.custom_minimum_size = Vector2(72, 0)
	path_row.add_child(path_label)
	_new_scene_path = LineEdit.new()
	_new_scene_path.placeholder_text = "res://scenes/new_scene.tscn"
	_new_scene_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_new_scene_path.text = "res://new_scene.tscn"
	path_row.add_child(_new_scene_path)
	box.add_child(path_row)
	var root_row := HBoxContainer.new()
	var root_label := Label.new()
	root_label.text = "Root"
	root_label.custom_minimum_size = Vector2(72, 0)
	root_row.add_child(root_label)
	_new_scene_root = OptionButton.new()
	for root_class in CollabConstants.SCENE_ROOT_CLASSES:
		_new_scene_root.add_item(root_class)
		if root_class == "Node3D":
			_new_scene_root.selected = _new_scene_root.item_count - 1
	root_row.add_child(_new_scene_root)
	box.add_child(root_row)
	_new_scene_dialog.add_child(box)
	_new_scene_dialog.confirmed.connect(_on_new_scene_confirmed)
	add_child(_new_scene_dialog)


func _build_add_file_dialog() -> void:
	_add_file_dialog = ConfirmationDialog.new()
	_add_file_dialog.title = "Add a project file"
	_add_file_dialog.ok_button_text = "Add file"
	_add_file_dialog.min_size = Vector2(520, 420)
	var box := VBoxContainer.new()
	var path_row := HBoxContainer.new()
	var path_label := Label.new()
	path_label.text = "Path"
	path_label.custom_minimum_size = Vector2(72, 0)
	path_row.add_child(path_label)
	_add_file_path = LineEdit.new()
	_add_file_path.placeholder_text = "res://scripts/new_script.gd"
	_add_file_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_row.add_child(_add_file_path)
	box.add_child(path_row)
	var content_label := Label.new()
	content_label.text = "Content"
	box.add_child(content_label)
	_add_file_content = TextEdit.new()
	_add_file_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_add_file_content.custom_minimum_size = Vector2(0, 240)
	_add_file_content.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	box.add_child(_add_file_content)
	_add_file_dialog.add_child(box)
	_add_file_dialog.confirmed.connect(_on_add_file_confirmed)
	add_child(_add_file_dialog)


func _section(title_text: String) -> VBoxContainer:
	var container := VBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_theme_constant_override("separation", 3)
	var header := Label.new()
	header.text = title_text
	header.add_theme_font_size_override("font_size", 13)
	container.add_child(header)
	_content.add_child(container)
	_content.add_child(HSeparator.new())
	return container


func _hint(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	label.add_theme_font_size_override("font_size", 12)
	return label


func _row(label_text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(72, 0)
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

## Toolbar entry point: uses the dock's current host settings.
func request_host() -> void:
	_on_host_pressed()


## Toolbar entry point: uses the invitation code typed into the dock.
func request_join() -> void:
	_on_join_pressed()


## Toolbar entry point: pastes an invitation code from the clipboard into the
## dock's code field and joins immediately.
func request_paste_join() -> void:
	var clipboard: String = DisplayServer.clipboard_get().strip_edges()
	if clipboard.is_empty():
		push_message("Clipboard is empty. Copy an invitation code first.", true)
		return
	_invite_input.text = clipboard
	push_message("Pasted invitation code from clipboard.", false)
	_on_join_pressed()


## Toolbar entry point: copies the generated invitation code.
func request_copy() -> void:
	_on_copy_pressed()


func _on_host_pressed() -> void:
	var username: String = _username_edit.text.strip_edges()
	var port: int = int(_port_spin.value)
	var mode: int = _mode_option.get_selected_id()
	var use_relay: bool = _relay_check.button_pressed
	var use_rendezvous: bool = _rendezvous_check.button_pressed
	if use_relay and _relay_address_edit.text.strip_edges().is_empty():
		push_message("No relay server configured; hosting directly. Enter a relay address to host over the internet.", true)
		use_relay = false
		_relay_check.button_pressed = false
		_update_relay_controls()
	if _settings != null:
		_settings.set_value(CollabSettings.KEY_PORT, port)
		_settings.set_value(CollabSettings.KEY_APPROVE_JOINS, _approve_check.button_pressed)
		_settings.set_value(CollabSettings.KEY_USE_RELAY, use_relay)
		_settings.set_value(CollabSettings.KEY_RELAY_ADDRESS, _relay_address_edit.text.strip_edges())
	host_requested.emit(username, port, mode, use_rendezvous, use_relay)


## Enables/disables the relay address field. Rendezvous (short codes) can be
## combined with relay mode, so it is not toggled here.
func _update_relay_controls() -> void:
	if _relay_address_edit == null:
		return
	var relay: bool = _relay_check.button_pressed
	_relay_address_edit.editable = relay
	_relay_address_edit.visible = relay


## Reflects relay settings pushed by the plugin (for example after a client
## pastes a long relay invitation that auto-configures the endpoint).
func set_relay_config(use_relay: bool, host: String, port: int) -> void:
	if _relay_check == null:
		return
	_relay_check.button_pressed = use_relay
	if _relay_address_edit != null:
		if host.strip_edges().is_empty():
			_relay_address_edit.text = ""
		else:
			_relay_address_edit.text = host if port == CollabConstants.DEFAULT_RELAY_PORT else "%s:%d" % [host, port]
	_update_relay_controls()


## Reflects a rendezvous URL auto-configured from an invitation.
func set_rendezvous_url(url: String) -> void:
	if _rendezvous_check == null:
		return
	if not url.strip_edges().is_empty():
		_rendezvous_check.button_pressed = true


func _on_join_pressed() -> void:
	var invite: String = _invite_input.text.strip_edges()
	if invite.is_empty():
		push_message("Enter or paste an invitation code (or host:port), then try again.", true)
		return
	push_message("Joining with code '%s'..." % invite, false)
	join_requested.emit(invite)


func _on_copy_pressed() -> void:
	var text: String = _invite_view.text.strip_edges()
	if text.is_empty():
		push_message("No invitation code to copy.", true)
		return
	DisplayServer.clipboard_set(text)
	push_message("Invitation code copied to clipboard.", false)


func _on_approve_pressed() -> void:
	var selected: PackedInt32Array = _request_list.get_selected_items()
	if selected.is_empty():
		return
	var entry: Dictionary = _requests[selected[0]]
	approve_requested.emit(int(entry.get("peer_id", 0)))


func _on_reject_pressed() -> void:
	var selected: PackedInt32Array = _request_list.get_selected_items()
	if selected.is_empty():
		return
	var entry: Dictionary = _requests[selected[0]]
	reject_requested.emit(int(entry.get("peer_id", 0)))


func _on_kick_pressed() -> void:
	var selected: PackedInt32Array = _participant_list.get_selected_items()
	if selected.is_empty():
		return
	var participant: CollabParticipant = _participants[selected[0]]
	if participant.is_host:
		push_message("The host cannot be removed.", true)
		return
	kick_requested.emit(participant.peer_id)


func _on_download_pressed() -> void:
	var root: String = _transfer_dir_edit.text.strip_edges()
	if _settings != null:
		_settings.set_value(CollabSettings.KEY_TRANSFER_DIR, root)
	download_requested.emit(root)


func _on_new_scene_pressed() -> void:
	_new_scene_dialog.popup_centered(Vector2i(420, 150))


func _on_new_scene_confirmed() -> void:
	var path: String = _new_scene_path.text.strip_edges()
	if path.is_empty():
		push_message("Enter a scene path.", true)
		return
	new_scene_requested.emit(path, _new_scene_root.get_item_text(_new_scene_root.selected))


func _on_add_file_pressed() -> void:
	_add_file_dialog.popup_centered(Vector2i(560, 460))


func _on_add_file_confirmed() -> void:
	var path: String = _add_file_path.text.strip_edges()
	if path.is_empty():
		push_message("Enter a file path.", true)
		return
	add_file_requested.emit(path, _add_file_content.text)


func _on_open_scene_pressed() -> void:
	var selected: PackedInt32Array = _scene_list.get_selected_items()
	if selected.is_empty():
		push_message("Select a scene to open.", true)
		return
	var entry: String = _scene_list.get_item_text(selected[0])
	open_scene_requested.emit(entry)


# ---------------------------------------------------------------------------
# State pushed by the plugin
# ---------------------------------------------------------------------------

func set_connection_status(state: int, text: String) -> void:
	if _status_label == null:
		return
	_status_label.text = "Status: %s" % text
	_active = state != CollabConstants.ConnectionState.DISCONNECTED


## True while a session is active (hosting/connecting/connected). The plugin uses
## this to mirror state onto the toolbar buttons.
func is_session_active() -> bool:
	return _active


func set_connectivity(state: int, detail: String) -> void:
	if _connectivity_label == null:
		return
	var names: Array[String] = ["unknown", "LAN only", "direct (externally reachable)", "relay"]
	_connectivity_label.text = "Connectivity: %s - %s" % [names[state] if state >= 0 and state < names.size() else "unknown", detail]


func set_mode(mode: int) -> void:
	if _mode_label == null:
		return
	if mode == MODE_GIT_PRESENCE:
		_mode_label.text = "Mode: Git presence only (no file sync)"
	else:
		_mode_label.text = "Mode: host-owned workspace"


func set_hosting_controls(active: bool) -> void:
	if _request_box == null:
		return
	_request_box.visible = active and not _requests.is_empty()
	if not active:
		_requests.clear()
		_request_list.clear()


func set_participants(list: Array) -> void:
	if _participant_list == null:
		return
	_participants = list
	_participant_list.clear()
	for participant in list:
		if participant == null:
			continue
		_participant_list.add_item(participant.display_name())


func add_join_request(peer_id: int, name: String) -> void:
	if _request_list == null:
		return
	for entry in _requests:
		if int(entry.get("peer_id", 0)) == peer_id:
			return
	_requests.append({"peer_id": peer_id, "name": name})
	_request_list.add_item("%s (%d)" % [name, peer_id])
	_request_box.visible = true
	push_message("'%s' wants to join. Approve or reject.", false)


func remove_join_request(peer_id: int) -> void:
	if _request_list == null:
		return
	for i in _requests.size():
		if int((_requests[i] as Dictionary).get("peer_id", 0)) == peer_id:
			_requests.remove_at(i)
			_request_list.remove_item(i)
			break
	if _requests.is_empty():
		_request_box.visible = false


func set_invite(invite: String) -> void:
	if _invite_view == null:
		return
	_invite_view.text = invite


func set_sync_status(text: String) -> void:
	if _sync_label != null:
		_sync_label.text = "Scene: %s" % text


func set_project_status(text: String) -> void:
	if _project_label != null:
		_project_label.text = "Project: %s" % text


func set_save_status(text: String) -> void:
	if _save_label != null:
		_save_label.text = "Save: %s" % text


func set_scenes(scenes: Array) -> void:
	_scenes = scenes
	if _scene_list == null:
		return
	_scene_list.clear()
	for scene in scenes:
		_scene_list.add_item(str(scene))


func set_transfer_progress(text: String) -> void:
	if _progress_label != null:
		_progress_label.text = text


func push_message(text: String, is_error: bool) -> void:
	if _messages == null:
		return
	var color: String = "ff8888" if is_error else "a0d0ff"
	_messages.append_text("[color=#%s]%s[/color]\n" % [color, _bbcode_escape(text)])


func _bbcode_escape(text: String) -> String:
	return text.replace("[", "\\[").replace("]", "\\]")
