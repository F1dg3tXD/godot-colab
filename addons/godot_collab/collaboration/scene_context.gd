@tool
## Per-scene collaboration state.
##
## A session can have several scenes in play at once (this is what lets a
## collaborator keep editing one scene while the host is focused on another).
## Each context owns the node-id map and diff watcher for a single `res://`
## scene path so scene operations are always scoped to the scene they belong to.
##
## A context is either:
## - [b]bound[/b]: its [member root] is a live root inside the editor's open
##   scene list; or
## - [b]detached[/b] (host only): its root was loaded from disk because the
##   host does not currently have the scene open. Detached contexts are written
##   back to disk after accepted operations so the host's project stays
##   authoritative even when the host is not viewing the scene.
class_name CollabSceneContext
extends RefCounted

var scene_id: String = ""
var root: Node = null
var node_ids: CollabNodeIdMap
var diff_watcher: CollabDiffWatcher
var revision: int = 0
## True when [member root] is a detached model loaded from disk rather than a
## live editor scene root.
var detached: bool = false
## True when this context is the scene currently focused in the editor.
var is_active: bool = false
## Set when the host applies remote operations that have not yet been written to
## disk. [CollabSceneSyncService] persists dirty contexts after a short debounce.
var dirty: bool = false
var last_change_ms: int = 0
## The bound [signal CollabDiffWatcher.operations_detected] callable. Kept so it
## can be disconnected, which is required to avoid a RefCounted reference cycle
## (context -> watcher -> bound callable -> context) that would leak the context.
var ops_callable: Callable = Callable()


func _init(p_scene_id: String = "", p_root: Node = null) -> void:
	scene_id = p_scene_id
	root = p_root
	node_ids = CollabNodeIdMap.new()
	diff_watcher = CollabDiffWatcher.new()
	diff_watcher.setup(node_ids)
