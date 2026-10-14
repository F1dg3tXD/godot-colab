@tool
## Authoritative-by-convention participant registry.
##
## On the host this is the single source of truth. On clients it mirrors the
## host's list, updated only from host-originated messages, so a client can
## never invent participants.
class_name CollabParticipantRegistry
extends RefCounted

signal changed()

var _participants: Dictionary = {} # peer_id:int -> CollabParticipant
var _local_peer_id: int = 0
var _is_host: bool = false


func set_local(peer_id: int, is_host: bool) -> void:
	_local_peer_id = peer_id
	_is_host = is_host


func clear() -> void:
	_participants.clear()
	changed.emit()


func upsert(participant: CollabParticipant) -> void:
	_participants[participant.peer_id] = participant
	changed.emit()


func remove(peer_id: int) -> bool:
	if _participants.erase(peer_id):
		changed.emit()
		return true
	return false


func get_participant(peer_id: int) -> CollabParticipant:
	return _participants.get(peer_id, null)


func has(peer_id: int) -> bool:
	return _participants.has(peer_id)


func approve(peer_id: int) -> void:
	var p: CollabParticipant = _participants.get(peer_id, null)
	if p != null:
		p.approved = true
		changed.emit()


func all() -> Array[CollabParticipant]:
	var out: Array[CollabParticipant] = []
	for key in _participants.keys():
		out.append(_participants[key])
	return out


func approved_peers() -> Array[int]:
	var out: Array[int] = []
	for key in _participants.keys():
		if (_participants[key] as CollabParticipant).approved:
			out.append(key)
	return out


func count() -> int:
	return _participants.size()


## Replaces the whole list (clients only). Host-originated so it is trusted.
func replace_all(list: Array) -> void:
	_participants.clear()
	for entry in list:
		if typeof(entry) == TYPE_DICTIONARY:
			var p := CollabParticipant.from_dict(entry)
			p.approved = true
			_participants[p.peer_id] = p
	changed.emit()


func to_payload() -> Array:
	var out: Array = []
	for key in _participants.keys():
		out.append((_participants[key] as CollabParticipant).to_dict())
	return out


## Marks activity for a peer. Returns false when the peer is unknown.
func touch(peer_id: int) -> bool:
	var p: CollabParticipant = _participants.get(peer_id, null)
	if p == null:
		return false
	p.touch()
	return true


## Removes peers that have not been seen within [param timeout_ms].
## Returns the list of removed peer ids.
func prune_stale(timeout_ms: int) -> Array[int]:
	var now: int = Time.get_ticks_msec()
	var removed: Array[int] = []
	for key in _participants.keys():
		var p: CollabParticipant = _participants[key]
		if p.peer_id == _local_peer_id:
			continue
		if now - p.last_seen_ms > timeout_ms:
			removed.append(p.peer_id)
	for id in removed:
		_participants.erase(id)
	if not removed.is_empty():
		changed.emit()
	return removed
