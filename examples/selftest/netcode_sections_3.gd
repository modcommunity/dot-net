extends "netcode_sections_2.gd"

## Sections of netcode_demo.gd, moved unchanged; part 3 of 7.



## Two peers, and a lost packet. Both were replicated wrongly and neither showed up
## anywhere else, because the integration run has exactly one peer and loses only
## packets carrying a property that changes again on the very next tick.
func _test_acked_baselines() -> void:
	print("")
	print("[acked baselines]")


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

	var limited := _acked_rate_limit()
	var lonely := _acked_lost_property()
	var untracked := _acked_untracked()
	_check("peer 7 has a record", not shared.peer_view_state(7).is_empty())
	shared.forget_peer(7)
	_check("and it is gone once the peer is", shared.peer_view_state(7).is_empty())
	_check("without disturbing peer 8", not shared.peer_view_state(8).is_empty())

	for entity in [first, limited, lonely, untracked]:
		_out_of_tree(entity)


func _acked_untracked() -> DotNetIdentity:
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
	return untracked


func _acked_lost_property() -> DotNetIdentity:
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
	return lonely


func _acked_rate_limit() -> DotNetIdentity:
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
	return limited


## [member DotNetConfig.share_dirty_sets] against the per-peer rule it short-cuts, on two copies
## of one entity through the same snapshots (loss, late acks, interest, budget, owed predicted
## state). Every peer's dirty set and bytes must match both ways, and the shared path be taken.
func _test_shared_dirty_sets() -> void:
	print("")
	print("[shared dirty sets]")
	_share_rng.seed = 4242

	var owner := 3
	var peers: Array[int] = [2, 3, 4, 5, 6, 7]
	var copies := _sharing_copies(owner)

	_check_shifted_runs(copies[0])

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
		var changes := _random_share_changes()
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

			var got := _share_collect(copies, peer, owner, snapshot, tick, acked_tick, strict, starved, answers)
			var lists: Array = got[0]
			var bytes: Array = got[1]
			shared_answers += int(got[2])

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

	_free_sharing_copies(copies)


## Both copies' dirty list and bytes for one peer at one snapshot, and how many earlier answers in
## [param answers] the sharing copy's equals (which is added to). Returns [lists, bytes, shared].
func _share_collect(copies: Array[Sharing], peer: int, owner: int, snapshot: int, tick: int,
		acked_tick: int, strict: bool, starved: bool, answers: Dictionary) -> Array:
	var lists: Array = []
	var bytes: Array = []
	var shared := 0
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
					shared += 1
					break
			answers[peer] = dirty
	return [lists, bytes, shared]


func _sharing_copies(owner: int) -> Array[Sharing]:
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
	return copies


## A run shifted once per bit of a byte and kept against the shift per write it replaced.
func _check_shifted_runs(sharing: Sharing) -> void:
	# DotNetBehaviour._shifted is what write_state lays in for every peer after the first
	# at that bit; checked at every bit over a written prefix that is not zero.
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
			kept.write_bit_run(sharing._shifted(entry, pad), pad, pad + bits)
			if per_write.to_bytes() != kept.to_bytes() or per_write.bit_length() != kept.bit_length():
				shifts_agree = false
	_check("a run shifted once per bit is the bits a shift per write gives", shifts_agree)


## One snapshot's change, the same for both copies: most move, some change nothing at all.
func _random_share_changes() -> Dictionary:
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
	return changes


func _free_sharing_copies(copies: Array[Sharing]) -> void:
	for behaviour in copies:
		var identity := behaviour.identity
		behaviour.free()
		identity.free()


## A stop whose snapshot is lost is not rewound to a stale position.
func _check_standing_still_lossy(per_tick: float) -> void:
	# Moving, then stopped by the server, and the snapshot carrying the stop is lost. The next has
	# nothing new against what the server BELIEVES the client has, so without re-sending until
	# confirmed the client rewinds to a stale position, read as the server's word.
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


## A server that holds a predicted entity still while a client predicts it moving: the snapshot
## carries the entity with nothing in it (no input reaches the server, as for a server-only
## freeze), and the client must read that as "your last-sent state" and be pulled back. [param lossy] drops one snapshot in four, acknowledgements wired.
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

	# The same hold, with the server listing the entity as unchanged rather than writing an empty
	# body. The client must still reconcile on every snapshot, where inputs are acknowledged and
	# the hold is enforced (#17).
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


func _still_manager(node_name: String, as_server: bool, peer: int, scope: StringName) -> DotNetManager:
	var m := DotNetManager.new()
	m.name = node_name
	m.is_server = as_server
	m.service_scope = scope
	m.local_peer_id = peer
	m.auto_tick = false
	m.config_file = ""
	m.config = DotNetConfig.new()
	m.config.tick_rate = 60
	m.config.snapshot_rate = 60 / STILL_INTERVAL
	if not as_server:
		# The first snapshot anchors the clock at the server's tick plus this lead, and
		# reconciliation replays up to the clock's tick, so it has to be the harness's lead,
		# or the first replay stops a tick short and the control reads that as disagreement.
		m.config.input_margin_ticks = STILL_LEAD
	add_child(m)
	return m


## Worst and last gap (x, y) between where the client predicted and where the server was.
func _still_gaps(server_at: Dictionary, client_at: Dictionary) -> Vector2:
	var worst := 0.0
	var last := 0.0
	for tick: int in server_at:
		if not client_at.has(tick):
			continue
		var gap := (client_at[tick] as Vector3).distance_to(server_at[tick] as Vector3)
		worst = maxf(worst, gap)
		last = gap
	return Vector2(worst, last)


## The steady-state packet size, from the last quarter, when nothing has changed for a
## long time and there is nothing left in flight to resend.
func _still_tail_bytes(bytes: Array[int]) -> int:
	var tail_bytes := 0
	for b in bytes.slice(int(bytes.size() * 0.75)):
		tail_bytes = maxi(tail_bytes, b)
	return tail_bytes


func _free_still_managers(host: DotNetManager, guest: DotNetManager) -> void:
	host.stop()
	guest.stop()
	remove_child(host)
	remove_child(guest)
	host.free()
	guest.free()


## Hooks the host's send (snapshots recorded in [param rec], every fourth dropped when lossy) and,
## for a compact run, the guest's schema reply.
func _still_wire(host: DotNetManager, guest: DotNetManager, lossy: bool, compact: bool, rec: Dictionary) -> void:
	var wire: Array[Dictionary] = rec["wire"]
	var sent: Array = rec["sent"]
	var bytes: Array[int] = rec["bytes"]
	var lost_ticks: Array[int] = rec["lost"]
	var now: Array = rec["now"]
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


## The player on the server and its remote on the guest; their Movement behaviours.
func _still_spawn(host: DotNetManager, guest: DotNetManager) -> Array:
	host.add_peer(2)
	host.spawner.register_factory(&"player", _build_player)
	guest.spawner.register_factory(&"player", _build_player)

	var on_server: DotNetIdentity = host.spawner.spawn(&"player", 2, Transform3D.IDENTITY, 0).value
	var on_client: DotNetIdentity = guest.spawner.spawn_remote(
		&"player", on_server.net_id, 2, Transform3D.IDENTITY, 0
	).value
	return [on_server.behaviours[0] as Movement, on_client.behaviours[0] as Movement]


## Delivers the recorded snapshots at client tick [param c]: how many applied, and how many left the
## rewound position away from what the server had at the tick they were built on.
func _still_deliver(guest: DotNetManager, movement: Movement, wire: Array[Dictionary], server_at: Dictionary, c: int) -> Vector2i:
	var applied_count := 0
	var stale := 0
	for entry in wire:
		guest.clock.tick = c
		var applied := guest.receive_snapshot(entry["payload"] as PackedByteArray)
		if not applied.ok:
			continue
		applied_count += 1
		var rewound: Variant = movement.authoritative_values().get(&"position")
		var truth: Vector3 = server_at[int(entry["tick"])]
		if rewound == null or (rewound as Vector3).distance_to(truth) > 0.05:
			stale += 1
	return Vector2i(applied_count, stale)


## One run of [method _test_standing_still]. [param server_moves] gives the server the client's
## inputs (until non-zero [param stop_at], then it stops the entity itself); [param lossy] drops
## every fourth snapshot. Returns worst and final gap, and how many rewinds went to a wrong position.
func _standing_still_run(server_moves: bool, lossy: bool, stop_at: int, compact: bool = false) -> Dictionary:
	const TICKS := 120
	var scope := "still_%d_%d_%d_%d" % [int(server_moves), int(lossy), stop_at, int(compact)]

	var host := _still_manager("StillServer_" + scope, true, 1, StringName(scope + "_server"))
	var guest := _still_manager("StillClient_" + scope, false, 2, StringName(scope + "_client"))

	var _a := host.setup()
	var _b := guest.setup()

	# payload, and the server tick it was built on — so the rewind can be checked against
	# what the server really had at that tick.
	var wire: Array[Dictionary] = []
	var sent := [0]
	var bytes: Array[int] = []
	var lost_ticks: Array[int] = []
	var now := [0]
	_still_wire(host, guest, lossy, compact, {"wire": wire, "sent": sent, "bytes": bytes, "lost": lost_ticks, "now": now})

	var _c := host.start()
	var _d := guest.start()
	var moves := _still_spawn(host, guest)
	var server_movement: Movement = moves[0]
	var client_movement: Movement = moves[1]

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

		var heard := _still_deliver(guest, client_movement, wire, server_at, c)
		snapshots += heard.x
		stale += heard.y
		wire.clear()

		# The acknowledgement rides in front of the next input packet, as every game's does.
		var _ack := host.receive_ack_payload(2, guest.encode_ack())

	var gaps := _still_gaps(server_at, client_at)
	var tail_bytes := _still_tail_bytes(bytes)

	var out := {
		"worst": gaps.x,
		"last": gaps.y,
		"snapshots": snapshots,
		"stale": stale,
		"stop_lost": lost_ticks.has(stop_at),
		"replays": int(guest.predictor.describe()["replays"]) - replays_before,
		"tail_bytes": tail_bytes,
	}

	_free_still_managers(host, guest)
	return out
