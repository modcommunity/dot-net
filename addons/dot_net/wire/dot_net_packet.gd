class_name DotNetPacket
extends RefCounted

## Batches messages into packets, and takes them apart again.
##
## [b]Why batch at all.[/b] Every packet carries per-packet overhead — IP, UDP or
## TCP, the transport's own framing — somewhere between 28 and 60 bytes before a
## single byte of yours. A server sending 12 small state updates to a peer as 12
## packets spends more on headers than on state. Batched into one, it spends the
## overhead once.
##
## The other reason is ordering: a batch is one unit of loss. Twelve separate
## unreliable packets can arrive in any order and any subset; one batch either
## arrives whole or not at all, which makes "these updates are from the same tick"
## true without a sequence number on each.
##
## [b]Fragmentation.[/b] A batch that exceeds the MTU is split, and the pieces are
## reassembled on the far side. This is only for reliable messages: fragmenting an
## unreliable payload means losing one fragment discards the whole thing, so the loss
## rate multiplies by the fragment count. Unreliable messages that do not fit are
## refused rather than fragmented, and the sender is told to send less.

const CHANNEL := "net.packet"

## Bytes of payload per packet before fragmenting.
##
## 1200 stays under the smallest MTU in practice (1280 for IPv6) with room for
## headers, so a packet is never fragmented by the network itself — which matters
## because network-level fragmentation loses the whole datagram if any fragment
## drops, and does it invisibly.
const DEFAULT_MTU := 1200

## Header: a tick stamp and a message count.
const HEADER_TICK_BITS := 32
const HEADER_COUNT_BITS := 10

## The most messages one batch may carry.
const MAX_MESSAGES := (1 << HEADER_COUNT_BITS) - 1

## Fragment header: id, index, total.
const FRAGMENT_ID_BITS := 16
const FRAGMENT_INDEX_BITS := 8
const MAX_FRAGMENTS := (1 << FRAGMENT_INDEX_BITS) - 1


## Accumulates messages until flushed.
class Batch extends RefCounted:
	var tick: int = 0
	var messages: Array[DotNetMessage] = []
	var _estimated_bytes: int = 0

	func _init(p_tick: int = 0) -> void:
		tick = p_tick

	## Whether adding [param size_bytes] would exceed the budget.
	func would_overflow(size_bytes: int, mtu: int) -> bool:
		return _estimated_bytes + size_bytes > mtu or messages.size() >= MAX_MESSAGES

	func add(message: DotNetMessage, size_bytes: int) -> void:
		messages.append(message)
		_estimated_bytes += size_bytes

	func is_empty() -> bool:
		return messages.is_empty()

	func estimated_bytes() -> int:
		return _estimated_bytes


## Encodes a batch into one payload.
##
## Returns the bytes. Callers that need to respect an MTU should have used
## [method Batch.would_overflow] while filling; this does not refuse an oversized
## batch, it fragments on send.
static func encode_batch(
	batch: Batch,
	registry: DotNetMessageRegistry
) -> DotResult:
	if batch.messages.size() > MAX_MESSAGES:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Too many messages in one batch.",
			"%d, limit %d" % [batch.messages.size(), MAX_MESSAGES]
		)

	var writer := DotNetWriter.new()
	writer.write_uint(batch.tick, HEADER_TICK_BITS)
	writer.write_uint(batch.messages.size(), HEADER_COUNT_BITS)

	for message in batch.messages:
		var encoded := registry.encode(message, writer)
		if not encoded.ok:
			return encoded

	if writer.overflowed:
		return DotResult.fail(
			DotError.CODE_INVALID, "The batch exceeded the buffer limit."
		)

	return DotResult.success(writer.to_bytes())


## Decodes a payload into messages.
##
## [b]Every failure mode here is reachable from the network.[/b] A truncated buffer,
## a count that does not match the body, an unknown message id — all are handled by
## returning what decoded successfully plus an error, rather than by throwing away
## the whole packet. A partially-readable batch usually means a schema mismatch, and
## the messages that did decode are the ones that say so.
static func decode_batch(
	payload: PackedByteArray,
	registry: DotNetMessageRegistry,
	from_peer_id: int,
	is_server: bool
) -> DotResult:
	var reader := DotNetReader.new(payload)

	var tick := reader.read_uint(HEADER_TICK_BITS)
	var count := reader.read_uint(HEADER_COUNT_BITS)

	if not reader.ok():
		return DotResult.fail(
			DotError.CODE_PARSE, "Truncated batch header.", "from peer %d" % from_peer_id
		)

	var messages: Array[DotNetMessage] = []
	var first_error: DotError = null

	for i in range(count):
		var decoded := registry.decode(reader, from_peer_id, is_server)

		if not decoded.ok:
			# Stop rather than continue: message bodies are variable-length and the
			# reader's position is only meaningful if every preceding message was
			# understood. Carrying on would decode noise.
			first_error = decoded.error
			break

		var message: DotNetMessage = decoded.value
		message.tick = tick
		messages.append(message)

	if first_error != null:
		var result := DotResult.failure(first_error)
		first_error.context = {
			"decoded": messages.size(),
			"expected": count,
			"tick": tick,
		}
		return result

	return DotResult.success({"tick": tick, "messages": messages})


# --- Fragmentation ---------------------------------------------------------

## Splits an oversized payload into MTU-sized fragments.
##
## Only for reliable delivery — see the class note. Returns one fragment when the
## payload already fits, so callers do not branch.
static func fragment(
	payload: PackedByteArray,
	fragment_id: int,
	mtu: int = DEFAULT_MTU
) -> DotResult:
	# Each fragment carries its own header, so the usable payload is smaller than
	# the MTU. 8 bytes covers id, index and total with room to spare.
	var usable := mtu - 8

	if usable <= 0:
		return DotResult.fail(
			DotError.CODE_INVALID, "MTU is too small to carry a fragment header."
		)

	if payload.size() <= usable:
		var single := _write_fragment(payload, fragment_id, 0, 1)
		return DotResult.success([single])

	var total := int(ceilf(float(payload.size()) / float(usable)))

	if total > MAX_FRAGMENTS:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Payload needs too many fragments.",
			"%d fragments of %d bytes; limit is %d — send less per tick"
				% [total, usable, MAX_FRAGMENTS]
		)

	var out: Array = []
	for index in range(total):
		var start := index * usable
		var end := mini(start + usable, payload.size())
		out.append(
			_write_fragment(payload.slice(start, end), fragment_id, index, total)
		)

	return DotResult.success(out)


static func _write_fragment(
	chunk: PackedByteArray,
	fragment_id: int,
	index: int,
	total: int
) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_uint(fragment_id, FRAGMENT_ID_BITS)
	writer.write_uint(index, FRAGMENT_INDEX_BITS)
	writer.write_uint(total, FRAGMENT_INDEX_BITS)
	writer.write_bytes(chunk)
	return writer.to_bytes()


## Reassembles fragments into whole payloads.
##
## Holds partial sets until they complete or expire. The expiry is what stops a
## sender that drops one fragment of every message from growing this without bound —
## which is otherwise a slow memory exhaustion any peer can cause.
class Reassembler extends RefCounted:
	## Seconds a partial fragment set is held.
	var timeout_sec: float = 5.0

	## Partial sets held at once, per peer. Beyond this the oldest is dropped.
	var max_pending: int = 64

	## fragment_id -> {total, received: {index: bytes}, at_ms}
	var _pending: Dictionary = {}

	## Feeds one fragment. Returns the whole payload once the set completes.
	func feed(data: PackedByteArray) -> DotResult:
		var reader := DotNetReader.new(data)

		var fragment_id := reader.read_uint(FRAGMENT_ID_BITS)
		var index := reader.read_uint(FRAGMENT_INDEX_BITS)
		var total := reader.read_uint(FRAGMENT_INDEX_BITS)
		var chunk := reader.read_bytes()

		if not reader.ok():
			return DotResult.fail(
				DotError.CODE_PARSE, "Truncated fragment."
			)

		if total == 0 or index >= total:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Fragment index out of range.",
				"index %d of %d" % [index, total]
			)

		if total == 1:
			return DotResult.success(chunk)

		_expire()

		if not _pending.has(fragment_id):
			if _pending.size() >= max_pending:
				# Drop the oldest rather than refusing the new one: a peer whose
				# fragments are being lost should still make progress on the ones
				# that do arrive.
				var oldest := _oldest_id()
				if oldest >= 0:
					_pending.erase(oldest)

			_pending[fragment_id] = {
				"total": total,
				"received": {},
				"at_ms": Time.get_ticks_msec(),
			}

		var entry: Dictionary = _pending[fragment_id]

		if int(entry["total"]) != total:
			# Two senders picked the same id, or a stale set is being overwritten.
			# Restarting is the only safe answer; mixing them produces garbage.
			entry["total"] = total
			entry["received"] = {}

		(entry["received"] as Dictionary)[index] = chunk

		if (entry["received"] as Dictionary).size() < total:
			return DotResult.success(null)

		var assembled := PackedByteArray()
		for i in range(total):
			assembled.append_array((entry["received"] as Dictionary)[i])

		_pending.erase(fragment_id)
		return DotResult.success(assembled)

	func _expire() -> void:
		var cutoff := Time.get_ticks_msec() - int(timeout_sec * 1000.0)
		var dead: Array = []

		for fragment_id in _pending:
			if int((_pending[fragment_id] as Dictionary)["at_ms"]) < cutoff:
				dead.append(fragment_id)

		for fragment_id in dead:
			_pending.erase(fragment_id)

	func _oldest_id() -> int:
		var oldest := -1
		var oldest_at := 0x7FFFFFFF

		for fragment_id in _pending:
			var at := int((_pending[fragment_id] as Dictionary)["at_ms"])
			if at < oldest_at:
				oldest_at = at
				oldest = fragment_id

		return oldest

	func pending_count() -> int:
		return _pending.size()

	func clear() -> void:
		_pending.clear()
