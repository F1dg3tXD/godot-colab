@tool
## Bidirectional map between stable session node ids and local scene nodes.
##
## Node ids are allocated by the host and never change when a node is renamed
## or reparented. Local nodes are held through weak references so removing a
## node from the scene does not leak.
class_name CollabNodeIdMap
extends RefCounted

var _by_id: Dictionary = {} # node_id:int -> WeakRef
var _by_node: Dictionary = {} # instance_id:int -> node_id:int
var _next_id: int = 1
# Client temporary ids are negatively numbered. -1 is reserved as the "no
# temporary id" sentinel used by the wire protocol, so real temp ids start at -2.
var _next_temp_id: int = -2


func clear() -> void:
	_by_id.clear()
	_by_node.clear()
	# The counters are deliberately *not* reset: ids are unique for the whole
	# session so a node created right after a snapshot clear cannot collide with
	# an id that is still in flight (for example the snapshot's own node ids).


## Host-only: allocate the next authoritative id.
func allocate_id() -> int:
	var id: int = _next_id
	_next_id += 1
	return id


## Client-only: allocate a temporary negative id, replaced once the host
## acknowledges the creation.
func allocate_temp_id() -> int:
	var id: int = _next_temp_id
	_next_temp_id -= 1
	return id


func register(node: Node, node_id: int) -> void:
	if node == null:
		return
	_by_id[node_id] = weakref(node)
	_by_node[node.get_instance_id()] = node_id


func id_for(node: Node) -> int:
	if node == null:
		return -1
	var iid: int = node.get_instance_id()
	if not _by_node.has(iid):
		return -1
	var mapped: int = _by_node[iid]
	# Guard against instance ids being reused after a node is freed.
	if node_for(mapped, false) != node:
		_by_node.erase(iid)
		return -1
	return mapped


func node_for(node_id: int, prune: bool = false) -> Node:
	var ref: WeakRef = _by_id.get(node_id, null)
	if ref == null:
		return null
	var node: Node = ref.get_ref()
	if node == null and prune:
		_by_id.erase(node_id)
	return node


func has_id(node_id: int) -> bool:
	return node_for(node_id, true) != null


## Rebinds a client temporary id to the host's authoritative id after the host
## echoes a create operation, so no duplicate node is produced.
func rebind(temp_id: int, authoritative_id: int) -> void:
	var node: Node = node_for(temp_id, false)
	if node == null:
		return
	register(node, authoritative_id)
	_unregister_entry(temp_id)


func unregister(node: Node) -> void:
	if node == null:
		return
	var iid: int = node.get_instance_id()
	if _by_node.has(iid):
		var id: int = _by_node[iid]
		_by_id.erase(id)
		_by_node.erase(iid)


## Removes entries whose nodes have been freed. Returns the removed ids.
func prune() -> Array[int]:
	var removed: Array[int] = []
	for key in _by_id.keys():
		if (_by_id[key] as WeakRef).get_ref() == null:
			_by_id.erase(key)
			removed.append(key)
	for key in _by_node.keys():
		var node: Node = node_for(_by_node[key], true)
		if node == null:
			_by_node.erase(key)
	return removed


func live_ids() -> Array[int]:
	var out: Array[int] = []
	for key in _by_id.keys():
		if (_by_id[key] as WeakRef).get_ref() != null:
			out.append(key)
	return out


func _unregister_entry(node_id: int) -> void:
	_by_id.erase(node_id)
	for key in _by_node.keys():
		if _by_node[key] == node_id:
			_by_node.erase(key)
			break
