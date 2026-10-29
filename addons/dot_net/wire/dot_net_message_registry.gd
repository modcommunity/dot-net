class_name DotNetMessageRegistry
extends RefCounted

## Maps message types to wire ids, and routes decoded messages to handlers. [b]The extension point most
## games touch first.[/b] Register your own message classes and they are batched, prioritised,
## direction-checked and dispatched exactly like the built-in ones.

const CHANNEL := "net.msg"

## Wire ids are 32 bits: the first four bytes of the type name's SHA-256.
const ID_BITS := 32

## The id that carries a peer's schema table rather than a message. No name can hash to it
## and be registered; see [method register].
const SCHEMA_ID := 0

## Types per registry. Unrelated to the id width now; a bound on a table a peer sends us.
const MAX_TYPES := 4096

## A type name on the wire, in a schema table.
const MAX_NAME_BYTES := 128

## Body length in bits, bounded before anything is sliced: a varint claiming four billion
## bits must not cause an allocation.
const MAX_BODY_BITS := 1 << 24

## Wire features beyond the messages, as bits of one varint appended to the schema table.
const FEATURE_UNCHANGED_RUNS := 1

## [constant FEATURE_INPUT_LEAD]: snapshots may end with how early this client's commands are
## reaching the server, which its clock steers by (see
## [code]docs/timelines.md#the-input-lead-the-server-reports[/code]).
const FEATURE_INPUT_LEAD := 2

## What this end announces. Every feature this build reads, by default; a test that wants to
## be an older peer clears it before the table is sent.
var features: int = FEATURE_UNCHANGED_RUNS | FEATURE_INPUT_LEAD

## A peer's schema table arrived and was compatible.
signal peer_adopted(peer_id: int)

## A peer's schema table arrived and cannot work with this one. [param error] is
## CODE_VERSION, with a message a player can read and the types in the detail.
signal peer_refused(peer_id: int, error: DotError)

## name -> {id, script, delivery, direction, handler, priority, required}
var _by_name: Dictionary = {}

## id -> name.
var _by_id: Dictionary = {}

var _sealed: bool = false
var _schema_hash: String = ""

## peer_id -> {"names": {name: {required, direction, delivery}}, "blocked": {id: true}}
var _peers: Dictionary = {}

## peer_id -> DotError, for a peer whose table was refused. Nothing it sends is decoded.
var _refused: Dictionary = {}

## Messages skipped because this end did not have their type -- the unknown traffic a
## peer one build ahead sends. Counted rather than logged each time, and logged once per
## id per peer at DEBUG.
var skipped: int = 0
var _skipped_noted: Dictionary = {}


## The wire id a type name travels as. The same number in every build that has the type.
## Derived from the name alone, so a message's bytes are its only contract: append fields, never
## reorder or retype one.
static func wire_id_for(type_name: StringName) -> int:
	var digest := DotHash.sha256_text(String(type_name))
	return digest.substr(0, 8).hex_to_int()


## Registers a message type. [param script] must extend [DotNetMessage].
func register(
	type_name: StringName,
	script: GDScript,
	delivery: DotNetMessage.Delivery = DotNetMessage.Delivery.RELIABLE,
	direction: DotNetMessage.Direction = DotNetMessage.Direction.BOTH,
	required: bool = true
) -> DotResult:
	if _sealed:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The message registry is sealed.",
			"register every type before connecting; a type added after the schema was "
			+ "sent to peers is one they were told this end does not have"
		)

	if type_name == &"":
		return DotResult.fail(
			DotError.CODE_INVALID, "A message type needs a name."
		)

	if String(type_name).to_utf8_buffer().size() > MAX_NAME_BYTES:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Message type name '%s' is too long." % type_name,
			"%d bytes at most" % MAX_NAME_BYTES
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

	var id := wire_id_for(type_name)

	# Four billion ids and a few dozen names: a collision is not going to happen by
	# chance, and if it does it must be a refusal at startup, where somebody can rename
	# one of them, rather than two types silently decoding as each other.
	if id == SCHEMA_ID or _by_id.has(id):
		return DotResult.fail(
			DotError.CODE_CONFLICT,
			"Message type '%s' collides with another type's wire id." % type_name,
			"id %d is %s; rename one of them" % [
				id, "reserved for the schema table" if id == SCHEMA_ID else "'%s'" % _by_id[id]
			]
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
		"id": id,
		"script": script,
		"delivery": delivery,
		"direction": direction,
		"handler": Callable(),
		"priority": 0,
		"required": required,
	}
	_by_id[id] = type_name

	_schema_hash = ""
	return DotResult.success(type_name)


## Sets the handler for a type. Signature: [code]func(message: DotNetMessage) -> void[/code].
func on(type_name: StringName, handler: Callable) -> DotResult:
	if not _by_name.has(type_name):
		return DotResult.fail(
			DotError.CODE_INVALID, "Unknown message type '%s'." % type_name
		)

	_by_name[type_name]["handler"] = handler
	return DotResult.success(type_name)


## Closes the schema. Called automatically on first use. Ids no longer depend on the set, so sealing
## renumbers nothing -- it exists because the table a peer was sent is a promise.
func seal() -> void:
	if _sealed:
		return

	_sealed = true
	_schema_hash = _compute_schema_hash()

	DotLog.info(
		CHANNEL,
		"message schema sealed",
		{
			"types": _by_name.size(),
			"required": required_names().size(),
			"hash": _schema_hash.substr(0, 12),
		}
	)


func is_sealed() -> bool:
	return _sealed


## A hash of what a peer MUST share with this one, for display and for a handshake. [b]Only the
## required types' names.[/b] An extra optional type must not read as incompatible.
func schema_hash() -> String:
	if not _sealed:
		seal()
	if _schema_hash == "":
		_schema_hash = _compute_schema_hash()
	return _schema_hash


func _compute_schema_hash() -> String:
	# Sorted as Strings, not StringNames: `Array.sort()` on StringNames compares interned
	# pointers, which is the order the names happened to be created in and differs between
	# two processes -- the bug that once gave two peers different wire ids for one type.
	return DotHash.sha256_text("|".join(required_names()))


## Every registered type's name, sorted.
func type_names() -> PackedStringArray:
	var out := PackedStringArray()
	for name in _by_name:
		out.append(String(name))
	out.sort()
	return out


## The names a peer has to know for this end to work with it, sorted.
func required_names() -> PackedStringArray:
	var out := PackedStringArray()
	for name in _by_name:
		if bool(_by_name[name]["required"]):
			out.append(String(name))
	out.sort()
	return out


func is_required(type_name: StringName) -> bool:
	return _by_name.has(type_name) and bool(_by_name[type_name]["required"])


## This end's schema as a standalone payload, for [DotNetManager.receive] on the other. Every type,
## with whether it is required, its direction and its delivery.
func schema_payload() -> PackedByteArray:
	if not _sealed:
		seal()

	var body := DotNetWriter.new()
	var names := type_names()
	body.write_varint(names.size())

	for name in names:
		var entry: Dictionary = _by_name[StringName(name)]
		body.write_string(name, MAX_NAME_BYTES)
		body.write_bool(bool(entry["required"]))
		body.write_uint(int(entry["direction"]), 2)
		body.write_uint(int(entry["delivery"]), 2)

	# Appended after the table shipped, so an older reader stops before it.
	body.write_varint(features)

	var writer := DotNetWriter.new()
	_frame(writer, SCHEMA_ID, body)
	return writer.to_bytes()


## Compares a peer's table with this one and remembers it. Both directions, because either end can be
## the newer: a type this end requires that the peer does not know, and a type the peer requires that
## this end does not.
func adopt_peer_schema(peer_id: int, reader: DotNetReader, is_server: bool) -> DotResult:
	var count := reader.read_varint()

	if not reader.ok() or count < 0 or count > MAX_TYPES:
		return DotResult.fail(
			DotError.CODE_PARSE,
			"A malformed message schema.",
			"peer %d announced %d types" % [peer_id, count]
		)

	var names := {}

	for _i in range(count):
		var name := reader.read_string(MAX_NAME_BYTES)
		var required := reader.read_bool()
		var direction := reader.read_uint(2)
		var delivery := reader.read_uint(2)

		if not reader.ok() or name == "":
			return DotResult.fail(
				DotError.CODE_PARSE,
				"A truncated message schema.",
				"peer %d" % peer_id
			)

		names[name] = {"required": required, "direction": direction, "delivery": delivery}

	# A table from before features were appended has nothing more, and offers none.
	var peer_features := 0
	if reader.has_more():
		peer_features = reader.read_varint()
		if not reader.ok() or peer_features < 0:
			peer_features = 0

	# Ids a peer means by a DIFFERENT name than this end does. Astronomically unlikely and
	# checkable only here, where both names are finally side by side.
	var blocked := {}
	var conflicts := PackedStringArray()

	for name in names.keys():
		var id := wire_id_for(StringName(name))
		if _by_id.has(id) and String(_by_id[id]) != name:
			blocked[id] = true
			conflicts.append("%s/%s" % [name, String(_by_id[id])])

	var missing_there := PackedStringArray()
	for name in required_names():
		if not names.has(name):
			missing_there.append(name)

	var missing_here := PackedStringArray()
	for name in names.keys():
		if bool(names[name]["required"]) and not _by_name.has(StringName(name)):
			missing_here.append(name)
	missing_here.sort()

	_peers[peer_id] = {"names": names, "blocked": blocked, "features": peer_features}

	var refusal := explain(missing_there, missing_here, conflicts, is_server)

	if refusal != null:
		_refused[peer_id] = refusal
		DotLog.warn(CHANNEL, "peer's message schema refused", {
			"peer": peer_id,
			"why": refusal.message,
			"detail": refusal.detail,
		})
		peer_refused.emit(peer_id, refusal)
		return DotResult.failure(refusal)

	_refused.erase(peer_id)

	DotLog.debug(CHANNEL, "peer's message schema adopted", {
		"peer": peer_id,
		"types": names.size(),
		"theirs_only": _count_unknown(names),
	})
	peer_adopted.emit(peer_id)
	return DotResult.success(peer_id)


func _count_unknown(names: Dictionary) -> int:
	var n := 0
	for name in names.keys():
		if not _by_name.has(StringName(name)):
			n += 1
	return n


## What to tell a player, and what to log, when two schemas cannot work together. Null when they can.
## [b]Says who has to update, not which messages differ.[/b] A player cannot do anything about a
## message type; the names go in the detail, for the operator reading the same line in a log.
static func explain(
	missing_there: PackedStringArray,
	missing_here: PackedStringArray,
	conflicts: PackedStringArray,
	is_server: bool
) -> DotError:
	if missing_there.is_empty() and missing_here.is_empty() and conflicts.is_empty():
		return null

	var message := ""
	var parts := PackedStringArray()

	if not missing_there.is_empty():
		message = (
			"This server's game needs a newer game client." if is_server
			else "This server is running an older version of this game."
		)
		parts.append("the %s does not know the required message types: %s"
			% ["client" if is_server else "server", ", ".join(missing_there)])

	if not missing_here.is_empty():
		if message == "":
			message = (
				"This game client is newer than the server's game." if is_server
				else "This server's game needs a newer game client."
			)
		parts.append("this %s does not know the required message types: %s"
			% ["server" if is_server else "client", ", ".join(missing_here)])

	if not conflicts.is_empty():
		if message == "":
			message = "This server and this game client cannot tell two of their messages apart."
		parts.append("these types share a wire id: %s" % ", ".join(conflicts))

	return DotError.make(DotError.CODE_VERSION, message, "; ".join(parts))


## Whether a peer's table has arrived.
func knows_peer(peer_id: int) -> bool:
	return _peers.has(peer_id)


## Whether a peer understands a type, as far as this end knows. True for a peer whose table has not
## arrived, because until it does the honest answer is "probably" and a sender that stayed quiet would
## lose the first messages of every join.
func peer_has(peer_id: int, type_name: StringName) -> bool:
	if not _peers.has(peer_id):
		return true
	return (_peers[peer_id]["names"] as Dictionary).has(String(type_name))


## Whether a peer has said it reads a wire [param feature] (a [code]FEATURE_*[/code] bit).
func peer_supports(peer_id: int, feature: int) -> bool:
	if not _peers.has(peer_id):
		return false
	return (int(_peers[peer_id].get("features", 0)) & feature) == feature


func is_refused(peer_id: int) -> bool:
	return _refused.has(peer_id)


func refusal_of(peer_id: int) -> DotError:
	return _refused.get(peer_id)


func forget_peer(peer_id: int) -> void:
	_peers.erase(peer_id)
	_refused.erase(peer_id)
	for key in _skipped_noted.keys():
		if int(String(key).get_slice(":", 0)) == peer_id:
			_skipped_noted.erase(key)


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


## Writes a message with its id header into [param writer]. Framed as [code]id (32) | body length in
## bits (varint) | align | body[/code].
func encode(message: DotNetMessage, writer: DotNetWriter) -> DotResult:
	var name := message.type_name()
	var id := id_of(name)

	if id < 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Message type '%s' is not registered." % name
		)

	var body := DotNetWriter.new()
	message.write(body)

	if body.overflowed:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Message '%s' is too large to encode." % name
		)

	_frame(writer, id, body)
	return DotResult.success(id)


static func _frame(writer: DotNetWriter, id: int, body: DotNetWriter) -> void:
	writer.write_uint(id, ID_BITS)
	writer.write_varint(body.bit_length())
	# Aligned so the body's own byte alignment -- `write_bytes` and `write_string` align
	# as they go -- means the same thing to the reader as it did to the writer.
	writer.write_aligned_bytes(body.to_bytes())


## Reads one message from [param reader], validating its direction. Succeeds with [code]null[/code] for
## a message there is nothing to dispatch for: a schema table, which it adopts; a type this end does
## not have, which it skips; and a type a refused peer sent.
func decode(
	reader: DotNetReader,
	from_peer_id: int,
	is_server: bool
) -> DotResult:
	if not _sealed:
		seal()

	var id := reader.read_uint(ID_BITS)
	var bits := reader.read_varint()

	if not reader.ok():
		return DotResult.fail(
			DotError.CODE_PARSE, "Truncated message header."
		)

	var body: DotNetReader = null
	if bits <= MAX_BODY_BITS:
		body = reader.take_bits(bits)

	if body == null:
		return DotResult.fail(
			DotError.CODE_PARSE,
			"Truncated message body.",
			"%d bits claimed, from peer %d" % [bits, from_peer_id]
		)

	if id == SCHEMA_ID:
		var adopted := adopt_peer_schema(from_peer_id, body, is_server)
		return adopted if not adopted.ok else DotResult.success(null)

	if _refused.has(from_peer_id):
		# Nothing from a peer whose schema was refused is understood: the host is about to
		# drop it, and a message decoded in the meantime is decoded against a table the two
		# ends have already agreed they do not share.
		return DotResult.success(null)

	var blocked := false
	if _peers.has(from_peer_id):
		blocked = (_peers[from_peer_id]["blocked"] as Dictionary).has(id)

	if blocked or not _by_id.has(id):
		skipped += 1
		var note_key := "%d:%d" % [from_peer_id, id]
		if not _skipped_noted.has(note_key):
			_skipped_noted[note_key] = true
			DotLog.debug(CHANNEL, "skipped a message type this end does not have", {
				"peer": from_peer_id, "id": id, "bits": bits,
			})
		return DotResult.success(null)

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
	message.read(body)

	# [b]A body that ran out is not a failure any more.[/b] The body's length was framed and checked
	# above, so a short body is not a truncated packet: it is a sender whose version of this message had
	# fewer fields.

	var valid := message.validate()
	if not valid.ok:
		return valid.wrap("Message '%s' failed validation." % name)

	return DotResult.success(message)


## Dispatches a decoded message to its handler. A type with no handler is not an error — a game may
## register a schema before the scene that handles it exists — but it is logged once per type so a
## missing handler does not present as a silently ignored feature.
var _warned_missing: Dictionary = {}

func dispatch(message: DotNetMessage) -> void:
	if message == null:
		return

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


func count() -> int:
	return _by_name.size()


func describe_lines() -> PackedStringArray:
	if not _sealed:
		seal()

	var out := PackedStringArray()
	out.append("schema %s (%d types, %d required, %d skipped)" % [
		schema_hash().substr(0, 16), _by_name.size(), required_names().size(), skipped
	])

	for name in type_names():
		var entry: Dictionary = _by_name[StringName(name)]
		out.append("  %08x %-28s %-18s %-10s %-8s %s" % [
			int(entry["id"]),
			name,
			DotNetMessage.Delivery.keys()[entry["delivery"]],
			DotNetMessage.Direction.keys()[entry["direction"]],
			"required" if bool(entry["required"]) else "optional",
			"handled" if (entry["handler"] as Callable).is_valid() else "-",
		])

	for peer_id in _peers.keys():
		out.append("  peer %d: %d types%s" % [
			int(peer_id),
			(_peers[peer_id]["names"] as Dictionary).size(),
			", REFUSED: %s" % (_refused[peer_id] as DotError).message if _refused.has(peer_id) else "",
		])

	return out
