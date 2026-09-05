class_name DotNetMessageRegistry
extends RefCounted

## Maps message types to wire ids, and routes decoded messages to handlers.
##
## [b]The extension point most games touch first.[/b] Register your own message
## classes and they are batched, prioritised, direction-checked and dispatched
## exactly like the built-in ones. Nothing in dot-net special-cases its own messages.
##
## [b]Ids are assigned by sorting type names, not by registration order.[/b] Two
## processes that registered the same set of types therefore agree on the numbering
## without negotiating, and a game can register its messages in whatever order suits
## its startup. What they cannot do is disagree about the [i]set[/i] — so the registry
## exposes a [method schema_hash] that peers compare during the handshake, turning a
## version mismatch into one clear error at connect time instead of garbled fields an
## hour later.

const CHANNEL := "net.msg"

## Wire ids are 12 bits: 4096 message types is far past any real game, and it keeps
## the per-message header at two bytes with the flags.
const ID_BITS := 12
const MAX_TYPES := 1 << ID_BITS

## name -> {id, script, delivery, direction, handler, priority}
var _by_name: Dictionary = {}

## id -> name, rebuilt whenever the set changes.
var _by_id: Dictionary = {}

var _sealed: bool = false
var _schema_hash: String = ""


## Registers a message type.
##
## [param script] must extend [DotNetMessage]. [param direction] is enforced on
## receipt — a message declared [constant DotNetMessage.Direction.TO_CLIENT] that
## arrives from a client is dropped and logged, which is the check that stops a
## client from sending itself a spawn.
func register(
	type_name: StringName,
	script: GDScript,
	delivery: DotNetMessage.Delivery = DotNetMessage.Delivery.RELIABLE,
	direction: DotNetMessage.Direction = DotNetMessage.Direction.BOTH
) -> DotResult:
	if _sealed:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The message registry is sealed.",
			"register every type before connecting; ids are fixed at seal time"
		)

	if type_name == &"":
		return DotResult.fail(
			DotError.CODE_INVALID, "A message type needs a name."
		)

	if _by_name.has(type_name):
		return DotResult.fail(
			DotError.CODE_STATE,
			"Message type '%s' is already registered." % type_name
		)

	if _by_name.size() >= MAX_TYPES:
		return DotResult.fail(
			DotError.CODE_STATE,
			"Too many message types (limit %d)." % MAX_TYPES
		)

	# Instantiating once at registration proves the script is usable and that its
	# declared name matches, rather than discovering it on the first send.
	var probe: Variant = script.new()
	if not (probe is DotNetMessage):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"'%s' must extend DotNetMessage." % type_name
		)

	var declared: StringName = (probe as DotNetMessage)._type_name()
	if declared != type_name:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Message name mismatch.",
			"registered as '%s' but _type_name() returns '%s'"
				% [type_name, declared]
		)

	_by_name[type_name] = {
		"id": -1,
		"script": script,
		"delivery": delivery,
		"direction": direction,
		"handler": Callable(),
		"priority": 0,
	}

	_schema_hash = ""
	return DotResult.success(type_name)


## Sets the handler for a type.
##
## Signature: [code]func(message: DotNetMessage) -> void[/code]. Separate from
## registration so a game can register its whole schema at startup and attach
## handlers later, per scene or per game mode.
func on(type_name: StringName, handler: Callable) -> DotResult:
	if not _by_name.has(type_name):
		return DotResult.fail(
			DotError.CODE_INVALID, "Unknown message type '%s'." % type_name
		)

	_by_name[type_name]["handler"] = handler
	return DotResult.success(type_name)


## Fixes the id assignment. Called automatically on first use.
##
## After sealing, registering fails — ids are on the wire, and adding a type would
## renumber every id above it and silently reinterpret every message.
func seal() -> void:
	if _sealed:
		return

	# [b]Sorted as Strings, not as StringNames.[/b] `Array.sort()` on a `StringName`
	# does NOT sort lexicographically — Godot compares StringNames by their interned
	# pointer, which is fast and is whatever order the names happened to be created in.
	# Two peers intern them in different orders, so they sort differently, so they assign
	# DIFFERENT WIRE IDS TO THE SAME MESSAGE TYPE and compute different schema hashes.
	#
	# Nothing errors. Each end encodes correctly and decodes the other's message as a
	# different type, or refuses it — and every existing test in this family missed it,
	# because they all run both ends in one process, where the two share one intern table
	# and therefore one order. A browser client is the first peer that is a genuinely
	# separate program, and it saw it immediately.
	var names: Array = []

	for key in _by_name.keys():
		names.append(String(key))

	names.sort()

	_by_id.clear()

	for i in range(names.size()):
		var name := StringName(names[i])
		_by_name[name]["id"] = i
		_by_id[i] = name

	_sealed = true
	_schema_hash = _compute_schema_hash(names)

	DotLog.info(
		CHANNEL,
		"message schema sealed",
		{"types": names.size(), "hash": _schema_hash.substr(0, 12)}
	)


func is_sealed() -> bool:
	return _sealed


## A hash of the registered schema, for handshake comparison.
##
## Covers names and delivery classes. Two peers with different hashes cannot
## communicate reliably, and finding that out at connect time is worth the eight
## bytes it costs.
func schema_hash() -> String:
	if not _sealed:
		seal()
	return _schema_hash


func _compute_schema_hash(names: Array) -> String:
	var parts := PackedStringArray()

	for name in names:
		var entry: Dictionary = _by_name[StringName(name)]
		parts.append("%s:%d" % [String(name), int(entry["delivery"])])

	return DotHash.sha256_text("|".join(parts))


# --- Encoding --------------------------------------------------------------

func id_of(type_name: StringName) -> int:
	if not _sealed:
		seal()
	if not _by_name.has(type_name):
		return -1
	return int(_by_name[type_name]["id"])


func delivery_of(type_name: StringName) -> DotNetMessage.Delivery:
	if not _by_name.has(type_name):
		return DotNetMessage.Delivery.RELIABLE
	return _by_name[type_name]["delivery"]


## Writes a message with its id header into [param writer].
func encode(message: DotNetMessage, writer: DotNetWriter) -> DotResult:
	var name := message.type_name()
	var id := id_of(name)

	if id < 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Message type '%s' is not registered." % name
		)

	writer.write_uint(id, ID_BITS)
	message.write(writer)

	return DotResult.success(id)


## Reads one message from [param reader], validating its direction.
##
## [param from_peer_id] is the transport's view of the sender — never a value from
## inside the payload. [param is_server] decides which directions are legal.
func decode(
	reader: DotNetReader,
	from_peer_id: int,
	is_server: bool
) -> DotResult:
	if not _sealed:
		seal()

	var id := reader.read_uint(ID_BITS)

	if not reader.ok():
		return DotResult.fail(
			DotError.CODE_PARSE, "Truncated message header."
		)

	if not _by_id.has(id):
		# An unknown id means the peers disagree about the schema, and since the
		# body length is unknown there is no way to skip it — the rest of the
		# packet is unreadable.
		return DotResult.fail(
			DotError.CODE_VERSION,
			"Unknown message id %d." % id,
			"the peers' message schemas differ"
		)

	var name: StringName = _by_id[id]
	var entry: Dictionary = _by_name[name]

	var direction: DotNetMessage.Direction = entry["direction"]

	if is_server and direction == DotNetMessage.Direction.TO_CLIENT:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"A client sent a server-to-client message.",
			"type '%s' from peer %d" % [name, from_peer_id]
		)

	if not is_server and direction == DotNetMessage.Direction.TO_SERVER:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"The server sent a client-to-server message.",
			"type '%s'" % name
		)

	var message: DotNetMessage = (entry["script"] as GDScript).new()
	message.sender_peer_id = from_peer_id
	message.read(reader)

	if not reader.ok():
		return DotResult.fail(
			DotError.CODE_PARSE,
			"Truncated message body.",
			"type '%s' from peer %d" % [name, from_peer_id]
		)

	var valid := message.validate()
	if not valid.ok:
		return valid.wrap("Message '%s' failed validation." % name)

	return DotResult.success(message)


## Dispatches a decoded message to its handler.
##
## A type with no handler is not an error — a game may register a schema before the
## scene that handles it exists — but it is logged once per type so a missing handler
## does not present as a silently ignored feature.
var _warned_missing: Dictionary = {}

func dispatch(message: DotNetMessage) -> void:
	var name := message.type_name()
	if not _by_name.has(name):
		return

	var handler: Callable = _by_name[name]["handler"]

	if not handler.is_valid():
		if not _warned_missing.has(name):
			_warned_missing[name] = true
			DotLog.warn(
				CHANNEL, "no handler for message type", {"type": String(name)}
			)
		return

	handler.call(message)


# --- Introspection ---------------------------------------------------------

func type_names() -> PackedStringArray:
	var out := PackedStringArray()
	for name in _by_name:
		out.append(String(name))
	out.sort()
	return out


func count() -> int:
	return _by_name.size()


func describe_lines() -> PackedStringArray:
	if not _sealed:
		seal()

	var out := PackedStringArray()
	out.append("schema %s (%d types)" % [_schema_hash.substr(0, 16), _by_name.size()])

	for name in type_names():
		var entry: Dictionary = _by_name[StringName(name)]
		out.append("  %-4d %-28s %-18s %-10s %s" % [
			int(entry["id"]),
			name,
			DotNetMessage.Delivery.keys()[entry["delivery"]],
			DotNetMessage.Direction.keys()[entry["direction"]],
			"handled" if (entry["handler"] as Callable).is_valid() else "-",
		])

	return out
