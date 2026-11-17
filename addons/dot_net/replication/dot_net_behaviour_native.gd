@tool
extends "dot_net_behaviour_views.gd"

## The native snapshot core's view of a [DotNetBehaviour]: its declarations as a spec, and each value encoded at the bit offsets the core asks for.

var _native_props: Array[StringName] = []
## Declaration index -> [value, pads, encodings] of the last [method _native_encode], to answer an unchanged value without running the codec again.
var _native_encoded: Dictionary = {}


## This behaviour's declarations for the native core: [code][properties, declarations,
## net_vars.size(), direct reads][/code], one PackedFloat64Array per declaration in [method DotNetVar.write]'s
## terms; the last says whether the core may read the values itself ([method _native_direct_reads]).
func _native_spec() -> Array:
	_native_props = []
	var slot_of := {}
	var decls: Array = []
	for declaration in net_vars:
		if not slot_of.has(declaration.property):
			slot_of[declaration.property] = _native_props.size()
			_native_props.append(declaration.property)
		decls.append(DotNetSimCodec.spec_row(declaration, slot_of[declaration.property]))
	return [_native_props, decls, net_vars.size(), _native_direct_reads()]


## What [method DotNetBehaviour._native_values] calls; a script that overrides any of them is read through it.
const _NATIVE_READ_HOOKS: Array[StringName] = [&"_net_read_property", &"_native_values", &"estimated_bits"]
## Script -> whether [method _native_direct_reads] holds for it, worked out once per script.
static var _direct_reads_by_script: Dictionary = {}


## Whether the native core may read this behaviour's values without calling [method DotNetBehaviour._native_values]
## ([member DotNetConfig.native_reads]): only when every script from this one down to [DotNetBehaviour] is GDScript
## and none overrides a read hook. [method Script.get_script_method_list] lists a method once per script in the
## chain that defines it, so an override shows as one more than [DotNetBehaviour]'s own.
func _native_direct_reads() -> bool:
	var script := get_script() as Script
	if script == null:
		return false
	if _direct_reads_by_script.has(script):
		return _direct_reads_by_script[script]
	var base := script
	var ok := true
	while base != null and base.get_global_name() != &"DotNetBehaviour":
		ok = ok and base is GDScript
		base = base.get_base_script()
	ok = ok and base != null and _native_hook_counts(script) == _native_hook_counts(base)
	_direct_reads_by_script[script] = ok
	return ok


static func _native_hook_counts(script: Script) -> Array[int]:
	var counts: Array[int] = []
	counts.resize(_NATIVE_READ_HOOKS.size())
	for method: Dictionary in script.get_script_method_list():
		var at := _NATIVE_READ_HOOKS.find(StringName(method["name"]))
		if at >= 0:
			counts[at] += 1
	return counts


## Off only to measure (and to test) what the two shortcuts in [method _native_encode] save.
static var native_encode_shortcuts := true


## [param value] as declaration [param index] writes it, begun at each of the first
## [param pads] bits of a byte: [code][bytes, bits, ...][/code]. For a custom codec, or a value
## only GDScript converts; called on the main thread when the snapshot opens.
func _native_encode(index: int, value: Variant, pads: int) -> Array:
	var declaration := net_vars[index]
	# Nobody can be sent an owner-only property of an entity with no owner (a bot, an NPC):
	# [method DotNetVar.visible_to] is false for every peer, so the core never asks for these
	# bytes. Encoding them is a codec call at each of eight bit offsets per entity per snapshot.
	if native_encode_shortcuts and declaration.audience == DotNetVar.Audience.OWNER and identity != null and identity.owner_peer_id <= 0:
		return []
	# The same value as the last snapshot's encodes to the same bytes (a codec is a function of the value and the bit it starts at): kept per declaration.
	var kept: Variant = _native_encoded.get(index)
	if native_encode_shortcuts and kept != null and int(kept[1]) == pads and typeof(kept[0]) == typeof(value) and kept[0] == value:
		return kept[2]
	var out: Array = []
	for pad in pads:
		var writer := DotNetWriter.new(64)
		if pad > 0:
			writer.write_bits(0, pad)
		declaration.write(writer, value)
		out.append(writer.to_bytes())
		out.append(writer.bit_length() - pad)
	_native_encoded[index] = [value, pads, out]
	return out
