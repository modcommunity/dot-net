@tool
extends "dot_net_manager_send.gd"

## The client side of a snapshot: reading one, applying its entities and reconciling the predicted ones.


func _receive_snapshot(payload: PackedByteArray) -> DotResult:
	if is_server:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "A server does not receive snapshots."
		)

	stats.note_received(payload.size())

	var reader := DotNetReader.new(payload)

	var tick := reader.read_uint(32)
	var count := reader.read_uint(12)

	if not reader.ok():
		stats.note_decode_failure()
		return DotResult.fail(DotError.CODE_PARSE, "Truncated snapshot header.")

	var skipped := _admit_snapshot_tick(tick)
	if skipped != null:
		return skipped

	var walked := _apply_snapshot_entities(reader, count, tick)
	if walked != null:
		return walked

	var trailer := _read_snapshot_trailer(reader, tick)
	if not trailer.ok:
		return trailer
	var part: int = trailer.value.x
	var total: int = trailer.value.y

	_receiving_total = total
	_receiving_mask |= 1 << part

	# Only here and once every part is in: an ack means the whole snapshot was applied, and a
	# tick with a part missing is never acknowledged, so the server re-sends it.
	if _receiving_mask == (1 << total) - 1:
		_applied_snapshot_tick = tick

	snapshot_applied.emit(tick)
	return DotResult.success(tick)


## Null to read on, else the result to return (superseded or repeated).
func _admit_snapshot_tick(tick: int) -> DotResult:
	# Every time: a client adopts the server's tick rate after it started.
	stats.snapshot_interval_ticks = config.ticks_per_snapshot()

	# Once per tick, not per part. See [member _seen_ticks].
	if not _seen_ticks.has(tick):
		_seen_ticks.append(tick)
		if _seen_ticks.size() > SEEN_TICKS_KEPT:
			_seen_ticks.pop_front()
		stats.note_snapshot(tick)

	if tick < _receiving_tick:
		# Superseded: applying it would overwrite newer state, and its arrival time would read
		# as a sudden lead. A late part of an older tick is dropped too and re-sent unacked.
		return DotResult.success(_applied_snapshot_tick)

	if tick == _receiving_tick and _applied_snapshot_tick == tick:
		# Every part is in: a repeat. (A repeat of one part while another is missing is applied
		# again, writing the same values; it is not told apart until its trailer is read.)
		return DotResult.success(_applied_snapshot_tick)

	if tick > _receiving_tick:
		_receiving_tick = tick
		_receiving_mask = 0
		_receiving_total = 0
		# The first part to arrive is the snapshot's arrival, for timing.
		interpolator.note_arrival()
		clock.sync_from_server(tick, stats.rtt_percentile(0.5))
		interpolator.note_lateness(tick, clock.received_tick())
	return null


## Null when all entities were applied, else the result to return.
func _apply_snapshot_entities(reader: DotNetReader, count: int, tick: int) -> DotResult:
	for _i in range(count):
		var net_id := reader.read_uint(DotNetRegistry.ID_BITS)
		var behaviour_count := reader.read_uint(6)

		if not reader.ok():
			stats.note_decode_failure()
			return DotResult.fail(DotError.CODE_PARSE, "Truncated snapshot entry.")

		var identity := registry.get_identity(net_id)

		if identity == null:
			# Not spawned yet or already despawned, both normal in flight; the body cannot
			# be skipped without its declarations.
			if not registry.was_recently_removed(net_id):
				DotLog.debug(
					CHANNEL, "state for an unknown entity", {"net_id": net_id}
				)
			return DotResult.success(tick)

		var applied := _apply_entity(identity, tick, reader, behaviour_count)
		if not applied.ok:
			stats.note_decode_failure()
			return applied
	return null


## Success with Vector2i(part, total).
func _read_snapshot_trailer(reader: DotNetReader, tick: int) -> DotResult:
	# Only a split snapshot or one with an unchanged list has a tail (see [method _send_to_peer]).
	var part := 0
	var total := 1
	if reader.bits_remaining() >= UNCHANGED_TAIL_MIN_BITS:
		var listed := _apply_unchanged_tail(reader, tick)
		if not listed.ok:
			stats.note_decode_failure()
			return listed
		part = reader.read_uint(4)
		total = reader.read_uint(4) + 1
		if not reader.ok() or part >= total:
			stats.note_decode_failure()
			return DotResult.fail(
				DotError.CODE_PARSE, "Bad snapshot part trailer.",
				"part %d of %d" % [part, total]
			)
		# After the trailer: padding, or the input lead ([method DotNetClock.note_input_lead]).
		if reader.bits_remaining() >= INPUT_LEAD_BITS:
			var arrival := reader.read_int(INPUT_LEAD_FIELD_BITS)
			var input_tick := tick + reader.read_int(INPUT_LEAD_FIELD_BITS)
			if reader.ok():
				clock.note_input_lead(input_tick, arrival)
	elif reader.bits_remaining() >= SNAPSHOT_PART_TRAILER_BITS:
		part = reader.read_uint(4)
		total = reader.read_uint(4) + 1
		if not reader.ok() or total < 2 or part >= total:
			stats.note_decode_failure()
			return DotResult.fail(
				DotError.CODE_PARSE, "Bad snapshot part trailer.",
				"part %d of %d" % [part, total]
			)
	return DotResult.success(Vector2i(part, total))


## One entity of a snapshot, client side: its body read from [param reader], or, with a null reader, an entity listed as unchanged and applied as an empty body would be ([method DotNetBehaviour.apply_unchanged]).
##
## Either way the predictor or interpolator hears of it at this tick, so a still entity's rewind and interpolation samples match.
func _apply_entity(
	identity: DotNetIdentity, tick: int, reader: DotNetReader, behaviour_count: int
) -> DotResult:
	var values := {}

	for b in range(behaviour_count):
		if b >= identity.behaviours.size():
			return DotResult.fail(
				DotError.CODE_VERSION,
				"Behaviour count mismatch.",
				"entity %d: sent %d, local has %d"
					% [identity.net_id, behaviour_count, identity.behaviours.size()]
			)

		var behaviour := identity.behaviours[b]

		# A predicted entity's state goes to reconciliation rather than being applied: applying it would
		# undo everything predicted since.
		if identity.is_predicted():
			# Deferred, the prediction stays in the properties until the flush: reading
			# writes the server's (older) state into them, and anything drawn or ticked
			# before the flush would otherwise see the entity a round trip back.
			var held := {}
			if config.reconcile_once_per_frame:
				for declaration in behaviour.net_vars:
					# The client never computes a server-driven value: the server's is the newest there is.
					if declaration.client_predicts:
						held[declaration.property] = behaviour._net_read_property(declaration.property)
			var applied: DotResult = DotResult.success(0)
			if reader == null:
				behaviour.apply_unchanged(tick, true)
			else:
				applied = behaviour.read_state(reader, tick, true)
			if not applied.ok:
				return applied
			values.merge(behaviour.authoritative_values(), true)
			for property: StringName in held:
				behaviour._net_write_property(property, held[property])
		else:
			var applied2: DotResult = DotResult.success(0)
			if reader == null:
				behaviour.apply_unchanged(tick)
			else:
				applied2 = behaviour.read_state(reader, tick)
			if not applied2.ok:
				return applied2

			# What the server last SENT, not what the property holds: an interpolated property
			# holds the interpolator's own blend, which would be handed back as the server's word
			# and freeze the entity part of the way (history.md #17, #18).
			var received := behaviour.received_values()
			for declaration in behaviour.net_vars:
				if declaration.interpolate and received.has(declaration.property):
					values[declaration.property] = received[declaration.property]

	if identity.is_predicted():
		if config.reconcile_once_per_frame:
			# The newest tick wins; `values` is the server's whole state (absent filled from
			# what came before), so an older snapshot's has nothing the newer one lacks.
			var waiting: Array = _pending_reconcile.get(identity.net_id, [])
			if not waiting.is_empty():
				if int(waiting[1]) > tick:
					return DotResult.success(tick)
				_reconciles_coalesced += 1
			_pending_reconcile[identity.net_id] = [identity, tick, values]
		else:
			_reconcile(identity, tick, values)
	elif not values.is_empty():
		interpolator.push(identity.net_id, tick, values)

	return DotResult.success(tick)


## The unchanged list in a snapshot part's tail (see [method _write_unchanged_tail]): every id in it applied as an entity with an empty body. An id this client does not hold is skipped; there is nothing to step over. Leaves the reader at the part trailer.
func _apply_unchanged_tail(reader: DotNetReader, tick: int) -> DotResult:
	var mark := reader.read_uint(8)
	if not reader.ok() or mark != UNCHANGED_TAIL_MARK:
		return DotResult.fail(DotError.CODE_PARSE, "Bad snapshot tail.", "mark %d" % mark)

	var run_count := _read_gamma(reader)
	if run_count < 0 or run_count > MAX_UNCHANGED_LISTED:
		return DotResult.fail(DotError.CODE_PARSE, "Bad unchanged-entity list.")

	var ids: PackedInt32Array = []
	var cursor := 0
	for _r in run_count:
		var gap := _read_gamma(reader)
		var length := _read_gamma(reader) + 1
		if gap < 0 or length < 1 or ids.size() + length > MAX_UNCHANGED_LISTED:
			return DotResult.fail(DotError.CODE_PARSE, "Bad unchanged-entity run.")
		var first := cursor + gap
		if first + length > (1 << DotNetRegistry.ID_BITS):
			return DotResult.fail(DotError.CODE_PARSE, "Unchanged-entity run out of range.")
		for id in range(first, first + length):
			ids.append(id)
		cursor = first + length

	# Read whole before applying any: a list that turns out truncated must change nothing.
	for net_id in ids:
		var identity := registry.get_identity(net_id)
		if identity == null:
			continue
		var applied := _apply_entity(identity, tick, null, identity.behaviours.size())
		if not applied.ok:
			return applied

	return DotResult.success(ids.size())


func _reconcile(identity: DotNetIdentity, tick: int, values: Dictionary) -> void:
	var started := Time.get_ticks_usec()
	predictor.reconcile(
		identity, tick, values, _local_inputs, clock.tick,
		clock.tick_duration()
	)
	_local_inputs.acknowledge(tick)
	_perf_reconcile_usec += Time.get_ticks_usec() - started
	_perf_reconciles += 1
	_perf_replayed_ticks += predictor._last_replay_ticks
