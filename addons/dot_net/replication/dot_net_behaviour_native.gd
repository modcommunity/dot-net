@tool
extends "dot_net_behaviour_views.gd"

## The native snapshot core's view of a [DotNetBehaviour]: its declarations as a spec, and each value encoded at the bit offsets the core asks for.

var _native_props: Array[StringName] = []
## Declaration index -> [value, pads, encodings] of the last [method _native_encode], to answer an unchanged value without running the codec again.
var _native_encoded: Dictionary = {}


## This behaviour's declarations for the native core: [code][properties, declarations,
## net_vars.size()][/code], one PackedFloat64Array per declaration in [method DotNetVar.write]'s terms.
func _native_spec() -> Array:
	_native_props = []
	var slot_of := {}
	var decls: Array = []
	for declaration in net_vars:
		if not slot_of.has(declaration.property):
			slot_of[declaration.property] = _native_props.size()
			_native_props.append(declaration.property)
		decls.append(DotNetSimCodec.spec_row(declaration, slot_of[declaration.property]))
	return [_native_props, decls, net_vars.size()]


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
