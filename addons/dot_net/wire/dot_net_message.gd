@tool
class_name DotNetMessage
extends RefCounted

## Base class for anything sent over the wire.
##
## Subclass it, declare a type name, and implement [method _write] / [method _read].
## Register it with a [DotNetMessageRegistry] and it becomes a first-class message —
## batched, prioritised, and routed to a handler like any built-in one.
##
## [codeblock]
## class_name ChatMessage extends DotNetMessage
##
## var text: String
## var channel: int
##
## func _type_name() -> StringName: return &"game.chat"
##
## func _write(w: DotNetWriter) -> void:
##     w.write_uint(channel, 4)
##     w.write_string(text, 256)
##
## func _read(r: DotNetReader) -> void:
##     channel = r.read_uint(4)
##     text = r.read_string(256)
##
## # once, at startup
## registry.register(&"game.chat", ChatMessage, DotNetMessage.Delivery.RELIABLE)
## [/codeblock]
##
## [b]Nothing here knows about your game.[/b] The built-in messages
## ([code]net.*[/code]) handle clock sync, spawning and state; everything else is
## yours, and the registry treats both identically.

## How a message should be delivered. Maps onto transport channels and to what
## happens when the network drops a packet.
enum Delivery {
	## Must arrive, in order. Spawns, despawns, chat, commands.
	##
	## Costs a retransmit and head-of-line blocking on loss, which is why state does
	## not use it.
	RELIABLE,
	## May be dropped. State snapshots, positions, anything a newer packet
	## supersedes.
	##
	## Resending a 100 ms old position is worse than useless — the newer one is
	## already on the way.
	UNRELIABLE,
	## Must arrive, order irrelevant. Independent events that do not sequence.
	RELIABLE_UNORDERED,
	## Only the newest matters; older queued copies are dropped before sending.
	##
	## For per-entity state where a backlog means the sender is behind. See
	## [DotNetPriority].
	UNRELIABLE_LATEST,
}

## Where a message may legitimately come from.
##
## Checked on receipt, before the handler runs. Without it, any client can send the
## server a "you have been kicked" or a spawn message — the single most common
## mistake in a hand-rolled protocol.
enum Direction {
	## Server to client only. A client sending this is refused and logged.
	TO_CLIENT,
	## Client to server only.
	TO_SERVER,
	## Either way.
	BOTH,
}

## Filled in by the registry on decode: which peer sent it.
##
## 1 is the server in Godot's multiplayer numbering. Never trust a peer id carried
## *inside* a message body; this one comes from the transport.
var sender_peer_id: int = 0

## Tick the message was created on, when the sender stamped one.
var tick: int = 0


# --- Subclass interface ----------------------------------------------------

## Stable identifier, namespaced. Yours should not start with [code]net.[/code].
func _type_name() -> StringName:
	return &""


func _write(_writer: DotNetWriter) -> void:
	push_error("%s does not implement _write()." % _type_name())


func _read(_reader: DotNetReader) -> void:
	push_error("%s does not implement _read()." % _type_name())


## Cheap validation after decoding, before the handler sees it.
##
## The place to reject a message whose fields are individually well-formed but
## collectively impossible — a negative count, a slot index past the maximum, a
## string that must be one of four values. Returning a failure drops the message and
## logs the sender.
##
## [b]Do this here, not in the handler.[/b] A handler that validates is a handler
## someone will copy without the validation.
func _validate() -> DotResult:
	return DotResult.success(true)


# --- Public API ------------------------------------------------------------

func type_name() -> StringName:
	return _type_name()


func write(writer: DotNetWriter) -> void:
	_write(writer)


func read(reader: DotNetReader) -> void:
	_read(reader)


func validate() -> DotResult:
	return _validate()


## Encodes to bytes on its own, without a batch. For tests and one-off sends.
func to_bytes() -> PackedByteArray:
	var writer := DotNetWriter.new()
	_write(writer)
	return writer.to_bytes()


func _to_string() -> String:
	return "%s(from %d)" % [_type_name(), sender_peer_id]
