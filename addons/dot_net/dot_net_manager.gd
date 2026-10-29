@tool
class_name DotNetManager
extends "dot_net_manager_send.gd"

## Drives the netcode. One per network session; place it and it runs.
##
## Owns the tick loop and wires the pieces together (clock, registry, spawner, interest, budget, interpolator, predictor, history), each reachable and replaceable. Sends through [member send_fn], so it is transport-agnostic. Usage: README.md.

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	DotRegistry.register(_service_name(), self)


func _exit_tree() -> void:
	DotRegistry.unregister_instance(_service_name(), self)


func _service_name() -> StringName:
	return DotRegistry.scoped_name(SERVICE, service_scope)


## Prepares everything. Call before [method start], or let [method start] call it.
func setup() -> DotResult:
	if config == null:
		config = DotNetConfig.new()

	if config_file != "":
		var loaded := config.apply_json_file(config_file)
		if not loaded.ok:
			return loaded

	config.apply_env()
	config.apply_cli()

	var valid := config.validate()
	if not valid.ok:
		return valid

	clock = DotNetClock.new(config.tick_rate, is_server)
	clock.input_margin_ticks = config.input_margin_ticks
	clock.adaptive_margin = config.adaptive_input_margin
	clock.lead_slack_ticks = config.input_lead_slack_ticks

	registry = DotNetRegistry.new(is_server, local_peer_id)
	messages = DotNetMessageRegistry.new()
	messages.peer_refused.connect(_on_peer_refused)
	budget = DotNetBudget.new(config)
	stats = DotNetStats.new()

	if interest == null:
		var distance := DotNetInterestDistance.new()
		distance.radius = config.interest_radius
		distance.far_every = config.far_every
		distance.far_distance = config.far_distance
		interest = distance
	elif interest is DotNetInterestGrid:
		# The config's knob, documented since the first version and applied by
		# nothing: a host that assigned a grid got the grid's own default whatever
		# the config said.
		(interest as DotNetInterestGrid).cell_size = config.interest_cell_size

	if is_server:
		history = DotNetHistory.new(config)
		_message_limiter = DotRateLimiter.new(
			float(config.client_message_rate),
			float(config.client_message_rate)
		)
	else:
		interpolator = DotNetInterpolator.new(config)
		predictor = DotNetPredictor.new(config)
		_local_inputs = DotNetInput.Buffer.new(config.input_history_ticks)

	_resolve_spawner()

	DotLog.info(
		CHANNEL,
		"netcode ready",
		{
			"role": "server" if is_server else "client",
			"tick_rate": config.tick_rate,
			"snapshot_rate": config.snapshot_rate,
			"interest": interest.strategy_name,
		}
	)

	return DotResult.success(self)


func _resolve_spawner() -> void:
	if spawner_ref == null:
		spawner_ref = DotNodeRef.of_created(&"Spawner", DotNetSpawner)

	var resolved := spawner_ref.resolve(self)

	if resolved.ok:
		spawner = resolved.value as DotNetSpawner
	else:
		DotLog.warn(
			CHANNEL, "could not resolve a spawner; creating one",
			{"ref": spawner_ref.describe()}
		)
		spawner = DotNetSpawner.new()
		spawner.name = "Spawner"
		add_child(spawner)

	spawner.setup(registry, config)
	spawner.spawned.connect(func(identity: DotNetIdentity) -> void:
		entity_spawned.emit(identity))
	spawner.despawned.connect(func(net_id: int) -> void:
		_forget_entity(net_id)
		entity_despawned.emit(net_id))


## Starts ticking.
func start() -> DotResult:
	if _running:
		return DotResult.success(self)

	if clock == null:
		var prepared := setup()
		if not prepared.ok:
			return prepared

	messages.seal()
	_running = true

	DotLog.info(
		CHANNEL, "started", {"schema": messages.schema_hash().substr(0, 12)}
	)

	# A client tells the server what it speaks as soon as it can speak at all. The server
	# is the end that decides whether the two can play, and it is told first so that a
	# refusal arrives before anything else the join would have sent.
	if not is_server:
		announce_schema(1)
	for peer_id in _peers:
		announce_schema(peer_id)

	return DotResult.success(self)


## Sends this end's message schema to a peer, through [member send_fn]. See [method DotNetMessageRegistry.schema_payload].
##
## Automatic in [method add_peer] and [method start], over RELIABLE; call again once a late reliable route exists. Adopting twice is harmless. Decoding never waits for the table (wire ids derive from names); only the REQUIRED-type check does.
func announce_schema(peer_id: int) -> bool:
	if not send_fn.is_valid() or messages == null:
		return false

	var payload := messages.schema_payload()
	send_fn.call(peer_id, payload, DotNetMessage.Delivery.RELIABLE)
	stats.note_sent(payload.size(), 1)
	return true


func _on_peer_refused(peer_id: int, error: DotError) -> void:
	DotLog.warn(CHANNEL, "peer cannot play with this schema", {
		"peer": peer_id, "why": error.message, "detail": error.detail,
	})
	peer_schema_refused.emit(peer_id, error)


func stop() -> void:
	_running = false
	_peers.clear()
	_input_buffers.clear()
	_acks.clear()
	_ack_wired.clear()
	_peer_added_tick.clear()
	_starved_ticks.clear()
	_last_inputs.clear()
	_snapshot_heard_tick = -1
	_last_snapshot_tick = 0
	_applied_snapshot_tick = 0
	_receiving_tick = -1
	_receiving_mask = 0
	_receiving_total = 0
	_seen_ticks.clear()
	_pending_reconcile.clear()

	if registry != null:
		registry.clear()
	if interpolator != null:
		interpolator.clear()
	if predictor != null:
		predictor.clear()
	if history != null:
		history.clear()

	DotLog.info(CHANNEL, "stopped")


func is_running() -> bool:
	return _running


## Registers a connected peer. Server side.
func add_peer(peer_id: int) -> void:
	if _peers.has(peer_id):
		return

	_peers.append(peer_id)
	_input_buffers[peer_id] = DotNetInput.Buffer.new(config.input_history_ticks)
	_acks[peer_id] = 0
	_ack_wired[peer_id] = false
	_peer_added_tick[peer_id] = _last_snapshot_tick
	_starved_ticks[peer_id] = 0

	DotLog.debug(CHANNEL, "peer added", {"peer": peer_id})

	if _running:
		announce_schema(peer_id)


## Ticks in [param seconds], or a number no silence reaches when it is 0 (never hold).
func _hold_ticks(seconds: float) -> int:
	if seconds <= 0.0:
		return 1 << 30
	return maxi(1, ceili(seconds * config.tick_rate))


## Removes a peer and everything it owned.
func remove_peer(peer_id: int) -> Array[DotNetIdentity]:
	_peers.erase(peer_id)
	_input_buffers.erase(peer_id)
	_acks.erase(peer_id)
	_ack_wired.erase(peer_id)
	_peer_added_tick.erase(peer_id)
	_starved_ticks.erase(peer_id)
	_last_inputs.erase(peer_id)

	if messages != null:
		messages.forget_peer(peer_id)

	budget.forget_peer(peer_id)
	interest.forget_peer(peer_id)
	if _native != null:
		_native.forget_peer(peer_id)

	# Every behaviour that ever replicated to this peer holds a record of what it was believed
	# to have; nothing else clears it, so a server churning players would leak one per behaviour.
	for identity in registry.all():
		for behaviour in identity.behaviours:
			behaviour.forget_peer(peer_id)

	var released := registry.take_owned_by(peer_id)

	DotLog.debug(
		CHANNEL, "peer removed", {"peer": peer_id, "entities": released.size()}
	)

	return released


func peers() -> Array[int]:
	return _peers.duplicate()


func input_buffer_for(peer_id: int) -> DotNetInput.Buffer:
	if not _input_buffers.has(peer_id):
		_input_buffers[peer_id] = DotNetInput.Buffer.new(config.input_history_ticks)
	return _input_buffers[peer_id]


func local_inputs() -> DotNetInput.Buffer:
	return _local_inputs


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or not _running or not auto_tick:
		return

	# Before step(), and unconditionally: the rolling rates have to close their
	# window even on a frame with no traffic, or a peer that stopped sending
	# keeps reporting the throughput it had when it stopped.
	if stats != null:
		stats.roll()

	step(delta)


## Advances by a frame's worth of time, running as many ticks as are due.
func step(delta: float) -> void:
	var ticks := clock.advance(delta)

	for _i in range(ticks):
		if is_server:
			server_tick(clock.tick)
		else:
			client_tick(clock.tick)

		ticked.emit(clock.tick)


## One authoritative tick: consume input, simulate, record history, maybe send.
func server_tick(tick: int) -> void:
	# The clock follows the tick it is driven at: a host that ticks this itself never advanced
	# the server's clock, and every joiner synced from tick 0 and had its commands discarded as late.
	if is_server:
		clock.tick = maxi(clock.tick, tick)

	var identities := registry.all()

	for peer_id in _peers:
		var buffer: DotNetInput.Buffer = _input_buffers[peer_id]
		var input := buffer.take(tick)

		if input == null:
			# The consumer repeats the last input, so a lost packet keeps the player moving;
			# past the hold it is given that input neutralised, so a blackout does not.
			buffer.note_starved()
			var starved: int = _starved_ticks.get(peer_id, 0) + 1
			_starved_ticks[peer_id] = starved
			if starved > _hold_ticks(config.starved_input_hold_sec) and _last_inputs.has(peer_id):
				_apply_input(peer_id, (_last_inputs[peer_id] as DotNetInput).neutralised(tick), tick)
			continue

		_starved_ticks[peer_id] = 0
		_last_inputs[peer_id] = input
		_apply_input(peer_id, input, tick)

	var step := clock.tick_duration()
	var started := Time.get_ticks_usec()
	_perf_server_ticks += 1

	# The list was taken before anything ran and a behaviour can change the world: a round
	# re-laying its map unregisters entities that this walk would then simulate and send
	# after clients were told they were gone (history.md 30).
	var changed := false
	for identity in identities:
		if registry.get_identity(identity.net_id) != identity:
			changed = true
			continue
		if not identity.can_simulate():
			continue
		for behaviour in identity.behaviours:
			behaviour._net_simulate(tick, step)

	for identity in identities:
		if changed:
			break
		changed = registry.get_identity(identity.net_id) != identity
	if changed:
		identities = _still_registered(identities)

	var period := config.ticks_per_snapshot()
	var simulated := Time.get_ticks_usec()
	_perf_server_sim_usec += simulated - started

	# Staggered: some peers every tick, each on its own phase. See
	# [member DotNetConfig.stagger_snapshots].
	if config.stagger_snapshots and period > 1:
		history.record(identities, tick)
		_send_snapshots(tick, identities, posmod(tick, period), period)
		_perf_server_send_usec += Time.get_ticks_usec() - simulated
		return

	_ticks_since_snapshot += 1

	if _ticks_since_snapshot >= period:
		_ticks_since_snapshot = 0
		history.record(identities, tick)
		_send_snapshots(tick, identities)
		_perf_server_send_usec += Time.get_ticks_usec() - simulated


## Those of [param identities] still registered as themselves. An entity registered during
## the tick is not added: it is in the next tick's list, as it always was.
func _still_registered(identities: Array[DotNetIdentity]) -> Array[DotNetIdentity]:
	var out: Array[DotNetIdentity] = []
	for identity in identities:
		if registry.get_identity(identity.net_id) == identity:
			out.append(identity)
	return out


## Hands an input to the entities a peer owns.
##
## Sanitised first, on the server, because everything in it came from a client.
func _apply_input(peer_id: int, input: DotNetInput, tick: int) -> void:
	input.sanitise(config.tick_rate)

	for identity in registry.owned_by(peer_id):
		for behaviour in identity.behaviours:
			if behaviour.has_method("_net_apply_input"):
				behaviour.call("_net_apply_input", input, tick)


## One client tick: sample input, predict, interpolate.
func client_tick(tick: int) -> void:
	if not clock.is_synced():
		# Predicting before the clock is aligned produces inputs stamped with ticks
		# the server has already passed, every one of which is discarded.
		return

	flush_reconcile()
	var started := Time.get_ticks_usec()
	predictor.predict(registry.predicted(), tick, clock.tick_duration())
	_perf_predict_usec += Time.get_ticks_usec() - started
	_perf_client_ticks += 1


## One predicted tick for a host that records its own command and simulates it: the snapshots read since the last tick are reconciled first ([method flush_reconcile]), then every predicted entity is handed [param input] and simulated for [param tick].
##
## Through the predictor, not around it: otherwise [member DotNetConfig.skip_matching_replays] has nothing to match and [method perf_counters] reports no predict time. (API 10.)
func predict_tick(tick: int, input: DotNetInput = null) -> void:
	if not clock.is_synced():
		return
	flush_reconcile()
	var started := Time.get_ticks_usec()
	# Neutralised in place: the buffered and sent input is this same object, so the server
	# and the replays see the held one too.
	if input != null and _snapshot_heard_tick >= 0 \
			and tick - _snapshot_heard_tick > _hold_ticks(config.prediction_hold_sec):
		input._neutralise()
		_held_ticks += 1
	# The buffered input is this same object, so its replays run on the rounded one too.
	if input != null and config.predict_wire_input:
		input.round_trip()
	predictor.predict(registry.predicted(), tick, clock.tick_duration(), input)
	_perf_predict_usec += Time.get_ticks_usec() - started
	_perf_client_ticks += 1


## Running totals of what a client spends on the network side of a frame, in wall-clock microseconds, for a readout or a benchmark to difference between two reads.
##
## [code]snapshot_usec[/code], [code]reconcile_usec[/code], [code]replayed_ticks[/code] (grows with latency), [code]predict_usec[/code], [code]client_ticks[/code].
func perf_counters() -> Dictionary:
	return {
		&"snapshots": _perf_snapshots,
		&"snapshot_usec": _perf_snapshot_usec,
		&"reconciles": _perf_reconciles,
		&"reconcile_usec": _perf_reconcile_usec,
		&"replayed_ticks": _perf_replayed_ticks,
		# Reconciles that found the prediction already right and replayed nothing
		# (DotNetConfig.skip_matching_replays); counted in `reconciles` too.
		&"skipped": predictor.skipped() if predictor != null else 0,
		&"client_ticks": _perf_client_ticks,
		&"predict_usec": _perf_predict_usec,
		# How far the prediction runs ahead of the newest snapshot: what each replay re-runs.
		&"lead_ticks": clock.input_tick() - clock.received_tick() if clock != null else 0,
		# Server side: ticks run, time simulating them (the game's tick runs inside a
		# behaviour's _net_simulate), and time recording history and sending snapshots.
		&"server_ticks": _perf_server_ticks,
		&"server_sim_usec": _perf_server_sim_usec,
		&"server_send_usec": _perf_server_send_usec,
	}


## Applies interpolation. Call from [method Node._process], not the tick loop.
##
## [param alpha] is how far this frame sits into the current tick; left negative it is [method DotNetClock.render_alpha], which needs the engine's physics rate equal to the tick rate. Interpolating on the tick would quantise remote motion to the tick rate. A suite that steps by hand passes 0.0.
func interpolate_frame(alpha: float = -1.0) -> void:
	if is_server or interpolator == null or not clock.is_synced():
		return

	flush_reconcile()

	if alpha < 0.0:
		alpha = clock.render_alpha()

	# The buffer follows its target at a bounded rate, on the frame's own time, so it
	# never moves the render time backwards. See DotNetInterpolator._target_snapshots.
	var now_usec := Time.get_ticks_usec()
	var elapsed := 0.0 if _last_frame_usec == 0 else float(now_usec - _last_frame_usec) / 1e6
	_last_frame_usec = now_usec
	interpolator.advance(minf(elapsed, 0.25))

	# The RECEIVE timeline, not the server's tick: the delay is counted back from the newest
	# snapshot held. Alpha is -1 to 2 because it carries a slip (see DotNetClock.render_alpha)
	# plus what re-anchoring moved that the drawing has not followed yet (receive_slip).
	var server_tick_now := float(clock.received_tick()) + clampf(alpha, -1.0, 2.0) \
		+ clock.receive_slip()

	for identity in registry.all():
		interpolator.apply(identity, server_tick_now)


## Applies a snapshot payload. Client side.
func receive_snapshot(payload: PackedByteArray) -> DotResult:
	var started := Time.get_ticks_usec()
	var result := _receive_snapshot(payload)
	if result.ok:
		_snapshot_heard_tick = clock.input_tick()
	_perf_snapshot_usec += Time.get_ticks_usec() - started
	_perf_snapshots += 1
	return result


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

	# In snapshots, not ticks: a gap of one period is no loss at all. Set every time,
	# because a client adopts the server's tick rate after it started.
	stats.snapshot_interval_ticks = config.ticks_per_snapshot()

	# Once per tick, not once per part: the second part of a snapshot is neither a repeat
	# nor a late arrival making up for a loss. See [member _seen_ticks].
	if not _seen_ticks.has(tick):
		_seen_ticks.append(tick)
		if _seen_ticks.size() > SEEN_TICKS_KEPT:
			_seen_ticks.pop_front()
		stats.note_snapshot(tick)

	if tick < _receiving_tick:
		# Older than one already read: superseded, so applying it would overwrite newer state,
		# and the clock is not fed from it (an old tick's arrival time reads as a sudden lead).
		# A late part of an older tick is dropped the same way; its tick is re-sent unacknowledged.
		return DotResult.success(_applied_snapshot_tick)

	if tick == _receiving_tick and _applied_snapshot_tick == tick:
		# Every part of this tick is in: anything more is a repeat. (A repeat of one part of
		# a tick still missing another is applied again, which writes the same values; it
		# cannot be told from the missing part until its trailer is read.)
		return DotResult.success(_applied_snapshot_tick)

	if tick > _receiving_tick:
		_receiving_tick = tick
		_receiving_mask = 0
		_receiving_total = 0
		# The first part of a tick to arrive is the snapshot's arrival, for timing. A
		# second part is the same send, a few microseconds later.
		interpolator.note_arrival()
		clock.sync_from_server(tick, stats.rtt_percentile(0.5))
		interpolator.note_lateness(tick, clock.received_tick())

	for _i in range(count):
		var net_id := reader.read_uint(DotNetRegistry.ID_BITS)
		var behaviour_count := reader.read_uint(6)

		if not reader.ok():
			stats.note_decode_failure()
			return DotResult.fail(DotError.CODE_PARSE, "Truncated snapshot entry.")

		var identity := registry.get_identity(net_id)

		if identity == null:
			# Either an entity we have not been told to spawn yet, or one already
			# despawned. Both are normal in flight; neither is recoverable here,
			# because skipping a variable-length body needs the declarations.
			if not registry.was_recently_removed(net_id):
				DotLog.debug(
					CHANNEL, "state for an unknown entity", {"net_id": net_id}
				)
			return DotResult.success(tick)

		var applied := _apply_entity(identity, tick, reader, behaviour_count)
		if not applied.ok:
			stats.note_decode_failure()
			return applied

	# Which part this was, and whether it lists unchanged entities. Only a split snapshot or one
	# with an unchanged list has anything after its entities (see [method _send_to_peer]).
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
		# What follows a tail's trailer is under a byte of padding, or the input lead: how
		# early this client's commands are reaching the server. See [method
		# DotNetClock.note_input_lead].
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

	_receiving_total = total
	_receiving_mask |= 1 << part

	# Only here, and not on any early return, and only once every part of the tick is in: an ack
	# means the whole snapshot was applied. The unknown-entity path abandons the rest of the
	# packet, and a tick with a part missing is never acknowledged, so the server re-sends it.
	if _receiving_mask == (1 << total) - 1:
		_applied_snapshot_tick = tick

	snapshot_applied.emit(tick)
	return DotResult.success(tick)


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


## Reconciles every predicted entity against the newest snapshot read for it since the last flush. Needed only with [member DotNetConfig.reconcile_once_per_frame]; [method client_tick] and [method interpolate_frame] call it.
func flush_reconcile() -> void:
	if _pending_reconcile.is_empty():
		return
	var waiting := _pending_reconcile
	_pending_reconcile = {}
	for net_id: int in waiting:
		var entry: Array = waiting[net_id]
		var identity: DotNetIdentity = entry[0]
		# Unregistered (or freed) since the snapshot: nothing left to correct.
		if not is_instance_valid(identity) or registry.get_identity(net_id) != identity:
			continue
		_reconcile(identity, int(entry[1]), entry[2])


func _forget_entity(net_id: int) -> void:
	_pending_reconcile.erase(net_id)
	if interpolator != null:
		interpolator.forget(net_id)
	if predictor != null:
		predictor.forget(net_id)
	if history != null:
		history.forget(net_id)


## Sends a message to a peer, or to everyone when [param peer_id] is 0.
func send(message: DotNetMessage, peer_id: int = 0) -> DotResult:
	if not send_fn.is_valid():
		return DotResult.fail(
			DotError.CODE_STATE, "No send function is set."
		)

	var writer := DotNetWriter.new()
	var encoded := messages.encode(message, writer)

	if not encoded.ok:
		return encoded

	var payload := writer.to_bytes()
	send_fn.call(peer_id, payload, messages.delivery_of(message.type_name()))
	stats.note_sent(payload.size(), 1)

	return DotResult.success(payload.size())


## Decodes and dispatches an incoming message payload.
##
## Rate-limited per peer on the server: every client message costs work.
func receive(payload: PackedByteArray, from_peer_id: int) -> DotResult:
	stats.note_received(payload.size())

	if is_server:
		if payload.size() > config.max_client_payload:
			stats.note_decode_failure()
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Payload from a client is too large.",
				"%d bytes from peer %d" % [payload.size(), from_peer_id]
			)

		if not _message_limiter.allow(from_peer_id):
			stats.note_rate_limited()
			return DotResult.fail(
				DotError.CODE_RATE_LIMITED,
				"Peer is sending too fast.",
				"peer %d" % from_peer_id
			)

	var reader := DotNetReader.new(payload)
	var decoded := messages.decode(reader, from_peer_id, is_server)

	if not decoded.ok:
		if decoded.code() == DotError.CODE_FORBIDDEN:
			stats.note_direction_violation()
		elif decoded.code() != DotError.CODE_VERSION:
			# A refused schema is not a decode failure: it decoded, and said the two ends
			# cannot play. It is reported through `peer_schema_refused`, not as noise.
			stats.note_decode_failure()
		return decoded

	# Null is a message there is nothing to hand a game: a peer's schema table, a type this
	# end does not have, or anything from a peer whose schema was refused. Not an error --
	# a peer one build ahead sends exactly this, and must be able to.
	if decoded.value == null:
		return DotResult.success(false)

	messages.dispatch(decoded.value)
	return DotResult.success(true)


func describe() -> Dictionary:
	var d := {
		"role": "server" if is_server else "client",
		"running": _running,
		"peers": _peers.size(),
		"entities": registry.count() if registry != null else 0,
		"clock": clock.describe() if clock != null else {},
		"stats": stats.describe() if stats != null else {},
		"interest": interest.describe() if interest != null else {},
	}

	if not is_server:
		d["held_ticks"] = _held_ticks

	if is_server:
		d["snapshots_split"] = snapshots_split
		d["largest_part_bytes"] = largest_part_bytes
		d["mtu"] = config.mtu if config != null else 0
		d["unchanged_listed"] = unchanged_listed
		d["unchanged_bytes_saved"] = unchanged_bytes_saved
		d["input_leads_sent"] = input_leads_sent
		d["snapshot_threads"] = {
			"configured": config.snapshot_workers if config != null else 0,
			"why_inline": _snapshot_threads_reason,
			"pooled": _snapshot_pooled,
			"last_peers": _snapshot_pooled_peers,
			"last_tasks": _snapshot_pooled_workers,
			"last_join_usec": _snapshot_join_usec,
			"mean_prep_usec": _snapshot_prep_usec_total / maxi(1, _snapshot_pooled),
			"mean_join_usec": _snapshot_join_usec_total / maxi(1, _snapshot_pooled),
			"mean_apply_usec": _snapshot_apply_usec_total / maxi(1, _snapshot_pooled),
		}

	if interpolator != null:
		d["interpolation"] = interpolator.describe()
	if predictor != null:
		d["prediction"] = predictor.describe()
		if config != null and config.reconcile_once_per_frame:
			d["prediction"]["coalesced"] = _reconciles_coalesced
	if history != null:
		d["lag_compensation"] = history.describe()

	return d


## Lines for a `net_status` console command.
func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("role       %s" % ("server" if is_server else "client"))
	out.append("entities   %d" % (registry.count() if registry != null else 0))

	if clock != null:
		out.append("tick       %d (%s)" % [
			clock.tick, "synced" if clock.is_synced() else "SYNCING"
		])
		out.append("rtt        %d ms, jitter %d ms" % [
			int(clock.rtt_ms()), int(clock.jitter_ms())
		])
		if not is_server:
			out.append("lead       %s" % clock.describe_lead())

	if is_server and config != null:
		out.append("snapshots  %d split, largest part %d B of %d" % [
			snapshots_split, largest_part_bytes, config.mtu
		])
		out.append("unchanged  %d listed, %d B of headers saved" % [
			unchanged_listed, unchanged_bytes_saved
		])
		out.append("leads      %d sent to clients" % input_leads_sent)
		if _native_note != "":
			out.append("native     %s" % _native_note)
		if config.snapshot_workers != 0:
			var n := maxi(1, _snapshot_pooled)
			out.append("threads    %d asked, %d snapshots pooled%s; last %d peers in %d tasks; mean us: prep %d, join %d, apply %d" % [
				config.snapshot_workers, _snapshot_pooled,
				(", inline: " + _snapshot_threads_reason) if _snapshot_threads_reason != "" else "",
				_snapshot_pooled_peers, _snapshot_pooled_workers,
				_snapshot_prep_usec_total / n, _snapshot_join_usec_total / n, _snapshot_apply_usec_total / n,
			])
			for line in DotParallel.describe_lines():
				out.append("  " + line)

	if stats != null:
		out.append("")
		out.append_array(stats.describe_lines())

	if interpolator != null:
		out.append("")
		out.append("interpolation:")
		var interp := interpolator.describe()
		for key in interp:
			out.append("  %-18s %s" % [str(key), str(interp[key])])

	if predictor != null:
		out.append("")
		out.append("prediction:")
		var pred := predictor.describe()
		for key in pred:
			out.append("  %-18s %s" % [str(key), str(pred[key])])

	if budget != null and is_server:
		out.append("")
		out.append_array(budget.describe_lines())

	return out

