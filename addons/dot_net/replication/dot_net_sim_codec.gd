class_name DotNetSimCodec
extends RefCounted
## dot-sim's native snapshot codec ([code]DotSimSnapshotCodec[/code], the [code]snapshot[/code]
## module): [method DotNetBehaviour._encode] and [method DotNetBehaviour.read_state] in Rust,
## bit for bit the bytes [DotNetVar] writes and the values it reads. Optional: with no dot-sim
## library loaded (a plain web export, or a dlink one without dot-sim's side module), with
## [member DotNetConfig.sim_codec] off or [member enabled] false, the GDScript codec runs, and a value the native one cannot reproduce exactly (a custom codec, a
## string, a value of the wrong type) is still written and read by the script. See
## docs/native.md.

const CLASS := &"DotSimSnapshotCodec"

## [code]decode[/code]'s stops; the crate's [code]Stop[/code].
const DONE := 0
const TRUNCATED_HEADER := 1
const TRUNCATED_ENTRY := 2
const UNKNOWN_INDEX := 3
const TRUNCATED_VALUE := 4
const SCRIPT := 5

## Off for the whole process: every behaviour bound after this uses the GDScript codec. For
## tests and measurements; a game turns it off with [member DotNetConfig.sim_codec].
static var enabled := true


## Whether the native codec can run in this process at all: the class exists only once dot-sim's
## library has loaded, on the web too (a dlink export with its side module, dot-sim docs/web.md).
static func available() -> bool:
	return enabled and ClassDB.class_exists(CLASS)


## A codec for [param net_vars] (one behaviour's declarations, bound to their config), or null
## when [param config] turns it off, it cannot load, or none of the declarations is its to do.
static func create(net_vars: Array[DotNetVar], config: DotNetConfig) -> Object:
	if config != null and not config.sim_codec:
		return null
	if net_vars.is_empty() or not available():
		return null
	var codec: Object = ClassDB.instantiate(CLASS)
	if codec == null:
		return null
	var rows: Array = []
	for declaration in net_vars:
		rows.append(spec_row(declaration, 0))
	if int(codec.call(&"set_spec", rows)) == 0:
		return null
	return codec


## One declaration in [method DotNetVar.write]'s terms: the row dot-net's own native core
## reads too ([method DotNetBehaviour._native_spec]), [param slot] its property's slot there.
static func spec_row(declaration: DotNetVar, slot: int) -> PackedFloat64Array:
	return PackedFloat64Array([
		declaration.type, declaration.audience, declaration.max_rate, declaration.epsilon,
		1.0 if declaration.on_spawn_only else 0.0, declaration.bit_width,
		declaration.min_value, declaration.max_value, declaration._extent(),
		declaration._position_bits(), declaration._max_speed(), declaration._velocity_bits(),
		declaration._rotation_bits(), slot,
	])


## [method DotNetBehaviour._encode] for [param behaviour] in its codec: the same
## [code][bytes, end bit, recorded, rate-limited properties][/code], or empty for the script to
## encode (a value only the script writes, or a snapshot worker thread: workers can encode one
## behaviour for two peers at once, and a codec has one scratch buffer).
static func encode(behaviour: DotNetBehaviour, declarations: Array[DotNetVar], pad: int) -> Array:
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		return []
	var recorded := {}
	var rated: Array[StringName] = []
	var indices := PackedInt32Array()
	var values: Array = []

	for declaration in declarations:
		var index := int(behaviour._index_of.get(declaration, -1))
		if index < 0:
			index = behaviour.net_vars.find(declaration)
		if index < 0:
			continue

		var value: Variant = behaviour._read_for_send(declaration.property)

		indices.append(index)
		values.append(value)
		recorded[declaration.property] = value
		if declaration.max_rate > 0.0:
			rated.append(declaration.property)

	var out: Array = behaviour._sim_codec.call(&"encode", pad, declarations.size(), indices, values)
	if out.is_empty():
		return []
	return [out[0], out[1], recorded, rated]


## [method DotNetBehaviour.read_state] for [param behaviour] in its codec: the same reads, values,
## change handlers, errors and reader position. A declaration only the script reads stops the
## codec; the script reads that value and the codec carries on after it.
static func read_state(
	behaviour: DotNetBehaviour, reader: DotNetReader, tick: int, rewind: bool
) -> DotResult:
	var net_vars := behaviour.net_vars
	var codec: Object = behaviour._sim_codec
	# Per call: a change handler may read another behaviour's state.
	var out: Array = []
	var remaining := -1
	var count := 0

	while true:
		var stop: int = codec.call(
			&"decode", reader._bytes, reader._bit_pos, reader._end_bits, remaining, out
		)
		reader._bit_pos = out[0]
		if out[1]:
			reader.exhausted = true

		var read := (out.size() - 4) >> 1
		if remaining < 0:
			if stop == TRUNCATED_HEADER:
				return DotResult.fail(DotError.CODE_PARSE, "Truncated state header.")
			count = read + int(out[2])
			behaviour._read_now.clear()

		for i in range(read):
			behaviour._apply_read(net_vars[int(out[4 + 2 * i])], out[5 + 2 * i])

		if stop == DONE:
			break
		if stop == TRUNCATED_ENTRY:
			return DotResult.fail(DotError.CODE_PARSE, "Truncated state entry.")
		if stop == UNKNOWN_INDEX:
			return DotResult.fail(
				DotError.CODE_VERSION,
				"State references an unknown property index.",
				"index %d, this behaviour has %d — the peers' declarations differ"
					% [int(out[3]), net_vars.size()]
			)
		if stop == TRUNCATED_VALUE:
			return DotResult.fail(
				DotError.CODE_PARSE, "Truncated property value.", String(net_vars[int(out[3])].property)
			)

		# SCRIPT: the codec read the index, the value is the script's.
		var declaration := net_vars[int(out[3])]
		var value: Variant = declaration.read(reader)
		if not reader.ok():
			return DotResult.fail(
				DotError.CODE_PARSE, "Truncated property value.", String(declaration.property)
			)
		behaviour._apply_read(declaration, value)
		remaining = int(out[2]) - 1
		if remaining == 0:
			break

	behaviour._finish_read(tick, rewind)
	return DotResult.success(count)
