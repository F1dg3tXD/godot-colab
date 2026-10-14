@tool
## Stable identity helpers (project + scene) and hashing utilities.
##
## Identities are short hex digests of file contents so two peers can tell
## whether they are looking at the same project/scene without exchanging the
## files themselves.
class_name CollabIdentity
extends RefCounted


## Returns a short (16 hex char) digest of [param path]'s contents, or an empty
## string when the file cannot be read.
static func content_id(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while not file.eof_reached():
		var chunk: PackedByteArray = file.get_buffer(1 << 16)
		if chunk.size() > 0:
			ctx.update(chunk)
	file.close()
	var digest: PackedByteArray = ctx.finish()
	return digest.hex_encode().substr(0, 16)


## Full sha256 of a file as hex; empty string on failure.
static func sha256_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while not file.eof_reached():
		var chunk: PackedByteArray = file.get_buffer(1 << 16)
		if chunk.size() > 0:
			ctx.update(chunk)
	file.close()
	return (ctx.finish() as PackedByteArray).hex_encode()


static func sha256_bytes(data: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return (ctx.finish() as PackedByteArray).hex_encode()


## Project identity derived from the project name + project.godot contents.
static func project_id_from_root(project_root: String) -> String:
	var project_godot: String = project_root.path_join("project.godot")
	var body := content_id(project_godot)
	if body.is_empty():
		return ""
	var project_name: String = str(ProjectSettings.get_setting("application/config/name", "unknown"))
	return ("%s:%s" % [project_name, body]).sha256_text().substr(0, 16)


static func engine_version() -> String:
	return Engine.get_version_info().get("string", "unknown")
