extends "netcode_sections_3.gd"

## Sections of netcode_demo.gd, moved unchanged; part 4 of 7.


func _test_remote_bumps() -> void:
	print("")
	print("[bumping a remote under loss]")

	var table := _bump_table()

	var oracle_worst := 0.0
	var contact := true
	var default_same := true
	var mean_ratio := 0.0
	var line_ratio := INF
	var lossy_worse := 0.0
	for speed in BUMP_SPEEDS:
		for loss in BUMP_LOSSES:
			var oracle: Dictionary = table[[speed, loss, &"oracle"]]
			var heard: Dictionary = table[[speed, loss, &"heard"]]
			var line: Dictionary = table[[speed, loss, &"line"]]
			var ahead: Dictionary = table[[speed, loss, &"extrapolated"]]
			var plain: Dictionary = table[[speed, loss, &"default"]]
			oracle_worst = maxf(oracle_worst, float(oracle["worst"]))
			contact = contact and int(oracle["contact"]) > 100
			default_same = default_same and is_equal_approx(float(plain["mean"]), float(heard["mean"])) \
				and is_equal_approx(float(plain["worst"]), float(heard["worst"]))
			mean_ratio = maxf(mean_ratio, float(ahead["mean"]) / float(heard["mean"]))
			line_ratio = minf(line_ratio, float(line["mean"]) / float(ahead["mean"]))
			if loss > 0.1:
				lossy_worse = maxf(lossy_worse, float(ahead["worst"]) - float(heard["worst"]))

	# The control: told where the bot really is, the client agrees with the server under any
	# loss, so every gap below is the estimate's and nothing else's.
	_check(
		"control: the true bot position predicts within 1 cm (%.4f m)" % oracle_worst,
		oracle_worst < 0.01
	)
	_check("and the player really is pushed, every run", contact)

	# The problem, measured: the last-heard position costs speed x age, and loss ages it.
	var heard_slow: float = table[[4.0, 0.0, &"heard"]]["worst"]
	var heard_fast: float = table[[8.0, 0.0, &"heard"]]["worst"]
	var heard_lossy: float = table[[8.0, 0.15, &"heard"]]["worst"]
	_check(
		"last heard: a faster bot costs more (%.2f m against %.2f)" % [heard_fast, heard_slow],
		heard_fast > heard_slow * 1.5
	)
	_check(
		"last heard: and loss costs more again (%.2f m at 15%%)" % heard_lossy,
		heard_lossy > heard_fast
	)

	# The decision. Carried along the replicated velocity, the mean gap is a fraction of the
	# last heard one everywhere, and the worst under loss is no worse.
	_check(
		"extrapolated: the mean gap is under a third of last heard's (worst ratio %.2f)" % mean_ratio,
		mean_ratio < 0.34
	)
	_check(
		"extrapolated: and the worst at 15%% loss is no worse (by %.2f m at most)" % lossy_worse,
		lossy_worse < 0.01
	)
	_check(
		"the interpolator's line through two positions does worse (mean x%.1f at best)" % line_ratio,
		line_ratio > 1.5
	)
	_check(
		"left at its default, extrapolated_value is the last heard position",
		default_same
	)


func _test_reconcile_once_per_frame() -> void:
	print("")
	print("[reconciled once a frame]")
	const TICKS := 64
	const LEAD := 6

	var host := DotNetManager.new()
	host.name = "OnceServer"
	host.is_server = true
	host.service_scope = &"once_server"
	host.local_peer_id = 1
	host.auto_tick = false
	host.config_file = ""
	host.config = DotNetConfig.new()
	host.config.tick_rate = 60
	host.config.snapshot_rate = 60
	add_child(host)

	var guests: Array[DotNetManager] = []
	for deferred in [false, true]:
		var guest := DotNetManager.new()
		guest.name = "OnceClient_%d" % int(deferred)
		guest.is_server = false
		guest.service_scope = StringName("once_client_%d" % int(deferred))
		guest.local_peer_id = 2
		guest.auto_tick = false
		guest.config_file = ""
		guest.config = DotNetConfig.new()
		guest.config.tick_rate = 60
		guest.config.snapshot_rate = 60
		guest.config.input_margin_ticks = LEAD
		guest.config.reconcile_once_per_frame = deferred
		add_child(guest)
		var _set := guest.setup()
		guests.append(guest)

	var _a := host.setup()
	var wire: Array[PackedByteArray] = []
	host.send_fn = func(_peer: int, payload: PackedByteArray, d: int) -> void:
		if d == DotNetMessage.Delivery.UNRELIABLE:
			wire.append(payload)

	var _c := host.start()
	host.add_peer(2)
	host.spawner.register_factory(&"player", _build_player)
	var on_server: DotNetIdentity = host.spawner.spawn(&"player", 2, Transform3D.IDENTITY, 0).value
	var moving: Array[Movement] = []
	for guest in guests:
		var _s := guest.start()
		guest.spawner.register_factory(&"player", _build_player)
		var mirror: DotNetIdentity = guest.spawner.spawn_remote(
			&"player", on_server.net_id, 2, Transform3D.IDENTITY, 0
		).value
		moving.append(mirror.behaviours[0] as Movement)

	var replays_before: Array[int] = []
	for guest in guests:
		replays_before.append(int(guest.predictor.describe()["replays"]))

	var bursts := 0
	var read := 0
	var untouched := true
	var worst_apart := 0.0

	for s in range(1, TICKS + 1):
		var c := s + LEAD
		# A turn every 8 ticks, so a replay on the wrong inputs could not agree by luck.
		var move := Vector2(1.0, 0.0) if (s / 8) % 2 == 0 else Vector2(0.0, 1.0)
		for g in range(2):
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
		# The server disagrees now and then (a rule the client does not know), so every
		# burst has a real correction in it to agree about.
		copy.move = move if s % 5 != 0 else Vector2(-1.0, 0.0)
		host.input_buffer_for(2).push(copy)
		host.server_tick(s)

		if s % BURST != 0:
			continue

		bursts += 1
		var held := moving[1].position
		for payload in wire:
			read += 1
			for guest in guests:
				guest.clock.tick = c
				var _r := guest.receive_snapshot(payload)
		wire.clear()
		if moving[1].position != held:
			untouched = false
		guests[1].flush_reconcile()
		worst_apart = maxf(worst_apart, moving[0].position.distance_to(moving[1].position))
		for guest in guests:
			var _ack := host.receive_ack_payload(2, guest.encode_ack())

	var replays_a := int(guests[0].predictor.describe()["replays"]) - replays_before[0]
	var replays_b := int(guests[1].predictor.describe()["replays"]) - replays_before[1]
	var coalesced := int(guests[1].describe()["prediction"].get("coalesced", -1))

	_check("each snapshot reconciled with it off (%d of %d)" % [replays_a, read],
		replays_a == read and read > 0)
	_check("once a burst with it on (%d for %d bursts)" % [replays_b, bursts],
		replays_b == bursts and bursts > 0)
	_check("and the rest counted as coalesced (%d)" % coalesced, coalesced == read - bursts)
	_check("nothing moves before the flush", untouched)
	_check("and both land in the same place (worst %.6f m apart)" % worst_apart, worst_apart < 1e-4)

	host.stop()
	remove_child(host)
	host.free()
	for guest in guests:
		guest.stop()
		remove_child(guest)
		guest.free()


## [member DotNetConfig.skip_matching_replays]: a snapshot the prediction already reached
## replays nothing, and one it did not is replayed as before. Two clients read the same
## snapshots: A replays every one, B skips the ones it predicted. The server overrules the
## input every 16 ticks, so B has real corrections to make; it must make them (end where A
## does, within what the wire's quantisation allows) and skip the rest.
##
## [param own_state]: the behaviour simulates on state of its own and copies the
## properties into it from `_net_state_applied`, as every game does. Reading a deferred
## snapshot runs that hook with the server's older state, and the manager then puts only
## the properties back; a skip that left it there had the next tick simulate from a round
## trip ago.
func _test_skip_matching_replays(own_state: bool) -> void:
	print("")
	print("[replays skipped when the prediction matched%s]" % (", own simulation state" if own_state else ""))
	const TICKS := 96
	const LEAD := 6

	var host := _bare_manager(true, 1)
	host.name = "SkipServer"
	host.service_scope = &"skip_server"
	host.config.tick_rate = 60
	host.config.snapshot_rate = 60
	add_child(host)

	# A: replays everything. B: skips, predicting through `DotNetPredictor.predict`.
	# C: skips, predicting through `DotNetManager.predict_tick` as a host with its own client
	# tick does. D: skips, but simulates its predicted behaviours by hand, as game-arena's
	# bridge did until 2026-10-17: the predictor never remembers those ticks, so only a snapshot
	# a replay happened to cover can match, and most replay the lead anyway.
	var guests: Array[DotNetManager] = []
	for g in range(4):
		var skip := g > 0
		var guest := DotNetManager.new()
		guest.name = "SkipClient_%d" % g
		guest.is_server = false
		guest.service_scope = StringName("skip_client_%d" % g)
		guest.local_peer_id = 2
		guest.auto_tick = false
		guest.config_file = ""
		guest.config = DotNetConfig.new()
		guest.config.tick_rate = 60
		guest.config.snapshot_rate = 60
		guest.config.input_margin_ticks = LEAD
		guest.config.skip_matching_replays = skip
		# Both deferred: a skip needs the prediction still in the properties when it decides.
		guest.config.reconcile_once_per_frame = true
		add_child(guest)
		var _set := guest.setup()
		guests.append(guest)

	var _a := host.setup()
	var wire: Array[PackedByteArray] = []
	host.send_fn = func(_peer: int, payload: PackedByteArray, d: int) -> void:
		if d == DotNetMessage.Delivery.UNRELIABLE:
			wire.append(payload)

	var _c := host.start()
	host.add_peer(2)
	host.spawner.register_factory(&"player", _build_player)
	var on_server: DotNetIdentity = host.spawner.spawn(&"player", 2, Transform3D.IDENTITY, 0).value
	var moving: Array[Movement] = []
	for guest in guests:
		var _s := guest.start()
		guest.spawner.register_factory(&"player", _build_player)
		var mirror: DotNetIdentity = guest.spawner.spawn_remote(
			&"player", on_server.net_id, 2, Transform3D.IDENTITY, 0
		).value
		var movement := mirror.behaviours[0] as Movement
		movement.keeps_own_state = own_state
		movement._sim_position = movement.position
		movement._sim_velocity = movement.velocity
		moving.append(movement)

	var before: Array[Dictionary] = []
	for guest in guests:
		before.append(guest.perf_counters())

	var worst_apart := 0.0
	var final_apart := 0.0
	var overruled := 0
	for s in range(1, TICKS + 1):
		var c := s + LEAD
		var move := Vector2(1.0, 0.0) if (s / 8) % 2 == 0 else Vector2(0.0, 1.0)
		for g in range(guests.size()):
			var input := DemoInput.new()
			input.tick = c
			input.delta = 1.0 / 60.0
			input.move = move
			guests[g].local_inputs().push(input)
			if g == 2 and guests[g].clock.is_synced():
				guests[g].predict_tick(c, input)
				continue
			moving[g]._net_apply_input(input, c)
			if g == 3:
				moving[g]._net_simulate(c, 1.0 / 60.0)
			else:
				guests[g].predictor.predict(guests[g].registry.predicted(), c, 1.0 / 60.0)

		var copy := DemoInput.new()
		copy.tick = c
		copy.delta = 1.0 / 60.0
		copy.move = move if s % 16 != 0 else Vector2(-1.0, 0.0)
		if s % 16 == 0:
			overruled += 1
		host.input_buffer_for(2).push(copy)
		host.server_tick(s)

		for payload in wire:
			for guest in guests:
				guest.clock.tick = c
				var _r := guest.receive_snapshot(payload)
				guest.flush_reconcile()
				var _ack := host.receive_ack_payload(2, guest.encode_ack())
		wire.clear()
		final_apart = moving[0].position.distance_to(moving[1].position)
		worst_apart = maxf(worst_apart, final_apart)

	var hp := host.perf_counters()
	_check("the server counts its ticks and their send time (%d ticks, %d us)" % [int(hp[&"server_ticks"]), int(hp[&"server_send_usec"])],
		int(hp[&"server_ticks"]) == TICKS and int(hp[&"server_send_usec"]) > 0)
	var a := guests[0].perf_counters()
	var b := guests[1].perf_counters()
	var replayed_a := int(a[&"replayed_ticks"]) - int(before[0][&"replayed_ticks"])
	var replayed_b := int(b[&"replayed_ticks"]) - int(before[1][&"replayed_ticks"])
	var skipped_b := int(b[&"skipped"]) - int(before[1][&"skipped"])
	var reconciles_b := int(b[&"reconciles"]) - int(before[1][&"reconciles"])
	var tc := guests[2].perf_counters()
	var replayed_c := int(tc[&"replayed_ticks"]) - int(before[2][&"replayed_ticks"])
	var skipped_c := int(tc[&"skipped"]) - int(before[2][&"skipped"])
	var reconciles_c := int(tc[&"reconciles"]) - int(before[2][&"reconciles"])
	var td := guests[3].perf_counters()
	var replayed_d := int(td[&"replayed_ticks"]) - int(before[3][&"replayed_ticks"])

	_check("with it off every snapshot replays the lead (%d ticks)" % replayed_a, replayed_a >= TICKS * LEAD / 2)
	_check("with it on most are skipped (%d of %d reconciles)" % [skipped_b, reconciles_b],
		skipped_b > 0 and skipped_b >= reconciles_b - overruled * 3)
	_check("and it replays a fraction of the ticks (%d against %d)" % [replayed_b, replayed_a],
		replayed_b > 0 and replayed_b * 4 < replayed_a)
	# Within the wire's quantisation: B kept its own unquantised prediction where A rewound
	# to the server's quantised state; a correction B missed would be a metre or more.
	_check("and lands where replaying everything does (worst %.4f m, last %.4f m apart)" % [worst_apart, final_apart],
		worst_apart < 0.05)
	_check("predict_tick skips as much (%d of %d reconciles, %d ticks) and counts its time (%d ticks, %d us)"
		% [skipped_c, reconciles_c, replayed_c, int(tc[&"client_ticks"]) - int(before[2][&"client_ticks"]), int(tc[&"predict_usec"]) - int(before[2][&"predict_usec"])],
		skipped_c >= reconciles_c - overruled * 3 - 2 and replayed_c * 4 < replayed_a
		and int(tc[&"client_ticks"]) - int(before[2][&"client_ticks"]) >= TICKS - 2)
	_check("where simulating by hand, unremembered, replays most of the lead anyway (%d ticks against %d)" % [replayed_d, replayed_c],
		replayed_d > replayed_c * 2)
	var c_apart := moving[2].position.distance_to(moving[0].position)
	_check("and predict_tick lands where replaying everything does (%.4f m)" % c_apart, c_apart < 0.05)
	# What predict_tick simulates is what the server decodes (predict_wire_input).
	var raw := DemoInput.new()
	raw.tick = 7
	raw.move = Vector2(0.123456, -0.654321)
	var sent := DotNetWriter.new()
	raw.write(sent)
	var decoded := DemoInput.new()
	decoded.read(DotNetReader.new(sent.to_bytes()))
	raw.round_trip()
	_check("round_trip rounds an input to what the server decodes (%s against %s)" % [raw.move, decoded.move],
		raw.move == decoded.move and raw.tick == 7 and not is_equal_approx(raw.move.x, 0.123456))

	host.stop()
	remove_child(host)
	host.free()
	for guest in guests:
		guest.stop()
		remove_child(guest)
		guest.free()


## [member DotNetConfig.stagger_snapshots]: every peer still gets a snapshot exactly every
## ticks_per_snapshot() ticks, but on its own phase, so no one tick builds them all. Run
## both ways, because a test that only ran staggered could not tell staggering from a
## server that happened to send to everybody at once.
func _test_staggered_snapshots() -> void:
	_sections_entered += 1
	print("")
	print("[staggered snapshots]")

	var by_mode := {}

	for staggered in [false, true]:
		var host := DotNetManager.new()
		host.name = "StaggerHost%s" % ("On" if staggered else "Off")
		host.is_server = true
		host.service_scope = &"stagger"
		host.local_peer_id = 1
		host.auto_tick = false
		host.config_file = ""
		host.config = DotNetConfig.new()
		host.config.tick_rate = 128
		host.config.snapshot_rate = 32
		host.config.stagger_snapshots = staggered
		add_child(host)
		var _ready_now := host.setup()

		var current := [0]
		var sends := {}
		host.send_fn = func(peer_id: int, _payload: PackedByteArray, d: int) -> void:
			if d != DotNetMessage.Delivery.UNRELIABLE:
				return
			if not sends.has(peer_id):
				sends[peer_id] = []
			(sends[peer_id] as Array).append(current[0])

		host.start()
		for peer_id in range(2, 10):
			host.add_peer(peer_id)
		host.spawner.register_factory(&"player", _build_player)
		var _spawned := host.spawner.spawn(&"player", 2, Transform3D.IDENTITY, 0)

		for t in range(1, 17):
			current[0] = t
			host.server_tick(t)

		by_mode[staggered] = sends
		host.stop()
		remove_child(host)
		host.free()

	var on: Dictionary = by_mode[true]
	var off: Dictionary = by_mode[false]

	var every_peer_four := on.size() == 8
	var four_apart := true
	var busiest := 0
	var per_tick := {}

	for peer_id in on:
		var ticks: Array = on[peer_id]
		every_peer_four = every_peer_four and ticks.size() == 4
		for k in range(1, ticks.size()):
			four_apart = four_apart and int(ticks[k]) - int(ticks[k - 1]) == 4
		for t in ticks:
			per_tick[t] = int(per_tick.get(t, 0)) + 1

	for t in per_tick:
		busiest = maxi(busiest, int(per_tick[t]))

	var off_busiest := 0
	var off_per_tick := {}
	for peer_id in off:
		for t in off[peer_id]:
			off_per_tick[t] = int(off_per_tick.get(t, 0)) + 1
	for t in off_per_tick:
		off_busiest = maxi(off_busiest, int(off_per_tick[t]))

	_check("staggered, every peer is sent four snapshots in sixteen ticks", every_peer_four)
	_check("each exactly four ticks after the last", four_apart)
	_check("and no tick builds more than a quarter of them (%d of 8)" % busiest, busiest <= 2)
	_check("unstaggered, every peer is sent on the same tick (%d of 8)" % off_busiest, off_busiest == 8)

	_sections_completed += 1


func _reorder_run(every_other: bool) -> void:
	_reorder_rng.seed = 20261009
	_reorder_held_change = false
	var label := "every other snapshot late" if every_other else "jitter"

	var host := DotNetManager.new()
	host.name = "ReorderServer"
	host.is_server = true
	host.service_scope = &"reorder_server"
	host.local_peer_id = 1
	host.auto_tick = false
	host.config_file = ""
	host.config = DotNetConfig.new()
	host.config.tick_rate = 60
	host.config.snapshot_rate = 20
	add_child(host)

	var watcher := DotNetManager.new()
	watcher.name = "ReorderClient"
	watcher.is_server = false
	watcher.service_scope = &"reorder_client"
	watcher.local_peer_id = 2
	watcher.auto_tick = false
	watcher.config_file = ""
	watcher.config = DotNetConfig.new()
	watcher.config.tick_rate = 60
	watcher.config.snapshot_rate = 20
	add_child(watcher)

	var _s1 := host.setup()
	var _s2 := watcher.setup()

	# Every snapshot the server sends to peer 2, held so the link can choose the order.
	var sent: Array[PackedByteArray] = []
	host.send_fn = func(peer_id: int, payload: PackedByteArray, d: int) -> void:
		if peer_id != 2:
			return
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var _schema := watcher.receive(payload, 1)
			return
		sent.append(payload)

	host.start()
	watcher.start()
	host.add_peer(2)
	host.spawner.register_factory(&"player", _build_player)
	watcher.spawner.register_factory(&"player", _build_player)

	# Somebody else's entity: this client only watches it.
	var spawned := host.spawner.spawn(&"player", 3, Transform3D.IDENTITY, 0)
	var server_entity: DotNetIdentity = spawned.value
	var _mirror := watcher.spawner.spawn_remote(&"player", server_entity.net_id, 3, Transform3D.IDENTITY, 0)
	var client_entity := watcher.registry.get_identity(server_entity.net_id)
	var on_server := server_entity.behaviours[0] as Movement
	var on_client := client_entity.behaviours[0] as Movement

	var deliver := func(payload: PackedByteArray) -> void:
		var _r := watcher.receive_snapshot(payload)
		var _a := host.receive_ack_payload(2, watcher.encode_ack())

	var held: Array[PackedByteArray] = []
	var health_seen: Array[int] = []
	var changed_at := -1
	var regressed := false

	for tick in range(1, 181):
		on_server.position += Vector3(0.05, 0.0, 0.0)
		# One change to a property that otherwise never changes, on a tick whose snapshot
		# the link below will deliver late.
		if tick == 61:
			on_server.health = 42
		host.server_tick(tick)

		for payload in sent:
			# The snapshot carrying the change is always held back, and any other one is
			# with a fixed chance; a held snapshot is delivered after the next one, when it
			# is older than one already applied and ignored.
			#
			# [b]Not every other one, which was tried first and never converged[/b]: the
			# client acknowledges only what it applies, the server re-sends in its very next
			# snapshot, and with every pair swapped that next snapshot is always the held
			# one -- the re-send lands late, every time, for ever. A link that reorders with
			# that exact period would starve a property; jitter does not have a period.
			var carries_change := tick >= 61 and tick <= 63 and held.is_empty() and changed_at < 0 \
				and not _reorder_held_change
			if held.is_empty() and (carries_change or every_other or _reorder_rng.randf() < 0.3):
				if carries_change:
					_reorder_held_change = true
				held.append(payload)
				continue
			deliver.call(payload)
			if not held.is_empty():
				deliver.call(held[0])
				held.clear()
			# And now and then a stale copy of one already applied, arriving again.
			if tick % 7 == 0:
				deliver.call(payload)
		sent.clear()

		var now_health := int(on_client.received_values().get(&"health", 100))
		health_seen.append(now_health)
		if now_health == 42 and changed_at < 0:
			changed_at = tick
		if changed_at >= 0 and now_health != 42:
			regressed = true

	var apart := absf(on_server.position.x - float((on_client.received_values().get(&"position", Vector3.ZERO) as Vector3).x))

	_check("%s: a change carried only by a late snapshot still arrives (tick %d)" % [label, changed_at],
		_reorder_held_change and changed_at > 63)
	_check("%s: and once arrived it never goes back to the older value" % label, not regressed)
	_check("%s: late and repeated snapshots decode cleanly (%d failures)" % [label, watcher.stats.decode_failures],
		watcher.stats.decode_failures == 0)
	_check("%s: the watched position keeps up (%.2f m behind)" % [label, apart], apart < 1.0)

	host.stop()
	watcher.stop()
	remove_child(host)
	remove_child(watcher)
	host.free()
	watcher.free()


func _test_reordered_and_repeated() -> void:
	_sections_entered += 1
	print("")
	print("[reordered and repeated snapshots]")
	_reorder_run(false)
	# The link that used to starve a property: every other snapshot held back, so the one
	# re-send after a loss always landed in a held one. A lost property is owed until it is
	# confirmed now, so it is sent again in each snapshot until one is applied.
	_reorder_run(true)
	_sections_completed += 1


func _parts_manager(label: String, server: bool, mtu: int) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = label
	manager.is_server = server
	manager.service_scope = StringName(label.to_lower())
	manager.local_peer_id = 1 if server else 2
	manager.auto_tick = false
	manager.config_file = ""
	manager.config = DotNetConfig.new()
	manager.config.tick_rate = 60
	# A snapshot every tick, so each server_tick below is one snapshot.
	manager.config.snapshot_rate = 60
	manager.config.mtu = mtu
	manager.config.per_client_budget = 0
	add_child(manager)
	var _s := manager.setup()
	# Every entity spawned is relevant at once, not after the interest cache expires.
	manager.interest.evaluation_interval_sec = 0.0
	return manager


## The entity count in a snapshot part's header.
func _part_count(payload: PackedByteArray) -> int:
	var reader := DotNetReader.new(payload)
	var _tick := reader.read_uint(32)
	return reader.read_uint(12)


## Where a snapshot's entities end, read with [param client]'s declarations.
func _bits_before_trailer(payload: PackedByteArray, client: DotNetManager) -> int:
	var reader := DotNetReader.new(payload)
	var _tick := reader.read_uint(32)
	var count := reader.read_uint(12)
	for _i in count:
		var net_id := reader.read_uint(DotNetRegistry.ID_BITS)
		var behaviours := reader.read_uint(6)
		var identity := client.registry.get_identity(net_id)
		if identity == null:
			return -1
		for b in behaviours:
			var _r := identity.behaviours[b].read_state(reader, 0)
	return reader.bit_position()
