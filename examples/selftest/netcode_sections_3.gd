extends "netcode_sections_2.gd"

## Sections of netcode_demo.gd, moved unchanged; part 3 of 7.


# --- Acked baselines -------------------------------------------------------

## Two peers, and a lost packet. Both were replicated wrongly and neither showed up
## anywhere else, because the integration run has exactly one peer and loses only
## packets carrying a property that changes again on the very next tick.
func _test_acked_baselines() -> void:
	print("")
	print("[acked baselines]")

	# --- A peer is not told what another peer was told -----------------------

	var first := _make_entity(&"player", 0)
	add_child(first.get_parent())
	var shared := first.behaviours[0] as Movement
	shared._bind(DotNetConfig.new())
	shared.position = Vector3(1, 2, 3)
	shared.health = 55

	var to_seven := shared.collect_dirty(7, false)
	_check("peer 7 is owed everything", to_seven.size() == 4)
	shared.write_state(DotNetWriter.new(), to_seven, 7, 100)

	# The bug: dirty tracking was one dictionary on the behaviour, so serving peer 7
	# marked the properties clean for everybody and peer 8 was sent nothing at all.
	var to_eight := shared.collect_dirty(8, false)
	_check(
		"peer 8 is still owed everything after peer 7 was served (%d)"
			% to_eight.size(),
		to_eight.size() == 4
	)
	shared.write_state(DotNetWriter.new(), to_eight, 8, 100)

	shared.health = 56
	_check("a change is dirty for peer 7 again", shared.collect_dirty(7, false).size() == 1)
	_check("and for peer 8 too", shared.collect_dirty(8, false).size() == 1)

	# Rate limiting was shared the same way: one peer's send silenced the property
	# for every other peer, not just for the one that had just been given it.
	var limited := _make_entity(&"player", 0)
	add_child(limited.get_parent())
	var capped := limited.behaviours[0] as Movement
	capped._bind(DotNetConfig.new())
	capped.find_var(&"health").at_most(1.0)
	capped.write_state(DotNetWriter.new(), capped.collect_dirty(7, true), 7, 100)
	capped.health = 70
	var eight_capped := false
	for declaration in capped.collect_dirty(8, false):
		if declaration.property == &"health":
			eight_capped = true
	_check("a rate limit is per peer, not global", eight_capped)
	# And it does hold back the peer just served. write_state records a send time only for
	# a rate-limited property (nothing else reads one), so this is what says it still does.
	# Armed: with no send time recorded, peer 7 is sent health again at once.
	capped.position = Vector3(9, 9, 9)
	var seven_health := false
	var seven_position := false
	for declaration in capped.collect_dirty(7, false):
		if declaration.property == &"health":
			seven_health = true
		if declaration.property == &"position":
			seven_position = true
	_check(
		"a rate-limited change waits for the peer just sent it; the rest does not",
		not seven_health and seven_position
	)

	# --- A lost snapshot is re-sent, once acknowledgements are wired ---------

	var lonely := _make_entity(&"player", 0)
	add_child(lonely.get_parent())
	var tracked := lonely.behaviours[0] as Movement
	tracked._bind(DotNetConfig.new())

	# Tick 100 lands. Tick 110 carries health and is lost. Tick 120 lands.
	tracked.write_state(DotNetWriter.new(), tracked.collect_dirty(7, true), 7, 100)
	tracked.sync_peer_acks(7, 100, true)

	tracked.health = 42
	var carried := tracked.collect_dirty(7, false)
	_check("the changed property is owed", carried.size() == 1)
	tracked.write_state(DotNetWriter.new(), carried, 7, 110)

	tracked.position = Vector3(9, 0, 0)
	tracked.write_state(DotNetWriter.new(), tracked.collect_dirty(7, false), 7, 120)

	# The peer acknowledges 120 without ever acknowledging 110: 110 did not arrive,
	# and a snapshot older than one already applied is superseded rather than late.
	tracked.sync_peer_acks(7, 120, true)

	var owed_again := []
	for declaration in tracked.collect_dirty(7, false):
		owed_again.append(declaration.property)
	_check(
		"the lost property is owed again (%s)" % str(owed_again),
		owed_again.has(&"health")
	)
	_check("and nothing that did arrive is re-sent", owed_again.size() == 1)

	# --- Without acknowledgements, nothing changes ---------------------------

	# The pre-existing behaviour, and what a host that has not wired acks still gets.
	var untracked := _make_entity(&"player", 0)
	add_child(untracked.get_parent())
	var optimistic := untracked.behaviours[0] as Movement
	optimistic._bind(DotNetConfig.new())
	optimistic.write_state(DotNetWriter.new(), optimistic.collect_dirty(7, true), 7, 100)
	optimistic.health = 42
	optimistic.write_state(DotNetWriter.new(), optimistic.collect_dirty(7, false), 7, 110)
	optimistic.trim_pending(7, 200)
	_check(
		"an unacknowledged send ages out as delivered when no acks arrive",
		optimistic.collect_dirty(7, false).is_empty()
	)

	# --- The record is dropped with the peer ---------------------------------

	_check("peer 7 has a record", not shared.peer_view_state(7).is_empty())
	shared.forget_peer(7)
	_check("and it is gone once the peer is", shared.peer_view_state(7).is_empty())
	_check("without disturbing peer 8", not shared.peer_view_state(8).is_empty())

	for entity in [first, limited, lonely, untracked]:
		_out_of_tree(entity)


## [member DotNetConfig.share_dirty_sets] against the per-peer rule it short-cuts, run side by
## side on two copies of one entity through the same snapshots: changes or none, peers left
## out (interest) or held back (budget), snapshots lost, acknowledged late or never, the
## owner's predicted entity owed until confirmed. Every peer's dirty set and bytes must be
## the same both ways, every snapshot; and the shared path must actually be taken.
func _test_shared_dirty_sets() -> void:
	print("")
	print("[shared dirty sets]")
	_share_rng.seed = 4242

	var owner := 3
	var peers: Array[int] = [2, 3, 4, 5, 6, 7]
	var copies: Array[Sharing] = []
	for share in [true, false]:
		var config := DotNetConfig.new()
		config.share_dirty_sets = share
		var identity := DotNetIdentity.new()
		identity.owner_peer_id = owner
		identity.authority = DotNetIdentity.Authority.SHARED
		var behaviour := Sharing.new()
		identity.behaviours = [behaviour]
		behaviour.identity = identity
		behaviour._bind(config)
		copies.append(behaviour)

	# A run shifted once per bit of a byte and kept (DotNetBehaviour._shifted, what write_state
	# lays in for every peer after the first at that bit) against the shift per write it
	# replaced, at every bit, over a written prefix that is not zero.
	var source := PackedByteArray([0xA5, 0x3C, 0xFF, 0x01, 0x80])
	var shifts_agree := true
	for bits in [1, 7, 8, 9, 17, 33, 40]:
		var data := source.slice(0, (bits + 7) >> 3)
		if bits & 7 != 0:
			data[data.size() - 1] &= (1 << (bits & 7)) - 1
		var entry := [data, bits, {}, []]
		for pad in range(1, 8):
			var per_write := DotNetWriter.new()
			per_write.write_bits(0x55, pad)
			per_write.write_shifted_run(data, bits)
			var kept := DotNetWriter.new()
			kept.write_bits(0x55, pad)
			kept.write_bit_run(copies[0]._shifted(entry, pad), pad, pad + bits)
			if per_write.to_bytes() != kept.to_bytes() or per_write.bit_length() != kept.bit_length():
				shifts_agree = false
	_check("a run shifted once per bit is the bits a shift per write gives", shifts_agree)

	var sent: Dictionary = {}     # peer -> ticks sent and not yet resolved, in order
	var acked: Dictionary = {}    # peer -> newest tick it has acknowledged
	for peer in peers:
		sent[peer] = []
		acked[peer] = 0

	var mismatches := 0
	var first_mismatch := ""
	var shared_answers := 0
	var written := 0

	for snapshot in range(1, 401):
		var tick := snapshot * 4

		# The same change to both copies: most snapshots move, some change nothing at all.
		var roll := _share_rng.randf()
		var changes := {}
		if roll < 0.7:
			changes[&"position"] = Vector3(_share_rng.randi_range(0, 3), 0, 0)
		if roll < 0.15:
			changes[&"health"] = _share_rng.randi_range(90, 92)
		if _share_rng.randf() < 0.05:
			changes[&"tag"] = ["", "a", "bb", "ccc"][_share_rng.randi_range(0, 3)]
		if _share_rng.randf() < 0.05:
			changes[&"secret"] = _share_rng.randf() < 0.5
		if _share_rng.randf() < 0.05:
			changes[&"seen"] = _share_rng.randi_range(0, 2)
		if _share_rng.randf() < 0.02:
			changes[&"kind"] = _share_rng.randi_range(1, 2)
		for behaviour in copies:
			for property in changes:
				behaviour.set(property, changes[property])
			behaviour.begin_snapshot_reads()

		var answers := {}  # peer -> the sharing copy's answer, to count the shared ones
		for peer in peers:
			# Peer 7 never acknowledges (the no-ack host); the rest do, late and with loss.
			var strict := peer != 7
			var acked_tick := int(acked[peer])
			var relevant := _share_rng.randf() < 0.9
			var starved := _share_rng.randf() < 0.1
			var arrives := _share_rng.randf() < 0.85
			var acks_now := strict and _share_rng.randf() < 0.8
			if not relevant:
				continue

			var lists: Array = []
			var bytes: Array = []
			for behaviour in copies:
				# The sharing copy the way DotNetManager asks (one fused call), the other the
				# three calls that are its definition: the two must agree, list and bytes.
				var dirty: Array[DotNetVar]
				if behaviour == copies[0]:
					dirty = behaviour.collect_for_peer(peer, acked_tick, strict, tick - 32 * 4, peer == owner)
				else:
					behaviour.sync_peer_acks(peer, acked_tick, strict)
					behaviour.trim_pending(peer, tick - 32 * 4)
					dirty = behaviour.collect_dirty(peer, false, peer == owner)
				var names := []
				for declaration in dirty:
					names.append(declaration.property)
				lists.append(names)
				var writer := DotNetWriter.new()
				# Entities start at any bit of a byte, so the string's alignment is exercised.
				if snapshot % 8 > 0:
					writer.write_bits(0, snapshot % 8)
				if not starved:
					behaviour.write_state(writer, dirty, peer, tick)
				bytes.append(writer.to_bytes())
				if behaviour == copies[0]:
					for other in answers:
						if is_same(answers[other], dirty):
							shared_answers += 1
							break
					answers[peer] = dirty

			if lists[0] != lists[1] or bytes[0] != bytes[1]:
				mismatches += 1
				if first_mismatch == "":
					first_mismatch = "snapshot %d peer %d: %s vs %s" % [snapshot, peer, lists[0], lists[1]]
			if not starved:
				written += 1
				if arrives:
					(sent[peer] as Array).append(tick)
			if acks_now and not (sent[peer] as Array).is_empty():
				# Acknowledges the newest that arrived, as a client does.
				acked[peer] = int((sent[peer] as Array).back())

		for behaviour in copies:
			behaviour.end_snapshot_reads()

	_check(
		"shared dirty sets match per-peer ones (%d of %d differ%s)"
			% [mismatches, written, "" if first_mismatch == "" else ": " + first_mismatch],
		mismatches == 0
	)
	# Armed: with the sharing off, or never taken, no two peers are handed one answer.
	_check(
		"and peers in step were handed one shared answer (%d)" % shared_answers,
		shared_answers > 100
	)

	for behaviour in copies:
		var identity := behaviour.identity
		behaviour.free()
		identity.free()


## A stop whose snapshot is lost is not rewound to a stale position.
func _check_standing_still_lossy(per_tick: float) -> void:
	# Moving, then stopped by the server — and the snapshot carrying the stop is lost. The
	# next one has nothing new to say against what the server BELIEVES the client has, so
	# without re-sending until confirmed the client rewinds to where it was before the lost
	# one: a stale position read as the server's word, on every snapshot until the loss is
	# discovered a round trip later.
	var stopped := _standing_still_run(false, true, STILL_STOP_AT)
	var lossy_bound := float(STILL_LEAD + 2 * STILL_INTERVAL) * per_tick + 0.01
	_check(
		"lossy: stopped by the server, and pulled back (worst %.2f m, bound %.2f)"
			% [float(stopped["worst"]), lossy_bound],
		float(stopped["worst"]) <= lossy_bound
	)
	_check(
		"lossy: the snapshot carrying the stop was the one lost",
		bool(stopped["stop_lost"])
	)
	_check(
		"lossy: and no rewind was to a stale position (%d of %d)"
			% [int(stopped["stale"]), int(stopped["snapshots"])],
		int(stopped["stale"]) == 0
	)


## A server that holds a predicted entity still, and a client that predicts it moving.
##
## [b]The case every other prediction check here cannot reach[/b], because in all of them
## the server moves the entity and a moving position is a changed position: it is in every
## snapshot, and reconciliation has something to rewind to. Here the server refuses the
## move without changing anything it replicates — no input reaches it, the way a server-only
## freeze, a wall only the server has, or any rule the client does not know about would
## refuse one — so the snapshot carries the entity with nothing in it. The client has to
## read that as "the server's state is the one you were last sent" and be pulled back.
##
## It read it as "the server's state is whatever you are predicting", adopted its own
## prediction as authoritative, and replayed the unacknowledged inputs on top of it — so
## the client did not merely fail to come back, it walked away at twice its own speed.
## game-hungario and the lobby measured 113 and 530 units in their naive admin controls.
##
## [param lossy] drops one snapshot in four, with acknowledgements wired as every game in
## the family wires them, because the send side's own shortcut — a property is not re-sent
## while its first send is in flight — is exactly what a lost packet turns into a stale
## baseline for the one entity that now rewinds to it.
func _test_standing_still() -> void:
	print("")
	print("[a predicted entity the server holds still]")

	# The client may be ahead of the server by its input lead plus the snapshot interval
	# since the last one it applied — plus one more interval for every snapshot lost —
	# at 10 m/s and 60 Hz. Anything beyond that is a prediction nothing corrected.
	var per_tick := 10.0 / 60.0

	var held := _standing_still_run(false, false, 0)
	var held_bound := float(STILL_LEAD + STILL_INTERVAL) * per_tick + 0.01
	_check(
		"the client is pulled back (worst %.2f m, bound %.2f)" % [float(held["worst"]), held_bound],
		float(held["worst"]) <= held_bound
	)
	_check(
		"and every snapshot reconciled it (%d of %d)"
			% [int(held["replays"]), int(held["snapshots"])],
		int(held["replays"]) == int(held["snapshots"]) and int(held["snapshots"]) > 0
	)
	_check(
		"to where the server holds it, every time (%d wrong)" % int(held["stale"]),
		int(held["stale"]) == 0
	)

	# Bandwidth. The fix must not have bought this by sending the entity in full every
	# snapshot: held still, the owner's entity costs its header and nothing else.
	_check(
		"an entity held still costs its header, not its state (%d B/snapshot)"
			% int(held["tail_bytes"]),
		int(held["tail_bytes"]) <= 12
	)

	_check_standing_still_lossy(per_tick)

	# The control. The same harness with the server taking every input must agree, or the
	# harness is what disagrees and the checks above measure nothing.
	var moving := _standing_still_run(true, false, 0)
	_check(
		"control: a server that moves it agrees with the client (worst %.3f m)"
			% float(moving["worst"]),
		float(moving["worst"]) < 0.05
	)

	# The same hold, with the server listing the entity as unchanged rather than writing an
	# empty body for it. The client must reconcile on every snapshot exactly as before:
	# reconcile is where its inputs are acknowledged and where the hold is enforced, so a
	# listed entity that skipped it would walk away again (#17).
	var listed := _standing_still_run(false, false, 0, true)
	_check(
		"listed as unchanged: pulled back all the same (worst %.2f m)" % float(listed["worst"]),
		float(listed["worst"]) <= held_bound
	)
	_check(
		"listed: every snapshot still reconciles it (%d of %d)"
			% [int(listed["replays"]), int(listed["snapshots"])],
		int(listed["replays"]) == int(listed["snapshots"]) and int(listed["snapshots"]) > 0
			and int(listed["stale"]) == 0
	)
	_check(
		"listed: and held still it costs less than its header (%d B, was %d)"
			% [int(listed["tail_bytes"]), int(held["tail_bytes"])],
		int(listed["tail_bytes"]) < int(held["tail_bytes"])
	)


## One run of [method _test_remote_bumps]: a server and a client in one process, the client
## [constant BUMP_LEAD] ticks ahead, every snapshot delivered at once or lost. Returns the
## worst and mean gap between where the client first predicted its player at a tick and
## where the server had it, and how many ticks the server pushed it.
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

	var server_at := {}
	var client_at := {}
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

	host.stop()
	guest.stop()
	remove_child(host)
	remove_child(guest)
	host.free()
	guest.free()
	return {"worst": worst, "mean": total / maxf(1.0, float(counted)), "contact": pushed[0]}


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


## One run of [method _test_standing_still]. [param server_moves] decides whether the
## server is given the client's inputs; a non-zero [param stop_at] gives them until that
## tick and then has the server stop the entity itself, as a freeze would. [param lossy]
## drops every fourth snapshot, which with a snapshot every third tick is the one at
## [constant STILL_STOP_AT]. Acknowledgements are wired, as every game in the family wires
## them.
##
## Returns the worst and final gap between where the client predicted the entity at a
## tick and where the server had it at that tick, and how many times the client rewound
## to a position the server did not have at the snapshot's tick.
func _standing_still_run(server_moves: bool, lossy: bool, stop_at: int, compact: bool = false) -> Dictionary:
	const TICKS := 120
	var scope := "still_%d_%d_%d_%d" % [int(server_moves), int(lossy), stop_at, int(compact)]

	var host := DotNetManager.new()
	host.name = "StillServer_" + scope
	host.is_server = true
	host.service_scope = StringName(scope + "_server")
	host.local_peer_id = 1
	host.auto_tick = false
	host.config_file = ""
	host.config = DotNetConfig.new()
	host.config.tick_rate = 60
	host.config.snapshot_rate = 60 / STILL_INTERVAL
	add_child(host)

	var guest := DotNetManager.new()
	guest.name = "StillClient_" + scope
	guest.is_server = false
	guest.service_scope = StringName(scope + "_client")
	guest.local_peer_id = 2
	guest.auto_tick = false
	guest.config_file = ""
	guest.config = DotNetConfig.new()
	guest.config.tick_rate = 60
	guest.config.snapshot_rate = 60 / STILL_INTERVAL
	# The first snapshot anchors the clock at the server's tick plus this lead, and
	# reconciliation replays up to the clock's tick — so it has to be the harness's lead,
	# or the first replay stops a tick short and the control reads that as disagreement.
	guest.config.input_margin_ticks = STILL_LEAD
	add_child(guest)

	var _a := host.setup()
	var _b := guest.setup()

	# payload, and the server tick it was built on — so the rewind can be checked against
	# what the server really had at that tick.
	var wire: Array[Dictionary] = []
	var sent := [0]
	var bytes: Array[int] = []
	var lost_ticks: Array[int] = []
	var now := [0]
	host.send_fn = func(_peer: int, payload: PackedByteArray, d: int) -> void:
		# Snapshots only; see _test_render_delay.
		if d != DotNetMessage.Delivery.UNRELIABLE:
			return
		sent[0] += 1
		bytes.append(payload.size())
		if lossy and sent[0] % 4 == 0:
			lost_ticks.append(now[0])
			return
		wire.append({"payload": payload, "tick": now[0]})

	# The client's schema reaches the server only when asked for: it is what tells the server
	# this client reads unchanged lists (docs/wire.md#unchanged-entities). Without it the
	# runs below are the format every client before the lists reads.
	if compact:
		guest.send_fn = func(_peer: int, payload: PackedByteArray, d: int) -> void:
			if d != DotNetMessage.Delivery.UNRELIABLE:
				var _adopted := host.receive(payload, 2)

	var _c := host.start()
	var _d := guest.start()
	host.add_peer(2)
	host.spawner.register_factory(&"player", _build_player)
	guest.spawner.register_factory(&"player", _build_player)

	var on_server: DotNetIdentity = host.spawner.spawn(&"player", 2, Transform3D.IDENTITY, 0).value
	var on_client: DotNetIdentity = guest.spawner.spawn_remote(
		&"player", on_server.net_id, 2, Transform3D.IDENTITY, 0
	).value
	var server_movement := on_server.behaviours[0] as Movement
	var client_movement := on_client.behaviours[0] as Movement

	var server_at := {}
	var client_at := {}
	var snapshots := 0
	var stale := 0
	var replays_before := int(guest.predictor.describe()["replays"])

	for s in range(1, TICKS + 1):
		var c := s + STILL_LEAD
		now[0] = s

		# The client samples, records and predicts tick c.
		var input := DemoInput.new()
		input.tick = c
		input.delta = 1.0 / 60.0
		input.move = Vector2(1.0, 0.0)
		guest.local_inputs().push(input)
		client_movement._net_apply_input(input, c)
		guest.predictor.predict(guest.registry.predicted(), c, 1.0 / 60.0)
		client_at[c] = client_movement.position

		# The server either takes it, or never hears of it, or stops the entity itself.
		var takes := server_moves or (stop_at > 0 and c < stop_at)
		if takes:
			var copy := DemoInput.new()
			copy.tick = c
			copy.delta = input.delta
			copy.move = input.move
			host.input_buffer_for(2).push(copy)

		if stop_at > 0 and s == stop_at:
			server_movement.current_input = null
			server_movement.velocity = Vector3.ZERO

		host.server_tick(s)
		server_at[s] = server_movement.position

		for entry in wire:
			guest.clock.tick = c
			var applied := guest.receive_snapshot(entry["payload"] as PackedByteArray)
			if not applied.ok:
				continue
			snapshots += 1
			var rewound: Variant = client_movement.authoritative_values().get(&"position")
			var truth: Vector3 = server_at[int(entry["tick"])]
			if rewound == null or (rewound as Vector3).distance_to(truth) > 0.05:
				stale += 1
		wire.clear()

		# The acknowledgement rides in front of the next input packet, as every game's does.
		var _ack := host.receive_ack_payload(2, guest.encode_ack())

	var worst := 0.0
	var last := 0.0
	for tick: int in server_at:
		if not client_at.has(tick):
			continue
		var gap := (client_at[tick] as Vector3).distance_to(server_at[tick] as Vector3)
		worst = maxf(worst, gap)
		last = gap

	# The steady-state packet size, from the last quarter, when nothing has changed for a
	# long time and there is nothing left in flight to resend.
	var tail := bytes.slice(int(bytes.size() * 0.75))
	var tail_bytes := 0
	for b in tail:
		tail_bytes = maxi(tail_bytes, b)

	var out := {
		"worst": worst,
		"last": last,
		"snapshots": snapshots,
		"stale": stale,
		"stop_lost": lost_ticks.has(stop_at),
		"replays": int(guest.predictor.describe()["replays"]) - replays_before,
		"tail_bytes": tail_bytes,
	}

	host.stop()
	guest.stop()
	remove_child(host)
	remove_child(guest)
	host.free()
	guest.free()
	return out
