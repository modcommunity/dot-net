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


## [member DotNetConfig.skip_idle_snapshots]: a server with nobody to send to prepares no snapshot, still
## reports one a snapshot tick, and a peer that joins afterwards is sent the world as before.
func _test_idle_snapshots() -> void:
	_sections_entered += 1
	print("")
	print("[idle snapshots]")
	var prepared := {}
	var reported := {}
	var joined_sends := {}
	for skip in [false, true]:
		var host := DotNetManager.new()
		host.name = "IdleHost%s" % ("Skip" if skip else "Build")
		host.is_server = true
		host.service_scope = &"idle_snapshots"
		host.local_peer_id = 1
		host.auto_tick = false
		host.config_file = ""
		host.config = DotNetConfig.new()
		host.config.tick_rate = 60
		host.config.snapshot_rate = 60
		host.config.skip_idle_snapshots = skip
		add_child(host)
		var _ready_now := host.setup()
		var sends := [0]
		host.send_fn = func(_peer_id: int, _payload: PackedByteArray, d: int) -> void:
			if d == DotNetMessage.Delivery.UNRELIABLE:
				sends[0] += 1
		var told := [0]
		host.snapshot_sent.connect(func(_tick: int, _peers: int) -> void: told[0] += 1)
		host.start()
		host.spawner.register_factory(&"player", _build_player)
		var _spawned := host.spawner.spawn(&"player", 0, Transform3D.IDENTITY, 0)
		for t in range(1, 9):
			host.server_tick(t)
		prepared[skip] = int(host.perf_counters()[&"snap_snapshots"])
		reported[skip] = told[0]
		host.add_peer(2)
		for t in range(9, 13):
			host.server_tick(t)
		joined_sends[skip] = sends[0]
		host.stop()
		remove_child(host)
		host.free()
	_check("with no peer, building prepares every snapshot (%d of 8)" % prepared[false], prepared[false] == 8)
	_check("and skipping prepares none (%d)" % prepared[true], prepared[true] == 0)
	_check("both still report a snapshot a tick (%d, %d)" % [reported[false], reported[true]], reported[false] == 8 and reported[true] == 8)
	_check("a peer joining later is sent snapshots either way (%d, %d)" % [joined_sends[false], joined_sends[true]], joined_sends[false] > 0 and joined_sends[true] == joined_sends[false])
	_sections_completed += 1


## A client clock and a server's input buffer at [param rate] Hz, 55 ms each way, [param loss] of
## the packets lost both ways, every packet carrying the last four commands. [param batched] hands
## a packet to [code]push_batch[/code], else each command to [code]push[/code]. Seeded, no real time.
func _lossy_lead_run(rate: int, loss: float, batched: bool, seconds: float, seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var clock := DotNetClock.new(rate)
	clock.follow_engine_time = false
	var buffer := DotNetInput.Buffer.new(120)
	var frame_ms := 1000.0 / float(rate)
	var one_way := 55.0
	var up: Array = []
	var down: Array = []
	var sent: Array[DotNetInput] = []
	var out := {"holes": 0, "starved": 0, "lead_min": 1 << 30, "lead_max": -(1 << 30), "late_reports": 0}
	var last_stamped := -1
	var settle := int(2.0 * float(rate))
	for frame in int(seconds * float(rate)):
		var now := float(frame) * frame_ms
		var server_at := 1000 + frame
		# The link is clean while the clock settles, so what is counted after is the loss's.
		var lossy := frame >= settle

		while not up.is_empty() and float(up[0][0]) <= now:
			var packet: Array = up.pop_front()[1]
			if batched:
				var _b := buffer.push_batch(packet)
			else:
				for i in packet.size():
					var command := packet[i] as DotNetInput
					if i != packet.size() - 1 and command.tick <= buffer.last_consumed_tick():
						continue
					var _p := buffer.push(command)
		if buffer.take(server_at) == null and lossy:
			out["starved"] = int(out["starved"]) + 1
		var sample := buffer.take_lead_sample()
		if not lossy or rng.randf() >= loss:
			down.append([now + one_way, server_at, sample])

		while not down.is_empty() and float(down[0][0]) <= now:
			var snapshot: Array = down.pop_front()
			clock.sync_from_server(int(snapshot[1]), 2.0 * one_way)
			var report: Vector2i = snapshot[2]
			if report.x != DotNetInput.Buffer.LEAD_NONE:
				clock.note_input_lead(report.y, report.x)
		var ticks := clock.advance(1.0 / float(rate))
		for i in ticks:
			var input := DemoInput.new()
			input.tick = clock.tick - (ticks - 1 - i)
			if lossy and last_stamped >= 0 and input.tick > last_stamped + 1:
				out["holes"] = int(out["holes"]) + input.tick - last_stamped - 1
			last_stamped = input.tick
			sent.append(input)
		if ticks > 0 and (not lossy or rng.randf() >= loss):
			up.append([now + one_way, sent.slice(maxi(0, sent.size() - 4))])
		if lossy:
			out["lead_min"] = mini(int(out["lead_min"]), clock.tick - server_at)
			out["lead_max"] = maxi(int(out["lead_max"]), clock.tick - server_at)
	out["catch_ups"] = int(clock.describe()["catch_ups"])
	out["late_reports"] = int(clock.describe()["late_reports"])
	return out


## game-fatal-contact's headless_lossy at 22 and 33 Hz: at 20% loss the input tick jumped 2 to 4 ticks
## several times a window. A command whose packet was lost arrives with a later packet, late by
## the loss; measured, the clock read that as a stall. Armed: the per-command control still jumps.
func _test_lossy_lead() -> void:
	_sections_entered += 1
	print("")
	print("[the input lead under packet loss]")

	# The measurement itself: three packets' worth arriving in the third, two ticks before use.
	var measured := DotNetInput.Buffer.new(16)
	var each := DotNetInput.Buffer.new(16)
	var packet: Array = []
	for tick in [10, 11, 12]:
		var command := DemoInput.new()
		command.tick = tick
		packet.append(command)
	for buffer: DotNetInput.Buffer in [measured, each]:
		var first := DemoInput.new()
		first.tick = 8
		var _f := buffer.push(first)
		var _t8 := buffer.take(8)
		var _t9 := buffer.take(9)
		var _s := buffer.take_lead_sample()
	var batch_result := measured.push_batch(packet)
	for command: DotNetInput in packet:
		var _e := each.push(command)
	var batch_sample := measured.take_lead_sample()
	var each_sample := each.take_lead_sample()
	_check("a packet's lead is measured on its newest command, not on the resent ones (%s, each on its own %s)"
			% [batch_sample, each_sample],
		batch_result.ok and batch_sample == Vector2i(2, 12) and each_sample == Vector2i(0, 10)
			and measured.size() == 3)
	var stale: Array = []
	for tick in [8, 9, 10]:
		var command := DemoInput.new()
		command.tick = tick
		stale.append(command)
	var _t10 := measured.take(10)
	var late_before := measured.late_count
	var stale_result := measured.push_batch(stale)
	_check("resent copies of simulated ticks are skipped, the packet's own late command is counted (%d late)"
			% (measured.late_count - late_before),
		not stale_result.ok and measured.late_count - late_before == 1)

	# Six seeded half-minutes a rate. The price of not chasing the loss is in the last check: a
	# command lost three packets running is not there for its tick, and the server repeats one.
	for rate: int in [22, 33]:
		var control := {"catch_ups": 0, "holes": 0, "starved": 0, "lead_min": 1 << 30, "lead_max": -(1 << 30)}
		var fixed := control.duplicate()
		for seed_value in 6:
			for batched: bool in [false, true]:
				var run := _lossy_lead_run(rate, 0.2, batched, 32.0, 1000 + seed_value)
				var total: Dictionary = fixed if batched else control
				for key: String in ["catch_ups", "holes", "starved"]:
					total[key] = int(total[key]) + int(run[key])
				total["lead_min"] = mini(int(total["lead_min"]), int(run["lead_min"]))
				total["lead_max"] = maxi(int(total["lead_max"]), int(run["lead_max"]))
		var ticks := 6 * 30 * rate
		print("    %d Hz, 20%% loss, 6 x 30 s: each command measured %s" % [rate, control])
		print("                               the packet's newest  %s" % [fixed])
		_check("at %d Hz the control's clock takes lost packets for stalls and jumps (%d jumps, %d ticks never stamped)"
				% [rate, int(control["catch_ups"]), int(control["holes"])],
			int(control["catch_ups"]) >= 3 and int(control["holes"]) >= 6)
		_check("measured per packet it never jumps and stamps every tick (%d jumps, %d holes)"
				% [int(fixed["catch_ups"]), int(fixed["holes"])],
			int(fixed["catch_ups"]) == 0 and int(fixed["holes"]) == 0)
		_check("the lead stays where the link needs it (%d..%d ticks, the control %d..%d) and %d of %d ticks ran without their command"
				% [int(fixed["lead_min"]), int(fixed["lead_max"]), int(control["lead_min"]),
					int(control["lead_max"]), int(fixed["starved"]), ticks],
			int(fixed["lead_max"]) == int(fixed["lead_min"])
				and int(fixed["lead_max"]) < int(control["lead_max"])
				and int(fixed["starved"]) * 100 < ticks)

	_check_replay_from_inside_a_hole()
	_sections_completed += 1


## The hole right after the newest acknowledged command: the clock jumped over ticks 14-16 and
## the snapshot for 13 arrives after 13's command was acknowledged away. Armed: without the
## buffer keeping that command the last two replayed nothing and the player stood 0.75 m short.
func _check_replay_from_inside_a_hole() -> void:
	var config := DotNetConfig.new()
	var dt := 1.0 / 60.0
	var inputs := _alternating_inputs(dt)
	var server := _in_tree(_make_entity(&"player", 2))
	server.is_authoritative = true
	var server_movement := server.behaviours[0] as Movement
	var at := {}
	for input in inputs:
		if input.tick < 14 or input.tick > 16:
			server_movement._net_apply_input(input, input.tick)
		server_movement._net_simulate(input.tick, dt)
		if input.tick >= 12 and input.tick <= 15:
			at[input.tick] = server_movement.snapshot_values().duplicate()
	var client := _in_tree(_make_entity(&"player", 2))
	client.is_owner = true
	client.is_authoritative = false
	var client_movement := client.behaviours[0] as Movement
	var history := DotNetInput.Buffer.new(config.input_history_ticks)
	for input in inputs:
		if input.tick < 14 or input.tick > 16:
			var _p := history.push(input)
	var predictor := DotNetPredictor.new(config)
	var replays: Array[int] = []
	var worst := 0.0
	# As DotNetManager does for every snapshot: reconcile, then acknowledge its tick.
	for tick: int in [12, 13, 14, 15]:
		var result := predictor.reconcile(client, tick, at[tick], history, 20, dt)
		replays.append(int(result.value) if result.ok else -1)
		worst = maxf(worst, client_movement.position.distance_to(server_movement.position))
		var _a := history.acknowledge(tick)
	_check("a replay that starts inside a hole runs on the acknowledged command before it (%s ticks replayed, %.4f m off at worst)"
			% [replays, worst],
		replays == ([8, 7, 6, 5] as Array[int]) and worst < 0.001)
	var before := DotNetInput.Buffer.new(config.input_history_ticks)
	_check("a buffer nothing was acknowledged in has no command before its first",
		before.latest_before(5) == null and history.latest_before(13) == null
			and history.latest_before(16) != null and history.latest_before(16).tick == 15 - 2)
	history.clear()
	_check("and a cleared buffer forgets the acknowledged one", history.latest_before(100) == null)
	_out_of_tree(server)
	_out_of_tree(client)


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
