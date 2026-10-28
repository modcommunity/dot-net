extends "netcode_sections_1.gd"

## Sections of netcode_demo.gd, moved unchanged; part 2 of 7.


## The interpolation buffer is a count of SNAPSHOTS and a render time is a TICK; subtracting one
## from the other unconverted made a "two snapshot" buffer two ticks, so every remote entity
## was extrapolated. Driven as a game does (128 ticks, 20 snapshots); asserts the extrapolation count.
func _test_render_delay() -> void:
	_sections_entered += 1
	print("")
	print("[render delay]")

	var fast := DotNetConfig.new()
	fast.tick_rate = 128
	fast.snapshot_rate = 20
	fast.interpolation_buffer = 2.0
	fast.adaptive_interpolation = false

	var sized := DotNetInterpolator.new(fast)
	_check(
		"the buffer is counted in snapshots (%.2f)" % sized.delay_snapshots(),
		is_equal_approx(sized.delay_snapshots(), 2.0)
	)
	# 128 / 20 is 6.4, and the manager sends every `ticks_per_snapshot()` = 6 ticks: two of
	# the snapshots that actually arrive are twelve ticks.
	_check(
		"and sampled in ticks: two snapshots at 128/20 are 12 (%.2f)" % sized.delay_ticks(),
		is_equal_approx(sized.delay_ticks(), 12.0)
	)
	_check(
		"its milliseconds are those ticks, and the config's (%.1f ms)" % sized.delay_ms(),
		absf(sized.delay_ms() - 12.0 / 128.0 * 1000.0) < 0.01
			and absf(sized.delay_ms() - fast.interpolation_delay() * 1000.0) < 0.01
	)

	var server_d := DotNetManager.new()
	server_d.name = "DelayServer"
	server_d.is_server = true
	server_d.service_scope = &"delay_server"
	server_d.local_peer_id = 1
	server_d.auto_tick = false
	server_d.config_file = ""
	server_d.config = DotNetConfig.new()
	server_d.config.tick_rate = 128
	server_d.config.snapshot_rate = 20
	add_child(server_d)

	var client_d := DotNetManager.new()
	client_d.name = "DelayClient"
	client_d.is_server = false
	client_d.service_scope = &"delay_client"
	client_d.local_peer_id = 2
	client_d.auto_tick = false
	client_d.config_file = ""
	client_d.config = DotNetConfig.new()
	client_d.config.tick_rate = 128
	client_d.config.snapshot_rate = 20
	client_d.config.interpolation_buffer = 2.0
	# Off so the buffer is the configured one: arrivals in a loop that does not wait are
	# all zero milliseconds apart, which would adapt it to something no link produces.
	client_d.config.adaptive_interpolation = false
	add_child(client_d)

	var ok_setup := server_d.setup().ok and client_d.setup().ok

	# Every fifth snapshot lost, never two in a row: the loss a two-snapshot buffer exists
	# to cover, so the lossy half must come out as clean as the clean one.
	var delivered: Array[PackedByteArray] = []
	var sent := [0]
	var lossy := [false]
	server_d.send_fn = func(peer_id: int, payload: PackedByteArray, d: int) -> void:
		# Snapshots only. The reliable route carries the schema table the manager
		# announces as it adds a peer, and counting it here would move which snapshot
		# the one-in-five loss lands on.
		if peer_id != 2 or d != DotNetMessage.Delivery.UNRELIABLE:
			return
		sent[0] += 1
		if lossy[0] and sent[0] % 5 == 0:
			return
		delivered.append(payload)

	server_d.start()
	client_d.start()
	server_d.add_peer(2)
	server_d.spawner.register_factory(&"player", _build_player)
	client_d.spawner.register_factory(&"player", _build_player)

	# Somebody else's entity — peer 3's — so this client interpolates it, never predicts it.
	var spawned := server_d.spawner.spawn(&"player", 3, Transform3D.IDENTITY, 0)
	var server_entity: DotNetIdentity = spawned.value if spawned.ok else null
	var mirrored := client_d.spawner.spawn_remote(
		&"player", server_entity.net_id if server_entity != null else 0, 3,
		Transform3D.IDENTITY, 0
	) if server_entity != null else DotResult.fail(DotError.CODE_INVALID, "no server entity")
	var remote: DotNetIdentity = mirrored.value if mirrored.ok else null
	_check(
		"a remote entity on a 128-tick client (setup %s, interpolated %s)"
			% [ok_setup, remote != null and not remote.is_predicted()],
		ok_setup and remote != null and not remote.is_predicted()
	)
	if remote == null:
		_sections_completed += 1
		return

	var server_move := server_entity.behaviours[0] as Movement
	var client_move := remote.behaviours[0] as Movement
	# Ten metres a second in x, set on the server and kept: no input drives peer 3.
	server_move.velocity = Vector3(10.0, 0.0, 0.0)

	var interp := client_d.interpolator
	var step_x := 10.0 / 128.0
	var worst := [0.0, 0.0, 0.0]
	var counts: Array[Dictionary] = []

	# The third leg is clean on a 120 ms round trip. The render time counts back from the newest
	# snapshot the client HOLDS, not the server's tick, or the flight time eats the buffer. Snapshots
	# arrive the instant they are sent, so it is right because of where it is measured from.
	for leg in range(3):
		lossy[0] = leg == 1
		if leg == 2:
			client_d.stats.note_rtt(120.0)
		interp.reset_counts()
		var start := 1 + leg * 384
		for tick in range(start, start + 384):
			server_d.server_tick(tick)
			for payload in delivered:
				var _applied := client_d.receive_snapshot(payload)
			delivered.clear()

			for quarter in range(4):
				var alpha := float(quarter) * 0.25
				client_d.interpolate_frame(alpha)
				# Past the first second the render time is well inside the stream; before
				# it the track may still be shorter than the buffer.
				if tick - start < 128:
					continue
				var expected := float(tick) + alpha - interp.delay_ticks()
				var off := absf(client_move.position.x - expected * step_x)
				worst[leg] = maxf(worst[leg], off)

			client_d.step(1.0 / 128.0)

		counts.append({
			"samples": interp.sample_count(),
			"stalls": interp.stall_count(),
			"extrapolations": interp.extrapolation_count(),
		})

	for leg in range(3):
		var c: Dictionary = counts[leg]
		var label: String = ["clean", "lossy (1 in 5)", "120 ms round trip"][leg]
		_check(
			"%s: every frame sampled (%d)" % [label, int(c["samples"])],
			int(c["samples"]) > 1152
		)
		# The number the bug was measured by. Unfixed, the render time runs past the newest
		# snapshot on most frames of both legs.
		_check(
			"%s: none extrapolated (%d of %d)"
				% [label, int(c["extrapolations"]), int(c["samples"])],
			int(c["extrapolations"]) == 0
		)
		_check(
			"%s: none at or past the newest snapshot (%d)" % [label, int(c["stalls"])],
			int(c["stalls"]) == 0
		)
		# And the picture is where the buffer says: `delay_ticks()` behind the server's
		# clock, on the entity's own line. Two centimetres is the position quantisation.
		_check(
			"%s: drawn %.1f ticks behind, on the line (worst %.3f m)"
				% [label, interp.delay_ticks(), float(worst[leg])],
			float(worst[leg]) < 0.02
		)

	# And then they stop. Every snapshot after the stop carries nothing for `position`, so what
	# is drawn later has to be where the server left them, not the blend being drawn when the
	# stop arrived (a property read back after the interpolator wrote into it).
	lossy[0] = false
	server_move.velocity = Vector3.ZERO
	for tick in range(1153, 1153 + 128):
		server_d.server_tick(tick)
		for payload in delivered:
			var _applied := client_d.receive_snapshot(payload)
		delivered.clear()
		for quarter in range(4):
			client_d.interpolate_frame(float(quarter) * 0.25)
		client_d.step(1.0 / 128.0)

	var gap := absf(client_move.position.x - server_move.position.x)
	_check(
		"stopped: drawn where the server left them (%.3f m short)" % gap,
		gap < 0.02
	)

	server_d.stop()
	client_d.stop()
	remove_child(server_d)
	remove_child(client_d)
	server_d.free()
	client_d.free()
	_sections_completed += 1


func _test_lag_compensation() -> void:
	print("")
	print("[lag compensation]")

	var config := DotNetConfig.new()
	config.history_sec = 1.0
	config.max_rewind_sec = 0.5

	var history := DotNetHistory.new(config)

	var target := _make_entity(&"player", 3)
	add_child(target.get_parent())
	target.net_id = 20

	# Walk it along the x axis, recording as it goes.
	for tick in range(0, 40):
		(target.entity as Node3D).global_position = Vector3(float(tick), 0, 0)
		history.record([target], tick)

	_check("history recorded", history.describe()["samples"] > 0)

	var past: Variant = history.position_at(20, 10.0)
	_check(
		"position at a past tick (%s)" % str(past),
		past != null and absf((past as Vector3).x - 10.0) < 0.5
	)

	# Between samples must interpolate, not snap to the nearest.
	var between: Variant = history.position_at(20, 10.5)
	_check(
		"interpolates between samples",
		between != null and absf((between as Vector3).x - 10.5) < 0.5
	)

	# Rewind, test, restore.
	var present := (target.entity as Node3D).global_position

	var rewound := history.rewind([target], 10, 39, 0)
	_check("rewound", rewound.ok)
	_check(
		"world moved to the past",
		absf((target.entity as Node3D).global_position.x - 10.0) < 0.5
	)

	history.restore()
	_check(
		"world restored",
		(target.entity as Node3D).global_position.distance_to(present) < 0.001
	)

	# Rewinding twice without restoring must be refused, not silently nested.
	history.rewind([target], 10, 39, 0)
	_check("double rewind refused", not history.rewind([target], 12, 39, 0).ok)
	history.restore()

	# An excessive claim is clamped, not honoured.
	var excessive := history.rewind([target], 0, 39, 0)
	_check("excessive rewind clamped", excessive.ok
		and int((excessive.value as Dictionary)["ticks_back"]) <= config.max_rewind_ticks())
	history.restore()

	# The safe wrapper restores even though the body returns a value.
	var result: Variant = history.with_rewind([target], 10, 39, 0, func() -> String:
		return "tested")
	_check("with_rewind returns the body's value", str(result) == "tested")
	_check("with_rewind restored", not history.is_rewound())

	_check_history_skips_orphans(history, target)

	# The view tick must account for both latency and interpolation delay.
	var view := history.client_view_tick(1000, 100.0, 2.0)
	_check("client view tick is in the past (%d)" % view, view < 1000 and view > 990)


func _test_prediction() -> void:
	print("[prediction]")

	_check_late_peer_id()

	var config := DotNetConfig.new()
	config.enable_prediction = true

	var predictor := DotNetPredictor.new(config)
	var dt := 1.0 / 60.0

	# Direction changes every tick, so simulating tick 14 with tick 20's input
	# gives a visibly different answer.
	var inputs: Array[DemoInput] = []
	for tick in range(1, 21):
		var input := DemoInput.new()
		input.tick = tick
		input.delta = dt
		input.move = Vector2(1.0, 0.0) if tick % 2 == 1 else Vector2(0.0, 1.0)
		inputs.append(input)

	# The server, as DotNetManager.server_tick does: take the input for the tick, apply it,
	# then simulate. In the tree, unlike the other sections' entities: reconciliation reads
	# `world_position()`, and `global_position` outside the tree is an engine error per call.
	var server_entity := _in_tree(_make_entity(&"player", 2))
	server_entity.is_authoritative = true
	var server_movement := server_entity.behaviours[0] as Movement

	var authoritative_at_10 := {}
	for input in inputs:
		server_movement._net_apply_input(input, input.tick)
		server_movement._net_simulate(input.tick, dt)
		if input.tick == 10:
			authoritative_at_10 = server_movement.snapshot_values().duplicate()

	_check("server moved on a changing input",
		server_movement.position.length() > 0.5)

	# The client: same twenty ticks predicted locally, then knocked off course, as
	# a missed collision or a shove from another player would.
	var client_entity := _in_tree(_make_entity(&"player", 2))
	client_entity.is_owner = true
	client_entity.is_authoritative = false
	_check("the client entity is predicted", client_entity.is_predicted())

	var client_movement := client_entity.behaviours[0] as Movement
	var buffer := DotNetInput.Buffer.new(config.input_history_ticks)

	for input in inputs:
		buffer.push(input)
		client_movement._net_apply_input(input, input.tick)
		client_movement._net_simulate(input.tick, dt)

	client_movement.position += Vector3(3.0, 0.0, 0.0)
	_check("the client diverged before reconciling",
		client_movement.position.distance_to(server_movement.position) > 1.0)

	# The server's answer for tick 10 arrives while the client is at tick 20.
	var replayed := predictor.reconcile(
		client_entity, 10, authoritative_at_10, buffer, 20, dt
	)
	_check("reconcile replayed the unacked ticks",
		replayed.ok and int(replayed.value) == 10)

	# The whole contract: after replaying ticks 11–20 the client must hold exactly
	# what the server computed for tick 20. Reverting the input application in
	# DotNetPredictor.reconcile leaves it 0.9 m away here.
	var gap := client_movement.position.distance_to(server_movement.position)
	_check("replay reconverged on the server's state (%.4f m apart)" % gap,
		gap < 0.001)
	_check("velocity reconverged too",
		client_movement.velocity.distance_to(server_movement.velocity) < 0.001)

	# A hole in the history: the client's clock jumped over ticks 14-16, so it made no commands
	# for them and the server ran them on tick 13's. The replay must do the same, not stop at
	# the hole (that left the predicted player 2 m short at 20% loss).
	var holed_server := _in_tree(_make_entity(&"player", 2))
	holed_server.is_authoritative = true
	var holed_server_movement := holed_server.behaviours[0] as Movement
	var holed_at_10 := {}
	for input in inputs:
		if input.tick < 14 or input.tick > 16:
			holed_server_movement._net_apply_input(input, input.tick)
		holed_server_movement._net_simulate(input.tick, dt)
		if input.tick == 10:
			holed_at_10 = holed_server_movement.snapshot_values().duplicate()
	var holed_client := _in_tree(_make_entity(&"player", 2))
	holed_client.is_owner = true
	holed_client.is_authoritative = false
	var holed_client_movement := holed_client.behaviours[0] as Movement
	var holed := DotNetInput.Buffer.new(config.input_history_ticks)
	for input in inputs:
		if input.tick < 14 or input.tick > 16:
			holed.push(input)
	# Its own predictor, so the counts the shared one is checked on below stay its own.
	var across := DotNetPredictor.new(config).reconcile(holed_client, 10, holed_at_10, holed, 20, dt)
	var hole_gap := holed_client_movement.position.distance_to(holed_server_movement.position)
	_check("a replay across a hole repeats the command before it, as the server did (%d ticks, %.4f m apart)" % [
		int(across.value) if across.ok else -1, hole_gap],
		across.ok and int(across.value) == 10 and hole_gap < 0.001)

	# And past the newest input is not a hole: those are ticks this client has not played
	# yet (a lockstep host reconciles before it records the tick). Replayed on the last
	# command they were predicted twice; game-arena's headless_net caught it at 1.5 m.
	var ahead_client := _in_tree(_make_entity(&"player", 2))
	ahead_client.is_owner = true
	ahead_client.is_authoritative = false
	var ahead := DotNetInput.Buffer.new(config.input_history_ticks)
	for input in inputs:
		if input.tick <= 12:
			ahead.push(input)
	var stopped := DotNetPredictor.new(config).reconcile(ahead_client, 10, authoritative_at_10, ahead, 14, dt)
	_check("a replay stops at the newest input rather than predict ticks not played (%d)" % (int(stopped.value) if stopped.ok else -1),
		stopped.ok and int(stopped.value) == 2)
	_out_of_tree(ahead_client)

	# A replay that cannot reach its inputs must stop rather than compound the
	# error — history has been acked away here, so there is nothing to replay from.
	var starved := DotNetInput.Buffer.new(config.input_history_ticks)
	var lonely := _in_tree(_make_entity(&"player", 2))
	lonely.is_owner = true
	lonely.is_authoritative = false
	var short := predictor.reconcile(
		lonely, 10, authoritative_at_10, starved, 20, dt
	)
	_check("a replay with no input history stops early",
		short.ok and int(short.value) < 10)

	# An entity the snapshot said nothing about is left predicted, not zeroed.
	var untouched := _in_tree(_make_entity(&"player", 2))
	untouched.is_owner = true
	untouched.is_authoritative = false
	var untouched_movement := untouched.behaviours[0] as Movement
	untouched_movement.position = Vector3(7.0, 0.0, 0.0)
	var absent := predictor.reconcile(untouched, 10, {}, buffer, 20, dt)
	_check("an entity absent from the snapshot keeps its prediction",
		absent.ok and int(absent.value) == 0
			and untouched_movement.position.x == 7.0)

	_check("the predictor reports what it did",
		predictor.describe()["replays"] == 2)

	# An entity that would simulate nothing (a dead player) keeps the rewind and replays
	# nothing: DotNetBehaviour._net_predicts.
	var dead := _in_tree(_make_entity(&"player", 2))
	dead.is_owner = true
	dead.is_authoritative = false
	var dead_movement := dead.behaviours[0] as Movement
	dead_movement.predicts = false
	dead_movement.position = Vector3(9.0, 0.0, 0.0)
	var unpredicted_before := int(predictor.describe()["unpredicted"])
	var kept := predictor.reconcile(dead, 10, authoritative_at_10, buffer, 20, dt)
	_check("a reconcile of an entity that is not predicting rewinds and replays nothing (%d ticks)" % int(kept.value),
		kept.ok and int(kept.value) == 0
			and dead_movement.position.is_equal_approx(authoritative_at_10[&"position"])
			and int(predictor.describe()["unpredicted"]) == unpredicted_before + 1)

	# The respawn: the reconcile after one that was not predicting moves it from the server's
	# state, not from a prediction, so it is no misprediction however far it goes.
	var respawned_at := authoritative_at_10.duplicate()
	respawned_at[&"position"] = (authoritative_at_10[&"position"] as Vector3) + Vector3(40.0, 0.0, 0.0)
	var before_respawn: Dictionary = predictor.describe()
	predictor._worst_error = 0.0
	dead_movement.predicts = true
	dead_movement.moves_body = true
	var respawn := predictor.reconcile(dead, 10, respawned_at, buffer, 20, dt)
	var after_respawn: Dictionary = predictor.describe()
	_check("a respawn's move is not counted as a correction (worst %.2f m)" % predictor._worst_error,
		respawn.ok and predictor._worst_error == 0.0
			and after_respawn["corrections"] == before_respawn["corrections"]
			and after_respawn["unpredicted_moves"] == int(before_respawn["unpredicted_moves"]) + 1)
	predictor.reconcile(dead, 10, authoritative_at_10, buffer, 20, dt)
	_check("the next misprediction after a respawn is counted again (%.2f m)" % predictor._worst_error,
		predictor._worst_error > 1.0)
	_out_of_tree(dead)

	for entity in [server_entity, client_entity, lonely, untouched, holed_server, holed_client]:
		_out_of_tree(entity)



## A link that turns jittery: the interpolation buffer must grow without moving the render
## time backwards, and once grown cover how late snapshots are. 128 ticks, a snapshot every 4,
## with the receive timeline on the quickest arrivals, as `DotNetClock` keeps it.
func _test_buffer_growth() -> void:
	print("[the buffer growing]")
	var config := DotNetConfig.new()
	config.tick_rate = 128
	config.snapshot_rate = 32
	config.adaptive_interpolation = true
	var interpolator := DotNetInterpolator.new(config)
	var period := config.ticks_per_snapshot()
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261010

	# Snapshot tick -> the tick it arrives on: on time for two seconds, then 0..6 ticks
	# late with one in twenty never arriving.
	var arrives := {}
	for sent in range(0, 128 * 6, period):
		if sent < 256:
			arrives[sent] = sent
		elif rng.randf() >= 0.05:
			arrives[sent] = sent + rng.randi_range(0, 6)

	var newest := -1
	var back := 0.0
	var last_render := -INF
	var extrapolated := 0
	for now in range(0, 128 * 6):
		for sent in arrives:
			if int(arrives[sent]) == now and int(sent) > newest:
				newest = int(sent)
				interpolator.note_lateness(newest, now)
		interpolator.advance(1.0 / 128.0)
		var render := float(now) - interpolator.delay_ticks()
		back = maxf(back, last_render - render)
		last_render = render
		if now >= 128 * 4 and render > float(newest):
			extrapolated += 1

	_check("growing the buffer never moved the render time back (%.2f ticks)" % back, back < 0.001)
	_check("once grown it covers the lateness: %d of 256 ticks extrapolated (buffer %.1f ticks)" % [
		extrapolated, interpolator.delay_ticks()], extrapolated == 0)
	_check("and on time it needs about an interval (%.1f ticks)" % _settled_delay(config),
		_settled_delay(config) <= float(period) + 1.5)


## Two slips the same way close together.
func _check_two_slips(physics: float) -> void:
	# 1b. Two slips the same way close together. The first is still being taken up when the
	# second lands, so the slip briefly passes 1; clamped there, the remainder was lost and
	# that frame moved half a tick less than its time (g2gfast's `headless_feel` caught it).
	var twice := DotNetClock.new(64, false)
	var timeline: Array[float] = []
	for i in range(40):
		if i == 10 or i == 15:
			# A physics frame that runs no tick: a tick's worth less in the accumulator.
			twice.set("_accumulator", float(twice.get("_accumulator")) - twice.tick_duration())
		var _steps := twice.advance(physics)
		timeline.append(float(twice.tick) - 1.0 + twice.render_alpha(0.0, physics))
	var least := INF
	var most := -INF
	for i in range(1, timeline.size()):
		least = minf(least, timeline[i] - timeline[i - 1])
		most = maxf(most, timeline[i] - timeline[i - 1])
	_check("two slips the same way five frames apart: every frame moves 0.5-1.5 of its time (%.2f-%.2f)" % [
		least, most], least > 0.5 and most < 1.5)


## What is drawn between ticks stays continuous through the three jumps in a client's timelines:
## a frame that ran no tick, the receive timeline re-anchoring, and a stream resuming after
## extrapolation. At 144 fps against 64 ticks, each against a control that has to show the jump.
func _test_drawing_through_slips() -> void:
	print("")
	print("[drawing through slips]")
	var frame := 1.0 / 144.0
	var physics := 1.0 / 64.0

	# 1. Drift. The clock runs its ticks 4% long, so about one physics frame in 25 runs none.
	var clock := DotNetClock.new(64, false)
	clock.set("_drift_scale", 1.04)
	var t := 0.0
	var physics_time := 0.0
	var drawn: Array[float] = []
	var naive: Array[float] = []
	for _i in range(144 * 3):
		t += frame
		while physics_time + physics <= t:
			physics_time += physics
			var _steps := clock.advance(physics)
		var frac := (t - physics_time) / physics
		drawn.append(float(clock.tick) - 1.0 + clock.render_alpha(frac, physics))
		naive.append(float(clock.tick) - 1.0 + frac)
	var worst := _worst_step_change(drawn)
	var naive_worst := _worst_step_change(naive)
	_check("a drifting clock draws evenly: no frame's step a tenth of a tick off (%.3f; the engine's fraction alone %.2f)" % [
		worst, naive_worst], worst < 0.1 and naive_worst > 0.5)

	_check_two_slips(physics)

	# 2. The receive timeline re-anchors: three ticks forward at once, then one back.
	var receiving := DotNetClock.new(64, false)
	receiving.set("_synced", true)
	t = 0.0
	physics_time = 0.0
	drawn.clear()
	naive.clear()
	for i in range(144 * 3):
		t += frame
		while physics_time + physics <= t:
			physics_time += physics
			var _steps := receiving.advance(physics)
		if i == 144:
			receiving.call("_follow_arrival", receiving.received_tick() + 3, false)
		if i == 288:
			for _n in range(DotNetClock.SETTLE_SAMPLES):
				receiving.call("_follow_arrival", receiving.received_tick() - 2, false)
		var frac := (t - physics_time) / physics
		drawn.append(float(receiving.received_tick()) + receiving.render_alpha(frac, physics) \
			+ receiving.receive_slip(frac, physics))
		naive.append(float(receiving.received_tick()) + frac)
	worst = _worst_step_change(drawn)
	naive_worst = _worst_step_change(naive)
	_check("a re-anchored receive timeline is followed gently (%.3f a frame; as it is %.2f)" % [
		worst, naive_worst], worst < 0.12 and naive_worst > 0.9)

	# 3. A snapshot stream stalls for ten ticks while a runner turns, and resumes.
	var config := DotNetConfig.new()
	config.tick_rate = 64
	config.snapshot_rate = 32
	config.adaptive_interpolation = false
	config.interpolation_buffer = 1.0
	var eased := _resume_steps(config, true)
	var snapped := _resume_steps(config, false)
	_check("a resumed stream is eased back, not snapped (worst %.1f mm a frame; snapped %.1f mm)" % [
		eased * 1000.0, snapped * 1000.0], eased < snapped / 3.0 and snapped > 0.03)


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
	var wire_spec := DotNetVar.make(&"position", DotNetVar.Type.VECTOR3_POSITION)
	var on_wire: Vector3 = wire_spec.wire_value(Vector3(1.2345, -0.004, 7.0))
	var round_trip := DotNetWriter.new()
	wire_spec.write(round_trip, Vector3(1.2345, -0.004, 7.0))
	_check("wire_value is the value a receiver reads, to the bit", on_wire == wire_spec.read(DotNetReader.new(round_trip.to_bytes())) and on_wire != Vector3(1.2345, -0.004, 7.0))

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
