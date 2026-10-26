extends "netcode_base.gd"

## The sections of netcode_demo.gd that need nothing the demo itself defines.



# --- Wire format -----------------------------------------------------------

func _test_wire() -> void:
	print("[wire]")

	var w := DotNetWriter.new()
	w.write_bool(true)
	w.write_bool(false)
	w.write_uint(12345, 16)
	w.write_int(-4321, 16)
	w.write_varint(300)
	w.write_svarint(-77)
	w.write_string("hello wire")
	w.write_bytes(PackedByteArray([1, 2, 3, 250]))

	var r := w.to_reader()
	_check("bool true", r.read_bool() == true)
	_check("bool false", r.read_bool() == false)
	_check("uint16", r.read_uint(16) == 12345)
	_check("int16 negative", r.read_int(16) == -4321)
	_check("varint", r.read_varint() == 300)
	_check("svarint negative", r.read_svarint() == -77)
	_check("string", r.read_string() == "hello wire")
	_check("bytes", r.read_bytes() == PackedByteArray([1, 2, 3, 250]))
	_check("no overrun", r.ok())

	# Bit packing must not waste bytes: 3 bits should occupy 1 byte, not 3.
	var packed := DotNetWriter.new()
	for _i in range(8):
		packed.write_bits(1, 1)
	_check("8 bits pack into 1 byte", packed.byte_length() == 1)

	# Reading past the end must be safe and detectable, not a crash.
	var short := DotNetReader.new(PackedByteArray([0x01]))
	short.read_uint(32)
	_check("overrun detected", not short.ok())
	_check("overrun returns zero", short.read_uint(8) == 0)

	# A hostile length prefix must not cause an allocation attempt.
	var hostile := DotNetWriter.new()
	hostile.write_varint(4_000_000_000)
	var hostile_reader := hostile.to_reader()
	var refused := hostile_reader.read_bytes(1024)
	_check("oversized length refused", refused.is_empty() and not hostile_reader.ok())


## A run of bits encoded once and laid into another writer, at every bit offset, with a
## string in it. A string is written byte-aligned, so its padding depends on where in a byte
## it starts: state encoded at one offset and laid in at another read back as garbage from
## the string on (game-playground's NPC weapon id, the first time snapshots did this).
func _test_bit_runs() -> void:
	print("")
	print("[bit runs]")
	var all_read := true

	for pad in range(8):
		var scratch := DotNetWriter.new()
		if pad > 0:
			scratch.write_bits(0, pad)
		scratch.write_uint(5, 6)
		scratch.write_string("zee_smg")
		scratch.write_uint(37, 7)

		var into := DotNetWriter.new()
		if pad > 0:
			into.write_bits(0b1011011 & ((1 << pad) - 1), pad)
		into.write_bit_run(scratch.to_bytes(), pad, scratch.bit_length())
		into.write_uint(9, 4)

		var reader := into.to_reader()
		var head := reader.read_uint(pad) if pad > 0 else 0
		var a := reader.read_uint(6)
		var text := reader.read_string()
		var b := reader.read_uint(7)
		var tail := reader.read_uint(4)
		all_read = all_read and head == (0b1011011 & ((1 << pad) - 1)) and a == 5 \
			and text == "zee_smg" and b == 37 and tail == 9

	_check("a run laid in at each of the eight bit offsets reads back, string and all", all_read)

	# And the shifted run: one copy encoded at bit 0, with nothing aligned in it, laid in
	# at every offset -- the path every moving player's state takes.
	var shifted_read := true
	var source := DotNetWriter.new()
	source.write_uint(5, 6)
	source.write_float_range(12.5, -100.0, 100.0, 16)
	source.write_uint(37, 7)
	for pad in range(8):
		var into := DotNetWriter.new()
		if pad > 0:
			into.write_bits(0b1101101 & ((1 << pad) - 1), pad)
		into.write_shifted_run(source.to_bytes(), source.bit_length())
		into.write_uint(9, 4)
		var reader := into.to_reader()
		var head := reader.read_uint(pad) if pad > 0 else 0
		var a := reader.read_uint(6)
		var f := reader.read_float_range(-100.0, 100.0, 16)
		var b := reader.read_uint(7)
		var tail := reader.read_uint(4)
		shifted_read = shifted_read and head == (0b1101101 & ((1 << pad) - 1)) and a == 5 \
			and absf(f - 12.5) < 0.01 and b == 37 and tail == 9
	_check("and a shifted run, encoded once at bit 0, reads back at each of them", shifted_read)


func _test_quantisation() -> void:
	print("")
	print("[quantisation]")

	var config := DotNetConfig.new()
	var bits := config.position_bits()

	var w := DotNetWriter.new()
	var original := Vector3(123.456, -78.9, 1000.001)
	w.write_vector3_range(original, -config.world_extent, config.world_extent, bits)

	var back := w.to_reader().read_vector3_range(
		-config.world_extent, config.world_extent, bits
	)

	# The error must be within one quantisation step, not merely "close".
	var step := (config.world_extent * 2.0) / float((1 << bits) - 1)
	_check(
		"position within one step (%.4f m)" % step,
		original.distance_to(back) < step * 2.0
	)

	# Out-of-range values clamp rather than wrap. Wrapping would teleport an entity
	# across the world.
	var far := DotNetWriter.new()
	far.write_float_range(99999.0, -100.0, 100.0, 16)
	_check(
		"out of range clamps",
		is_equal_approx(far.to_reader().read_float_range(-100.0, 100.0, 16), 100.0)
	)

	# Angles wrap, because they are cyclic.
	var angle := DotNetWriter.new()
	angle.write_angle(370.0, 12)
	var read_angle := angle.to_reader().read_angle(12)
	_check("angle wraps to 0-360", read_angle < 15.0)

	# Quaternion smallest-three must survive a round trip accurately.
	var worst := 0.0
	for i in range(24):
		var q := Quaternion(
			Vector3(1, 2, 3).normalized(), float(i) * 0.25
		).normalized()

		var qw := DotNetWriter.new()
		qw.write_quaternion(q, 12)
		var qb := qw.to_reader().read_quaternion(12)

		# q and -q are the same rotation, so compare the angle between them.
		worst = maxf(worst, absf(q.angle_to(qb)))

	_check("quaternion within 1 degree (%.3f)" % rad_to_deg(worst), rad_to_deg(worst) < 1.0)

	# A quaternion costs far less than four floats — the whole point.
	var qsize := DotNetWriter.new()
	qsize.write_quaternion(Quaternion.IDENTITY, 9)
	_check("quaternion under 5 bytes", qsize.byte_length() <= 5)

	# Directions must come back unit-length.
	var dir := DotNetWriter.new()
	dir.write_direction(Vector3(1, 2, -3).normalized(), 12)
	var read_dir := dir.to_reader().read_direction(12)
	_check("direction stays normalised", absf(read_dir.length() - 1.0) < 0.01)

	# A degenerate direction must not produce NaN on the far side.
	var zero := DotNetWriter.new()
	zero.write_direction(Vector3.ZERO, 12)
	_check("zero direction is finite", zero.to_reader().read_direction(12).is_finite())


## The body of a schema payload, as `decode` would hand it to `adopt_peer_schema`.
func _schema_body(payload: PackedByteArray) -> DotNetReader:
	var r := DotNetReader.new(payload)
	var id := r.read_uint(DotNetMessageRegistry.ID_BITS)
	var bits := r.read_varint()
	if id != DotNetMessageRegistry.SCHEMA_ID:
		return DotNetReader.new(PackedByteArray())
	return r.take_bits(bits)


func _test_packets() -> void:
	print("")
	print("[packets]")

	var registry := DotNetMessageRegistry.new()
	registry.register(&"demo.chat", ChatMessage)
	registry.seal()

	var batch := DotNetPacket.Batch.new(42)
	for i in range(5):
		var m := ChatMessage.new()
		m.text = "message %d" % i
		batch.add(m, 16)

	var encoded := DotNetPacket.encode_batch(batch, registry)
	_check("batch encoded", encoded.ok)

	var decoded := DotNetPacket.decode_batch(encoded.value, registry, 3, true)
	_check("batch decoded", decoded.ok)

	if decoded.ok:
		var payload: Dictionary = decoded.value
		_check("tick survived", int(payload["tick"]) == 42)
		_check("all five messages", (payload["messages"] as Array).size() == 5)
		_check(
			"order preserved",
			((payload["messages"] as Array)[3] as ChatMessage).text == "message 3"
		)

	# Batching beats sending separately, which is the reason it exists.
	var separate := 0
	for i in range(5):
		var m := ChatMessage.new()
		m.text = "message %d" % i
		var single := DotNetWriter.new()
		registry.encode(m, single)
		separate += single.byte_length() + 28  # a conservative UDP+IP header
	_check(
		"batching saves overhead (%d vs %d bytes)"
			% [(encoded.value as PackedByteArray).size() + 28, separate],
		(encoded.value as PackedByteArray).size() + 28 < separate
	)

	# Fragmentation round trip.
	var big := PackedByteArray()
	big.resize(5000)
	for i in range(big.size()):
		big[i] = i % 251

	var fragments := DotNetPacket.fragment(big, 7, 1200)
	_check("fragmented", fragments.ok and (fragments.value as Array).size() > 1)

	var reassembler := DotNetPacket.Reassembler.new()
	var whole: PackedByteArray = PackedByteArray()

	# Fed out of order, because that is how they arrive.
	var pieces: Array = (fragments.value as Array).duplicate()
	pieces.reverse()

	for piece in pieces:
		var fed := reassembler.feed(piece)
		if fed.ok and fed.value != null:
			whole = fed.value

	_check("reassembled", whole == big)
	_check("nothing left pending", reassembler.pending_count() == 0)

	# A fragment claiming an out-of-range index must be refused.
	var bad := DotNetWriter.new()
	bad.write_uint(1, 16)
	bad.write_uint(9, 8)
	bad.write_uint(3, 8)
	bad.write_bytes(PackedByteArray([1]))
	_check(
		"bad fragment index refused",
		not reassembler.feed(bad.to_bytes()).ok
	)


## Thinning keeps own and near entities every snapshot and far ones in turns.
func _check_interest_thinning(config: DotNetConfig, observer: DotNetIdentity, all: Array[DotNetIdentity]) -> void:
	var thin := DotNetInterestDistance.new()
	thin.radius = 100000.0
	thin.evaluation_interval_sec = 0.0
	_check("thinning is off by default", not thin.thins())
	thin.far_every = 4
	thin.far_distance = 50.0
	var seen := {}
	for snap in 4:
		var kept: Array = []
		var ctx := {"tick": snap * config.ticks_per_snapshot(), "config": config}
		thin.thin_into(kept, observer, thin.relevant_for(observer, all, 1, ctx), 1, ctx)
		for identity: DotNetIdentity in kept:
			seen[identity.net_id] = int(seen.get(identity.net_id, 0)) + 1
	_check("thinning: own and near every snapshot, a far one once in far_every (%s)" % seen,
		int(seen.get(1, 0)) == 4 and int(seen.get(2, 0)) == 4 and int(seen.get(3, 0)) == 1 and int(seen.get(4, 0)) == 1)

	# Tiers: 3 is in the first band past 3000 m (every 4th), 4 in the second (every 8th).
	thin.far_distance = 3000.0
	thin.far_tiers = 3
	for coherent: bool in [false, true]:
		thin.far_coherent = coherent
		seen = {}
		var same := true
		for snap in 8:
			var ctx := {"tick": snap * config.ticks_per_snapshot(), "config": config}
			var turns: Array[String] = []
			for peer in [1, 2]:
				var kept: Array = []
				thin.thin_into(kept, observer, thin.relevant_for(observer, all, peer, ctx), peer, ctx)
				var names := ""
				for identity: DotNetIdentity in kept:
					names += "%d," % identity.net_id
					if peer == 1:
						seen[identity.net_id] = int(seen.get(identity.net_id, 0)) + 1
				turns.append(names)
			same = same and turns[0] == turns[1]
		_check("tiers: near every snapshot, band 1 one in 4, band 2 one in 8 (%s)" % seen,
			int(seen.get(2, 0)) == 8 and int(seen.get(3, 0)) == 2 and int(seen.get(4, 0)) == 1)
		_check("far_coherent %s: two peers %s the same far turns" % [coherent, "share" if coherent else "stagger"],
			same == coherent)


## The two entity caps combine to the tighter one.
func _check_entity_caps() -> void:
	# 0 means unlimited on either side rather than "cap at zero".
	var caps := DotNetConfig.new()
	caps.max_entities_per_snapshot = 256
	caps.max_tracked_entities = 64
	_check("the tighter of the two entity caps wins", caps.entity_cap() == 64)
	caps.max_tracked_entities = 4096
	_check("and the other way round", caps.entity_cap() == 256)
	caps.max_entities_per_snapshot = 0
	_check("an unlimited snapshot cap leaves the tracked cap", caps.entity_cap() == 4096)
	caps.max_tracked_entities = 0
	_check("and both unlimited is unlimited", caps.entity_cap() == 0)


func _test_budget() -> void:
	print("")
	print("[bandwidth]")

	var config := DotNetConfig.new()
	config.per_client_budget = 1000
	var budget := DotNetBudget.new(config)

	_check("spending allowed initially", budget.can_spend(1, 500))
	budget.note_packet(1, 900)
	_check("spending refused past the budget", not budget.can_spend(1, 500))
	_check("remaining reported", budget.remaining(1) == 100)

	# The accumulator must stop a low-priority entity being starved forever.
	var low := _make_entity(&"prop", 0)
	add_child(low.get_parent())
	low.net_id = 10
	low.priority = 0.1

	var high := _make_entity(&"player", 0)
	add_child(high.get_parent())
	high.net_id = 11
	high.priority = 10.0

	var candidates: Array[DotNetIdentity] = [low, high]
	var scores := {10: 0.1, 11: 10.0}

	var high_first := 0
	var low_first := 0

	for round_index in range(90):
		var ordered := budget.accumulate(2, candidates, scores)
		if ordered[0].net_id == 11:
			high_first += 1
			budget.note_sent(2, 11, 10)
		else:
			low_first += 1
			budget.note_sent(2, 10, 10)

	_check("high priority sent more often", high_first > low_first)
	_check("low priority is not starved (%d of 90)" % low_first, low_first > 0)

	# The order accumulate returns (an integer sort of the accumulators' bits) against a
	# plain descending sort of the same numbers, with ties, zeros and a wide range.
	var many: Array[DotNetIdentity] = []
	var accumulators := {}
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	for i in 40:
		var entity := DotNetIdentity.new()
		entity.net_id = 100 + i
		many.append(entity)
		accumulators[entity.net_id] = [0.0, 1.0, 1.0, 0.25, 3.5e6, 1e-9][i % 6] * float(1 + i % 7) \
			if i % 5 != 0 else rng.randf_range(0.0, 50.0)
	var by_bits := DotNetBudget._by_accumulator(many, accumulators)
	var descending := true
	for i in range(1, by_bits.size()):
		if float(accumulators[by_bits[i - 1].net_id]) < float(accumulators[by_bits[i].net_id]):
			descending = false
	var same_members := by_bits.size() == many.size()
	for entity in many:
		if not by_bits.has(entity):
			same_members = false
	_check("accumulate orders by accumulator, highest first, losing nobody",
		descending and same_members)
	for entity in many:
		entity.free()


## The same timeline over a jittery link.
func _check_render_timeline_jitter() -> void:
	# The same over a jittery link: 64 ticks, a snapshot every second tick, each taking
	# 1..4 ticks to arrive, so they arrive late, early and out of order.
	var jit := DotNetClock.new(64, false)
	jit.adaptive_margin = false
	var rng := RandomNumberGenerator.new()
	rng.seed = 64
	var server_now := 2000
	var in_flight: Array = []
	var back_steps := 0
	var worst_back := 0
	var worst_off := 0
	var previous := -1
	for frame in range(640):
		server_now += 1
		if server_now % 2 == 0:
			in_flight.append([frame + rng.randi_range(1, 4), server_now])
		jit.advance(1.0 / 64.0)
		var due: Array = []
		for packet in in_flight:
			if int(packet[0]) <= frame:
				due.append(packet)
		for packet in due:
			in_flight.erase(packet)
			jit.sync_from_server(int(packet[1]), 47.0)
		if previous >= 0 and jit.received_tick() < previous:
			back_steps += 1
			worst_back = maxi(worst_back, previous - jit.received_tick())
		if frame > 64:
			worst_off = maxi(worst_off, absi(jit.received_tick() - (server_now - 1)))
		previous = jit.received_tick()
	_check(
		"over a jittery link the receive timeline almost never goes back, and one tick at most (%d times, %d ticks)"
			% [back_steps, worst_back],
		back_steps <= 3 and worst_back <= 1
	)
	_check(
		"and stays within a tick or two of the quickest arrival (%d)" % worst_off,
		worst_off <= 2
	)


## A replicated node taken out of the tree is neither recorded nor rewound, and raises no engine error.
func _check_history_skips_orphans(history: DotNetHistory, target: DotNetIdentity) -> void:
	# A replicated node taken out of the tree between ticks — a round re-laying its map
	# does this, before the identity is unregistered. Recording it read its global basis
	# and printed an engine error per entity per tick; recording it at all would put a
	# sample at the origin for a rewind to drag a hitbox through.
	var gone := _make_entity(&"player", 4)
	gone.net_id = 21
	var errors := EngineErrors.new()
	OS.add_logger(errors)
	history.record([target, gone], 40)
	var guarded := history.rewind([target, gone], 38, 40, 0)
	history.restore()
	OS.remove_logger(errors)
	_check("an entity out of the tree is not recorded", history.position_at(21, 40.0) == null)
	_check("and one in the tree still is", history.position_at(20, 40.0) != null)
	_check("a rewind skips it and still moves the rest", guarded.ok
		and int((guarded.value as Dictionary)["rewound"]) == 1)
	_check("with no engine error from either (%d)" % errors.count(), errors.count() == 0)
	gone.get_parent().free()


# --- Integration -----------------------------------------------------------

## Runs a server and a client against each other over a lossy loopback.
## Client-side prediction replay, against a server simulating the same inputs.
##
## [DotNetPredictor] had no section of its own, and the integration run below does
## not substitute for one: it feeds a [i]constant[/i] input for all sixty ticks, and
## a replay that ignores the input history lands on the right answer whenever the
## input never changes. The zig-zag here is the entire point.
## A silent peer's last input is repeated for DotNetConfig.starved_input_hold_sec and then
## neutralised, and a client with no snapshot for prediction_hold_sec predicts on a held input.
func _test_starved_input() -> void:
	print("[starved input]")
	var mi := MemberInput.new()
	mi._neutralise()
	_check("the default _neutralise neutralises members and keeps the rest",
		mi.cmd.move == Vector2.ZERO and mi.cmd.buttons == 0 and mi.cmd.yaw == 1.5 and mi.plain == 3)
	var moved := []
	for hold in [0.25, 0.0]:
		var s := DotNetManager.new()
		s.is_server = true
		s.auto_tick = false
		s.config_file = ""
		s.service_scope = StringName("starve_%d" % moved.size())
		s.config = DotNetConfig.new()
		s.config.starved_input_hold_sec = hold
		add_child(s)
		s.setup()
		s.start()
		s.add_peer(5)
		var body := _in_tree(_make_entity(&"player", 5))
		body.is_authoritative = true
		var _reg := s.registry.register(body, 0, 0, s.config)
		for tick in range(1, 6):
			var input := DemoInput.new()
			input.tick = tick
			input.delta = 1.0 / 60.0
			input.move = Vector2(1.0, 0.0)
			var _pushed := s.input_buffer_for(5).push(input)
		for tick in range(1, 61):
			s.server_tick(tick)
		var movement := body.behaviours[0] as Movement
		moved.append([movement.position.x, movement.velocity.length()])
		_out_of_tree(body)
		remove_child(s)
		s.free()
	# 5 ticks of input, 15 repeated, then still: 20 of 60 ticks of walking.
	_check("a silent peer is stopped after the hold (%.2f m, %.2f m/s)" % moved[0],
		absf(float(moved[0][0]) - 10.0 * 20.0 / 60.0) < 0.05 and float(moved[0][1]) == 0.0)
	_check("and with no hold repeats its last input for ever (%.2f m)" % float(moved[1][0]),
		absf(float(moved[1][0]) - 10.0) < 0.05)

	var c := DotNetManager.new()
	c.is_server = false
	c.local_peer_id = 5
	c.auto_tick = false
	c.config_file = ""
	c.service_scope = &"starve_client"
	c.config = DotNetConfig.new()
	add_child(c)
	c.setup()
	c.clock.sync_from_server(100, 0.0)
	c._snapshot_heard_tick = 100
	var held := []
	for tick in [110, 100 + ceili(c.config.prediction_hold_sec * 60.0) + 1]:
		var input := DemoInput.new()
		input.tick = tick
		input.delta = 1.0 / 60.0
		input.move = Vector2(1.0, 0.0)
		c.predict_tick(tick, input)
		held.append(input.move.x)
	_check("a client holds its input only after prediction_hold_sec without a snapshot (%s)" % str(held),
		held[0] == 1.0 and absf(held[1]) < 0.01 and int(c.describe()["held_ticks"]) == 1)
	remove_child(c)
	c.free()


## A client that learns its peer id after setup still predicts the entity it owns.
func _check_late_peer_id() -> void:
	# A client that learns its peer id after setup — from a handshake, as the lobby's does.
	# The registry kept the id it was built with, so its own entity registered as somebody
	# else's and was never predicted, on a real socket only: every loopback in the family
	# set the id before setup.
	var late := DotNetManager.new()
	late.name = "LatePeer"
	late.is_server = false
	late.service_scope = &"late_peer"
	late.local_peer_id = 0
	late.auto_tick = false
	late.config_file = ""
	late.config = DotNetConfig.new()
	add_child(late)
	var _up := late.setup()
	late.local_peer_id = 7
	var mine := _make_entity(&"player", 7)
	var _registered := late.registry.register(mine, 30, 0, late.config)
	_check("a peer id set after setup reaches the registry", late.registry.local_peer_id() == 7)
	_check("so the entity it owns is predicted", mine.is_predicted())
	mine.get_parent().free()
	remove_child(late)
	late.free()


# --- Correction offsets ---------------------------------------------------

## What a renderer adds to a predicted entity so a correction is eased: every one, and
## added to what is still easing. Nothing in the family read [method
## DotNetPredictor.visual_offset] until game-g2gfast's `headless_feel` measured a 30 cm
## correction jumping the eye in one frame.
func _test_correction_offsets() -> void:
	print("[correction offsets]")
	var config := DotNetConfig.new()
	config.enable_prediction = true
	var dt := 1.0 / 60.0

	var inputs: Array[DemoInput] = []
	for tick in range(1, 21):
		var input := DemoInput.new()
		input.tick = tick
		input.delta = dt
		input.move = Vector2(1.0, 0.0)
		inputs.append(input)

	var server_entity := _in_tree(_make_entity(&"player", 2))
	server_entity.is_authoritative = true
	var server_movement := server_entity.behaviours[0] as Movement
	var at_10 := {}
	for input in inputs:
		server_movement._net_apply_input(input, input.tick)
		server_movement._net_simulate(input.tick, dt)
		if input.tick == 10:
			at_10 = server_movement.snapshot_values().duplicate()

	var client_entity := _in_tree(_make_entity(&"player", 2))
	client_entity.is_owner = true
	client_entity.is_authoritative = false
	var client_movement := client_entity.behaviours[0] as Movement
	client_movement.moves_body = true
	var buffer := DotNetInput.Buffer.new(config.input_history_ticks)
	for input in inputs:
		buffer.push(input)
		client_movement._net_apply_input(input, input.tick)
		client_movement._net_simulate(input.tick, dt)

	var predictor := DotNetPredictor.new(config)

	# Four millimetres: under the reporting epsilon, and the size a replay from a quantised
	# state moves a player by on every snapshot.
	client_movement.position += Vector3(0.004, 0.0, 0.0)
	client_movement._move_body()
	var _small := predictor.reconcile(client_entity, 10, at_10, buffer, 20, dt)
	var small := predictor.visual_offset(client_entity.net_id)
	_check("a correction under the epsilon is not counted (%d)" % int(predictor.describe()["corrections"]),
		int(predictor.describe()["corrections"]) == 0)
	_check("and is still eased (offset %.1f mm)" % (small.length() * 1000.0),
		absf(small.length() - 0.004) < 0.001)

	# A second correction while the first is easing: added to it, not put in its place.
	client_movement.position += Vector3(0.3, 0.0, 0.0)
	client_movement._move_body()
	var _big := predictor.reconcile(client_entity, 10, at_10, buffer, 20, dt)
	var both := predictor.visual_offset(client_entity.net_id)
	_check("a second correction adds to what is still easing (%.1f mm, 304 expected)" % (both.length() * 1000.0),
		absf(both.length() - 0.304) < 0.003)

	for entity in [server_entity, client_entity]:
		_out_of_tree(entity)


## The largest change between one frame's step and the next in [param timeline].
static func _worst_step_change(timeline: Array[float]) -> float:
	var worst := 0.0
	for i in range(2, timeline.size()):
		worst = maxf(worst, absf((timeline[i] - timeline[i - 1]) - (timeline[i - 1] - timeline[i - 2])))
	return worst


## A runner on a 4 m circle at 9 m/s, its snapshots stalled for ten ticks and then all
## arriving at once, drawn through `apply` at 144 Hz: the largest change between one frame's
## step and the next. [param frames] drives `advance`, which is what turns the easing on.
func _resume_steps(config: DotNetConfig, frames: bool) -> float:
	var watcher := Interpolated.new()
	watcher.name = "Net"
	var host := Node3D.new()
	host.name = "Resumed"
	add_child(host)
	host.add_child(watcher)
	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 5
	host.add_child(identity)
	var registry := DotNetRegistry.new(false, 1)
	registry.register(identity, 91, 0, config)

	var interpolator := DotNetInterpolator.new(config)
	var omega := 9.0 / 4.0 / 64.0
	var at := func(tick: int) -> Vector3:
		return Vector3(cos(float(tick) * omega), 0.0, sin(float(tick) * omega)) * 4.0
	var pushed := -2
	var positions: Array[Vector3] = []
	for i in range(144 * 3):
		var now := float(i) * 64.0 / 144.0
		var stalled := now >= 120.0 and now < 130.0
		while not stalled and pushed + 2 <= int(now):
			pushed += 2
			interpolator.push(91, pushed, {"position": at.call(pushed)})
		if frames:
			interpolator.advance(1.0 / 144.0)
		interpolator.apply(identity, now)
		positions.append(watcher.rendered)

	host.queue_free()
	var worst := 0.0
	for i in range(144, positions.size()):
		worst = maxf(worst, ((positions[i] - positions[i - 1]) - (positions[i - 1] - positions[i - 2])).length())
	return worst


## The buffer a link that is always on time settles to, in ticks.
func _settled_delay(config: DotNetConfig) -> float:
	var interpolator := DotNetInterpolator.new(config)
	var period := config.ticks_per_snapshot()
	# Ten seconds: the buffer gives time back at 1% an arrival, by design.
	for now in range(0, 128 * 10):
		if now % period == 0:
			interpolator.note_lateness(now, now)
		interpolator.advance(1.0 / 128.0)
	# The shrink is slow by design; ask where it is heading.
	return float(interpolator.describe()["target_snapshots"]) * float(period)


## A bump-test entity: a [Pacer] the server owns, or a [Bumper] its owner predicts.
func _build_bump(_context: Dictionary, prefab: StringName, speed: float) -> Node:
	var body := Node3D.new()
	body.name = "Entity"
	var identity := DotNetIdentity.new()
	identity.name = "NetIdentity"
	identity.prefab_id = prefab
	identity.authority = (
		DotNetIdentity.Authority.SERVER if prefab == &"pacer"
		else DotNetIdentity.Authority.SHARED
	)
	body.add_child(identity)
	var behaviour: DotNetBehaviour
	if prefab == &"pacer":
		var pacer := Pacer.new()
		pacer.speed = speed
		behaviour = pacer
	else:
		behaviour = Bumper.new()
	behaviour.name = "Behaviour"
	body.add_child(behaviour)
	identity.entity = body
	identity.behaviours = [behaviour]
	behaviour.identity = identity
	behaviour._bind(DotNetConfig.new())
	return body


## [param d] with its keys in sorted order, so two dictionaries built in another order compare.
func _sorted_dict(d: Dictionary) -> Dictionary:
	var keys := d.keys()
	keys.sort()
	var out := {}
	for k: Variant in keys:
		out[k] = d[k]
	return out


## "" when [param a] and [param b] hold the same bytes in the same order, else the first index
## and size that differ.
func _first_difference(a: Array, b: Array) -> String:
	if a.size() != b.size():
		return "%d entries against %d" % [a.size(), b.size()]
	for i in a.size():
		var x: PackedByteArray = var_to_bytes(a[i])
		var y: PackedByteArray = var_to_bytes(b[i])
		if x != y:
			return "entry %d (%d B against %d B)" % [i, x.size(), y.size()]
	return ""
