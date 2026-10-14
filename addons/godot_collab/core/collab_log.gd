@tool
## Minimal logging helper so every subsystem reports consistently and the dock
## can surface the same messages it prints to the console.
class_name CollabLog
extends RefCounted

signal entry_emitted(level: int, message: String)

enum Level { DEBUG = 0, INFO = 1, WARN = 2, ERROR = 3 }

const _PREFIX: String = "[godot_collab]"

var _min_level: int = Level.DEBUG


func set_level(level: int) -> void:
	_min_level = clampi(level, Level.DEBUG, Level.ERROR)


func debug(message: String) -> void:
	_emit(Level.DEBUG, message)


func info(message: String) -> void:
	_emit(Level.INFO, message)


func warn(message: String) -> void:
	_emit(Level.WARN, message)


func error(message: String) -> void:
	_emit(Level.ERROR, message)


func _emit(level: int, message: String) -> void:
	if level < _min_level:
		return
	var prefix: String = ["[dbg]", "[info]", "[warn]", "[error]"][level]
	if level >= Level.WARN:
		printerr("GodotCollab ", prefix, " ", message)
	else:
		print("Godot Collab ", prefix, " ", message)
	entry_emitted.emit(level, message)
