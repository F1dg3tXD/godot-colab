@tool
## Builds and validates the eligible-file manifest for project snapshots.
##
## Only source files are listed. Generated/editor caches ([code].godot/[/code])
## and version-control metadata ([code].git/[/code]) are excluded unless a git
## clone mode is explicitly requested.
class_name CollabProjectManifest
extends RefCounted

## Directory names (relative to the project root) that are never transferred.
const EXCLUDED_DIRS: Array[String] = [".godot", ".git", "android", ".vscode", ".idea", ".import"]

## File suffixes that are never transferred.
const EXCLUDED_SUFFIXES: Array[String] = [".tmp", ".translation", ".log"]

## Hard cap on the number of files in one manifest.
const MAX_FILES: int = 20000


## Returns { ok, error, files: Array[{path,size,sha256}], total_size }.
## [param max_total_bytes] caps the summed size (0 means unlimited).
static func build(project_root: String, max_total_bytes: int = 0, include_git: bool = false) -> Dictionary:
	var result: Dictionary = {"ok": false, "error": "", "files": [], "total_size": 0}
	if not DirAccess.dir_exists_absolute(project_root):
		result["error"] = "project root does not exist"
		return result
	var files: Array = []
	var total: int = 0
	var queue: Array[String] = [""]
	while not queue.is_empty():
		var rel_dir: String = queue.pop_back()
		var abs_dir: String = project_root if rel_dir.is_empty() else project_root.path_join(rel_dir)
		var dir := DirAccess.open(abs_dir)
		if dir == null:
			continue
		dir.list_dir_begin()
		var name: String = dir.get_next()
		while name != "":
			if name == "." or name == "..":
				name = dir.get_next()
				continue
			var rel: String = name if rel_dir.is_empty() else rel_dir.path_join(name)
			if dir.current_is_dir():
				if not _dir_excluded(name, include_git) and not CollabPathGuard.is_symlink(abs_dir.path_join(name)):
					queue.append(rel)
			elif not _file_excluded(name) and not CollabPathGuard.is_symlink(abs_dir.path_join(name)):
				var size: int = _file_size(abs_dir.path_join(name))
				total += size
				files.append({"path": rel, "size": size, "sha256": ""})
				if files.size() > MAX_FILES:
					result["error"] = "too many files (%d)" % MAX_FILES
					return result
				if max_total_bytes > 0 and total > max_total_bytes:
					result["error"] = "project exceeds the configured size limit"
					return result
			name = dir.get_next()
		dir.list_dir_end()
	for entry in files:
		var digest: String = CollabIdentity.sha256_file(project_root.path_join(str(entry["path"])))
		if digest.is_empty():
			result["error"] = "could not hash %s" % str(entry["path"])
			return result
		entry["sha256"] = digest
	result["ok"] = true
	result["files"] = files
	result["total_size"] = total
	return result


static func to_wire(files: Array) -> Array:
	var out: Array = []
	for entry in files:
		out.append({
			"path": str(entry.get("path", "")),
			"size": int(entry.get("size", 0)),
			"sha256": str(entry.get("sha256", "")),
		})
	return out


## True when a relative path points into an excluded directory or suffix.
static func is_excluded_relative(rel: String) -> bool:
	if rel.is_empty():
		return true
	var normalized: String = CollabPathGuard.normalize_relative(rel)
	if normalized.is_empty():
		return true
	for seg in normalized.split("/", false):
		if EXCLUDED_DIRS.has(seg):
			return true
	var ext: String = "." + rel.get_extension().to_lower()
	return EXCLUDED_SUFFIXES.has(ext)


static func _dir_excluded(name: String, include_git: bool) -> bool:
	if name == ".git" and include_git:
		return false
	return EXCLUDED_DIRS.has(name)


static func _file_excluded(name: String) -> bool:
	return EXCLUDED_SUFFIXES.has("." + name.get_extension().to_lower())


static func _file_size(abs_path: String) -> int:
	var file := FileAccess.open(abs_path, FileAccess.READ)
	if file == null:
		return 0
	var size: int = file.get_length()
	file.close()
	return size
