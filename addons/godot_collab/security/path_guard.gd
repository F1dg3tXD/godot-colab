@tool
## Filesystem path safety for project transfer and workspace writes.
##
## All transfer paths are treated as *relative* paths inside an explicitly
## approved root. This class rejects absolute paths, traversal, backslash
## tricks, Windows drive/UNC prefixes, NUL bytes and (optionally) symlinks.
class_name CollabPathGuard
extends RefCounted

const MAX_RELATIVE_LENGTH: int = 400
const MAX_SEGMENTS: int = 64


## True when [param path] is a safe, non-escaping relative path.
static func is_safe_relative(path: String) -> bool:
	var normalized := normalize_relative(path)
	return not normalized.is_empty()


## Normalizes a client-supplied relative path. Returns an empty string when the
## path is unsafe (absolute, escapes the root, contains traversal or is empty).
static func normalize_relative(path: String) -> String:
	var p: String = path.strip_edges()
	if p.is_empty() or p.length() > 512:
		return ""
	# A literal "\u0000" escape in source is rejected by the script parser, and
	# constructing a NUL string with String.chr(0) triggers engine warnings, so
	# scan the UTF-8 bytes for an embedded NUL instead.
	if p.to_utf8_buffer().has(0):
		return ""
	if p.contains("\\"):
		return ""
	if p.is_absolute_path():
		return ""
	# Reject Windows drive letters and UNC-style prefixes explicitly.
	if p.length() >= 2 and p[1] == ":":
		return ""
	# Collapse and verify no traversal escapes the root.
	var simplified: String = ("res://" + p).simplify_path()
	if simplified == "res://":
		return ""
	if not simplified.begins_with("res://"):
		return ""
	var rel: String = simplified.substr("res://".length())
	if rel.is_empty() or rel.begins_with("../") or rel == ".." or rel.contains("/../"):
		return ""
	var segments: PackedStringArray = rel.split("/", false)
	if segments.size() > 64:
		return ""
	for seg in segments:
		if seg == "." or seg == ".." or seg.is_empty():
			return ""
	return rel


## Resolves [param relative] inside [param root] (an absolute OS path).
## Returns an empty string when the path is unsafe or escapes the root.
static func resolve_within(root: String, relative: String) -> String:
	var rel: String = normalize_relative(relative)
	if rel.is_empty():
		return ""
	var clean_root: String = root.simplify_path().trim_suffix("/")
	var candidate: String = clean_root.path_join(rel).simplify_path()
	if not is_within(clean_root, candidate):
		return ""
	return candidate


## True when [param candidate] is [param root] or lives underneath it.
static func is_within(root: String, candidate: String) -> bool:
	var clean_root: String = root.simplify_path().trim_suffix("/")
	var clean_candidate: String = candidate.simplify_path()
	if clean_candidate == clean_root:
		return true
	return clean_candidate.begins_with(clean_root + "/")


## True if [param path] is a symbolic link (used to refuse writing through
## links that could escape the workspace).
static func is_symlink(path: String) -> bool:
	var dir: DirAccess = DirAccess.open(path.get_base_dir())
	if dir == null:
		return false
	return dir.is_link(path.get_file())


## Ensures every component of [param relative] under [param root] is not a
## symlink. Returns true when it is safe to write.
static func no_symlink_escape(root: String, relative: String) -> bool:
	var rel: String = normalize_relative(relative)
	if rel.is_empty():
		return false
	var clean_root: String = root.simplify_path().trim_suffix("/")
	var current: String = clean_root
	if is_symlink(current):
		return false
	for seg in rel.split("/", false):
		current = current.path_join(seg)
		if FileAccess.file_exists(current) or DirAccess.dir_exists_absolute(current):
			if is_symlink(current):
				return false
	return true
