extends "netcode_sections_7.gd"


## A client's artificial latency pair: a server and a client over a hand-pumped link.
func _latency_pair() -> Dictionary:
	var host := _parts_manager("LatencyServer", true, 1200)
	var guest := _parts_manager("LatencyClient", false, 1200)
	var got := {"up": [], "down": []}
	for m in [host, guest]:
		var manager := m as DotNetManager
		manager.messages.register(&"demo.chat", ChatMessage)
		manager.messages.register(
			&"demo.notice", ServerNotice, DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT
		)
	host.messages.on(&"demo.chat", func(_m: DotNetMessage) -> void: (got["up"] as Array).append(got["t"]))
	guest.messages.on(&"demo.notice", func(_m: DotNetMessage) -> void: (got["down"] as Array).append(got["t"]))
	got["t"] = 0.0
	host.send_fn = func(_peer: int, payload: PackedByteArray, _d: int) -> void:
		var _r := guest.receive(payload, 1)
	guest.send_fn = func(_peer: int, payload: PackedByteArray, _d: int) -> void:
		var _r := host.receive(payload, 2)
	return {"host": host, "guest": guest, "got": got}


## Sends one message each way and steps the client for [param seconds]; returns the first delivery time each way, or -1.
func _latency_run(pair: Dictionary, seconds: float) -> Array[float]:
	var host := pair["host"] as DotNetManager
	var guest := pair["guest"] as DotNetManager
	var got := pair["got"] as Dictionary
	(got["up"] as Array).clear()
	(got["down"] as Array).clear()
	got["t"] = 0.0
	var chat := ChatMessage.new()
	chat.text = "hi"
	var notice := ServerNotice.new()
	notice.notice = "hi"
	var _a := guest.send(chat)
	var _b := host.send(notice, 2)
	var steps := int(seconds / 0.01)
	for i in steps:
		got["t"] = float(i + 1) * 0.01
		guest.step(0.01)
	var up: Array = got["up"]
	var down: Array = got["down"]
	return [-1.0 if up.is_empty() else float(up[0]), -1.0 if down.is_empty() else float(down[0])]


## [b]`cl_latency_baseline`[/b]: 0 adds nothing, 0.2 s delays a client's traffic both ways by about that, and the server's `sv_allow_client_latency` 0 forces it back to 0.
func _test_latency_baseline() -> void:
	_sections_entered += 1
	print("")
	print("[client latency baseline]")

	var pair := _latency_pair()
	var guest := pair["guest"] as DotNetManager
	var latency := guest.latency
	guest.start()
	(pair["host"] as DotNetManager).start()

	_check("idle by default: not delaying, not busy", not latency.delaying() and not latency.busy())
	var base := _latency_run(pair, 0.5)
	_check("baseline 0 delivers at once both ways (%s)" % [base], base[0] == 0.0 and base[1] == 0.0)
	_check("and queues nothing", latency.pending() == 0)

	latency.requested = 0.2
	var lagged := _latency_run(pair, 0.5)
	_check("baseline 0.2 delays outgoing by ~0.2 s (%.2f)" % lagged[0], absf(lagged[0] - 0.2) <= 0.02)
	_check("and incoming by ~0.2 s (%.2f)" % lagged[1], absf(lagged[1] - 0.2) <= 0.02)
	_check("and the queue drains", latency.pending() == 0)

	guest.send_fn = guest.send_fn
	_check("assigning send_fn back while delaying keeps the real one", guest.send_fn.is_valid())

	_check("the server's switch 0 is accepted", latency.set_cvar("sv_allow_client_latency", "0"))
	_check("which forces the effective baseline to 0 (%.2f)" % latency.effective(), latency.effective() == 0.0)
	var forced := _latency_run(pair, 0.5)
	_check("traffic is immediate again (%s)" % [forced], forced[0] == 0.0 and forced[1] == 0.0)
	_check("the client's own request is kept (%.2f)" % latency.requested, latency.requested == 0.2)

	latency.set_cvar("sv_allow_client_latency", "1")
	_check("switching it back on restores 0.2", latency.effective() == 0.2)
	var chat := ChatMessage.new()
	chat.text = "held"
	var _s := guest.send(chat)
	_check("a packet is held", latency.pending() == 1)
	latency.allowed = false
	_check("forbidding releases what was held, in order", latency.pending() == 0)

	_check("a bad cvar value is refused", not latency.set_cvar("cl_latency_baseline", "fast"))
	_check("an unknown cvar is refused", not latency.set_cvar("sv_other", "1"))
	_sections_completed += 1


func _interpolation_notifies() -> void:
	# Everything above checks that a smooth value is computed; this checks that anything is told
	# about it. Without the notification a game copies state only on a snapshot, so a remote
	# moves in 20 Hz steps and the interpolator's output is discarded.
	var config2 := DotNetConfig.new()
	config2.adaptive_interpolation = false
	config2.interpolation_buffer = 2.0

	var watcher := Interpolated.new()
	watcher.name = "Net"

	var host := Node3D.new()
	host.name = "Interpolated"
	add_child(host)
	host.add_child(watcher)

	var watched := DotNetIdentity.new()
	watched.name = "Identity"
	watched.owner_peer_id = 5
	host.add_child(watched)

	var registry := DotNetRegistry.new(false, 1)
	registry.register(watched, 77, 0, config2)

	var live := DotNetInterpolator.new(config2)
	live.push(77, 100, {"position": Vector3(0, 0, 0)})
	live.push(77, 110, {"position": Vector3(10, 0, 0)})

	live.apply(watched, 107)

	_check("the interpolated value reaches the behaviour", watcher.notifications > 0)
	_check(
		"and is what the behaviour renders (x=%.2f)" % watcher.rendered.x,
		watcher.rendered.x > 0.1 and watcher.rendered.x < 9.9
	)
	_check(
		"stamped with the render tick, not the newest snapshot (%d)" % watcher.last_tick,
		watcher.last_tick == 107
	)

	# A predicted entity must not be notified: writing interpolated state over a
	# prediction fights the predictor every frame.
	watched.authority = DotNetIdentity.Authority.SHARED
	watched.is_owner = true
	watched.is_authoritative = false
	var before_predicted := watcher.notifications
	live.apply(watched, 108)
	_check(
		"a predicted entity is not interpolated over",
		watcher.notifications == before_predicted
	)


func _interpolation_settled_skip() -> void:
	# DotNetConfig.skip_settled_interp: a draw equal to last frame's is not written again, until a snapshot
	# arrives or a frame is missed. Off, every frame writes, as before.
	var was_native := DotNetInterpolator.native_enabled
	DotNetInterpolator.native_enabled = false
	for skip: bool in [false, true]:
		var config := DotNetConfig.new()
		config.adaptive_interpolation = false
		config.interpolation_buffer = 2.0
		config.skip_settled_interp = skip
		var watcher := Interpolated.new()
		watcher.name = "Net"
		var host := Node3D.new()
		host.name = "Settled%s" % skip
		add_child(host)
		host.add_child(watcher)
		var watched := DotNetIdentity.new()
		watched.name = "Identity"
		watched.owner_peer_id = 5
		host.add_child(watched)
		DotNetRegistry.new(false, 1).register(watched, 78, 0, config)
		var live := DotNetInterpolator.new(config)
		live.push(78, 100, {"position": Vector3(3, 0, 0)})
		live.push(78, 110, {"position": Vector3(3, 0, 0)})
		var frame: Array[DotNetIdentity] = [watched]
		live.apply_frame(frame, 107.0)
		live.apply_frame(frame, 108.0)
		live.apply_frame(frame, 109.0)
		var held := watcher.notifications
		_check("settled skip %s: a still entity is written %d of 3 frames" % [skip, held], held == (1 if skip else 3))
		_check("settled skip %s: counted (%d)" % [skip, live.settled_count()], live.settled_count() == (2 if skip else 0))
		watcher.position = Vector3(9, 9, 9)
		live.push(78, 120, {"position": Vector3(3, 0, 0)})
		live.apply_frame(frame, 110.0)
		_check("settled skip %s: a snapshot wakes it (x=%.1f)" % [skip, watcher.position.x], watcher.position == Vector3(3, 0, 0))
		live.push(78, 130, {"position": Vector3(13, 0, 0)})
		live.apply_frame(frame, 131.0)
		var moved := watcher.position
		live.apply_frame(frame, 133.0)
		_check("settled skip %s: a moving entity is written every frame" % skip, watcher.position != moved)
		watcher.position = Vector3(9, 9, 9)
		live.apply(watched, 133.0)
		_check("settled skip %s: apply always writes" % skip, watcher.position != Vector3(9, 9, 9))
		host.queue_free()
	DotNetInterpolator.native_enabled = was_native


func _interpolation_value_at(interpolator: DotNetInterpolator) -> void:
	# value_at: the drawn value at an absolute render tick, counting nothing, never extrapolating.
	var counted := interpolator.sample_count()
	var at: Variant = interpolator.value_at(1, &"position", 102.5)
	var again: Variant = interpolator.value_at(1, &"position", 102.5)
	_check("value_at blends at a render tick (x=%s)" % [at], at is Vector3 and absf((at as Vector3).x - 2.5) < 0.001 and at == again)
	_check("value_at holds the newest past the end", interpolator.value_at(1, &"position", 130.0) == Vector3(10, 0, 0))
	_check("value_at counts no samples", interpolator.sample_count() == counted)
	_check("value_at of an unknown entity is null", interpolator.value_at(99, &"position", 100.0) == null)
	_check("value_at before the oldest sample is null, as a server's rewind past its history", interpolator.value_at(1, &"position", 99.0) == null)
	interpolator.push(4, 100, {"position": Vector3.ZERO})
	interpolator.push(4, 102, {"position": Vector3(0.5, 0, 0)})
	interpolator.push(4, 104, {"position": Vector3(40, 0, 0)})
	interpolator.push(4, 106, {"position": Vector3(40.5, 0, 0)})
	_check("value_at with a cut is null before a teleport", interpolator.value_at(4, &"position", 101.0, 10.0) == null)
	_check("and blends after it", interpolator.value_at(4, &"position", 105.0, 10.0) == Vector3(40.25, 0, 0))
	_check("and without one blends across it", interpolator.value_at(4, &"position", 101.0) == Vector3(0.25, 0, 0))
	# bracket_at / value_between: the snapshot ticks a view tick was drawn between, and the
	# blend between exactly those two, so both ends rewind between the same samples (API 15).
	_check("bracket_at names the two snapshot ticks around a view tick", interpolator.bracket_at(101.0) == Vector2i(100, 102))
	_check("and one tick when the view tick is a snapshot's", interpolator.bracket_at(104.0) == Vector2i(104, 104))
	_check("and (-1, -1) before the oldest", interpolator.bracket_at(50.0) == Vector2i(-1, -1))
	_check("value_between blends the two samples named (a gap kept as a gap)", interpolator.value_between(4, &"position", 104, 106, 105.5) == Vector3(40.375, 0, 0))
	_check("and is null for a sample the track does not have", interpolator.value_between(4, &"position", 103, 106, 105.0) == null)
	_check("value_between with a cut is null across a teleport inside the bracket", interpolator.value_between(4, &"position", 102, 104, 103.0, 10.0) == null)
	_check("and ignores a teleport after the bracket, as the server's rewind cannot know it", interpolator.value_between(4, &"position", 100, 102, 101.0, 10.0) == Vector3(0.25, 0, 0))
	var wire_spec := DotNetVar.make(&"position", DotNetVar.Type.VECTOR3_POSITION)
	var on_wire: Vector3 = wire_spec.wire_value(Vector3(1.2345, -0.004, 7.0))
	var round_trip := DotNetWriter.new()
	wire_spec.write(round_trip, Vector3(1.2345, -0.004, 7.0))
	_check("wire_value is the value a receiver reads, to the bit", on_wire == wire_spec.read(DotNetReader.new(round_trip.to_bytes())) and on_wire != Vector3(1.2345, -0.004, 7.0))
	_check("wire_value snaps every range kind to exactly what the wire reads back", _wire_value_parity())


## wire_value snaps the range kinds without buffers; it must agree with a real write and read to
## the bit, in range, out of range, on the edges and at odd widths.
func _wire_value_parity() -> bool:
	var specs: Array[DotNetVar] = [
		DotNetVar.make(&"p", DotNetVar.Type.VECTOR3_POSITION),
		DotNetVar.make(&"v", DotNetVar.Type.VECTOR3_VELOCITY),
		DotNetVar.make(&"r", DotNetVar.Type.VECTOR3_RANGE).range_of(-3.0, 5.5).bits(11),
		DotNetVar.make(&"f", DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 100.0).bits(7),
		DotNetVar.make(&"g", DotNetVar.Type.FLOAT_RANGE).range_of(-1.0, 1.0).bits(1),
		DotNetVar.make(&"h", DotNetVar.Type.FLOAT_RANGE).range_of(-2.0, 2.0).bits(40),
		DotNetVar.make(&"b", DotNetVar.Type.BOOL),
	]
	var rng := RandomNumberGenerator.new()
	rng.seed = 715
	for spec in specs:
		for i in range(400):
			var scale := 10.0 if i < 200 else 3000.0
			var value: Variant
			match spec.type:
				DotNetVar.Type.FLOAT_RANGE:
					value = rng.randf_range(-scale, scale) if i > 3 else [0.0, 100.0, -1.0, 2.0][i]
				DotNetVar.Type.BOOL:
					value = i % 2 == 0
				_:
					value = Vector3(rng.randf_range(-scale, scale), rng.randf_range(-scale, scale), rng.randf_range(-scale, scale))
			var writer := DotNetWriter.new()
			spec.write(writer, value)
			var expected: Variant = spec.read(DotNetReader.new(writer.to_bytes()))
			var got: Variant = spec.wire_value(value)
			if typeof(got) != typeof(expected) or got != expected:
				push_error("wire_value parity: %s %s -> %s, wire reads %s" % [spec.property, value, got, expected])
				return false
	return true


func _test_interpolation() -> void:
	_sections_entered += 1
	print("")
	print("[interpolation]")

	var config := DotNetConfig.new()
	config.adaptive_interpolation = false
	config.interpolation_buffer = 2.0

	var interpolator := DotNetInterpolator.new(config)

	interpolator.push(1, 100, {"position": Vector3(0, 0, 0)})
	interpolator.push(1, 110, {"position": Vector3(10, 0, 0)})

	# The buffer is 2 snapshots, and at 60 ticks / 20 snapshots a snapshot is 3 ticks, so this
	# renders 6 ticks behind: tick 101, a tenth of the way from 100 to 110. (x=7 is between the
	# two snapshots either way, so the check alone would not tell 2 ticks from 6.)
	var midpoint := interpolator.sample(1, 107)
	var sampled: Vector3 = midpoint.get("position", Vector3.ZERO)
	_check(
		"interpolates between snapshots (x=%.1f)" % sampled.x,
		sampled.x > 0.1 and sampled.x < 9.9
	)
	_check(
		"six ticks behind at 60/20, not two (x=%.2f)" % sampled.x,
		absf(sampled.x - 1.0) < 0.01
	)

	# Out-of-order arrivals must still be usable.
	interpolator.push(1, 105, {"position": Vector3(5, 0, 0)})
	var reordered := interpolator.sample(1, 104)
	_check("out-of-order sample used", reordered.has("position"))

	_interpolation_value_at(interpolator)

	# Discrete values must not be blended into states that never existed.
	interpolator.push(2, 100, {"weapon": 1})
	interpolator.push(2, 110, {"weapon": 5})
	var weapon: Variant = interpolator.sample(2, 103).get("weapon", 0)
	_check("discrete values are not blended", weapon == 1 or weapon == 5)

	# Quaternions must slerp, not lerp — a lerp of two rotations is not a rotation.
	var a := Quaternion(Vector3.UP, 0.0)
	var b := Quaternion(Vector3.UP, PI * 0.5)
	interpolator.push(3, 100, {"rotation": a})
	interpolator.push(3, 110, {"rotation": b})
	var blended: Variant = interpolator.sample(3, 105).get("rotation", Quaternion.IDENTITY)
	_check(
		"rotation stays unit length",
		absf((blended as Quaternion).length() - 1.0) < 0.001
	)

	# Extrapolation must be bounded, or a stalled stream sends entities to infinity.
	var far_future := interpolator.sample(1, 100000)
	var extrapolated: Vector3 = far_future.get("position", Vector3.ZERO)
	_check(
		"extrapolation is bounded",
		extrapolated.length() < 1000.0
	)

	_interpolation_notifies()
	_interpolation_settled_skip()

	_check_render_timeline()

	# Adaptive buffering must grow under jitter.
	var adaptive := DotNetInterpolator.new(DotNetConfig.new())
	var initial := adaptive.delay_ticks()
	for i in range(40):
		adaptive.note_arrival()
		# Irregular arrivals.
		await get_tree().process_frame
	_check("adaptive buffer responds", adaptive.delay_ticks() >= initial * 0.5)
	_sections_completed += 1


## The stuck-on-the-spawn-pad report: a browser's first visit stalls for seconds, then draws slow
## frames, and the engine drops every physics step past its cap. A clock handed only the steps'
## deltas never sees the dropped time (docs/timelines.md#time-the-engine-drops).
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
	# (a stall it never saw) catches up at once. Armed: the reported lead's path returned without
	# looking and the clock stayed 30 ticks behind, every command late.
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
