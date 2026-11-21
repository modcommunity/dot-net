class_name DotNetCostProbe
extends RefCounted

## Reports bytes per message class to GameSpice Profiler's [code]DotProfilerNetCost[/code] when that addon is installed. GameSpice Net does not depend on it: the class is found by name once, and every call is one bool test while the profiler is absent or not recording.

const IN := 0
const OUT := 1

static var _script: Script = null
static var _looked := false


## Counts one message of [param bytes] for [param cls] in direction [constant IN] or [constant OUT].
static func note(cls: StringName, dir: int, bytes: int) -> void:
	if not _looked:
		_find()
	if _script == null or not _script.get(&"enabled"):
		return
	_script.call(&"add", cls, dir, bytes)


## True when a profiler is present and recording.
static func active() -> bool:
	if not _looked:
		_find()
	return _script != null and _script.get(&"enabled")


## Looks the profiler class up again, for a game that loads it late.
static func reset() -> void:
	_looked = false
	_script = null


## Uses [param script] as the profiler class (it needs a static [code]enabled[/code] and [code]add(cls, dir, bytes)[/code]); for tests and for a game that names its own.
static func bind(script: Script) -> void:
	_script = script
	_looked = true


static func _find() -> void:
	_looked = true
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		if entry.get("class") == &"DotProfilerNetCost":
			_script = load(String(entry.get("path"))) as Script
			return
