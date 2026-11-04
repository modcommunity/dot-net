extends "netcode_sections_8.gd"

## Sections of netcode_demo.gd, moved unchanged; part 9 of 9.


## Three managers over a lossless pipe and the entities they share, for [method _test_unchanged_entities].
class QuietRig extends RefCounted:
	var host: DotNetManager
	var fresh: DotNetManager
	var legacy: DotNetManager
	var exclude: ExcludeInterest
	var sent := {2: [], 3: []}
	var on_server: Array = []
	var on_fresh: Array = []
	var on_legacy: Array = []

	func deliver(tick: int) -> void:
		host.server_tick(tick)
		for payload: PackedByteArray in sent[2]:
			var _r := fresh.receive_snapshot(payload)
		for payload: PackedByteArray in sent[3]:
			var _r := legacy.receive_snapshot(payload)
		var _a := host.receive_ack_payload(2, fresh.encode_ack())
		var _b := host.receive_ack_payload(3, legacy.encode_ack())

	func sizes(peer: int) -> int:
		var n := 0
		for payload: PackedByteArray in sent[peer]:
			n += payload.size()
		return n

	func all_at(list: Array, tick: int) -> int:
		var n := 0
		for c in list:
			if c.last_applied == tick:
				n += 1
		return n

	func clear_sent() -> void:
		sent[2].clear()
		sent[3].clear()


func _unchanged_rig(entities: int) -> QuietRig:
	var rig := QuietRig.new()
	rig.host = _parts_manager("QuietServer", true, 1200)
	rig.fresh = _parts_manager("QuietClient", false, 1200)
	rig.legacy = _parts_manager("QuietLegacy", false, 1200)
	var host := rig.host
	var fresh := rig.fresh
	var legacy := rig.legacy
	legacy.local_peer_id = 3
	# A client from before the lists: it announces no features, as its table had none.
	legacy.messages.features = 0
	rig.exclude = ExcludeInterest.new()
	host.interest = rig.exclude
	var sent := rig.sent
	host.send_fn = func(peer_id: int, payload: PackedByteArray, d: int) -> void:
		var to: DotNetManager = fresh if peer_id == 2 else legacy
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var _schema := to.receive(payload, 1)
			return
		(sent[peer_id] as Array).append(payload)
	fresh.send_fn = func(_peer: int, payload: PackedByteArray, d: int) -> void:
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var _adopted := host.receive(payload, 2)
	legacy.send_fn = func(_peer: int, payload: PackedByteArray, d: int) -> void:
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var _adopted := host.receive(payload, 3)
	host.start()
	fresh.start()
	legacy.start()
	host.add_peer(2)
	host.add_peer(3)
	for m in [host, fresh, legacy]:
		(m as DotNetManager).spawner.register_factory(&"counted", _build_counted)
	_check("the new client says it reads unchanged lists, the old one does not",
		host.messages.peer_supports(2, DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS)
			and not host.messages.peer_supports(3, DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS))
	for i in entities:
		# Owned by nobody here, so both clients interpolate them.
		var spawned: DotNetIdentity = host.spawner.spawn(&"counted", 9, Transform3D.IDENTITY, 0).value
		# Out of view means out at once, not after the boundary's grace period.
		spawned.interest_linger_sec = 0.0
		var _f := fresh.spawner.spawn_remote(&"counted", spawned.net_id, 9, Transform3D.IDENTITY, 0)
		var _l := legacy.spawner.spawn_remote(&"counted", spawned.net_id, 9, Transform3D.IDENTITY, 0)
		rig.on_server.append(spawned.behaviours[0])
		rig.on_fresh.append(fresh.registry.get_identity(spawned.net_id).behaviours[0])
		rig.on_legacy.append(legacy.registry.get_identity(spawned.net_id).behaviours[0])
	return rig


## [b]An entity with nothing to say is listed, not written.[/b] A client announcing
## [constant DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS] gets runs of ids in the part's tail,
## applied exactly as an empty body. Armed with each fix reverted in turn (send, receive, early return).
func _test_unchanged_entities() -> void:
	print("")
	print("[unchanged entities]")
	var rig := _unchanged_rig(30)
	_unchanged_savings(rig)
	_unchanged_relevance(rig)
	_unchanged_codec(rig)
	rig.host.stop()
	rig.fresh.stop()
	rig.legacy.stop()
	for m in [rig.host, rig.fresh, rig.legacy]:
		remove_child(m)
		(m as DotNetManager).free()


func _unchanged_savings(rig: QuietRig) -> void:
	var on_server := rig.on_server
	var on_fresh := rig.on_fresh
	var on_legacy := rig.on_legacy
	var fresh := rig.fresh
	var legacy := rig.legacy
	var sent := rig.sent
	const ENTITIES := 30
	# Everything once, then only entity 0 moves.
	for i in ENTITIES:
		on_server[i].position = Vector3(1.0 + i, 0, 0)
	rig.deliver(3)
	sent[2].clear()
	sent[3].clear()
	on_server[0].position = Vector3(50, 0, 0)
	rig.deliver(6)

	var compact_bytes: int = rig.sizes(2)
	var legacy_bytes: int = rig.sizes(3)
	# 29 entities of 36 bits is 130 bytes of headers; the list of them is a few bits.
	_check("29 unchanged entities cost a few bits, not 130 B (%d B, old format %d B)"
			% [compact_bytes, legacy_bytes],
		compact_bytes + 120 <= legacy_bytes)
	_check("and only the moving entity is written (%d)" % _part_count(sent[2][0]),
		sent[2].size() == 1 and _part_count(sent[2][0]) == 1)
	_check("every entity's per-snapshot hook fired at the new tick (%d of %d)"
			% [rig.all_at(on_fresh, 6), ENTITIES],
		rig.all_at(on_fresh, 6) == ENTITIES)
	_check("as it does on the old format (%d of %d)" % [rig.all_at(on_legacy, 6), ENTITIES],
		rig.all_at(on_legacy, 6) == ENTITIES)
	var tracked := 0
	for i in ENTITIES:
		var track: Variant = fresh.interpolator._tracks.get(on_fresh[i].identity.net_id)
		if track != null and int(track.newest_tick()) == 6:
			tracked += 1
	_check("the interpolator holds a sample at that tick for each (%d)" % tracked, tracked == ENTITIES)
	_check("and both acknowledge it (%d, %d)" % [fresh.ack_tick(), legacy.ack_tick()],
		fresh.ack_tick() == 6 and legacy.ack_tick() == 6)


func _unchanged_relevance(rig: QuietRig) -> void:
	var on_server := rig.on_server
	var on_fresh := rig.on_fresh
	var on_legacy := rig.on_legacy
	var fresh := rig.fresh
	var legacy := rig.legacy
	var host := rig.host
	var sent := rig.sent
	const ENTITIES := 30
	# Out of view: neither written nor listed, so it hears nothing, on either format.
	rig.exclude.excluded[on_server[5].identity.net_id] = true
	sent[2].clear()
	sent[3].clear()
	rig.deliver(9)
	_check("an entity that left relevance is not listed (last %d, others %d of %d)"
			% [on_fresh[5].last_applied, rig.all_at(on_fresh, 9), ENTITIES - 1],
		on_fresh[5].last_applied == 6 and rig.all_at(on_fresh, 9) == ENTITIES - 1
			and on_legacy[5].last_applied == 6)

	# Nothing relevant at all: a snapshot still goes, for the clock and the acknowledgement.
	for c in on_server:
		rig.exclude.excluded[c.identity.net_id] = true
	sent[2].clear()
	sent[3].clear()
	rig.deliver(12)
	_check("with nothing relevant a header-only snapshot is still sent (%d B, %d B)"
			% [rig.sizes(2), rig.sizes(3)],
		sent[2].size() == 1 and sent[3].size() == 1 and _part_count(sent[2][0]) == 0
			and (sent[2][0] as PackedByteArray).size() == 6 and (sent[3][0] as PackedByteArray).size() == 6)
	_check("and it feeds the clock and is acknowledged (%d, %d)" % [fresh.ack_tick(), legacy.ack_tick()],
		fresh.ack_tick() == 12 and legacy.ack_tick() == 12 and fresh.clock.received_tick() >= 12)
	rig.exclude.excluded.clear()

	# Over the MTU with a list: every part applies and the tick is acknowledged.
	host.config.mtu = 96
	for i in range(0, ENTITIES, 3):
		on_server[i].position = Vector3(500.0 + i, 0, 0)
	sent[2].clear()
	sent[3].clear()
	var failures := fresh.stats.decode_failures
	rig.deliver(15)
	_check("split with a list: %d parts, all applied, tick acknowledged (%d)" % [sent[2].size(), fresh.ack_tick()],
		sent[2].size() > 1 and fresh.ack_tick() == 15 and rig.all_at(on_fresh, 15) == ENTITIES
			and fresh.stats.decode_failures == failures)
	host.config.mtu = 1200

	# An old client handed a tail by mistake refuses it as a bad part trailer, not a misread.
	var mark := DotNetManager.UNCHANGED_TAIL_MARK
	_check("the tail's mark reads to an old client as an impossible trailer",
		(mark & 0xF) >= (mark >> 4) + 1)


func _unchanged_codec(rig: QuietRig) -> void:
	var on_fresh := rig.on_fresh
	var fresh := rig.fresh
	# The run codec, against sets a contiguous block, a scatter and a mix.
	var codec_ok := true
	var sets := [[1, 2, 3, 4, 5], [7, 100, 4000, 16000000], [3, 4, 9, 10, 11, 12, 40], [1]]
	for ids_set: Array in sets:
		var ids := PackedInt32Array(ids_set)
		var runs := DotNetManager._unchanged_runs(ids)
		var w := DotNetWriter.new()
		DotNetManager._write_unchanged_tail(w, runs)
		var r := w.to_reader()
		var got: Array = []
		var _m := r.read_uint(8)
		var count := DotNetManager._read_gamma(r)
		var cursor := 0
		for _k in count:
			var first := cursor + DotNetManager._read_gamma(r)
			var length := DotNetManager._read_gamma(r) + 1
			for id in range(first, first + length):
				got.append(id)
			cursor = first + length
		if got != ids_set or w.bit_length() + DotNetManager.SNAPSHOT_PART_TRAILER_BITS \
				!= DotNetManager._unchanged_tail_bits(runs):
			codec_ok = false
	_check("unchanged runs round-trip, and their size is known before writing", codec_ok)

	# A truncated list changes nothing and is a decode failure.
	var bad := DotNetWriter.new()
	bad.write_uint(20, 32)
	bad.write_uint(0, 12)
	bad.write_uint(DotNetManager.UNCHANGED_TAIL_MARK, 8)
	DotNetManager._write_gamma(bad, 1)
	DotNetManager._write_gamma(bad, on_fresh[0].identity.net_id)
	bad.write_bits(0, 12)
	var before: Variant = on_fresh[0].applied
	var refused := fresh.receive_snapshot(bad.to_bytes())
	_check("a truncated list is refused and applies nothing",
		not refused.ok and on_fresh[0].applied == before)


## [method DotNetVar.server_driven]: a property only the server writes never counts as a misprediction,
## and a skipped replay still leaves the server's value in it. Both guests skip matching replays; the
## server bumps [code]health[/code] every 8 ticks, and only guest 1 declares it server-driven.
func _test_server_driven_vars() -> void:
	print("")
	print("[server-driven vars]")
	const TICKS := 64
	const LEAD := 4
	var host := _bare_manager(true, 1)
	host.name = "DrivenServer"
	host.service_scope = &"driven_server"
	host.config.tick_rate = 60
	host.config.snapshot_rate = 60
	add_child(host)
	var guests := _skip_guests(LEAD, 2)
	guests[0].config.skip_matching_replays = true
	var _a := host.setup()
	var wire: Array[PackedByteArray] = []
	host.send_fn = func(_peer: int, payload: PackedByteArray, d: int) -> void:
		if d == DotNetMessage.Delivery.UNRELIABLE:
			wire.append(payload)
	var _c := host.start()
	host.add_peer(2)
	host.spawner.register_factory(&"player", _build_player)
	var on_server: DotNetIdentity = host.spawner.spawn(&"player", 2, Transform3D.IDENTITY, 0).value
	var served := on_server.behaviours[0] as Movement
	var moving := _skip_mirrors(guests, on_server, false)
	for declaration in moving[1].net_vars:
		if declaration.property == &"health":
			var _d := declaration.server_driven()
	var stale := 0
	for s in range(1, TICKS + 1):
		var c := s + LEAD
		var move := Vector2(1.0, 0.0) if (s / 8) % 2 == 0 else Vector2(0.0, 1.0)
		for g in range(guests.size()):
			var input := DemoInput.new()
			input.tick = c
			input.delta = 1.0 / 60.0
			input.move = move
			guests[g].local_inputs().push(input)
			moving[g]._net_apply_input(input, c)
			guests[g].predictor.predict(guests[g].registry.predicted(), c, 1.0 / 60.0)
		var copy := DemoInput.new()
		copy.tick = c
		copy.delta = 1.0 / 60.0
		copy.move = move
		host.input_buffer_for(2).push(copy)
		if s % 8 == 0:
			served.health -= 1
		host.server_tick(s)
		for payload in wire:
			for guest in guests:
				guest.clock.tick = c
				var _r := guest.receive_snapshot(payload)
				guest.flush_reconcile()
				var _ack := host.receive_ack_payload(2, guest.encode_ack())
		wire.clear()
		if moving[1].health != served.health:
			stale += 1
	var control: Dictionary = guests[0].predictor.describe()
	var marked: Dictionary = guests[1].predictor.describe()
	_check("a predicted server-only value mismatches every bump (%s)" % [control["mismatches"]],
		int((control["mismatches"] as Dictionary).get(&"health", 0)) >= TICKS / 8 - 1)
	_check("a server-driven value is never a mismatch (%s)" % [marked["mismatches"]],
		not (marked["mismatches"] as Dictionary).has(&"health"))
	_check("so its replays are skipped (%d skipped, %d replays; control %d, %d)" % [int(marked["skipped"]), int(marked["replays"]), int(control["skipped"]), int(control["replays"])],
		int(marked["skipped"]) > int(control["skipped"]) and int(marked["replays"]) < int(control["replays"]))
	_check("and the client holds the server's value after every snapshot (%d ticks stale)" % stale, stale == 0)
	_check("the predicted position agrees with the replaying guest (%.4f m apart)" % moving[1].position.distance_to(moving[0].position),
		moving[1].position.distance_to(moving[0].position) < 0.01)
	_free_managers([host] + guests)


## A [Movement] that counts how often each tick is simulated.
class CountedMovement extends Movement:
	var runs: Dictionary = {}

	func _net_simulate(tick: int, delta: float) -> void:
		runs[tick] = int(runs.get(tick, 0)) + 1
		super(tick, delta)


## [b]A reconcile replays only ticks already predicted.[/b] A client that advances its clock and records the tick's input before [method DotNetManager.predict_tick] has a snapshot waiting at that point; the replay must stop at the last tick predicted, or it plays the new one and predict_tick plays it again.
func _test_replay_bound() -> void:
	print("")
	print("[replay stops at the last predicted tick]")
	var straight := _bound_run(&"none")
	for order: StringName in [&"flush first", &"advance first", &"on receipt"]:
		var run := _bound_run(order)
		_check("%s: no tick played twice before it was predicted (%d)" % [order, int(run["twice"])],
			int(run["twice"]) == 0 and int(run["replays"]) > 0)
		var apart := (run["position"] as Vector3).distance_to(straight["position"])
		_check("%s: and lands where no snapshot does (%.4f m)" % [order, apart], apart < 0.0001)


## Predicts 60 ticks, some frames two at a time, with a snapshot of a tick predicted three before read every third frame. [param order] is where the clock moves relative to the reconcile.
func _bound_run(order: StringName) -> Dictionary:
	var c := DotNetManager.new()
	c.is_server = false
	c.local_peer_id = 5
	c.auto_tick = false
	c.config_file = ""
	c.service_scope = StringName("bound_%s" % order)
	c.config = DotNetConfig.new()
	c.config.reconcile_once_per_frame = order != &"on receipt"
	add_child(c)
	var _up := c.setup()
	c.clock.sync_from_server(0, 0.0)
	var body := Node3D.new()
	var identity := DotNetIdentity.new()
	identity.owner_peer_id = 5
	identity.authority = DotNetIdentity.Authority.SHARED
	body.add_child(identity)
	var mover := CountedMovement.new()
	body.add_child(mover)
	identity.entity = body
	identity.behaviours = [mover]
	mover.identity = identity
	mover._bind(c.config)
	add_child(body)
	var _reg := c.registry.register(identity, 40, 0, c.config)
	var replays_before := int(c.predictor.describe()["replays"])
	var states := {}
	var twice := 0
	var t := 0
	for frame in range(40):
		var ticks := 2 if frame % 4 == 3 else 1
		var snapshot := []
		if order != &"none" and frame % 3 == 2 and states.has(t - 3):
			var s := t - 3
			snapshot = [identity, s, {&"position": states[s][0], &"velocity": states[s][1]}]
		if order == &"flush first":
			if not snapshot.is_empty():
				c._pending_reconcile[40] = snapshot
			c.flush_reconcile()
		c.clock.tick = t + ticks
		if not snapshot.is_empty() and order == &"advance first":
			c._pending_reconcile[40] = snapshot
		if not snapshot.is_empty() and order == &"on receipt":
			c._reconcile(identity, int(snapshot[1]), snapshot[2])
		for i in range(ticks):
			var tick := c.clock.tick - (ticks - 1 - i)
			var input := DemoInput.new()
			input.tick = tick
			input.delta = 1.0 / 60.0
			input.move = Vector2(1.0, 0.0) if (tick / 6) % 2 == 0 else Vector2(0.0, 1.0)
			var _pushed := c.local_inputs().push(input)
			c.predict_tick(tick, input)
			if int(mover.runs.get(tick, 0)) != 1:
				twice += 1
			states[tick] = [mover.position, mover.velocity]
		t += ticks
	var out := {"twice": twice, "position": mover.position,
		"replays": int(c.predictor.describe()["replays"]) - replays_before}
	remove_child(body)
	body.free()
	_free_managers([c])
	return out


## [b]A tick the clock jumped over is predicted on the previous command.[/b] The server ran it on that command, and a snapshot describing a tick the client never remembered predicting replays the lead.
func _test_skipped_ticks() -> void:
	print("")
	print("[ticks a clock jump stepped over are predicted]")
	var filled := _skip_run(8, false)
	_check("no snapshot found a tick unpredicted (%s)" % [filled["mismatches"]],
		not (filled["mismatches"] as Dictionary).has(&"(no prediction)"))
	_check("every snapshot skipped its replay (%d skipped, %d replays, %d ticks filled)" % [filled["skipped"], filled["replays"], filled["filled"]],
		int(filled["replays"]) == 0 and int(filled["skipped"]) > 10 and int(filled["filled"]) > 0)
	_check("no tick simulated twice or never (%s)" % [filled["bad"]], (filled["bad"] as Array).is_empty())
	_check("and it lands on the server's state (%.5f m)" % float(filled["apart"]), float(filled["apart"]) < 0.0001)
	var off := _skip_run(0, false)
	_check("with the fill off, a snapshot of a skipped tick finds no prediction (%s)" % [off["mismatches"]],
		int((off["mismatches"] as Dictionary).get(&"(no prediction)", 0)) > 0 and int(off["replays"]) > 0)
	var own := _skip_run(8, true)
	_check("a game filling the gap itself is not filled again (%d filled, %s)" % [own["filled"], own["bad"]],
		int(own["filled"]) == 0 and (own["bad"] as Array).is_empty() and int(own["replays"]) == 0)
	var long := _skip_run(2, false)
	_check("a jump past predict_fill_ticks is left to the replay (%d filled, %d replays)" % [long["filled"], long["replays"]],
		int(long["filled"]) > 0 and int(long["replays"]) > 0)


## A client that predicts only the tick its clock lands on, jumping 3 or 4 ticks every fifth frame, against a server that runs every tick and keeps the previous command through a hole; a snapshot six ticks old is read every frame. [param own_fill] predicts the skipped ticks itself first, as a game working round the hole does.
func _skip_run(fill: int, own_fill: bool) -> Dictionary:
	var c := DotNetManager.new()
	c.is_server = false
	c.local_peer_id = 5
	c.auto_tick = false
	c.config_file = ""
	c.service_scope = StringName("skip_%d_%s" % [fill, own_fill])
	c.config = DotNetConfig.new()
	c.config.reconcile_once_per_frame = true
	c.config.skip_matching_replays = true
	c.config.predict_fill_ticks = fill
	add_child(c)
	var _up := c.setup()
	c.clock.sync_from_server(0, 0.0)
	var body := Node3D.new()
	var identity := DotNetIdentity.new()
	identity.owner_peer_id = 5
	identity.authority = DotNetIdentity.Authority.SHARED
	body.add_child(identity)
	var mover := CountedMovement.new()
	body.add_child(mover)
	identity.entity = body
	identity.behaviours = [mover]
	mover.identity = identity
	mover._bind(c.config)
	add_child(body)
	var _reg := c.registry.register(identity, 40, 0, c.config)
	var server := Movement.new()
	var states := {}
	var t := 0
	var last: DemoInput = null
	for frame in range(60):
		var ticks := (3 + frame % 2) if frame % 5 == 4 else 1
		if states.has(t - 6):
			c._pending_reconcile[40] = [identity, t - 6, {&"position": states[t - 6][0], &"velocity": states[t - 6][1]}]
		var tick := t + ticks
		c.clock.tick = tick
		var input := DemoInput.new()
		input.tick = tick
		input.delta = 1.0 / 60.0
		input.move = Vector2(1.0, 0.0) if (tick / 7) % 2 == 0 else Vector2(0.0, 1.0)
		var _pushed := c.local_inputs().push(input)
		if own_fill and last != null:
			for s in range(t + 1, tick):
				c.predict_tick(s, last)
		c.predict_tick(tick, input)
		var step := c.clock.tick_duration()
		for s in range(t + 1, tick + 1):
			if s == tick:
				server._net_apply_input(input, s)
			server._net_simulate(s, step)
			states[s] = [server.position, server.velocity]
		last = input
		t = tick
	var bad := []
	for s in range(1, t + 1):
		if int(mover.runs.get(s, 0)) != 1:
			bad.append("%d:%d" % [s, int(mover.runs.get(s, 0))])
	var described: Dictionary = c.predictor.describe()
	var out := {"bad": bad, "apart": mover.position.distance_to(server.position),
		"replays": int(described["replays"]), "skipped": int(described["skipped"]),
		"filled": int(described["filled"]), "mismatches": described["mismatches"]}
	server.free()
	remove_child(body)
	body.free()
	_free_managers([c])
	return out
