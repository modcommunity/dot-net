@tool
extends "dot_net_manager_state.gd"

## How one peer's snapshot is cut into parts and written: the two builders, the unchanged tail.

## What one peer's snapshot is built from: everything about the peer that lives in a shared
## table or needs this thread, read before the fork.
class SnapshotJob extends RefCounted:
	var peer_id: int = 0
	var observer: DotNetIdentity = null
	var lead := Vector2i(DotNetInput.Buffer.LEAD_NONE, -1)
	var send_lead: bool = false
	var compact: bool = false
	var acked_tick: int = 0
	var strict: bool = false
	var oldest_pending: int = 0
	var remaining_bytes: int = 0
	var peer_budget: DotNetBudget.PeerBudget = null
	## Set by the interest phase ([method _interest_chunk]): what the build writes, in order.
	var ordered: Array = []
	var answer: Array = []
	var cap_count: int = 0


## One peer's snapshot, built and not yet sent: the payloads, and what the build found that
## lives in a table every peer shares, for [method _apply_build] on the manager's thread.
## The peer's own records (its views, its budget) were written by the build itself.
class SnapshotBuild extends RefCounted:
	var peer_id: int = 0
	var payloads: Array[PackedByteArray] = []
	## Entities in each payload, as [DotNetStats] counts them (the unchanged list included).
	var entity_counts: PackedInt32Array = []
	## [method DotNetInterest.relevance]'s answer, to commit.
	var relevance: Array = []
	## Relevant entities before the entity cap, for [method DotNetInterest.note_cap].
	var cap_count: int = 0
	var split: bool = false
	var unchanged_listed: int = 0
	var unchanged_bytes_saved: int = 0
	var input_leads_sent: int = 0
	## The first oversized entity's fields, for the one warning; empty when none was.
	var oversize: Dictionary = {}


## The per-peer half of [method _send_snapshots] for a caller that has already filtered and
## accumulated [param relevant]: builds on this thread into the live records and sends. Kept as it
## was rather than via [method _build_peer] (14% dearer inline); a change to one is a change to both.
func _send_to_peer(
	peer_id: int,
	tick: int,
	relevant: Array[DotNetIdentity]
) -> bool:
	if not send_fn.is_valid():
		return false

	# [b]A snapshot bigger than [member DotNetConfig.mtu] goes out as several parts, each a whole
	# snapshot of its own entities.[/b] ENet fragments over its MTU and losing one fragment loses the
	# packet; the cut is decided before writing, from the exact size, which cannot be undone after (docs/wire.md#snapshot-parts).
	var limit_bits := config.mtu * 8 - SNAPSHOT_PART_TRAILER_BITS

	# How early this peer's commands have been arriving, for its clock to steer by: in every
	# part, so a lost part does not lose it, behind an empty tail where the part has none.
	# Taken whether or not it is sent, so a sample never describes more than one period.
	var lead := Vector2i(DotNetInput.Buffer.LEAD_NONE, -1)
	if _input_buffers.has(peer_id):
		lead = (_input_buffers[peer_id] as DotNetInput.Buffer).take_lead_sample()
	var send_lead := lead.x != DotNetInput.Buffer.LEAD_NONE \
		and messages.peer_supports(peer_id, DotNetMessageRegistry.FEATURE_INPUT_LEAD)
	if send_lead:
		limit_bits -= _unchanged_tail_bits(PackedInt32Array()) + INPUT_LEAD_BITS

	var parts: Array[DotNetWriter] = []
	var counts: PackedInt32Array = []
	var writer := _begin_snapshot_part(tick)
	parts.append(writer)
	counts.append(0)

	var written := 0
	var remaining_bytes := budget.remaining(peer_id)
	var peer_budget := budget.for_peer(peer_id)

	# Entities with nothing to say, listed by id at the end of a part rather than written with
	# an empty body, for a peer that has said it reads the list. See
	# docs/wire.md#unchanged-entities.
	var compact := messages.peer_supports(peer_id, DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS)
	var unchanged: PackedInt32Array = []
	var unchanged_header_bits := 0

	var acked_tick := int(_acks.get(peer_id, 0))
	var strict := bool(_ack_wired.get(peer_id, false))
	# Anything sent longer ago than this is resolved one way or the other, so a peer
	# that stops acknowledging costs a bounded window rather than a growing record.
	var oldest_pending: int = tick - config.ack_window_snapshots * config.ticks_per_snapshot()

	for identity in relevant:
		# The entity this peer predicts. Its client reads a property's absence as "unchanged" and
		# rewinds to what it last received, so a property stays owed here until confirmed
		# ([method DotNetBehaviour.collect_dirty]).
		var predicted_by_peer := identity.owner_peer_id == peer_id \
			and identity.authority == DotNetIdentity.Authority.SHARED

		var dirties: Array = []
		for behaviour in identity.behaviours:
			# Resolve what this peer has confirmed before deciding what is dirty, so
			# a property whose only send was lost is dirty again and goes out here:
			# sync_peer_acks, trim_pending and collect_dirty, as one call.
			dirties.append(behaviour.collect_for_peer(
				peer_id, acked_tick, strict, oldest_pending, predicted_by_peer))

		if compact:
			var anything := false
			for dirty: Array in dirties:
				if not dirty.is_empty():
					anything = true
					break
			if not anything:
				# Nothing to write, so nothing for the budget or the parts to weigh: it costs
				# its share of a run of ids. It still counts as served, for the accumulator.
				unchanged.append(identity.net_id)
				unchanged_header_bits += DotNetRegistry.ID_BITS + 6 + 6 * identity.behaviours.size()
				budget.note_sent(peer_id, identity.net_id, 0)
				continue

		# A full update's guess, for the budget and the part cut: only for an entity being written.
		var estimated := 0
		for behaviour in identity.behaviours:
			estimated += behaviour.estimated_bits(peer_id)
		estimated = (estimated + 7) >> 3

		# After the dirty check, not before: an entity with nothing to say is not one the
		# budget needs to hold back. Resolving acks first for one that is then held back is
		# harmless -- the same resolution happens next snapshot either way.
		if written > 0 and estimated > remaining_bytes:
			budget.note_starved(peer_id)
			continue

		# Measured only near the end of a part: an entity is rarely over twice its estimate plus 32
		# bytes, and the exact figure costs a lookup per behaviour per entity per peer for an
		# answer that is nearly always "it fits".
		if counts[counts.size() - 1] > 0 \
				and writer.bit_length() + estimated * 16 + 256 > limit_bits \
				and _entity_end_bit(writer.bit_length(), identity, dirties) > limit_bits:
			if parts.size() >= MAX_SNAPSHOT_PARTS:
				# Out of parts: what does not fit waits, exactly as the budget makes it wait,
				# and the accumulator puts it at the front next time.
				budget.note_starved(peer_id)
				continue
			writer = _begin_snapshot_part(tick)
			parts.append(writer)
			counts.append(0)

		var before := writer.byte_length()

		# The id and then the behaviour count, as one field: bits are written low first, so
		# this is the same bits as the two writes, for one call per entity per peer.
		writer.write_bits(identity.net_id & ((1 << DotNetRegistry.ID_BITS) - 1) \
			| ((identity.behaviours.size() & 0x3F) << DotNetRegistry.ID_BITS),
			DotNetRegistry.ID_BITS + 6)

		for b in identity.behaviours.size():
			identity.behaviours[b].write_state(writer, dirties[b], peer_id, tick)

		if not _warned_oversize and writer.bit_length() > limit_bits:
			_warned_oversize = true
			DotLog.warn(CHANNEL, "an entity's state alone is bigger than the snapshot MTU; it is sent oversized", {
				"net_id": identity.net_id,
				"prefab": str(identity.prefab_id),
				"bytes": (writer.bit_length() + 7) >> 3,
				"mtu": config.mtu,
			})

		var spent := writer.byte_length() - before
		remaining_bytes -= spent
		# budget.note_sent, inlined: a call and a lookup of the same record per entity.
		peer_budget.accumulators[identity.net_id] = 0.0
		peer_budget.starved_ticks[identity.net_id] = 0
		peer_budget.bytes_this_second += spent
		counts[counts.size() - 1] += 1
		written += 1

	# A part left empty (only the last, after a cut starved everything) is not sent, or the client
	# would wait on it before acknowledging the tick. The first is kept even when empty: a
	# snapshot of nothing still goes out, see below.
	if parts.size() > 1 and counts[counts.size() - 1] == 0:
		parts.pop_back()
		counts.remove_at(counts.size() - 1)

	# [b]A snapshot goes out every snapshot tick, even with nothing in it.[/b] It is the client's
	# clock (`sync_from_server`, receive timeline, interpolation buffer) and the acknowledgement
	# rides on one applied. A quiet world is a small snapshot, never a missing one.

	# The unchanged list goes at the end of the last part when it fits there, else in a part of
	# its own, else (sixteen parts already) not at all: those entities then miss one refresh,
	# exactly as a starved entity does.
	var tail_part := -1
	var runs := _unchanged_runs(unchanged)
	if not runs.is_empty():
		var tail_bits := _unchanged_tail_bits(runs)
		if parts[parts.size() - 1].bit_length() + tail_bits <= limit_bits + SNAPSHOT_PART_TRAILER_BITS:
			tail_part = parts.size() - 1
		elif parts.size() < MAX_SNAPSHOT_PARTS:
			parts.append(_begin_snapshot_part(tick))
			counts.append(0)
			tail_part = parts.size() - 1
		else:
			budget.note_starved(peer_id)
		if tail_part >= 0:
			unchanged_listed += unchanged.size()
			unchanged_bytes_saved += maxi(0, (unchanged_header_bits - tail_bits) >> 3)

	var total := parts.size()
	if total > 1:
		snapshots_split += 1

	for index in total:
		var part := parts[index]
		# Only a split snapshot carries the trailer, so one that fits is byte for byte what
		# this addon sent before parts existed -- unless it lists unchanged entities, whose tail
		# always ends in one.
		if index == tail_part:
			_write_unchanged_tail(part, runs)
			part.write_uint(index, 4)
			part.write_uint(total - 1, 4)
		elif send_lead:
			_write_unchanged_tail(part, PackedInt32Array())
			part.write_uint(index, 4)
			part.write_uint(total - 1, 4)
		elif total > 1:
			part.write_uint(index, 4)
			part.write_uint(total - 1, 4)

		if send_lead:
			var span := 1 << (INPUT_LEAD_FIELD_BITS - 1)
			part.write_int(clampi(lead.x, -span, span - 1), INPUT_LEAD_FIELD_BITS)
			part.write_int(clampi(lead.y - tick, -span, span - 1), INPUT_LEAD_FIELD_BITS)
			input_leads_sent += 1

		var payload := part.to_bytes()

		# Patch the count in now that it is known. The header is byte-aligned by
		# construction, so this is a plain byte edit rather than a bit splice.
		var count_byte := SNAPSHOT_COUNT_BIT >> 3
		var count := counts[index]
		if count_byte + 1 < payload.size():
			payload[count_byte] = count & 0xFF
			payload[count_byte + 1] = (payload[count_byte + 1] & 0xF0) | ((count >> 8) & 0x0F)

		send_fn.call(peer_id, payload, DotNetMessage.Delivery.UNRELIABLE)

		largest_part_bytes = maxi(largest_part_bytes, payload.size())
		budget.note_packet(peer_id, payload.size())
		stats.note_sent(payload.size(), count + (unchanged.size() if index == tail_part else 0))

	return true


## Everything [method _build_peer] needs from shared tables and from this thread.
func _freeze_job(peer_id: int, tick: int) -> SnapshotJob:
	var job := SnapshotJob.new()
	job.peer_id = peer_id
	job.observer = _observer_for(peer_id)
	# [b]The observer may not be in [code]identities[/code][/b], read before input and simulation: a
	# peer's first entity registered this tick is located by [method _observer_for] but never
	# frozen, and interest would read its position on a worker. Frozen here, on the main thread.
	if job.observer != null and not job.observer.is_position_frozen():
		job.observer.freeze_position()
		_late_frozen.append(job.observer)

	# How early this peer's commands have been arriving, for its clock to steer by: in every
	# part, so a lost part does not lose it, behind an empty tail where the part has none.
	# Taken whether or not it is sent, so a sample never describes more than one period.
	if _input_buffers.has(peer_id):
		job.lead = (_input_buffers[peer_id] as DotNetInput.Buffer).take_lead_sample()
	job.send_lead = job.lead.x != DotNetInput.Buffer.LEAD_NONE \
		and messages.peer_supports(peer_id, DotNetMessageRegistry.FEATURE_INPUT_LEAD)

	# Entities with nothing to say, listed by id at the end of a part rather than written with
	# an empty body, for a peer that has said it reads the list. See
	# docs/wire.md#unchanged-entities.
	job.compact = messages.peer_supports(peer_id, DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS)

	job.acked_tick = int(_acks.get(peer_id, 0))
	job.strict = bool(_ack_wired.get(peer_id, false))
	# Anything sent longer ago than this is resolved one way or the other, so a peer
	# that stops acknowledging costs a bounded window rather than a growing record.
	job.oldest_pending = tick - config.ack_window_snapshots * config.ticks_per_snapshot()
	job.remaining_bytes = budget.remaining(peer_id)
	job.peer_budget = budget.for_peer(peer_id)
	return job


## [method _send_to_peer] on a worker: one peer's parts built into the peer's live
## [DotNetBehaviour.PeerView]s and budget record, with the task's own [param caches]. Everything
## shared comes back in the build for [method _apply_build]. A copy, not a generalisation.
func _build_peer(
	job: SnapshotJob,
	tick: int,
	relevant: Array,
	caches: Dictionary
) -> SnapshotBuild:
	var build := SnapshotBuild.new()
	var peer_id := job.peer_id
	build.peer_id = peer_id
	var peer_budget := job.peer_budget

	# [b]A snapshot bigger than [member DotNetConfig.mtu] goes out as several parts, each a whole
	# snapshot of its own entities.[/b] ENet fragments over its MTU and losing one fragment loses the
	# packet; the cut is decided before writing, from the exact size, which cannot be undone after (docs/wire.md#snapshot-parts).
	var limit_bits := config.mtu * 8 - SNAPSHOT_PART_TRAILER_BITS

	var lead := job.lead
	var send_lead := job.send_lead
	if send_lead:
		limit_bits -= _unchanged_tail_bits(PackedInt32Array()) + INPUT_LEAD_BITS

	var parts: Array[DotNetWriter] = []
	var counts: PackedInt32Array = []
	var writer := _begin_snapshot_part(tick)
	parts.append(writer)
	counts.append(0)

	var written := 0
	var remaining_bytes := job.remaining_bytes

	var compact := job.compact
	var unchanged: PackedInt32Array = []
	var unchanged_header_bits := 0

	var acked_tick := job.acked_tick
	var strict := job.strict
	var oldest_pending := job.oldest_pending

	var starved := 0
	var entity_views: Array = []
	var entity_caches: Array = []

	for identity: DotNetIdentity in relevant:
		# The entity this peer predicts. Its client reads a property's absence as "unchanged" and
		# rewinds to what it last received, so a property stays owed here until confirmed
		# ([method DotNetBehaviour.collect_dirty]).
		var predicted_by_peer := identity.owner_peer_id == peer_id \
			and identity.authority == DotNetIdentity.Authority.SHARED

		var dirties: Array = []
		entity_views.clear()
		entity_caches.clear()
		for behaviour in identity.behaviours:
			# Made on the manager's thread before the fork ([method _send_snapshots_pooled]):
			# a read here, never an insert into the behaviour's shared table.
			var view: DotNetBehaviour.PeerView = behaviour._views[peer_id]
			var cache: DotNetBehaviour.EncodeCache = caches.get(behaviour)
			if cache == null:
				cache = DotNetBehaviour.EncodeCache.new()
				caches[behaviour] = cache
			entity_views.append(view)
			entity_caches.append(cache)
			# Resolve what this peer has confirmed before deciding what is dirty, so
			# a property whose only send was lost is dirty again and goes out here:
			# sync_peer_acks, trim_pending and collect_dirty, as one call.
			dirties.append(behaviour.collect_for_view(
				view, peer_id, acked_tick, strict, oldest_pending, predicted_by_peer, cache))

		if compact:
			var anything := false
			for dirty: Array in dirties:
				if not dirty.is_empty():
					anything = true
					break
			if not anything:
				# Nothing to write, so nothing for the budget or the parts to weigh: it costs
				# its share of a run of ids. It still counts as served, for the accumulator.
				unchanged.append(identity.net_id)
				unchanged_header_bits += DotNetRegistry.ID_BITS + 6 + 6 * identity.behaviours.size()
				peer_budget.accumulators[identity.net_id] = 0.0
				peer_budget.starved_ticks[identity.net_id] = 0
				continue

		# A full update's guess, for the budget and the part cut: only for an entity being written.
		var estimated := 0
		for behaviour in identity.behaviours:
			estimated += behaviour.estimated_bits(peer_id)
		estimated = (estimated + 7) >> 3

		# After the dirty check, not before: an entity with nothing to say is not one the
		# budget needs to hold back. Resolving acks first for one that is then held back is
		# harmless -- the same resolution happens next snapshot either way.
		if written > 0 and estimated > remaining_bytes:
			starved += 1
			continue

		# Measured only near the end of a part: an entity is rarely over twice its estimate plus 32
		# bytes, and the exact figure costs a lookup per behaviour per entity per peer for an
		# answer that is nearly always "it fits".
		if counts[counts.size() - 1] > 0 \
				and writer.bit_length() + estimated * 16 + 256 > limit_bits \
				and _entity_end_bit_cached(writer.bit_length(), identity, dirties, entity_caches) > limit_bits:
			if parts.size() >= MAX_SNAPSHOT_PARTS:
				# Out of parts: what does not fit waits, exactly as the budget makes it wait,
				# and the accumulator puts it at the front next time.
				starved += 1
				continue
			writer = _begin_snapshot_part(tick)
			parts.append(writer)
			counts.append(0)

		var before := writer.byte_length()

		# The id and then the behaviour count, as one field: bits are written low first, so
		# this is the same bits as the two writes, for one call per entity per peer.
		writer.write_bits(identity.net_id & ((1 << DotNetRegistry.ID_BITS) - 1) \
			| ((identity.behaviours.size() & 0x3F) << DotNetRegistry.ID_BITS),
			DotNetRegistry.ID_BITS + 6)

		for b in identity.behaviours.size():
			identity.behaviours[b].write_for_view(
				writer, dirties[b], entity_views[b], tick, entity_caches[b])

		if writer.bit_length() > limit_bits and build.oversize.is_empty():
			build.oversize = {
				"net_id": identity.net_id,
				"prefab": str(identity.prefab_id),
				"bytes": (writer.bit_length() + 7) >> 3,
				"mtu": config.mtu,
			}

		var spent := writer.byte_length() - before
		remaining_bytes -= spent
		peer_budget.accumulators[identity.net_id] = 0.0
		peer_budget.starved_ticks[identity.net_id] = 0
		peer_budget.bytes_this_second += spent
		counts[counts.size() - 1] += 1
		written += 1

	# A part left empty (only the last, after a cut starved everything) is not sent, or the client
	# would wait on it before acknowledging the tick. The first is kept even when empty: a
	# snapshot of nothing still goes out, see below.
	if parts.size() > 1 and counts[counts.size() - 1] == 0:
		parts.pop_back()
		counts.remove_at(counts.size() - 1)

	# [b]A snapshot goes out every snapshot tick, even with nothing in it.[/b] It is the client's
	# clock (`sync_from_server`, receive timeline, interpolation buffer) and the acknowledgement
	# rides on one applied. A quiet world is a small snapshot, never a missing one.

	# The unchanged list goes at the end of the last part when it fits there, else in a part of
	# its own, else (sixteen parts already) not at all: those entities then miss one refresh,
	# exactly as a starved entity does.
	var tail_part := -1
	var runs := _unchanged_runs(unchanged)
	if not runs.is_empty():
		var tail_bits := _unchanged_tail_bits(runs)
		if parts[parts.size() - 1].bit_length() + tail_bits <= limit_bits + SNAPSHOT_PART_TRAILER_BITS:
			tail_part = parts.size() - 1
		elif parts.size() < MAX_SNAPSHOT_PARTS:
			parts.append(_begin_snapshot_part(tick))
			counts.append(0)
			tail_part = parts.size() - 1
		else:
			starved += 1
		if tail_part >= 0:
			build.unchanged_listed += unchanged.size()
			build.unchanged_bytes_saved += maxi(0, (unchanged_header_bits - tail_bits) >> 3)

	var total := parts.size()
	build.split = total > 1

	for index in total:
		var part := parts[index]
		# Only a split snapshot carries the trailer, so one that fits is byte for byte what
		# this addon sent before parts existed -- unless it lists unchanged entities, whose tail
		# always ends in one.
		if index == tail_part:
			_write_unchanged_tail(part, runs)
			part.write_uint(index, 4)
			part.write_uint(total - 1, 4)
		elif send_lead:
			_write_unchanged_tail(part, PackedInt32Array())
			part.write_uint(index, 4)
			part.write_uint(total - 1, 4)
		elif total > 1:
			part.write_uint(index, 4)
			part.write_uint(total - 1, 4)

		if send_lead:
			var span := 1 << (INPUT_LEAD_FIELD_BITS - 1)
			part.write_int(clampi(lead.x, -span, span - 1), INPUT_LEAD_FIELD_BITS)
			part.write_int(clampi(lead.y - tick, -span, span - 1), INPUT_LEAD_FIELD_BITS)
			build.input_leads_sent += 1

		var payload := part.to_bytes()

		# Patch the count in now that it is known. The header is byte-aligned by
		# construction, so this is a plain byte edit rather than a bit splice.
		var count_byte := SNAPSHOT_COUNT_BIT >> 3
		var count := counts[index]
		if count_byte + 1 < payload.size():
			payload[count_byte] = count & 0xFF
			payload[count_byte + 1] = (payload[count_byte + 1] & 0xF0) | ((count >> 8) & 0x0F)

		build.payloads.append(payload)
		build.entity_counts.append(count + (unchanged.size() if index == tail_part else 0))

	peer_budget.starved_this_tick += starved
	peer_budget.total_starved += starved
	return build


## Makes [param build]'s shared changes and sends its parts. The manager's thread, in peer order.
func _apply_build(build: SnapshotBuild, context: Dictionary) -> void:
	var peer_id := build.peer_id

	interest.commit_relevance(peer_id, build.relevance)
	interest.note_cap(peer_id, build.cap_count, config.entity_cap(), context)

	if not _warned_oversize and not build.oversize.is_empty():
		_warned_oversize = true
		DotLog.warn(CHANNEL, "an entity's state alone is bigger than the snapshot MTU; it is sent oversized",
			build.oversize)

	if build.split:
		snapshots_split += 1
	unchanged_listed += build.unchanged_listed
	unchanged_bytes_saved += build.unchanged_bytes_saved
	input_leads_sent += build.input_leads_sent

	for index in build.payloads.size():
		var payload := build.payloads[index]
		send_fn.call(peer_id, payload, DotNetMessage.Delivery.UNRELIABLE)
		largest_part_bytes = maxi(largest_part_bytes, payload.size())
		budget.note_packet(peer_id, payload.size())
		stats.note_sent(payload.size(), build.entity_counts[index])


## [param ids] (in the order they were served) as runs of consecutive ids, sorted:
## [code][start, length, start, length, ...][/code].
static func _unchanged_runs(ids: PackedInt32Array) -> PackedInt32Array:
	var out: PackedInt32Array = []
	if ids.is_empty():
		return out
	var sorted := ids.duplicate()
	sorted.sort()
	var start := sorted[0]
	var length := 1
	for i in range(1, sorted.size()):
		var id := sorted[i]
		if id == start + length:
			length += 1
		elif id >= start + length:
			out.append(start)
			out.append(length)
			start = id
			length = 1
	out.append(start)
	out.append(length)
	return out


## Bits [method _write_unchanged_tail] writes for [param runs], plus the part trailer after it.
static func _unchanged_tail_bits(runs: PackedInt32Array) -> int:
	var bits := 8 + _gamma_bits(runs.size() >> 1) + SNAPSHOT_PART_TRAILER_BITS
	var cursor := 0
	for i in range(0, runs.size(), 2):
		bits += _gamma_bits(runs[i] - cursor) + _gamma_bits(runs[i + 1] - 1)
		cursor = runs[i] + runs[i + 1]
	return bits


## The mark, the number of runs, and each run as the gap from the end of the one before and
## its length less one, all Elias gamma: a contiguous block of ids costs a few bits whatever
## its size, a scattered set a few bits an entity. See docs/wire.md#unchanged-entities.
static func _write_unchanged_tail(writer: DotNetWriter, runs: PackedInt32Array) -> void:
	writer.write_uint(UNCHANGED_TAIL_MARK, 8)
	_write_gamma(writer, runs.size() >> 1)
	var cursor := 0
	for i in range(0, runs.size(), 2):
		_write_gamma(writer, runs[i] - cursor)
		_write_gamma(writer, runs[i + 1] - 1)
		cursor = runs[i] + runs[i + 1]


## Elias gamma of [code]value + 1[/code], so zero is one bit: zero bits for the width after the leading
## one, then the number from its leading one down, most-significant bit first, because the reader
## counts zeros to learn the width.
static func _write_gamma(writer: DotNetWriter, value: int) -> void:
	var n := value + 1
	var width := 0
	while (n >> (width + 1)) != 0:
		width += 1
	if width > 0:
		writer.write_bits(0, width)
	for bit in range(width, -1, -1):
		writer.write_bits((n >> bit) & 1, 1)


static func _gamma_bits(value: int) -> int:
	var n := value + 1
	var width := 0
	while (n >> (width + 1)) != 0:
		width += 1
	return 2 * width + 1


## The reader's half of [method _write_gamma]. -1, with the reader failed or not, for a width
## past [constant DotNetRegistry.ID_BITS]: no id, gap or run needs more, and a stream of zeros
## from a broken packet must not become a long loop.
static func _read_gamma(reader: DotNetReader) -> int:
	var width := 0
	while reader.read_bits(1) == 0:
		if not reader.ok():
			return -1
		width += 1
		if width > DotNetRegistry.ID_BITS:
			return -1
	var n := 1
	for _i in width:
		n = (n << 1) | reader.read_bits(1)
	if not reader.ok():
		return -1
	return n - 1


## A snapshot part's header: the tick, and a count patched in once the entities are written.
## Writing the count first would mean guessing how many fit.
func _begin_snapshot_part(tick: int) -> DotNetWriter:
	var writer := DotNetWriter.new()
	writer.write_uint(tick, 32)
	writer.write_uint(0, 12)
	return writer


## Where an entity would end if written at [param from_bit] with [param dirties] (one array of
## declarations per behaviour), exactly. Each behaviour's encoding depends on the bit of a
## byte it starts at, so they are measured in order.
func _entity_end_bit(from_bit: int, identity: DotNetIdentity, dirties: Array) -> int:
	var at := from_bit + DotNetRegistry.ID_BITS + 6
	for b in identity.behaviours.size():
		at += identity.behaviours[b].state_bits(dirties[b], at & 7)
	return at


## [method _entity_end_bit] with each behaviour's [DotNetBehaviour.EncodeCache], for
## [method _build_peer].
func _entity_end_bit_cached(
	from_bit: int, identity: DotNetIdentity, dirties: Array, caches: Array
) -> int:
	var at := from_bit + DotNetRegistry.ID_BITS + 6
	for b in identity.behaviours.size():
		at += identity.behaviours[b].state_bits_cached(dirties[b], at & 7, caches[b])
	return at
