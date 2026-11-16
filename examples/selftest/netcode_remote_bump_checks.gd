extends "netcode_sections_3.gd"

## The remote-bump runs of netcode_demo.gd: a server and a client in one process, snapshots delivered or lost.


## One run of [method _test_remote_bumps]: a server and a client in one process, the client
## [constant BUMP_LEAD] ticks ahead, snapshots delivered at once or lost. Returns the worst and
## mean gap to the server's position and how many ticks the server pushed it.
func _bump_run(speed: float, loss: float, estimate: StringName) -> Dictionary:
	var scope := "bump_%d_%d_%s" % [roundi(speed), roundi(loss * 100.0), estimate]
	var dt := 1.0 / 60.0

	var host := DotNetManager.new()
	host.name = "BumpServer_" + scope
	host.is_server = true
	host.service_scope = StringName(scope + "_server")
	host.local_peer_id = 1
	host.auto_tick = false
	host.config_file = ""
	host.config = DotNetConfig.new()
	add_child(host)

	var guest := DotNetManager.new()
	guest.name = "BumpClient_" + scope
	guest.is_server = false
	guest.service_scope = StringName(scope + "_client")
	guest.local_peer_id = 2
	guest.auto_tick = false
	guest.config_file = ""
	guest.config = DotNetConfig.new()
	guest.config.input_margin_ticks = BUMP_LEAD
	if estimate == &"extrapolated":
		guest.config.remote_extrapolation_sec = BUMP_EXTRAPOLATE_SEC
	add_child(guest)

	var _a := host.setup()
	var _b := guest.setup()

	# The same draws for every estimate at one loss, so they are compared on the same packets.
	var draws := RandomNumberGenerator.new()
	draws.seed = 7001 + roundi(loss * 100.0)
	var wire: Array[PackedByteArray] = []
	host.send_fn = func(_peer: int, payload: PackedByteArray, d: int) -> void:
		if d != DotNetMessage.Delivery.UNRELIABLE:
			return
		if draws.randf() < loss:
			return
		wire.append(payload)

	var _c := host.start()
	var _d := guest.start()
	host.add_peer(2)
	for side: DotNetManager in [host, guest]:
		side.spawner.register_factory(&"pacer", _build_bump.bind(&"pacer", speed))
		side.spawner.register_factory(&"bumper", _build_bump.bind(&"bumper", speed))

	# The bot first, so it is simulated before the player on the server; [method Pacer.at]
	# makes the order not matter anyway.
	var bot_s: DotNetIdentity = host.spawner.spawn(&"pacer", 1, Transform3D.IDENTITY, 0).value
	var me_s: DotNetIdentity = host.spawner.spawn(&"bumper", 2, Transform3D.IDENTITY, 0).value
	var bot_c: DotNetIdentity = guest.spawner.spawn_remote(
		&"pacer", bot_s.net_id, 1, Transform3D.IDENTITY, 0
	).value
	var me_c: DotNetIdentity = guest.spawner.spawn_remote(
		&"bumper", me_s.net_id, 2, Transform3D.IDENTITY, 0
	).value
	var pacer_s := bot_s.behaviours[0] as Pacer
	var pacer_c := bot_c.behaviours[0] as Pacer
	var bumper_s := me_s.behaviours[0] as Bumper
	var bumper_c := me_c.behaviours[0] as Bumper

	var pushed := [0]
	bumper_s.obstacle_at = func(tick: int) -> Vector3:
		var bot: Vector3 = pacer_s.at(tick, dt)[0]
		if absf(bumper_s.position.x - bot.x) < Bumper.APART:
			pushed[0] += 1
		return bot

	_bump_obstacle_estimate(estimate, bumper_c, pacer_s, pacer_c, bot_c, guest, dt)
	var server_at := {}
	var client_at := {}
	_bump_drive(host, guest, bumper_s, bumper_c, wire, server_at, client_at, dt)
	var gaps := _bump_gaps(server_at, client_at)

	_free_managers([host, guest])
	return {"worst": gaps[0], "mean": gaps[1], "contact": pushed[0]}


func _bump_drive(host: DotNetManager, guest: DotNetManager, bumper_s: Bumper, bumper_c: Bumper, wire: Array[PackedByteArray], server_at: Dictionary, client_at: Dictionary, dt: float) -> void:
	for s in range(1, BUMP_TICKS + 1):
		var c := s + BUMP_LEAD
		var input := DemoInput.new()
		input.tick = c
		input.delta = dt
		input.move = Vector2(1.0, 0.0)
		guest.local_inputs().push(input)
		bumper_c._net_apply_input(input, c)
		guest.predictor.predict(guest.registry.predicted(), c, dt)
		client_at[c] = bumper_c.position

		var copy := DemoInput.new()
		copy.tick = c
		copy.delta = dt
		copy.move = input.move
		host.input_buffer_for(2).push(copy)

		host.server_tick(s)
		server_at[s] = bumper_s.position

		for payload in wire:
			guest.clock.tick = c
			var _applied := guest.receive_snapshot(payload)
		wire.clear()
		var _ack := host.receive_ack_payload(2, guest.encode_ack())


func _bump_obstacle_estimate(estimate: StringName, bumper_c: Bumper, pacer_s: Pacer, pacer_c: Pacer, bot_c: DotNetIdentity, guest: DotNetManager, dt: float) -> void:
	match estimate:
		&"oracle":
			bumper_c.obstacle_at = func(tick: int) -> Vector3:
				return pacer_s.at(tick, dt)[0]
		&"heard":
			bumper_c.obstacle_at = func(_tick: int) -> Vector3:
				return pacer_c.heard_position if pacer_c.heard_tick >= 0 else Vector3.INF
		&"ignore":
			bumper_c.obstacle_at = Callable()
		&"line":
			bumper_c.obstacle_at = func(tick: int) -> Vector3:
				var drawn := guest.interpolator.sample(bot_c.net_id, float(tick))
				return drawn.get(&"position", Vector3.INF)
		_:
			# `extrapolated` and `default`: the call a game makes, at the tick being simulated.
			bumper_c.obstacle_at = func(tick: int) -> Vector3:
				var at: Variant = pacer_c.extrapolated_value(&"position", &"velocity", tick)
				return Vector3.INF if at == null else at as Vector3


func _bump_gaps(server_at: Dictionary, client_at: Dictionary) -> Array[float]:
	var worst := 0.0
	var total := 0.0
	var counted := 0
	for tick: int in server_at:
		# The first second is the client finding its feet; nothing in it is about bumps.
		if tick <= 60 or not client_at.has(tick):
			continue
		var gap := (client_at[tick] as Vector3).distance_to(server_at[tick] as Vector3)
		worst = maxf(worst, gap)
		total += gap
		counted += 1
	return [worst, total / maxf(1.0, float(counted))]


func _bump_table() -> Dictionary:
	var table := {}
	for speed in BUMP_SPEEDS:
		for loss in BUMP_LOSSES:
			for estimate in BUMP_ESTIMATES:
				table[[speed, loss, estimate]] = _bump_run(speed, loss, estimate)

	print("  worst / mean gap in m, input lead %d ticks at 60 Hz, 20 snapshots/s" % BUMP_LEAD)
	for speed in BUMP_SPEEDS:
		for loss in BUMP_LOSSES:
			var row := "  bot %.0f m/s, loss %2d%%:" % [speed, roundi(loss * 100.0)]
			for estimate: StringName in [&"heard", &"ignore", &"line", &"extrapolated"]:
				var r: Dictionary = table[[speed, loss, estimate]]
				row += "  %s %.2f / %.3f" % [estimate, float(r["worst"]), float(r["mean"])]
			print(row)
	return table

