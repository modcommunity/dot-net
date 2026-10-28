extends "netcode_sections_5.gd"

## Sections of netcode_demo.gd, moved unchanged; part 6 of 7.


func _test_snapshot_threads() -> void:
	print("")
	print("[snapshot threads]")

	# The same scripted ten-peer game built on this thread, on four workers, and on two with
	# DotParallel.verify on. Every payload sent, and every PeerView and budget accumulator after
	# each tick, must come out byte for byte the same. The scenario is built to reach every
	# per-peer record a build writes: distance interest that changes with motion, an owner per
	# peer, loss in the acks, a budget that starves, parts at a small MTU, and half the peers on
	# the old wire format.
	var was_verify := DotParallel.verify
	var runs_before := DotParallel.verify_runs

	DotParallel.verify = false
	var off: Dictionary = _threads_scenario("ThreadsOff", 0, false)
	var on: Dictionary = _threads_scenario("ThreadsOn", 4, false)
	DotParallel.verify = true
	var verified: Dictionary = _threads_scenario("ThreadsVerify", 2, false)
	var runs_after := DotParallel.verify_runs
	DotParallel.verify = false
	var broken: Dictionary = _threads_scenario("ThreadsBroken", 4, true)
	# The paths the first scenario leaves out (evaluation interval 0, no linger, no stagger,
	# nothing rate-limited, no strings): serial against pooled again for each.
	var extra := {}
	for variant: String in ["cache", "grid", "thin"]:
		DotParallel.verify = false
		var serial: Dictionary = _threads_scenario("Extra" + variant + "Off", 0, false, variant)
		var pooled: Dictionary = _threads_scenario("Extra" + variant + "On", 3, false, variant)
		DotParallel.verify = true
		var checked: Dictionary = _threads_scenario("Extra" + variant + "Verify", 2, false, variant)
		DotParallel.verify = false
		extra[variant] = [serial, pooled, checked]
	DotParallel.verify = was_verify

	_check("the scenario sent parts to ten peers (%d payloads)" % (off["payloads"] as Array).size(),
		int(off["peers_fed"]) == 10 and (off["payloads"] as Array).size() > 300)
	_check("it starved entities and split snapshots into parts (%d starved, %d multi-part)"
			% [off["starved"], off["split"]],
		int(off["starved"]) > 0 and int(off["split"]) > 0)
	_check("with workers available the pooled path ran (%d of %d snapshots)"
			% [on["pooled"], on["snapshots"]],
		not DotParallel.available() or int(on["pooled"]) == int(on["snapshots"]))
	_check("threads off never pools", int(off["pooled"]) == 0)
	_check("snapshot workers line names the workers and the interest path (%s)" % on["note"],
		not DotParallel.available() or (str(on["note"]).contains("workers active: 4")
			and str(on["note"]).contains("interest distance")))
	_check("four workers send the same payloads, byte for byte %s" % _first_difference(off["payloads"], on["payloads"]),
		_first_difference(off["payloads"], on["payloads"]) == "")
	_check("four workers leave the same PeerViews and budgets after every tick %s"
			% _first_difference(off["states"], on["states"]),
		_first_difference(off["states"], on["states"]) == "")
	_check("two workers with verify on: same payloads and state",
		_first_difference(off["payloads"], verified["payloads"]) == ""
			and _first_difference(off["states"], verified["states"]) == ""
			and (not DotParallel.available() or int(verified["pooled"]) > 0))
	# A build writes its peers' records in place, so running it twice would advance every
	# view and accumulator twice: verify must leave these tasks alone. The byte comparison
	# with the inline path above is what proves them instead.
	_check("verify never re-runs a build that writes in place (%d re-runs)"
			% (runs_after - runs_before),
		runs_after == runs_before)
	# Armed: a pooled build that ignores its peer's acks must be seen to differ, or the
	# comparisons above prove nothing.
	_check("armed: a pooled build that ignores acks is caught",
		not DotParallel.available()
			or _first_difference(off["payloads"], broken["payloads"]) != "")

	_check_thread_variants(off, extra)

	_test_first_entity_mid_tick()
	_test_view_count()


## A value for a declaration of [param type], with edge cases every few rounds.
func _native_sample(type: int, round: int) -> Variant:
	var edge := round % 9 == 0
	match type:
		DotNetVar.Type.BOOL:
			return _rng.randi() % 2 == 0
		DotNetVar.Type.UINT:
			return _rng.randi_range(0, 400)
		DotNetVar.Type.INT:
			return _rng.randi_range(-700, 700)
		DotNetVar.Type.VARINT:
			return (1 << 40) - _rng.randi() if edge else _rng.randi_range(-100000, 100000)
		DotNetVar.Type.FLOAT:
			return _rng.randf_range(-1.0e5, 1.0e5)
		DotNetVar.Type.FLOAT_RANGE:
			return _rng.randf_range(-12.0, 12.0)
		DotNetVar.Type.VECTOR3_POSITION:
			return Vector3(_rng.randf_range(-3000, 3000), _rng.randf_range(-50, 50), _rng.randf_range(-3000, 3000))
		DotNetVar.Type.VECTOR3_VELOCITY:
			return Vector3(_rng.randf_range(-150, 150), _rng.randf_range(-150, 150), _rng.randf_range(-150, 150))
		DotNetVar.Type.VECTOR3_RANGE:
			return Vector3(_rng.randf_range(-6, 6), _rng.randf_range(-6, 6), _rng.randf_range(-6, 6))
		DotNetVar.Type.DIRECTION:
			return Vector3.ZERO if edge else Vector3(_rng.randf_range(-2, 2), _rng.randf_range(-2, 2), _rng.randf_range(-2, 2))
		DotNetVar.Type.QUATERNION:
			var q := Quaternion(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1))
			return q * 3.0 if edge else q.normalized()
		DotNetVar.Type.ANGLE:
			return _rng.randf_range(-1000.0, 1000.0)
		DotNetVar.Type.STRING:
			return "ü€".repeat(300) + "x" if edge else "name-%d" % _rng.randi()
		DotNetVar.Type.BYTES:
			var b := PackedByteArray()
			for _i in _rng.randi_range(0, 20):
				b.append(_rng.randi() % 256)
			return b
	return null


## Every native encoder writes what [method DotNetVar.write] writes, at every bit pad.
func _native_encoders_match(loaded: bool) -> void:
	var declarations: Array[DotNetVar] = [
		DotNetVar.make(&"a", DotNetVar.Type.BOOL),
		DotNetVar.make(&"b", DotNetVar.Type.UINT).bits(7),
		DotNetVar.make(&"c", DotNetVar.Type.INT).bits(9),
		DotNetVar.make(&"d", DotNetVar.Type.VARINT),
		DotNetVar.make(&"e", DotNetVar.Type.FLOAT),
		DotNetVar.make(&"f", DotNetVar.Type.FLOAT_RANGE).range_of(-10.0, 10.0).bits(12),
		DotNetVar.make(&"g", DotNetVar.Type.VECTOR3_POSITION),
		DotNetVar.make(&"h", DotNetVar.Type.VECTOR3_VELOCITY),
		DotNetVar.make(&"i", DotNetVar.Type.VECTOR3_RANGE).range_of(-5.0, 5.0).bits(10),
		DotNetVar.make(&"j", DotNetVar.Type.DIRECTION).bits(11),
		DotNetVar.make(&"k", DotNetVar.Type.QUATERNION),
		DotNetVar.make(&"l", DotNetVar.Type.ANGLE).bits(9),
		DotNetVar.make(&"m", DotNetVar.Type.STRING),
		DotNetVar.make(&"n", DotNetVar.Type.BYTES),
	]
	var holder := DotNetBehaviour.new()
	for declaration in declarations:
		declaration.bind_config(DotNetConfig.new())
	holder.net_vars = declarations
	var specs: Array = holder._native_spec()[1]
	holder.free()
	var core: Object = ClassDB.instantiate(DotNetNative.CORE_CLASS) if loaded else null
	var compared := 0
	var mismatched: Array = []
	for round in 120:
		for index in declarations.size():
			var value: Variant = _native_sample(declarations[index].type, round)
			for pad in 8:
				var w := DotNetWriter.new(64)
				if pad > 0:
					w.write_bits(0, pad)
				declarations[index].write(w, value)
				if core == null:
					continue
				var got: Array = core.encode_value(specs[index], value, pad)
				compared += 1
				if got.size() != 2 or got[0] != w.to_bytes() or int(got[1]) != w.bit_length() - pad:
					if mismatched.size() < 3:
						mismatched.append("%s %s pad %d" % [DotNetVar.Type.keys()[declarations[index].type], value, pad])
	_check("native: every encoder writes DotNetVar.write's bits at every pad (%d compared; %s)" % [compared, mismatched],
		not loaded or (compared == 120 * 14 * 8 and mismatched.is_empty()))


## The optional native core ([DotNetNative]) against the GDScript path: each encoder bit for bit
## at every pad, and whole scripted games byte for byte, inline and on workers. Without the
## library built every check reads as the fallback's: GDScript sends, and says why.
func _test_native() -> void:
	print("")
	print("[native]")
	var loaded := DotNetNative.load_library().ok
	print("  native library: %s" % ("loaded" if loaded else DotNetNative.describe()["reason"]))

	_native_encoders_match(loaded)

	for variant: String in ["", "coded", "thin", "grid"]:
		var serial: Dictionary = _threads_scenario("Native" + variant + "Off", 0, false, variant)
		var inline: Dictionary = _threads_scenario("Native" + variant + "On", 0, false, variant, true)
		var pooled: Dictionary = _threads_scenario("Native" + variant + "Pool", 3, false, variant, true)
		var name := variant if variant != "" else "base"
		_check("native %s: the run says how it built (%s)" % [name, inline["native_note"]],
			str(inline["native_note"]).begins_with("on" if loaded else "asked, GDScript in use"))
		for run: Array in [["inline", inline], ["three workers", pooled]]:
			var other: Dictionary = run[1]
			_check("native %s, %s: the same payloads %s and views and budgets %s as GDScript" % [
					name, run[0], _first_difference(serial["payloads"], other["payloads"]),
					_first_difference(serial["normal_states"], other["normal_states"])],
				(serial["payloads"] as Array).size() > 100
					and _first_difference(serial["payloads"], other["payloads"]) == ""
					and _first_difference(serial["normal_states"], other["normal_states"]) == "")

	# Interest in the library too (DotNetConfig.native_interest): the same entities chosen, ranked and
	# thinned for every peer (a payload carries exactly the chosen entities, in order), the same budgets.
	for variant: String in ["", "coded", "thin", "cache"]:
		var serial: Dictionary = _threads_scenario("NativeInterest" + variant + "Off", 0, false, variant)
		var name := variant if variant != "" else "base"
		for run: Array in [["inline", 0], ["three workers", 3]]:
			var other: Dictionary = _threads_scenario(
				"NativeInterest%s%d" % [variant, run[1]], run[1], false, variant, true, true)
			_check("native interest %s, %s: the same entities and payloads %s and budgets %s as GDScript" % [
					name, run[0], _first_difference(serial["payloads"], other["payloads"]),
					_first_difference(serial["normal_states"], other["normal_states"])],
				(serial["payloads"] as Array).size() > 100
					and bool(other["interest_native"]) == loaded
					and _first_difference(serial["payloads"], other["payloads"]) == ""
					and _first_difference(serial["normal_states"], other["normal_states"]) == "")

	for workers: int in [0, 3]:
		var forgot: Dictionary = _threads_scenario("NativeToggleOff%d" % workers, workers, false, "toggle")
		var toggled: Dictionary = _threads_scenario("NativeToggleOn%d" % workers, workers, false, "toggle", true)
		_check("native on and off mid-game, %d workers: everything resent at each switch %s" % [
				workers, _first_difference(forgot["payloads"], toggled["payloads"])],
			not loaded or (_first_difference(forgot["payloads"], toggled["payloads"]) == ""
				and _first_difference(forgot["normal_states"], toggled["normal_states"]) == ""))

	var cfg := OS.get_user_data_dir().path_join("dot_net_native_probe.cfg")
	var probe := ConfigFile.new()
	probe.set_value("libraries", "never.x86_64", "bin/a.so")
	probe.set_value("libraries", "%s.x86_64" % OS.get_name().to_lower(), "bin/missing.so")
	probe.save(cfg)
	var found := DotNetNative._library_for_platform(cfg)
	_check("native: a .cfg's library for this platform is found before loading it (%s)" % found,
		not OS.has_feature("x86_64") or found == cfg.get_base_dir().path_join("bin/missing.so"))
	DirAccess.remove_absolute(cfg)


func _input_batches_server_half(buffer: DotNetInput.Buffer, writer: DotNetWriter, read: Array) -> void:
	# The server's half: a resent copy of a consumed tick is not a late input.
	var server := DotNetInput.Buffer.new(32)
	for input in read:
		server.push(input)
	server.take(11)
	server.take(12)
	_check("the server's buffer says how far it has consumed", server.last_consumed_tick() == 12)
	var again := DotNetInput.read_batch(DotNetReader.new(writer.to_bytes()),
		func() -> DotNetInput: return DemoInput.new())
	var pushed := 0
	for input in again:
		if input.tick > server.last_consumed_tick():
			server.push(input)
			pushed += 1
	_check("so a host skips the stale copies instead of counting them late",
		pushed == 1 and server.late_count == 0 and server.duplicate_count == 1,
		)
	# Lost packet, next one arrives: the lost tick is there before it is due.
	var lost_then := DotNetInput.Buffer.new(32)
	var batch_15 := buffer.recent(3, 15)
	for input in batch_15:
		lost_then.push(input)
	_check("a packet lost before tick 14 is covered by the next one",
		lost_then.take(14) != null and lost_then.take(15) != null)


## Every packet carries the last few inputs, so one lost packet costs no tick.
func _test_input_batches() -> void:
	print("")
	print("[input batches]")

	var buffer := DotNetInput.Buffer.new(32)
	for tick in [10, 11, 12, 14, 15]:
		var input := DemoInput.new()
		input.tick = tick
		input.delta = 1.0 / 60.0
		input.move = Vector2(0.1 * tick - 1.0, 0.5)
		input.fire = tick % 2 == 0
		buffer.push(input)

	var recent := buffer.recent(3, 14)
	_check("recent() is the newest three at or before a tick, oldest first",
		recent.size() == 3 and recent[0].tick == 11 and recent[2].tick == 14)

	var writer := DotNetWriter.new()
	DotNetInput.write_batch(writer, recent)
	var read := DotNetInput.read_batch(DotNetReader.new(writer.to_bytes()),
		func() -> DotNetInput: return DemoInput.new())
	var same := read.size() == 3
	for i in range(mini(read.size(), 3)):
		var a: DemoInput = recent[i]
		var b: DemoInput = read[i]
		same = same and a.tick == b.tick and a.fire == b.fire \
			and a.move.distance_to(b.move) < 0.01 and absf(a.delta - b.delta) < 0.001
	_check("a batch round-trips every tick, across a gap, with its fields", same)

	var one := DotNetWriter.new()
	recent[2].write(one)
	print("    one input %d bytes, a batch of three %d" % [one.to_bytes().size(), writer.to_bytes().size()])
	_check("the copies cost less than a whole input each",
		writer.to_bytes().size() < one.to_bytes().size() * 3)

	var cut := writer.to_bytes().slice(0, writer.to_bytes().size() - 2)
	var partial := DotNetInput.read_batch(DotNetReader.new(cut),
		func() -> DotNetInput: return DemoInput.new())
	_check("a truncated batch keeps only the inputs it read whole",
		partial.size() == 2 and partial[1].tick == 12)

	_input_batches_server_half(buffer, writer, read)


## The server says how early each client's commands arrive, and the clock steers by it.
##
## One server, two clients on the same simulated link: one that reads the report and one from
## before it (its table names no features). Every 1/60 s frame the server takes what has
## arrived and runs a tick, and each client takes its snapshots, advances its clock and sends
## a command for every tick it ran. The link is 40 ms each way, then 70, then 40 again. The
## round trip a game feeds the clock is modelled on ENet's: it moves an eighth of the way to
## the truth every half second.
##
## Armed: the client from before the report is the control (with its lead from the modelled
## round trip, nearly every one of the 240 ticks after the rise had its command late: 469
## counted, each late and then starved); with the receive timeline not held to real time while the clock runs fast
## (no [code]_receive_excess[/code]), it was still 6 ticks past the newest snapshot a second
## and a half after the rise, against the control's 3; it is 4.
func _test_input_lead() -> void:
	print("")
	print("[the input lead the server reports]")

	var host := _parts_manager("LeadServer", true, 1200)
	var fresh := _parts_manager("LeadClient", false, 1200)
	var legacy := _parts_manager("LeadLegacy", false, 1200)
	legacy.local_peer_id = 3
	legacy.messages.features = DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS
	# Twenty snapshots a second, as most games here send: the receive timeline steps back a
	# tick only after sixteen arrivals behind it, so a timeline the drift carried ahead stays
	# there for most of a second a tick.
	for m in [host, fresh, legacy]:
		(m as DotNetManager).config.snapshot_rate = 20

	var clients := {2: fresh, 3: legacy}
	# [arrival ms, payload] in flight, each direction, each client.
	var down := {2: [], 3: []}
	var up := {2: [], 3: []}
	var link := {"one_way": 40.0, "now": 0.0}

	host.send_fn = func(peer_id: int, payload: PackedByteArray, d: int) -> void:
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var _schema := (clients[peer_id] as DotNetManager).receive(payload, 1)
			return
		(down[peer_id] as Array).append([float(link["now"]) + float(link["one_way"]), payload])
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

	_check("the new client says it reads the input lead, the old one does not",
		host.messages.peer_supports(2, DotNetMessageRegistry.FEATURE_INPUT_LEAD)
			and not host.messages.peer_supports(3, DotNetMessageRegistry.FEATURE_INPUT_LEAD))

	var frame_ms := 1000.0 / 60.0
	var state := {"frame": 0, "enet_rtt": 80.0, "legacy_bytes": 0, "legacy_snapshots": 0}
	# Per client, over a phase: late or missing commands, when the last one was, the real lead's
	# range, and how far the receive timeline ran past the newest snapshot that had arrived.
	var phase := {}

	var run := func(seconds: float) -> void:
		# Cleared, not reassigned: a lambda's captured variable is its own copy of the reference.
		phase.clear()
		for peer in [2, 3]:
			phase[peer] = {"missed_at_start": host.input_buffer_for(peer).late_count
				+ host.input_buffer_for(peer).starved_count, "last_miss_ms": -1.0,
				"lead_min": 1 << 30, "lead_max": -(1 << 30), "ahead_max": -(1 << 30), "newest": -1}
		var started := float(link["now"])
		var frames := int(seconds * 60.0)
		for _f in frames:
			var now := float(state["frame"]) * frame_ms
			link["now"] = now
			state["frame"] = int(state["frame"]) + 1
			# ENet's smoothed round trip: an eighth of the way to the truth every half second.
			if int(state["frame"]) % 30 == 0:
				state["enet_rtt"] = float(state["enet_rtt"]) + (2.0 * float(link["one_way"]) - float(state["enet_rtt"])) / 8.0

			# The server: what has arrived, then one tick.
			for peer in [2, 3]:
				var queue: Array = up[peer]
				var buffer := host.input_buffer_for(peer)
				while not queue.is_empty() and float(queue[0][0]) <= now:
					var _pushed := buffer.push(queue.pop_front()[1])
			host.server_tick(int(state["frame"]))

			for peer in [2, 3]:
				var client: DotNetManager = clients[peer]
				var queue: Array = down[peer]
				var p: Dictionary = phase[peer]
				while not queue.is_empty() and float(queue[0][0]) <= now:
					var payload: PackedByteArray = queue.pop_front()[1]
					if peer == 3:
						state["legacy_bytes"] = int(state["legacy_bytes"]) + payload.size()
						state["legacy_snapshots"] = int(state["legacy_snapshots"]) + 1
					client.stats.note_rtt(float(state["enet_rtt"]))
					var _r := client.receive_snapshot(payload)
					p["newest"] = maxi(int(p["newest"]), DotNetReader.new(payload).read_uint(32))
				var ticks := client.clock.advance(1.0 / 60.0)
				for i in ticks:
					if not client.clock.is_synced():
						continue
					var input := DemoInput.new()
					input.tick = client.clock.tick - (ticks - 1 - i)
					input.delta = 1.0 / 60.0
					(up[peer] as Array).append([now + float(link["one_way"]), input])
				if client.clock.is_synced():
					var lead := client.clock.tick - int(state["frame"])
					p["lead_min"] = mini(int(p["lead_min"]), lead)
					p["lead_max"] = maxi(int(p["lead_max"]), lead)
					# From a second and a half in: a link that slows leaves a gap in the
					# snapshots, which the timeline runs on through (as it should) until the
					# next one; what is measured is whether it comes back.
					if int(p["newest"]) >= 0 and now - started >= 1500.0:
						p["ahead_max"] = maxi(int(p["ahead_max"]), client.clock.received_tick() - int(p["newest"]))
				var buffer := host.input_buffer_for(peer)
				if buffer.late_count + buffer.starved_count > int(p.get("missed_seen", p["missed_at_start"])):
					p["missed_seen"] = buffer.late_count + buffer.starved_count
					p["last_miss_ms"] = now - started

	var missed := func(peer: int) -> int:
		var buffer := host.input_buffer_for(peer)
		return buffer.late_count + buffer.starved_count - int(phase[peer]["missed_at_start"])

	var describe := func(peer: int) -> String:
		var p: Dictionary = phase[peer]
		return "%d late or missing, the last %s; real lead %d..%d ticks; receive timeline at most %d past the newest snapshot" % [
			missed.call(peer), "never" if float(p["last_miss_ms"]) < 0.0 else "%.2f s in" % (float(p["last_miss_ms"]) / 1000.0),
			int(p["lead_min"]), int(p["lead_max"]), int(p["ahead_max"])]

	run.call(3.0)
	run.call(2.0)
	print("    40 ms, settled:  reported %s" % describe.call(2))
	print("                     control  %s" % describe.call(3))
	var settled_fresh := int(phase[2]["lead_max"])
	_check("settled, both clients' commands are on time (%d, %d)" % [missed.call(2), missed.call(3)],
		missed.call(2) == 0 and missed.call(3) == 0)
	_check("and the reported client's arrive the slack it asks for early (%d ticks, asked %d)"
			% [int(fresh.clock.describe()["last_arrival_lead"]), fresh.config.input_lead_slack_ticks],
		int(fresh.clock.describe()["last_arrival_lead"]) == fresh.config.input_lead_slack_ticks)
	_check("the old client's snapshots carry no report: 6 bytes each, as before (%d over %d)"
			% [int(state["legacy_bytes"]), int(state["legacy_snapshots"])],
		int(state["legacy_bytes"]) == 6 * int(state["legacy_snapshots"]))
	_check("the new client steers by the reports, the old one by the round trip",
		fresh.clock.is_lead_reported() and not legacy.clock.is_lead_reported())

	link["one_way"] = 70.0
	run.call(4.0)
	print("    40 to 70 ms:     reported %s" % describe.call(2))
	print("                     control  %s" % describe.call(3))
	_check("the link slowing by 30 ms each way costs the reported client at most 4 commands (%d)" % missed.call(2),
		missed.call(2) <= 4)
	_check("and none after the first half second (last %s)" % ("never" if float(phase[2]["last_miss_ms"]) < 0.0
			else "%.2f s in" % (float(phase[2]["last_miss_ms"]) / 1000.0)),
		float(phase[2]["last_miss_ms"]) < 500.0)
	_check("the control, from the round trip, loses many more (%d)" % missed.call(3),
		missed.call(3) >= 20)
	_check("running fast leaves the receive timeline no further past the snapshots than the control's (%d, %d)"
			% [int(phase[2]["ahead_max"]), int(phase[3]["ahead_max"])],
		int(phase[2]["ahead_max"]) <= int(phase[3]["ahead_max"]) + 1)
	var slow_lead := int(phase[2]["lead_max"])

	link["one_way"] = 40.0
	run.call(4.0)
	print("    70 to 40 ms:     reported %s" % describe.call(2))
	print("                     control  %s" % describe.call(3))
	_check("a link getting quicker costs no command (%d)" % missed.call(2), missed.call(2) == 0)
	_check("and the lead is given back, to what it was at 40 ms (%d, was %d, at 40 ms %d)"
			% [int(phase[2]["lead_min"]), slow_lead, settled_fresh],
		int(phase[2]["lead_min"]) <= settled_fresh and slow_lead > settled_fresh)

	for m in [host, fresh, legacy]:
		(m as DotNetManager).stop()
		(m as DotNetManager).queue_free()

	# A host that stamps its own lead (every game's headless_net harness stamps `_tick + 2`)
	# hears about commands the clock did not stamp: each report asks a tick more than the clock
	# has given, whatever it gives. Capped, it stops (7 ticks ahead); uncapped it ran 29 ahead in 10 s.
	var stray := DotNetClock.new(60)
	stray.sync_from_server(100, 20.0)
	var server_at := 100
	var stray_lead := 0
	for f in 600:
		var _ticks := stray.advance(1.0 / 60.0)
		server_at += 1
		stray.sync_from_server(server_at, 20.0)
		# The command the host sent for the server's tick plus two, there one tick early.
		stray.note_input_lead(server_at + 2, 1)
		stray_lead = stray.tick - server_at
	_check("a clock told about commands it did not stamp does not run away (%d ticks ahead)" % stray_lead,
		stray.is_lead_reported() and stray_lead <= 12)


## A first visit's frames, against a server running in real time: the engine running at most
## [param cap] steps a frame and dropping the rest, [param stalls] (seconds) at the start, then
## frames of 60 to 150 ms. [param follow] hands the clock the engine's numbers once a frame, as
## [method DotNetClock.advance] does inside a real physics frame; without it the clock is handed
## only the steps' deltas, which is all it had before. Returns what the server saw after the
## stalls: commands late, ticks with none, and when the last late one arrived.
func _first_visit(rate: int, cap: int, stalls: Array, follow: bool, slow_seconds: float = 6.0,
		frame_ms: float = 150.0, read_first: bool = false, settle_ms: float = 1000.0 / 60.0,
		each_frame: Callable = Callable()) -> Dictionary:
	var host := _parts_manager("DropServer%d" % rate, true, 1200)
	var guest := _parts_manager("DropClient%d" % rate, false, 1200)
	for m in [host, guest]:
		(m as DotNetManager).config.tick_rate = rate
		(m as DotNetManager).config.snapshot_rate = 32
		(m as DotNetManager).clock.tick_rate = rate
	guest.clock.follow_engine_time = false

	var one_way := 50.0
	var down: Array = []
	var up: Array = []
	var link := {"now": 0.0}
	host.send_fn = func(_peer: int, payload: PackedByteArray, d: int) -> void:
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var _schema := guest.receive(payload, 1)
			return
		down.append([float(link["now"]) + one_way, payload])
	guest.send_fn = func(_peer: int, payload: PackedByteArray, d: int) -> void:
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var _adopted := host.receive(payload, 2)
	host.start()
	guest.start()
	host.add_peer(2)

	var buffer := host.input_buffer_for(2)
	var step_ms := 1000.0 / float(rate)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	# Frames: a second at 60 Hz to settle, the stalls, then slow frames.
	var frames: Array[float] = []
	for _i in int(1000.0 / settle_ms):
		frames.append(settle_ms)
	var stalls_end := float(int(1000.0 / settle_ms)) * settle_ms
	for stall in stalls:
		frames.append(float(stall) * 1000.0)
		stalls_end += float(stall) * 1000.0
		for _i in int(1000.0 / 6.0 / settle_ms):
			frames.append(settle_ms)
			stalls_end += settle_ms
	var slow := 0.0
	while slow < slow_seconds * 1000.0:
		var ms := frame_ms if frame_ms > 0.0 else rng.randf_range(60.0, 150.0)
		frames.append(ms)
		slow += ms

	# In a dictionary: a lambda captures a local by value.
	var server := {"tick": 0}
	var acc := 0.0
	var physics := 0
	var now := 0.0
	var out := {"late": 0, "starved": 0, "last_late_ms": -1.0, "measured_from": 0, "ticks": 0, "arrivals": []}
	var late_seen := 0
	var counted := false
	var run_server := func(until: float) -> void:
		# The server, in real time.
		while float(int(server["tick"]) + 1) * step_ms <= until:
			server["tick"] = int(server["tick"]) + 1
			link["now"] = float(server["tick"]) * step_ms
			while not up.is_empty() and float(up[0][0]) <= float(link["now"]):
				var input: DotNetInput = up.pop_front()[1]
				# How early it came, in the server's own terms: ticks before the one it simulates next.
				(out["arrivals"] as Array).append(Vector2(float(link["now"]) - stalls_end, float(input.tick - int(server["tick"]))))
				var _pushed := buffer.push(input)
			host.server_tick(int(server["tick"]))
	for f in frames.size():
		run_server.call(now)
		if not counted and now >= stalls_end + 1000.0:
			# A second after the last stall, what follows is counted.
			counted = true
			out["late"] = -buffer.late_count
			out["starved"] = -buffer.starved_count
			out["measured_from"] = int(server["tick"])
		if buffer.late_count > late_seen:
			late_seen = buffer.late_count
			if counted:
				out["last_late_ms"] = now - stalls_end
		# The engine: this frame's steps cover the time to its start, at most `cap` of them; what
		# is past the cap is dropped.
		acc += frames[f - 1] if f > 0 else 0.0
		var steps := mini(cap, int(acc / step_ms))
		acc -= float(steps) * step_ms
		if steps == cap:
			acc = fmod(acc, step_ms)
		if read_first and steps > 0:
			# A host that reads its packets inside its physics step, before the clock's.
			if follow:
				guest.clock.note_engine_frame(f, int(now * 1000.0), physics + 1, rate, cap)
			while not down.is_empty() and float(down[0][0]) <= now:
				guest.stats.note_rtt(2.0 * one_way + (frames[f - 1] if f > 0 else 0.0))
				var _r := guest.receive_snapshot(down.pop_front()[1])
		if each_frame.is_valid():
			each_frame.call(guest.clock, now - stalls_end)
		var produced: Array = []
		for i in steps:
			physics += 1
			if i == 0 and follow:
				guest.clock.note_engine_frame(f, int(now * 1000.0), physics, rate, cap)
			var ticks := guest.clock.advance(step_ms / 1000.0)
			for k in ticks:
				if not guest.clock.is_synced():
					continue
				var input := DemoInput.new()
				input.tick = guest.clock.tick - (ticks - 1 - k)
				input.delta = step_ms / 1000.0
				produced.append(input)
		# The frame's process: the stall or the slow frame, then its packets, read and sent at the
		# end of it as a host polls its socket.
		var end := now + frames[f]
		run_server.call(end)
		link["now"] = end
		while not read_first and not down.is_empty() and float(down[0][0]) <= end:
			if follow:
				guest.clock.note_engine_time(int(end * 1000.0), physics, rate, cap)
			# A transport's round trip waits for the client's next poll, so it holds the frame.
			guest.stats.note_rtt(2.0 * one_way + frames[f])
			var _r := guest.receive_snapshot(down.pop_front()[1])
		for input in produced:
			up.append([end + one_way, input])
		now = end
	out["late"] = int(out["late"]) + buffer.late_count
	out["starved"] = int(out["starved"]) + buffer.starved_count
	out["ticks"] = int(server["tick"]) - int(out["measured_from"])
	out["floors"] = guest.clock.floor_count()
	out["lost_ms"] = int(guest.clock.lost_seconds() * 1000.0)
	out["snaps"] = int(guest.clock.describe()["snaps"])
	for m in [host, guest]:
		(m as DotNetManager).stop()
		(m as DotNetManager).queue_free()
	return out


## The stuck-on-the-spawn-pad report: a browser's first visit stalls
## for seconds while it loads and compiles shaders, then draws slow frames, and the engine drops
## every physics step past its cap. Handed only the steps' deltas, the clock never saw the
## dropped time; the reported lead learnt it a round trip late, and with the absolute catch-up
## skipped once the reports steered, the client stayed behind and the server discarded nearly
## every command as late. See docs/timelines.md#time-the-engine-drops.
func _test_dropped_time() -> void:
	print("")
	print("[time the engine drops: a first visit's stalls and slow frames]")

	var describe := func(r: Dictionary) -> String:
		return "%d late, %d without a command, of %d ticks; last late %s; %d ms dropped, %d floors, %d snaps" % [
			int(r["late"]), int(r["starved"]), int(r["ticks"]),
			"never" if float(r["last_late_ms"]) < 0.0 else "%.1f s after the stalls" % (float(r["last_late_ms"]) / 1000.0),
			int(r["lost_ms"]), int(r["floors"]), int(r["snaps"])]

	for rate in [60, 128]:
		# The engine's default cap of 8: 133 ms at 60, 62.5 ms at 128, so the slow frames drop
		# time at 128 every frame and at 60 now and then.
		var fixed: Dictionary = _first_visit(rate, 8, [3.0, 2.0], true)
		var blind: Dictionary = _first_visit(rate, 8, [3.0, 2.0], false)
		print("    %d ticks, cap 8:  wall %s" % [rate, describe.call(fixed)])
		print("                     steps %s" % describe.call(blind))
		# Armed: handed only the steps (as every clock was before), 64 of 297 late at 60 and 255
		# of 633 at 128, with no tick of the 633 commanded in time; the floor alone changes
		# that by two.
		_check("%d ticks: after the stalls, at most 2%% of commands late (%d of %d)" % [
				rate, int(fixed["late"]), int(fixed["ticks"])],
			int(fixed["late"]) * 50 <= int(fixed["ticks"]))
		_check("%d ticks: the dropped time was seen (%d ms of at least %d), and nothing snapped (%d)" % [
				rate, int(fixed["lost_ms"]), 4500, int(fixed["snaps"])],
			int(fixed["lost_ms"]) >= 4500 and int(fixed["snaps"]) == 0)
		if rate == 128:
			_check("128 ticks: a clock handed only the steps loses many more (%d)" % int(blind["late"]),
				int(blind["late"]) >= 10 * maxi(1, int(fixed["late"])))

	# The floor, on its own: a clock steered by the reports that finds itself behind the server
	# (a stall it never saw, as every clock was before it looked at the wall) catches up at once.
	# Armed: before, the reported lead's path returned without looking and the clock stayed 30
	# ticks behind, every command late, until a report a round trip later said so.
	var behind := DotNetClock.new(60)
	behind.follow_engine_time = false
	behind.sync_from_server(1000, 100.0)
	for _i in 3:
		var _t := behind.advance(1.0 / 60.0)
	behind.note_input_lead(behind.tick, 2)
	var was := behind.tick
	behind.sync_from_server(was + 30, 100.0)
	_check("a reported clock behind the newest snapshot jumps past it (%d -> %d, snapshot %d)" % [
			was, behind.tick, behind.received_tick()],
		behind.is_lead_reported() and behind.tick > behind.received_tick() and behind.floor_count() == 1)

	# Frames the engine keeps up with, beside the same clock handed only the steps: nothing is
	# credited, the floor is never needed, and the two clocks are the same clock.
	var calm: Dictionary = _first_visit(128, 32, [], true, 4.0)
	var calm_blind: Dictionary = _first_visit(128, 32, [], false, 4.0)
	print("    128 ticks, cap 32, no stall: wall %s" % describe.call(calm))
	print("                                steps %s" % describe.call(calm_blind))
	_check("frames the engine keeps up with: nothing credited, no floor (%d ms, %d)" % [
			int(calm["lost_ms"]), int(calm["floors"])],
		int(calm["lost_ms"]) == 0 and int(calm["floors"]) == 0)
	# Not exactly the same clock any more: following the wall also discounts a frame longer than
	# the last second has seen (DotNetClock._discount_long_frame), which these random frames
	# have now and then. Never a worse one.
	_check("and the clock does no worse than when handed only the steps (%d late, %d)" % [
			int(calm["late"]), int(calm_blind["late"])],
		int(calm["late"]) <= int(calm_blind["late"]) and int(calm["starved"]) <= int(calm_blind["starved"]))

	# A host that reads its snapshots inside its physics step, before the clock advances: the
	# stall is seen at that frame's first step, before the snapshots that followed it are read.
	var polled: Dictionary = _first_visit(128, 8, [3.0, 2.0], true, 6.0, 150.0, true)
	print("    128 ticks, cap 8, read in the physics step: %s" % describe.call(polled))
	_check("read in the physics step, at most 2%% late and no snap (%d of %d, %d)" % [
			int(polled["late"]), int(polled["ticks"]), int(polled["snaps"])],
		int(polled["late"]) * 50 <= int(polled["ticks"]) and int(polled["snaps"]) == 0)


## A ping measured across a stall must not become the round trip.
func _cover_stalls_ping() -> void:
	# Zombie Zone on the web: the game's ping measured across a
	# 10.7 s stall read 14.8 s, and every snapshot after it carried that as the round trip. The
	# median, the jitter and with them the lead ran to 800 ticks and the clock snapped nine
	# times in one frame. Armed: a round trip a stall explains is held near the median.
	var web := DotNetClock.new(64)
	web.follow_engine_time = false
	web.sync_from_server(1000, 88.0)
	var frame := 0
	var wall := 0
	var steps := 0
	for _i in 20:
		frame += 1
		wall += 15625
		steps += 1
		web.note_engine_frame(frame, wall, steps, 64, 16)
		var _t := web.advance(1.0 / 64.0)
	frame += 1
	wall += 10700000
	steps += 16
	web.note_engine_frame(frame, wall, steps, 64, 16)
	var _t2 := web.advance(1.0 / 64.0)
	for _i in 9:
		web.sync_from_server(web.received_tick() + 1, 14819.0)
	print("    64 ticks, 10.7 s stall, a ping of 14.8 s: rtt %d ms, %d held, %d snaps, lead %d" % [
		int(web.rtt_ms()), web.rtt_rejected(), int(web.describe()["snaps"]), web.tick - web.received_tick()])
	_check("a round trip a stall explains is held down (%d held)" % web.rtt_rejected(),
		web.rtt_rejected() == 9)
	_check("the estimate stays the link's (%d ms)" % int(web.rtt_ms()), web.rtt_ms() < 400.0)
	_check("and nothing snaps (%d)" % int(web.describe()["snaps"]), int(web.describe()["snaps"]) == 0)

	# A client that runs at 3 frames a second has a "stall" in every frame; a real 600 ms link must
	# still be believed, or the clock never adapts to it.
	var slow := DotNetClock.new(64)
	slow.follow_engine_time = false
	slow.sync_from_server(1000, 40.0)
	frame = 0
	wall = 0
	steps = 0
	for _i in 60:
		frame += 1
		wall += 333000
		steps += 21
		slow.note_engine_frame(frame, wall, steps, 64, 32)
		var _ts := slow.advance(1.0 / 64.0)
		slow.sync_from_server(slow.received_tick() + 21, 40.0 if _i < 10 else 600.0)
	print("    slow client: rtt %d ms, %d held, stalls %d" % [int(slow.rtt_ms()), slow.rtt_rejected(), slow._stalls.size()])
	_check("a slow client still learns a real 600 ms link (%d ms)" % int(slow.rtt_ms()),
		slow.rtt_ms() > 500.0)

	# A big stall followed by a run of 0.3 s frames must still explain the ping across it.
	var burst := DotNetClock.new(64)
	burst.follow_engine_time = false
	burst.sync_from_server(1000, 88.0)
	frame = 0
	wall = 0
	steps = 0
	for _i in 20:
		frame += 1
		wall += 15625
		steps += 1
		burst.note_engine_frame(frame, wall, steps, 64, 16)
		var _tb := burst.advance(1.0 / 64.0)
	frame += 1
	wall += 10700000
	steps += 16
	burst.note_engine_frame(frame, wall, steps, 64, 16)
	for _i in 6:
		frame += 1
		wall += 300000
		steps += 16
		burst.note_engine_frame(frame, wall, steps, 64, 16)
	burst.sync_from_server(burst.received_tick() + 1, 14819.0)
	_check("a stall is not forgotten behind later short stalls (%d held)" % burst.rtt_rejected(),
		burst.rtt_rejected() == 1)
