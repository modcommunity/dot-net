extends "netcode_sections_6.gd"

## Sections of netcode_demo.gd, moved unchanged; part 7 of 7.


## A stall before any median, and a stall inside a live lead history.
func _cover_stalls_cold_and_live() -> void:
	# Cold start: a stall before any untouched sample leaves no median to hold near, and the
	# first real round trips must not be pinned at 250 ms.
	var cold := DotNetClock.new(64)
	cold.follow_engine_time = false
	var frame := 1
	var wall := 15625
	var steps := 1
	cold.note_engine_frame(frame, wall, steps, 64, 16)
	frame += 1
	wall += 2000000
	steps += 16
	cold.note_engine_frame(frame, wall, steps, 64, 16)
	cold.sync_from_server(1000, 600.0)
	for _i in 8:
		cold.sync_from_server(cold.received_tick() + 1, 600.0)
	print("    cold start stall: rtt %d ms, %d held" % [int(cold.rtt_ms()), cold.rtt_rejected()])
	_check("a stall before any median does not pin a 600 ms link (%d ms)" % int(cold.rtt_ms()),
		cold.rtt_ms() > 500.0)

	# A stall inside a live lead history, then the link's real round trip again.
	var live := DotNetClock.new(64)
	live.follow_engine_time = false
	live.sync_from_server(1000, 88.0)
	frame = 0
	wall = 0
	steps = 0
	for _i in 120:
		frame += 1
		wall += 15625
		steps += 1
		live.note_engine_frame(frame, wall, steps, 64, 16)
		var _tl := live.advance(1.0 / 64.0)
		live.sync_from_server(live.received_tick() + 1, 88.0)
		live.note_input_lead(live.tick - 3, 4)
	var live_before := live.is_lead_reported()
	frame += 1
	wall += 3000000
	steps += 192
	live.note_engine_frame(frame, wall, steps, 64, 16)
	var _tl2 := live.advance(1.0 / 64.0)
	for _i in 4:
		live.sync_from_server(live.received_tick() + 1, 3088.0)
	var held_in_stall := live.rtt_rejected()
	var snaps_in_stall := int(live.describe()["snaps"])
	var rtt_in_stall := live.rtt_ms()
	for _i in 120:
		frame += 1
		wall += 15625
		steps += 1
		live.note_engine_frame(frame, wall, steps, 64, 16)
		var _tl3 := live.advance(1.0 / 64.0)
		live.sync_from_server(live.received_tick() + 1, 88.0)
		live.note_input_lead(live.tick - 3, 4)
	print("    live lead: reported %s, held %d, snaps %d, rtt in stall %d, after %d ms, lead %d" % [
		live_before, held_in_stall, snaps_in_stall, int(rtt_in_stall), int(live.rtt_ms()),
		live.tick - live.received_tick()])
	_check("a stall in a live lead history is held and does not snap (%d held, %d snaps)" % [
		held_in_stall, snaps_in_stall], live_before and held_in_stall == 4 and snaps_in_stall == 0)
	_check("the estimate stays near the link inside the stall (%d ms)" % int(rtt_in_stall),
		rtt_in_stall < 400.0)
	_check("and returns to the real round trip after it (%d ms)" % int(live.rtt_ms()),
		absf(live.rtt_ms() - 88.0) < 20.0 and int(live.describe()["snaps"]) == 0)


## The Zombie Zone web measurement: the clock synced, then a loading cover held
## seconds of stalls, and when it dropped the clock snapped and the input lead jumped. A stall
## after sync must leave no snap and a lead within bounds.
func _test_cover_stalls() -> void:
	_sections_entered += 1
	print("")
	print("[stalls under a loading cover after the clock synced]")
	# Armed: at 128 the stall is 640 ticks, past the 512 the lead history holds, and the clock
	# jumped 640 ahead (lead 651) and snapped back a second later.
	for rate in [60, 64, 128]:
		var seen := {"lead_max": -999, "lead_min": 999}
		var watch := func(clock: DotNetClock, ms: float) -> void:
			if clock.is_synced():
				var lead := clock.tick - clock.received_tick()
				seen["lead_max"] = maxi(int(seen["lead_max"]), lead)
				seen["lead_min"] = mini(int(seen["lead_min"]), lead)
		var r: Dictionary = _first_visit(rate, 16 if rate == 64 else 8, [1.7, 3.3, 3.5, 2.9, 5.0], true, 6.0, 1000.0 / 30.0, false, 1000.0 / 60.0, watch)
		print("    %d ticks: %d snaps, %d floors, lead %d..%d, %d late of %d, %d ms dropped" % [
			rate, int(r["snaps"]), int(r["floors"]), int(seen["lead_min"]), int(seen["lead_max"]),
			int(r["late"]), int(r["ticks"]), int(r["lost_ms"])])
		_check("%d ticks: no snap after stalls (%d)" % [rate, int(r["snaps"])], int(r["snaps"]) == 0)
		_check("%d ticks: lead stays within 0.5 s (%d)" % [rate, int(seen["lead_max"])],
			int(seen["lead_max"]) <= rate / 2)

	_cover_stalls_ping()
	_cover_stalls_cold_and_live()
	_sections_completed += 1


func _test_join_hitch() -> void:
	_sections_entered += 1
	print("")
	print("[a short hitch after joining, and a clock pushed too far ahead]")
	var slack := DotNetConfig.new().input_lead_slack_ticks
	# The most ticks early any command reached the server in [from, to) ms after the hitch.
	var most_early := func(r: Dictionary, from: float, to: float) -> int:
		var most := -999
		for a in r["arrivals"]:
			var v: Vector2 = a
			if v.x >= from and v.x < to:
				most = maxi(most, int(v.y))
		return most

	# A load hitch shorter than the engine's step cap drops no time, so nothing is credited, and the
	# commands made after it reached the server that much early. Steered by those reports a client
	# at 128 ran 18 ticks early after a 0.3 s hitch and gave them back slowly.
	var short: Dictionary = _first_visit(128, 8, [0.3], true, 3.0, 1000.0 / 240.0, false, 1000.0 / 240.0)
	var early: int = most_early.call(short, 1000.0, 3000.0)
	print("    128 ticks, 0.3 s hitch: at most %d early after 1 s, %d late" % [early, int(short["late"])])
	_check("a 0.3 s hitch at 128 leaves commands at most slack+2 early within 1 s (%d, slack %d)"
			% [early, slack], early <= slack + 2 and early >= 0)
	_check("and none late (%d)" % int(short["late"]), int(short["late"]) == 0)

	# The same hitch at 60 is past the step cap, so the dropped part is credited too. The lead
	# still rises for a second (9 early), so this asks only that it is back within the slack
	# by 2.5 s.
	var over: Dictionary = _first_visit(60, 8, [0.3], true, 3.0, 1000.0 / 60.0, false, 1000.0 / 60.0)
	var later: int = most_early.call(over, 2500.0, 3000.0)
	print("    60 ticks, 0.3 s hitch: at most %d early 1-3 s on, %d at 2.5 s, %d late" % [
			int(most_early.call(over, 1000.0, 3000.0)), later, int(over["late"])])
	_check("a 0.3 s hitch at 60 is back within slack+2 by 2.5 s (%d)" % later,
		later <= slack + 2 and later >= 0)
	_check("and none late (%d)" % int(over["late"]), int(over["late"]) == 0)

	# Pushed 100 ticks ahead at 128 (0.78 s, short of a snap): slowed at the drift rate, 6.4
	# ticks a second, it took 16 s to come back.
	var pushed := {"done": false}
	var nudge := func(clock: DotNetClock, ms: float) -> void:
		if ms >= 0.0 and not pushed["done"]:
			pushed["done"] = true
			clock.tick += 100
	var p: Dictionary = _first_visit(128, 8, [], true, 10.0, 1000.0 / 240.0, false, 1000.0 / 240.0, nudge)
	var back: int = most_early.call(p, 9000.0, 10000.0)
	print("    128 ticks pushed 100 ahead: at most %d early 9-10 s on, %d late, %d snaps" % [
			back, int(p["late"]), int(p["snaps"])])
	_check("a clock pushed 100 ticks ahead is back within slack+2 in 9 s (%d)" % back,
		back <= slack + 2 and back >= 0)
	_check("and none late on the way, no snap (%d, %d)" % [int(p["late"]), int(p["snaps"])],
		int(p["late"]) == 0 and int(p["snaps"]) == 0)
	_sections_completed += 1


func _adopt_tick_rate_checks() -> void:
	# adopt_tick_rate: raises the cap to a quarter second of ticks, never lowers a higher one.
	var rate_was := Engine.physics_ticks_per_second
	Engine.max_physics_steps_per_frame = 8
	DotNetClock.adopt_tick_rate(128)
	_check("adopt_tick_rate(128) sets the rate and a 32 step cap (%d Hz, %d)" % [
		Engine.physics_ticks_per_second, Engine.max_physics_steps_per_frame],
		Engine.physics_ticks_per_second == 128 and Engine.max_physics_steps_per_frame == 32)
	Engine.max_physics_steps_per_frame = 100
	DotNetClock.adopt_tick_rate(128)
	_check("and never lowers a higher cap (%d)" % Engine.max_physics_steps_per_frame,
		Engine.max_physics_steps_per_frame == 100)
	Engine.max_physics_steps_per_frame = 8
	DotNetClock.adopt_tick_rate(60)
	_check("60 Hz needs 15 steps (%d)" % Engine.max_physics_steps_per_frame,
		Engine.max_physics_steps_per_frame == 15)
	DotNetClock.adopt_tick_rate(0)
	_check("a rate of 0 changes nothing (%d Hz)" % Engine.physics_ticks_per_second,
		Engine.physics_ticks_per_second == 60)
	Engine.physics_ticks_per_second = rate_was


## The same, through the engine itself: a clock advanced once a physics step reads the engine's
## numbers on its own and credits a stall, credits nothing while a server's clock runs in the
## same process (it stalled too), and a clock advanced by hand never reads them.
func _test_dropped_time_live() -> void:
	_sections_entered += 1
	print("")
	print("[time the engine drops, through the engine]")

	var cap_was := Engine.max_physics_steps_per_frame
	Engine.max_physics_steps_per_frame = 8
	var rate := Engine.physics_ticks_per_second
	# The sections before free their managers at the end of the frame.
	await get_tree().process_frame
	var alone := not DotNetClock.server_in_process()

	# Half a second inside one physics step, while [param clock] is advanced once a step: the
	# engine runs its cap of steps after it and drops the rest. Returns the ticks the clock ran
	# from the stall on, and the wall time that passed, in ticks.
	var stall := func(clock: DotNetClock) -> Vector2:
		clock.sync_from_server(1000, 40.0)
		for _i in 10:
			await get_tree().physics_frame
			var _a := clock.advance(1.0 / float(rate))
		var before := clock.tick
		var wall := Time.get_ticks_usec()
		OS.delay_msec(500)
		for _i in 40:
			await get_tree().physics_frame
			var _a := clock.advance(1.0 / float(rate))
		return Vector2(clock.tick - before, float(Time.get_ticks_usec() - wall) / 1000000.0 * float(rate))

	var remote := DotNetClock.new(rate)
	var remote_ran: Vector2 = await stall.call(remote)
	# The server's clock in this process, alive through the second stall.
	var beside := DotNetClock.new(rate, true)
	var listen := DotNetClock.new(rate)
	var listen_ran: Vector2 = await stall.call(listen)
	var server_seen := DotNetClock.server_in_process()
	beside = null
	var by_hand := DotNetClock.new(rate)
	by_hand.sync_from_server(1000, 40.0)
	OS.delay_msec(200)
	for _i in 30:
		var _h := by_hand.advance(1.0 / 60.0)
	print("    no server in this process: %d ms credited, %d ticks for %.0f of wall time" % [
		int(remote.lost_seconds() * 1000.0), int(remote_ran.x), remote_ran.y])
	print("    a server in this process: %d ms credited, %d ticks for %.0f; by hand: %d ms (engine %d Hz, cap %d)" % [
		int(listen.lost_seconds() * 1000.0), int(listen_ran.x), listen_ran.y,
		int(by_hand.lost_seconds() * 1000.0), rate, Engine.max_physics_steps_per_frame])
	# Armed: following nothing, 0 ms credited and 40 ticks for 61 of wall time. Counting the
	# reference frame's own steps (it was a frame catching up) credited 157 ms and ran 49.
	_check("with no server in this process, the half second the engine dropped is credited (%d ms)" % int(remote.lost_seconds() * 1000.0),
		alone and remote.lost_seconds() >= 0.25)
	_check("and the clock keeps up with the wall clock through it (%d ticks for %.0f)" % [int(remote_ran.x), remote_ran.y],
		remote_ran.x >= remote_ran.y - 6.0)
	# Armed: following the engine beside a server (v0.1.8), 318 ms credited and 59 ticks run, the
	# stall ahead of a server that never ran it (dot-server-deploy's lookatme_client).
	_check("with a server's clock in this process, which stalled too, nothing is credited (%d ms)" % int(listen.lost_seconds() * 1000.0),
		server_seen and listen.lost_seconds() == 0.0)
	_check("a clock advanced by hand credits nothing (%d ms)" % int(by_hand.lost_seconds() * 1000.0),
		by_hand.lost_seconds() == 0.0)
	_check("and the count of servers in this process goes back down (%s)" % DotNetClock.server_in_process(),
		alone and not DotNetClock.server_in_process())
	_adopt_tick_rate_checks()
	Engine.max_physics_steps_per_frame = cap_was
	_sections_completed += 1


func _test_integration() -> void:
	_sections_entered += 1
	print("")
	print("[integration]")

	server = _bare_manager(true, 1)
	server.name = "Server"
	server.config.snapshot_rate = 20
	server.config.tick_rate = 60
	add_child(server)

	client = _bare_manager(false, 2)
	client.name = "Client"
	client.config.snapshot_rate = 20
	client.config.tick_rate = 60
	add_child(client)

	_check("server setup", server.setup().ok)
	_check("client setup", client.setup().ok)

	# The loopback: the server's payloads land in the client, with loss.
	server.send_fn = func(peer_id: int, payload: PackedByteArray, d: int) -> void:
		if peer_id != 2 and peer_id != 0:
			return
		# The reliable route: the schema table, which the client decodes as a message.
		# Never dropped -- a reliable channel is one that does not lose things.
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var into := client.receive(payload, 1)
			_check("the client adopts the server's schema table", into.ok)
			return
		_drop_next += 1
		# Drop one packet in five, so interpolation and loss handling are exercised
		# rather than assumed.
		if _drop_next % 5 == 0:
			return
		_in_flight.append({"payload": payload})

	server.start()
	client.start()

	server.add_peer(2)

	# The same prefab on both sides, built in code so the demo needs no scene files.
	server.spawner.register_factory(&"player", _build_player)
	client.spawner.register_factory(&"player", _build_player)

	var spawned := server.spawner.spawn(&"player", 2, Transform3D.IDENTITY, 0)
	_check("server spawned", spawned.ok)

	var server_entity: DotNetIdentity = spawned.value
	var mirrored := client.spawner.spawn_remote(
		&"player", server_entity.net_id, 2, Transform3D.IDENTITY, 0
	)
	_check("client mirrored the spawn", mirrored.ok)

	var client_entity: DotNetIdentity = mirrored.value
	_check("ids match", client_entity.net_id == server_entity.net_id)
	_check("client knows it owns it", client_entity.is_owner)

	# Drive the server for a second of simulated time, feeding it input.
	var server_movement := server_entity.behaviours[0] as Movement

	for tick in range(1, 61):
		var input := DemoInput.new()
		input.tick = tick
		input.delta = 1.0 / 60.0
		input.move = Vector2(1.0, 0.0)

		server.input_buffer_for(2).push(input)
		client.local_inputs().push(input)

		server.server_tick(tick)

		# Deliver whatever the loopback is holding.
		for entry in _in_flight:
			client.receive_snapshot(entry["payload"])
		_in_flight.clear()

	_check(
		"server simulated movement (x=%.2f)" % server_movement.position.x,
		server_movement.position.x > 5.0
	)

	var client_movement := client_entity.behaviours[0] as Movement
	_check(
		"client received state (x=%.2f)" % client_movement.position.x,
		client_movement.position.x > 1.0
	)

	# The two must agree closely despite 20% packet loss.
	var divergence := absf(
		server_movement.position.x - client_movement.position.x
	)
	_check(
		"client tracks the server within 2 m (%.2f m apart)" % divergence,
		divergence < 2.0
	)

	_check("stats recorded sends", server.stats.packets_sent > 0)
	_check("stats recorded receives", client.stats.packets_received > 0)
	_check(
		"loss was detected (%d snapshots)" % client.stats.snapshots_lost,
		client.stats.snapshots_lost > 0
	)
	_check("no decode failures", client.stats.decode_failures == 0)
	_check(
		"batching is efficient (%.0f B/packet)" % server.stats.average_packet_bytes(),
		server.stats.average_packet_bytes() > 0.0
	)

	# Disconnect must release everything the peer owned.
	var released := server.remove_peer(2)
	_check("peer removal released its entities", released.size() == 1)
	_check("registry emptied", server.registry.count() == 0)
	_sections_completed += 1


## Ninety ticks of the server's snapshots reaching [param c] four ticks late, the mirror spawned
## at tick 30; returns the mirror.
func _drive_late_mirror(s: DotNetManager, c: DotNetManager, held: Array[PackedByteArray], server_vars: ObserverVars, server_entity: DotNetIdentity) -> DotNetIdentity:
	var later: Array = []
	var acks: Array = []
	var client_entity: DotNetIdentity = null
	for tick in range(1, 91):
		server_vars.wobble = tick % 200
		s.server_tick(tick)
		later.append([tick + 4, held.duplicate()])
		held.clear()
		for item: Array in later.duplicate():
			if int(item[0]) <= tick:
				for payload: PackedByteArray in item[1]:
					c.receive_snapshot(payload)
				later.erase(item)
		# A loading client sends no acknowledgements until its entities exist.
		if client_entity != null:
			acks.append([tick + 4, c.ack_tick()])
		for item: Array in acks.duplicate():
			if int(item[0]) <= tick:
				s.receive_ack(2, mini(int(item[1]), tick))
				acks.erase(item)
		# The mirror appears only after the first second of snapshots.
		if tick == 30:
			client_entity = c.spawner.spawn_remote(
				&"mirror", server_entity.net_id, 3, Transform3D.IDENTITY, 0
			).value
	return client_entity


## An observer that learns of an entity after the server's first snapshots still gets the
## state that never changes again (a game's alive/health, sent once), when it sends no
## acknowledgement until the mirror exists: the server must send that state again then.
func _test_late_mirror_observer_vars() -> void:
	_sections_entered += 1
	print("")
	print("[late mirror]")

	var s := _bare_manager(true, 1)
	var c := _bare_manager(false, 2)
	s.config.ack_window_snapshots = 4
	add_child(s)
	add_child(c)
	s.setup()
	c.setup()

	var held: Array[PackedByteArray] = []
	s.send_fn = func(peer_id: int, payload: PackedByteArray, d: int) -> void:
		if peer_id != 2:
			return
		if d != DotNetMessage.Delivery.UNRELIABLE:
			c.receive(payload, 1)
		else:
			held.append(payload)
	s.start()
	c.start()
	s.add_peer(2)

	s.spawner.register_factory(&"mirror", _build_mirror)
	c.spawner.register_factory(&"mirror", _build_mirror)

	# Owned by peer 3, so peer 2 observes it.
	var server_entity: DotNetIdentity = s.spawner.spawn(&"mirror", 3, Transform3D.IDENTITY, 0).value
	var server_vars := server_entity.behaviours[1] as ObserverVars
	server_vars.alive = true
	server_vars.hp = 87
	server_vars.armour = 40

	var client_entity := _drive_late_mirror(s, c, held, server_vars, server_entity)

	_check("the late mirror exists", client_entity != null)
	var client_vars := client_entity.behaviours[1] as ObserverVars
	_check("observer alive arrived (%s)" % client_vars.alive, client_vars.alive)
	_check("observer hp arrived (%d)" % client_vars.hp, client_vars.hp == 87)
	_check("shared armour arrived (%d)" % client_vars.armour, client_vars.armour == 40)

	s.queue_free()
	c.queue_free()
	_sections_completed += 1





## [b]An entity whose node is freed before the netcode stops.[/b] A game change frees the old
## world's scene before the module stops its manager, so `clear()` meets identities that are
## already gone; each was a script error ("invalid instance") on a run that passed.
func _test_freed_entity() -> void:
	_sections_entered += 1
	print("")
	print("[freed entity]")

	var config := DotNetConfig.new()
	var registry := DotNetRegistry.new(true, 1)
	var kept := _make_entity(&"player", 2)
	var freed := _make_entity(&"player", 3)
	registry.register(kept, 0, 1, config)
	registry.register(freed, 0, 1, config)
	var freed_id := freed.net_id
	freed.get_parent().free()

	var errors := EngineErrors.new()
	OS.add_logger(errors)
	var dropped := registry.unregister(freed_id)
	registry.clear()
	OS.remove_logger(errors)

	_check("a freed entity is unregistered", dropped.ok)
	_check("and leaves nothing behind for its owner", registry.owned_by(3).is_empty())
	_check("clear() takes the live one too", registry.count() == 0)
	_check("with no script error from either (%d)" % errors.count(), errors.count() == 0)
	kept.get_parent().free()
	_sections_completed += 1


## [b]An entity unregistered by another behaviour inside the same server tick[/b] (#30): a round
## re-laying its map from `_net_simulate` removes entities from the registry and tree while the
## manager still walks its list; each was simulated once more with no transform.
func _test_unregistered_mid_tick() -> void:
	_sections_entered += 1
	print("")
	print("[unregistered mid-tick]")

	var host := DotNetManager.new()
	host.name = "MidTickHost"
	host.is_server = true
	host.service_scope = &"midtick"
	host.local_peer_id = 1
	host.auto_tick = false
	host.config_file = ""
	host.config = DotNetConfig.new()
	host.config.tick_rate = 60
	host.config.snapshot_rate = 60
	add_child(host)
	var _ready_now := host.setup()

	var sent := [0]
	host.send_fn = func(_peer_id: int, _payload: PackedByteArray, d: int) -> void:
		if d == DotNetMessage.Delivery.UNRELIABLE:
			sent[0] += 1
	host.start()
	host.add_peer(2)

	# The remover first in the registry's order, the victim after it.
	var remover_identity := _in_tree(_make_entity(&"player", 2))
	var remover_body := remover_identity.get_parent()
	var remover := Unregisters.new()
	remover.name = "Unregisters"
	remover_body.remove_child(remover_identity)
	remover_identity.behaviours = [remover]
	remover.identity = remover_identity
	remover_body.add_child(remover)
	remover_body.add_child(remover_identity)
	var victim_identity := _in_tree(_make_entity(&"player", 2))
	var victim_movement: Movement = victim_identity.behaviours[0]
	victim_movement.moves_body = true
	victim_movement.velocity = Vector3(1.0, 0.0, 0.0)
	var _a := host.registry.register(remover_identity, 0, 1, host.config)
	var _b := host.registry.register(victim_identity, 0, 1, host.config)
	remover_identity.behaviours = [remover]
	remover.host = host
	remover.victim = victim_identity

	var errors := EngineErrors.new()
	OS.add_logger(errors)
	var before := victim_movement.position
	host.server_tick(1)
	OS.remove_logger(errors)

	_check("the remover ran (%d)" % remover.simulated, remover.simulated == 1)
	_check("an entity unregistered earlier in the tick is not simulated", victim_movement.position == before)
	_check("with no engine error (%d)" % errors.count(), errors.count() == 0)
	_check("and the tick's snapshot still went out (%d)" % sent[0], sent[0] >= 1)

	host.stop()
	remove_child(host)
	host.free()
	remover_body.queue_free()
	victim_identity.get_parent().queue_free()
	_sections_completed += 1


## The input history is a derived quantity and is raised, not warned about.
## The two counts the wire carries in 6 bits refuse past 63 with an error, rather than a 64th
## being sent as 0 (DotNetWriter masks silently) and aliasing the first.
func _test_count_limits() -> void:
	print("count limits")
	var errors := EngineErrors.new()
	OS.add_logger(errors)

	var many := Movement.new()
	many._bind(DotNetConfig.new())
	var before := many.net_vars.size()
	for i in range(70):
		var _v := many.replicate(StringName("extra_%d" % i), DotNetVar.Type.UINT)
	_check("a behaviour keeps 63 replicated properties and refuses the rest", many.net_vars.size() == 63 and before < 63)

	var body := Node3D.new()
	var identity := DotNetIdentity.new()
	body.add_child(identity)
	for i in range(66):
		var b := Movement.new()
		b.name = "B%d" % i
		body.add_child(b)
	identity.entity = body
	identity._collect_from(body)
	_check("an entity keeps 63 behaviours and refuses the rest", identity.behaviours.size() == 63)

	OS.remove_logger(errors)
	_check("each refusal is an error, not silence (%d)" % errors.count(), errors.count() >= 10)
	many.free()
	body.free()


func _test_config_sizing() -> void:
	print("config sizing")
	var config := DotNetConfig.new()
	config.tick_rate = 128
	config.input_history_ticks = 8
	var valid := config.validate()
	_check("a config that cannot hold its own rewind is still valid", valid.ok)
	_check(
		"and its input history has been raised to cover it",
		config.input_history_ticks >= int(config.max_rewind_sec * 128.0) * 2
	)


## The spawner's prefab table lets a spawn message name an id instead of a scene path, so a peer
## cannot make others load an arbitrary scene. The pooling path ([member free_on_despawn],
## [method register_factory]) hands back a node already in the tree.
func _test_spawning() -> void:
	_sections_entered += 1
	print("")
	print("[spawning]")

	var config := DotNetConfig.new()
	var registry := DotNetRegistry.new(true, 1)

	var spawner := DotNetSpawner.new()
	spawner.name = "Spawner"
	spawner.setup(registry, config)
	add_child(spawner)

	var good := _pack_entity(true)
	var identity_less := _pack_entity(false)

	_check("empty id refused", not spawner.register_prefab(&"", good).ok)
	_check("null scene refused", not spawner.register_prefab(&"nothing", null).ok)

	var no_identity := spawner.register_prefab(&"broken", identity_less)
	_check(
		"a scene with no identity is refused at registration",
		not no_identity.ok and no_identity.error.code == DotError.CODE_INVALID
	)

	_check("prefab registered", spawner.register_prefab(&"player", good).ok)
	var again := spawner.register_prefab(&"player", good)
	_check(
		"a duplicate id is refused",
		not again.ok and again.error.code == DotError.CODE_STATE
	)
	_check("prefab is known", spawner.has_prefab(&"player"))

	# The allow-list property: an id nobody registered cannot name anything.
	var unknown := spawner.spawn(&"res://addons/dot_net/plugin.cfg", 1)
	_check(
		"an unregistered id cannot be spawned",
		not unknown.ok and unknown.error.code == DotError.CODE_INVALID
	)

	var spawned := spawner.spawn(&"player", 7, Transform3D(Basis(), Vector3(3, 0, 4)))
	_check("spawned", spawned.ok)
	var live := spawned.value as DotNetIdentity
	_check("registered on spawn", registry.get_identity(live.net_id) == live)
	_check("owner recorded", live.owner_peer_id == 7)
	_check("prefab recorded", live.prefab_id == &"player")
	_check("landed in the container", live.entity.get_parent() != null
		and live.entity.get_parent().name == &"Entities")
	_check(
		"transform applied",
		live.entity is Node3D
			and (live.entity as Node3D).global_position.is_equal_approx(Vector3(3, 0, 4))
	)

	# A client may not invent entities, and may not invent ids either.
	var client_registry := DotNetRegistry.new(false, 2)
	var client_spawner := DotNetSpawner.new()
	client_spawner.name = "ClientSpawner"
	client_spawner.setup(client_registry, config)
	add_child(client_spawner)
	client_spawner.register_prefab(&"player", good)

	var refused := client_spawner.spawn(&"player", 2)
	_check(
		"only the authority spawns",
		not refused.ok and refused.error.code == DotError.CODE_FORBIDDEN
	)
	_check(
		"a remote spawn needs the server's id",
		not client_spawner.spawn_remote(&"player", 0, 2, Transform3D.IDENTITY, 0).ok
	)
	var remote := client_spawner.spawn_remote(
		&"player", 4242, 2, Transform3D.IDENTITY, 0
	)
	_check("remote spawn uses the id it was given",
		remote.ok and (remote.value as DotNetIdentity).net_id == 4242)

	_pool.clear()
	_pool_context = {}
	_pool_parent = Node.new()
	_pool_parent.name = "Pool"
	add_child(_pool_parent)

	var factory := func(context: Dictionary) -> Node:
		_pool_context = context
		if not _pool.is_empty():
			_pool_reused += 1
			return _pool.pop_back()
		return _build_entity_node()

	_check("factory registered", spawner.register_factory(&"pooled", factory).ok)
	_check(
		"a factory cannot shadow a prefab",
		not spawner.register_factory(&"player", factory).ok
	)
	_check("ids are listed", Array(spawner.prefab_ids()).has("pooled")
		and Array(spawner.prefab_ids()).has("player"))

	var not_a_node := func(_context: Dictionary) -> Node: return null
	spawner.register_factory(&"broken_factory", not_a_node)
	var produced_nothing := spawner.spawn(&"broken_factory", 1)
	_check("a factory returning nothing is an error", not produced_nothing.ok)

	var first := spawner.spawn(&"pooled", 7, Transform3D.IDENTITY, 0, {"loadout": "rocket"})
	_check("factory spawn", first.ok)
	_check("context reaches the factory", str(_pool_context.get("loadout", "")) == "rocket")

	# The game keeps the node, which is what free_on_despawn is for, and hands the
	# same one back the next time the id is spawned. The spawner is handed a node
	# that is already parented — by the spawner itself, on the previous spawn.
	spawner.free_on_despawn = false
	var pooled_identity := first.value as DotNetIdentity
	var pooled_node := pooled_identity.entity
	var pooled_id := pooled_identity.net_id

	var despawned := spawner.despawn(pooled_id)
	_check("despawned", despawned.ok and registry.get_identity(pooled_id) == null)
	_check("node kept for the pool", is_instance_valid(pooled_node))

	# A pool parks idle instances out of the live container, or "pooled" and "live" are the same
	# set and reuse looks like a first spawn. The spawner must handle a node that comes back with
	# a parent that is not the container.
	pooled_node.get_parent().remove_child(pooled_node)
	_pool_parent.add_child(pooled_node)
	_pool.append(pooled_node)
	_pool_reused = 0

	var second := spawner.spawn(&"pooled", 9, Transform3D(Basis(), Vector3(1, 2, 3)))
	_check("pooled node reused", _pool_reused == 1)
	_check("respawn from the pool", second.ok,)
	if second.ok:
		var reborn := second.value as DotNetIdentity
		_check("reused node is registered", registry.get_identity(reborn.net_id) == reborn)
		_check("reused node moved into the container",
			reborn.entity.get_parent() != null
			and reborn.entity.get_parent().name == &"Entities")
		_check("reused node left the pool", _pool_parent.get_child_count() == 0)
		_check("reused node was given a new id", reborn.net_id != pooled_id)
		_check("reused node took the new owner", reborn.owner_peer_id == 9)
		_check(
			"reused node was moved",
			(reborn.entity as Node3D).global_position.is_equal_approx(Vector3(1, 2, 3))
		)

	spawner.free_on_despawn = true

	_check("despawning nothing is an error", not spawner.despawn(999999).ok)

	var extra := spawner.spawn(&"player", 7)
	_check("second entity for peer 7", extra.ok)
	var owned := registry.owned_by(7).size()
	var swept := spawner.despawn_owned_by(7)
	_check("despawn_owned_by returns the count", swept == owned, )
	_check("peer 7 owns nothing", registry.owned_by(7).is_empty())

	# register_prefab's contract is that a prefab with no identity is a *startup* error, not a
	# silently non-networked spawn. The inspector path must honour it too, or the guarantee
	# only holds for games that register in code.
	var declared := DotNetSpawner.new()
	declared.name = "DeclaredSpawner"
	declared.prefabs = {"good": good, "bad": identity_less}
	declared.setup(registry, config)
	add_child(declared)

	_check("declared prefab registered", declared.has_prefab(&"good"))
	_check("declared prefab with no identity refused", not declared.has_prefab(&"bad"))

	_sections_completed += 1
