@tool
extends "dot_net_manager_receive.gd"

## The acknowledgement half of [DotNetManager]: the tick a client acks, its wire form, and what the server does with one.


## The newest snapshot tick this client has applied in full. Client side.
##
## Zero until one has been. Send it with [method encode_ack]; hand it to [method receive_ack] there.
func ack_tick() -> int:
	return _applied_snapshot_tick


## The current acknowledgement as a payload. Client side.
##
## Not sent for you: this addon owns no client-to-server channel, so append it to the input packet you already send (four bytes) and give it to [method receive_ack_payload] on the server. Optional; without it an unconfirmed snapshot is assumed to have arrived once it ages out, and a dropped property is stranded until it changes. See [method receive_ack].
func encode_ack() -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_uint(_applied_snapshot_tick, 32)
	return writer.to_bytes()


## Records that a peer has applied every snapshot up to [param tick]. Server side. Snapshots are
## unreliable and carry only what changed; acknowledgements let the server re-send what a dropped
## packet lost.
func receive_ack(peer_id: int, tick: int) -> DotResult:
	if not is_server:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "Only a server receives acknowledgements."
		)

	if not _acks.has(peer_id):
		return DotResult.fail(
			DotError.CODE_STATE, "No such peer.", "peer %d" % peer_id
		)

	# The tick comes from a client: one past the newest sent would confirm state never sent. A stale
	# (lower) ack is not refused; reordering makes it normal, and it is ignored below.
	if tick < 0 or tick > _last_snapshot_tick:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Acknowledged a snapshot that was never sent.",
			"peer %d claimed tick %d; the newest is %d"
				% [peer_id, tick, _last_snapshot_tick]
		)

	if not bool(_ack_wired.get(peer_id, false)):
		_ack_wired[peer_id] = true
		# Sends that aged out before this first ack were assumed delivered, which a client
		# still loading is not: it skips snapshots naming entities it has not been told of.
		# Start over once, so state that never changes again (health, alive) is re-sent.
		var window := config.ack_window_snapshots * config.ticks_per_snapshot()
		if _last_snapshot_tick - int(_peer_added_tick.get(peer_id, 0)) > window:
			for identity in registry.all():
				for behaviour in identity.behaviours:
					behaviour.forget_peer(peer_id)
		DotLog.debug(
			CHANNEL,
			"peer is acknowledging snapshots; lost state will be re-sent",
			{"peer": peer_id}
		)

	if tick > int(_acks.get(peer_id, 0)):
		_acks[peer_id] = tick
	_note_acked(peer_id, tick)

	return DotResult.success(int(_acks[peer_id]))


## Decodes an acknowledgement produced by [method encode_ack]. Server side.
func receive_ack_payload(peer_id: int, payload: PackedByteArray) -> DotResult:
	var reader := DotNetReader.new(payload)
	var tick := reader.read_uint(32)

	if not reader.ok():
		return DotResult.fail(DotError.CODE_PARSE, "Truncated acknowledgement.")

	return receive_ack(peer_id, tick)


## Whether a peer's acknowledgements are arriving, so losses can be recovered.
func peer_acks_wired(peer_id: int) -> bool:
	return bool(_ack_wired.get(peer_id, false))
