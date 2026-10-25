class_name DotNetNative
extends RefCounted
## Loads dot-net's optional native snapshot library and makes a [code]DotNetNativeCore[/code] for
## a server's [DotNetManager] when [member DotNetConfig.native] asks for one. Never required: on
## any failure the GDScript path runs and the reason is logged once. See docs/native.md.

const CHANNEL := "net.native"

## The library's [code]abi_version()[/code] this GDScript was written against.
const ABI := 2
const CORE_CLASS := &"DotNetNativeCore"
const ADDON_CFG := "res://addons/dot_net/native/dot_net_native.cfg"
const EXE_DIR_CFG := "dot_net_native/dot_net_native.cfg"

# One load per process: GDExtensionManager refuses a second one of the same classes.
static var _attempted := false
static var _loaded_from := ""
static var _reason := ""


## A new core for one manager, or the reason there is none.
static func make_core(config: DotNetConfig) -> DotResult:
	var res := load_library(config.native_path if config != null else "")
	if not res.ok:
		return res
	return DotResult.success(ClassDB.instantiate(CORE_CLASS))


## Loads the library once per process. [param path] is a [code].cfg[/code]; empty tries the
## addon's own, then one next to the executable.
static func load_library(path: String = "") -> DotResult:
	if ClassDB.class_exists(CORE_CLASS):
		return _check_abi()
	if _attempted:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, _reason)
	_attempted = true
	if not DotPlatform.is_desktop():
		return _refuse("native snapshots need a desktop or server build (%s)" % DotPlatform.kind_name())
	var candidates: PackedStringArray = []
	if not path.is_empty():
		candidates.append(path)
	else:
		candidates.append(ProjectSettings.globalize_path(ADDON_CFG))
		candidates.append(OS.get_executable_path().get_base_dir().path_join(EXE_DIR_CFG))
	var skipped: PackedStringArray = []
	for candidate in candidates:
		var file := ProjectSettings.globalize_path(candidate)
		if not FileAccess.file_exists(file):
			skipped.append("%s: absent" % file)
			continue
		# Checked first: the engine prints an ERROR for a .cfg with no library for this platform.
		var library := _library_for_platform(file)
		if library.is_empty() or not FileAccess.file_exists(library):
			skipped.append("%s: no library built for this platform" % file)
			continue
		var status := GDExtensionManager.load_extension(file)
		if status == GDExtensionManager.LOAD_STATUS_OK or status == GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
			if ClassDB.class_exists(CORE_CLASS):
				_loaded_from = file
				return _check_abi()
		skipped.append("%s: did not load (status %d)" % [file, status])
	DotLog.debug(CHANNEL, "no native snapshot library loaded", {"tried": skipped})
	return _refuse("no native library loaded (%s); build it with addons/dot_net/native/build.sh" % "; ".join(skipped))


## The library [param cfg] names for this platform's feature tags, as an absolute path, or "".
static func _library_for_platform(cfg: String) -> String:
	var parsed := ConfigFile.new()
	if parsed.load(cfg) != OK or not parsed.has_section("libraries"):
		return ""
	for key in parsed.get_section_keys("libraries"):
		var fits := true
		for tag in key.split("."):
			if not OS.has_feature(tag):
				fits = false
				break
		if fits:
			var path := String(parsed.get_value("libraries", key, ""))
			return ProjectSettings.globalize_path(path) if path.is_absolute_path() else cfg.get_base_dir().path_join(path)
	return ""


static func _check_abi() -> DotResult:
	var abi := int(ClassDB.class_call_static(CORE_CLASS, &"abi_version"))
	if abi != ABI:
		_reason = "the native library is ABI %d, this dot-net wants %d; rebuild it" % [abi, ABI]
		return DotResult.fail(DotError.CODE_VERSION, _reason)
	return DotResult.success(_loaded_from)


static func _refuse(reason: String) -> DotResult:
	_reason = reason
	return DotResult.fail(DotError.CODE_UNSUPPORTED, reason)


static func describe() -> Dictionary:
	return {
		"loaded": ClassDB.class_exists(CORE_CLASS),
		"from": _loaded_from,
		"reason": _reason,
	}
