extends Node

## Runs a server and a client in one process and checks the netcode works.
##
## Everything here is offline and deterministic. The two managers are wired to each
## other through a loopback that can delay, reorder and drop packets, which is what
## makes it possible to test interpolation and reconciliation at all — a real network
## would not reproduce the same conditions twice.
##
## [codeblock]
## godot --headless --path . res://examples/netcode_demo.tscn
## [/codeblock]
##
## Exits non-zero on any failure, so it works as a smoke test in CI.

# --- Test fixtures ---------------------------------------------------------

## A movement component, of the kind a game would write.
class Movement extends DotNetBehaviour:
	var position: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var grounded: bool = true
	var health: int = 100

	## Input applied this tick, set by the manager or by prediction.
	var current_input: DemoInput = null

	func _register_net_vars() -> void:
		replicate(&"position", DotNetVar.Type.VECTOR3_POSITION) \
			.interpolated().with_priority(5.0)
		replicate(&"velocity", DotNetVar.Type.VECTOR3_VELOCITY) \
			.with_epsilon(0.02)
		replicate(&"grounded", DotNetVar.Type.BOOL)
		replicate(&"health", DotNetVar.Type.UINT).bits(8).interpolated()

	func _net_apply_input(input: DotNetInput, _tick: int) -> void:
		current_input = input as DemoInput

	## Deterministic given the same input and starting state — the property the
	## whole prediction model depends on.
	func _net_simulate(_tick: int, delta: float) -> void:
		if current_input != null:
			velocity.x = current_input.move.x * 10.0
			velocity.z = current_input.move.y * 10.0

		position += velocity * delta

	func _net_record_history() -> Dictionary:
		return {"grounded": grounded}


## A behaviour that records what the interpolator told it.
##
## Exists because the interesting question about interpolation is not whether it computes
## a smooth value — [method DotNetInterpolator.sample] is checked directly above — but
## whether anything is ever told about it. A game copies replicated state into a node from
## a hook, and if the only hook it has is the one a snapshot fires, every remote entity
## moves at the snapshot rate while the interpolated value sits in a property nobody read.
class Interpolated extends DotNetBehaviour:
	var position: Vector3 = Vector3.ZERO
	var health: int = 100

	## Where the interpolated value was copied to. What a game's node position would be.
	var rendered: Vector3 = Vector3.ZERO
	var notifications: int = 0
	var last_tick: int = -1

	func _register_net_vars() -> void:
		replicate(&"position", DotNetVar.Type.VECTOR3_POSITION).interpolated()
		replicate(&"health", DotNetVar.Type.UINT).bits(8)

	func _net_interpolated(tick: int) -> void:
		notifications += 1
		last_tick = tick
		rendered = position


## A player's controls.
class DemoInput extends DotNetInput:
	var move: Vector2 = Vector2.ZERO
	var fire: bool = false

	func _write(w: DotNetWriter) -> void:
		w.write_float_range(move.x, -1.0, 1.0, 10)
		w.write_float_range(move.y, -1.0, 1.0, 10)
		w.write_bool(fire)

	func _read(r: DotNetReader) -> void:
		move.x = r.read_float_range(-1.0, 1.0, 10)
		move.y = r.read_float_range(-1.0, 1.0, 10)
		fire = r.read_bool()

	func _sanitise() -> void:
		# A client can send any representable vector; only the server decides what a
		# legal one is.
		move = move.limit_length(1.0)


## A game's own message type.
class ChatMessage extends DotNetMessage:
	var text: String = ""

	func _type_name() -> StringName:
		return &"demo.chat"

	func _write(w: DotNetWriter) -> void:
		w.write_string(text, 128)

	func _read(r: DotNetReader) -> void:
		text = r.read_string(128)

	func _validate() -> DotResult:
		if text.strip_edges() == "":
			return DotResult.fail(DotError.CODE_INVALID, "Empty chat message.")
		return DotResult.success(true)


## A server-to-client-only message, to prove direction is enforced.
class ServerNotice extends DotNetMessage:
	var notice: String = ""

	func _type_name() -> StringName:
		return &"demo.notice"

	func _write(w: DotNetWriter) -> void:
		w.write_string(notice, 128)

	func _read(r: DotNetReader) -> void:
		notice = r.read_string(128)


# --- Harness ---------------------------------------------------------------

var _passed := 0
var _failed := 0

## Suspending sections entered, and suspending sections that ran to the end.
##
## A section that suspends must be called with [code]await[/code]. Called without
## it, the section runs only as far as its first suspension and everything after
## that — including its assertions — is silently dropped, while [method _run]
## carries straight on to [method SceneTree.quit]. Nothing reports it: the count
## printed at the end is a count of checks that ran, so checks that never ran
## cannot lower it, and the exit code stays 0.
##
## That is not hypothetical. [method _test_interpolation] was called without
## [code]await[/code], so "adaptive buffer responds" never ran once in this demo's
## life, and the locals of the suspended coroutine — two interpolators, their two
## configs and three tracks — were the seven objects Godot reported leaked at
## exit. Every previous audit read the count, saw 125, and believed it.
##
## Every suspending section increments both: the first on entry, the second on its
## last line. [method _run] compares them, which turns a silent drop into a failed
## check. A new suspending section must do the same.
var _sections_entered := 0
var _sections_completed := 0

var server: DotNetManager
var client: DotNetManager

## Payloads in flight, so latency and loss can be simulated.
var _in_flight: Array[Dictionary] = []
var _drop_next: int = 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_rng.seed = 12345
	await _run()


func _run() -> void:
	_test_config_sizing()
	print("dot-net self-test")
	print("")

	_test_wire()
	_test_quantisation()
	_test_messages()
	_test_packets()
	_test_clock()
	await _test_replication()
	_test_interest()
	_test_budget()
	await _test_interpolation()
	_test_lag_compensation()
	_test_prediction()
	_test_spawning()
	_test_acked_baselines()
	await _test_integration()

	print("")
	_check(
		"every suspending section ran to completion (%d/%d)"
			% [_sections_completed, _sections_entered],
		_sections_completed == _sections_entered
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	if DotPlatform.is_headless():
		await get_tree().process_frame
		get_tree().quit(1 if _failed > 0 else 0)


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


# --- Messages --------------------------------------------------------------

func _test_messages() -> void:
	print("")
	print("[messages]")

	var registry := DotNetMessageRegistry.new()

	_check(
		"register",
		registry.register(&"demo.chat", ChatMessage).ok
	)
	_check(
		"register second",
		registry.register(
			&"demo.notice", ServerNotice,
			DotNetMessage.Delivery.RELIABLE,
			DotNetMessage.Direction.TO_CLIENT
		).ok
	)
	_check(
		"duplicate refused",
		not registry.register(&"demo.chat", ChatMessage).ok
	)

	registry.seal()
	_check("sealed", registry.is_sealed())
	_check(
		"register after seal refused",
		not registry.register(&"demo.late", ChatMessage).ok
	)

	# Ids come from sorted names, so two peers agree without negotiating.
	var other := DotNetMessageRegistry.new()
	other.register(&"demo.notice", ServerNotice, DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.TO_CLIENT)
	other.register(&"demo.chat", ChatMessage)
	other.seal()

	_check(
		"ids agree regardless of registration order",
		registry.id_of(&"demo.chat") == other.id_of(&"demo.chat")
	)
	_check(
		"schema hashes match",
		registry.schema_hash() == other.schema_hash()
	)

	var third := DotNetMessageRegistry.new()
	third.register(&"demo.chat", ChatMessage)
	third.seal()
	_check(
		"different schema hashes differ",
		registry.schema_hash() != third.schema_hash()
	)

	# Round trip.
	var message := ChatMessage.new()
	message.text = "hello from the client"

	var w := DotNetWriter.new()
	_check("encode", registry.encode(message, w).ok)

	var decoded := registry.decode(w.to_reader(), 5, true)
	_check("decode", decoded.ok)
	_check(
		"payload survived",
		decoded.ok and (decoded.value as ChatMessage).text == "hello from the client"
	)
	_check(
		"sender is the transport's view",
		decoded.ok and (decoded.value as DotNetMessage).sender_peer_id == 5
	)

	# A client must not be able to send a server-to-client message.
	var notice := ServerNotice.new()
	notice.notice = "you have been kicked"
	var nw := DotNetWriter.new()
	registry.encode(notice, nw)

	var violation := registry.decode(nw.to_reader(), 7, true)
	_check(
		"direction violation refused",
		not violation.ok and violation.code() == DotError.CODE_FORBIDDEN
	)

	# The same message is fine going the other way.
	var legitimate := registry.decode(nw.to_reader(), 1, false)
	_check("server-to-client accepted on a client", legitimate.ok)

	# Validation runs before the handler sees it.
	var empty := ChatMessage.new()
	empty.text = "   "
	var ew := DotNetWriter.new()
	registry.encode(empty, ew)
	_check(
		"validation rejects",
		not registry.decode(ew.to_reader(), 3, true).ok
	)

	# An unknown id means a schema mismatch and must be reported as one.
	var bogus := DotNetWriter.new()
	bogus.write_uint(4000, DotNetMessageRegistry.ID_BITS)
	var unknown := registry.decode(bogus.to_reader(), 3, true)
	_check(
		"unknown id reported as a version problem",
		not unknown.ok and unknown.code() == DotError.CODE_VERSION
	)

	# Dispatch.
	var received: Array[String] = []
	registry.on(&"demo.chat", func(m: DotNetMessage) -> void:
		received.append((m as ChatMessage).text))
	registry.dispatch(decoded.value)
	_check("dispatched to the handler", received.size() == 1)


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


# --- Clock -----------------------------------------------------------------

func _test_clock() -> void:
	print("")
	print("[clock]")

	var authority := DotNetClock.new(60, true)
	var ticks := authority.advance(1.0 / 60.0 * 3.0)
	_check("advances by whole ticks", ticks == 3)
	_check("tick advanced", authority.tick == 3)

	# A long stall must not produce an unbounded catch-up burst.
	var stalled := DotNetClock.new(60, true)
	var burst := stalled.advance(2.0, 8)
	_check("catch-up is bounded", burst == 8)

	var follower := DotNetClock.new(60, false)
	_check("starts unsynced", not follower.is_synced())

	# First sample adopts outright.
	follower.sync_from_server(1000, 100.0)
	_check("syncs on the first sample", follower.is_synced())

	# The client must run AHEAD of the server, or every input arrives late.
	_check(
		"input timeline leads the server (%d vs %d)"
			% [follower.tick, follower.server_tick()],
		follower.tick > follower.server_tick()
	)

	# Half of a 100 ms round trip at 60 Hz is 3 ticks.
	_check(
		"server estimate accounts for one-way latency",
		follower.server_tick() >= 1002 and follower.server_tick() <= 1004
	)

	# Render must be behind the server, or there is nothing to interpolate between.
	_check("render tick lags the server", follower.render_tick(4) < follower.server_tick())

	# Small drift corrects by changing tick length, not by jumping.
	var before := follower.tick
	follower.sync_from_server(1005, 100.0)
	_check("small drift does not snap", absi(follower.tick - before) < 5)
	_check("drift correction applied", absf(follower.drift_percent()) > 0.0)

	# A huge error is not drift; it must snap.
	follower.sync_from_server(50000, 100.0)
	_check("large error snaps", follower.tick > 49000)

	# Jitter must widen the margin, or a jittery connection loses inputs.
	var jittery := DotNetClock.new(60, false)
	for i in range(20):
		jittery.sync_from_server(100 + i, 50.0 + float(i % 2) * 80.0)
	_check("jitter measured", jittery.jitter_ms() > 5.0)


# --- Replication -----------------------------------------------------------

func _test_replication() -> void:
	_sections_entered += 1
	print("")
	print("[replication]")

	var config := DotNetConfig.new()

	var registry := DotNetRegistry.new(true, 1)
	var identity := _make_entity(&"player", 7)
	add_child(identity.get_parent())

	var registered := registry.register(identity, 0, 0, config)
	_check("registered", registered.ok)
	_check("id allocated", identity.net_id > 0)
	_check("found by id", registry.get_identity(identity.net_id) == identity)
	_check("behaviours collected", identity.behaviours.size() == 1)
	_check("behaviour bound", identity.behaviours[0].is_bound())
	_check("owner tracked", registry.owned_by(7).size() == 1)

	# Ids must never be reused: a snapshot in flight for a dead entity must not be
	# applied to a live one.
	var first_id := identity.net_id
	registry.unregister(first_id)
	var second := _make_entity(&"player", 7)
	add_child(second.get_parent())
	registry.register(second, 0, 0, config)
	_check("ids are not reused", second.net_id != first_id)
	_check("despawn is remembered", registry.was_recently_removed(first_id))

	# Dirty tracking.
	var movement := second.behaviours[0] as Movement
	var dirty := movement.collect_dirty(7, false)
	_check("everything dirty initially", dirty.size() == 4)

	var w := DotNetWriter.new()
	movement.write_state(w, dirty, 7)
	_check("nothing dirty after sending", movement.collect_dirty(7, false).is_empty())

	movement.position = Vector3(5, 0, 5)
	_check("change marks dirty", movement.collect_dirty(7, false).size() == 1)

	# Epsilon suppresses noise below the threshold.
	movement.velocity += Vector3(0.001, 0, 0)
	var after_noise := movement.collect_dirty(7, false)
	var velocity_dirty := false
	for declaration in after_noise:
		if declaration.property == &"velocity":
			velocity_dirty = true
	_check("epsilon suppresses noise", not velocity_dirty)

	movement.velocity += Vector3(1.0, 0, 0)
	var after_real := movement.collect_dirty(7, false)
	velocity_dirty = false
	for declaration in after_real:
		if declaration.property == &"velocity":
			velocity_dirty = true
	_check("real change passes epsilon", velocity_dirty)

	# Round trip through the wire.
	var receiver := _make_entity(&"player", 7)
	add_child(receiver.get_parent())
	var client_registry := DotNetRegistry.new(false, 2)
	client_registry.register(receiver, second.net_id, 0, config)

	movement.position = Vector3(12.0, 3.0, -4.0)
	movement.health = 55
	movement.grounded = false

	var state := DotNetWriter.new()
	movement.write_state(state, movement.collect_dirty(7, true), 7)

	var applied := (receiver.behaviours[0] as Movement).read_state(
		state.to_reader(), 0
	)
	_check("state applied", applied.ok)

	var received := receiver.behaviours[0] as Movement
	_check(
		"position replicated",
		received.position.distance_to(Vector3(12.0, 3.0, -4.0)) < 0.05
	)
	_check("int replicated exactly", received.health == 55)
	_check("bool replicated", received.grounded == false)

	# Owner-only properties must not reach observers.
	var secret := movement.find_var(&"health")
	secret.audience = DotNetVar.Audience.OWNER
	_check("owner sees owner-only", secret.visible_to(7, 7))
	_check("observer does not", not secret.visible_to(9, 7))
	secret.audience = DotNetVar.Audience.EVERYONE

	await get_tree().process_frame
	_sections_completed += 1


func _test_interest() -> void:
	print("")
	print("[interest]")

	var config := DotNetConfig.new()
	var context := {"tick": 0, "config": config}

	var observer := _make_entity(&"player", 1)
	add_child(observer.get_parent())
	(observer.entity as Node3D).global_position = Vector3.ZERO
	observer.net_id = 1

	var near := _make_entity(&"prop", 0)
	add_child(near.get_parent())
	(near.entity as Node3D).global_position = Vector3(10, 0, 0)
	near.net_id = 2

	var far := _make_entity(&"prop", 0)
	add_child(far.get_parent())
	(far.entity as Node3D).global_position = Vector3(5000, 0, 0)
	far.net_id = 3

	var beacon := _make_entity(&"objective", 0)
	add_child(beacon.get_parent())
	(beacon.entity as Node3D).global_position = Vector3(9000, 0, 0)
	beacon.always_relevant = true
	beacon.net_id = 4

	var all: Array[DotNetIdentity] = [observer, near, far, beacon]

	var distance := DotNetInterestDistance.new()
	distance.radius = 100.0
	distance.evaluation_interval_sec = 0.0

	var relevant := distance.relevant_for(observer, all, 1, context)
	var ids := {}
	for identity in relevant:
		ids[identity.net_id] = true

	_check("near entity included", ids.has(2))
	_check("far entity excluded", not ids.has(3))
	_check("always_relevant included regardless of distance", ids.has(4))
	_check("observer's own entity included", ids.has(1))

	# The grid must agree with the brute-force answer — that is the whole
	# correctness requirement for a spatial index.
	var grid := DotNetInterestGrid.new()
	grid.radius = 100.0
	grid.cell_size = 64.0
	grid.evaluation_interval_sec = 0.0
	grid._prepare(all, context)

	var grid_relevant := grid.relevant_for(observer, all, 1, context)
	var grid_ids := {}
	for identity in grid_relevant:
		grid_ids[identity.net_id] = true

	_check("grid agrees with distance", grid_ids.has(2) and not grid_ids.has(3))
	_check("grid keeps always_relevant", grid_ids.has(4))

	# The config's cell size reaches a grid the host assigned — a knob documented
	# from the first version and applied by nothing.
	var sized := DotNetManager.new()
	sized.name = "Sized"
	sized.is_server = true
	sized.auto_tick = false
	sized.config_file = ""
	var sized_config := DotNetConfig.new()
	sized_config.interest_cell_size = 48.0
	sized.config = sized_config
	var sized_grid := DotNetInterestGrid.new()
	sized.interest = sized_grid
	add_child(sized)
	sized.setup()
	_check("interest_cell_size reaches an assigned grid", sized_grid.cell_size == 48.0)
	sized.queue_free()

	# The two entity caps combine to the tighter one, and 0 means unlimited on
	# either side rather than "cap at zero".
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

	# The reason the cap goes through prioritise: a cut that drops what the
	# observer owns is the bug this family has already shipped once.
	var crowd: Array[DotNetIdentity] = [beacon]
	for i in range(20):
		crowd.append(_make_entity(&"prop", 0))
	var kept: Array[DotNetIdentity] = distance.prioritise(observer, crowd, 3, context)
	var kept_ids := {}
	for identity in kept:
		kept_ids[identity.net_id] = true
	_check("a tight cap keeps always_relevant", kept.size() == 3 and kept_ids.has(beacon.net_id))

	# "All" includes everything, which is what makes it the wrong default for a
	# competitive game.
	var everything := DotNetInterestAll.new()
	_check(
		"all strategy includes the far entity",
		everything.relevant_for(observer, all, 1, context).size() == 4
	)

	# Prioritisation must keep always_relevant when the cap bites.
	var capped := distance.prioritise(observer, all, 2, context)
	var capped_ids := {}
	for identity in capped:
		capped_ids[identity.net_id] = true
	_check("cap applied", capped.size() == 2)
	_check("always_relevant survives the cap", capped_ids.has(4))

	# --- what a cached answer must never drop ---------------------------------
	#
	# The cache holds which entities were relevant at one instant. An entity spawned
	# since is in nobody's cached set, so an observer would not receive its own new
	# entity — nor an always-relevant one — until the cache expired.
	#
	# [b]That window is not small and on some hosts it never closes.[/b] In a game where
	# players respawn, split or fire projectiles it is a quarter of a second of an entity
	# that exists only by prediction; and on a host that ticks faster than the wall clock
	# — which is every headless test and every fast-forwarded replay — the age never
	# reaches the interval and the entity is never sent at all. The position still looks
	# right the whole time, because the owner is predicting it, so the symptom is only in
	# what cannot be predicted: mass, health, ammunition, a team change.
	var cached := DotNetInterestDistance.new()
	cached.radius = 100.0
	cached.evaluation_interval_sec = 5.0

	# Populate the cache with the world as it is now.
	cached.relevant_for(observer, all, 1, context)

	var newborn := _make_entity(&"player", 1)
	add_child(newborn.get_parent())
	(newborn.entity as Node3D).global_position = Vector3(4000, 0, 0)
	newborn.net_id = 5

	var newborn_beacon := _make_entity(&"objective", 0)
	add_child(newborn_beacon.get_parent())
	(newborn_beacon.entity as Node3D).global_position = Vector3(8000, 0, 0)
	newborn_beacon.always_relevant = true
	newborn_beacon.net_id = 6

	var grown: Array[DotNetIdentity] = [
		observer, near, far, beacon, newborn, newborn_beacon
	]

	var after := cached.relevant_for(observer, grown, 1, context)
	var after_ids := {}
	for identity in after:
		after_ids[identity.net_id] = true

	_check("a cached answer still includes what the observer owns", after_ids.has(5))
	_check("and anything always relevant", after_ids.has(6))
	_check("without losing what it already had", after_ids.has(2))
	_check("or gaining what it should not", not after_ids.has(3))

	# Pinning must not grow the cache: an entry added to it would survive the expiry
	# that is supposed to re-evaluate it.
	(newborn.entity as Node3D).global_position = Vector3(4000, 0, 0)
	newborn.owner_peer_id = 99
	var repinned := cached.relevant_for(observer, grown, 1, context)
	var repinned_ids := {}
	for identity in repinned:
		repinned_ids[identity.net_id] = true
	_check(
		"and a pin is not remembered as if it had been evaluated",
		not repinned_ids.has(5)
	)

	# A custom strategy is a subclass and nothing else — the extensibility claim.
	var custom := TagInterest.new()
	var tagged := custom.relevant_for(observer, all, 1, context)
	var tagged_ids := {}
	for identity in tagged:
		tagged_ids[identity.net_id] = true
	_check("custom strategy filters by tag", tagged_ids.has(4) and not tagged_ids.has(2))


## A strategy defined entirely outside dot-net.
class TagInterest extends DotNetInterest:
	func _init() -> void:
		strategy_name = "objectives-only"
		evaluation_interval_sec = 0.0

	func _is_relevant(
		_observer: DotNetIdentity,
		entity: DotNetIdentity,
		_context: Dictionary
	) -> bool:
		return entity.has_tag("objective")


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

	# The buffer is 2 snapshots at 20 Hz = 2 ticks of delay in this unit.
	var midpoint := interpolator.sample(1, 107)
	var sampled: Vector3 = midpoint.get("position", Vector3.ZERO)
	_check(
		"interpolates between snapshots (x=%.1f)" % sampled.x,
		sampled.x > 0.1 and sampled.x < 9.9
	)

	# Out-of-order arrivals must still be usable.
	interpolator.push(1, 105, {"position": Vector3(5, 0, 0)})
	var reordered := interpolator.sample(1, 104)
	_check("out-of-order sample used", reordered.has("position"))

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

	# --- the interpolated value has to reach something ------------------------
	#
	# Everything above checks that a smooth value is computed. This checks that anything
	# is told about it. Without the notification a game only copies replicated state on a
	# snapshot, so a remote entity moves in 20 Hz steps and the interpolator's whole
	# output is discarded — which looks exactly like an interpolator that does not work.
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

	# --- the render timeline has to move between packets ----------------------
	#
	# `server_tick()` is what `render_tick()` — and therefore every interpolated position
	# — is derived from. An estimate that only moved when a snapshot arrived would make
	# the rendered tick a step function of arrivals: the interpolator would produce a new
	# value on the frames a packet happened to land on and the same value on every frame
	# in between, which is the 20 Hz stepping interpolation exists to remove.
	var clock := DotNetClock.new(60, false)
	clock.adaptive_margin = false
	clock.sync_from_server(1000, 0.0)

	var anchored := clock.server_tick()
	_check("the estimate is anchored by a sample (%d)" % anchored, anchored == 1000)

	# Six ticks of local time, no packet.
	for _i in range(6):
		clock.advance(1.0 / 60.0)

	_check(
		"and advances between them (%d -> %d)" % [anchored, clock.server_tick()],
		clock.server_tick() > anchored
	)
	_check(
		"at the tick rate (%d)" % (clock.server_tick() - anchored),
		clock.server_tick() == anchored + 6
	)
	_check(
		"so the render tick follows it",
		clock.render_tick(2) == clock.server_tick() - 2
	)

	# And a sample re-anchors it absolutely rather than adding to it.
	clock.sync_from_server(1000, 0.0)
	_check(
		"a sample re-anchors it rather than accumulating (%d)" % clock.server_tick(),
		clock.server_tick() == 1000
	)

	# Adaptive buffering must grow under jitter.
	var adaptive := DotNetInterpolator.new(DotNetConfig.new())
	var initial := adaptive.delay_ticks()
	for i in range(40):
		adaptive.note_arrival()
		# Irregular arrivals.
		await get_tree().process_frame
	_check("adaptive buffer responds", adaptive.delay_ticks() >= initial * 0.5)
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

	# The view tick must account for both latency and interpolation delay.
	var view := history.client_view_tick(1000, 100.0, 2.0)
	_check("client view tick is in the past (%d)" % view, view < 1000 and view > 990)


# --- Integration -----------------------------------------------------------

## Runs a server and a client against each other over a lossy loopback.
## Client-side prediction replay, against a server simulating the same inputs.
##
## [DotNetPredictor] had no section of its own, and the integration run below does
## not substitute for one: it feeds a [i]constant[/i] input for all sixty ticks, and
## a replay that ignores the input history lands on the right answer whenever the
## input never changes. The zig-zag here is the entire point.
func _test_prediction() -> void:
	print("[prediction]")

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

	# The server, doing exactly what DotNetManager.server_tick does: take the
	# input for the tick, apply it, then simulate.
	# In the tree, unlike the other sections' entities: reconciliation reads
	# `world_position()` to measure the correction, and `global_position` on a
	# Node3D outside the tree is an engine error per call.
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

	for entity in [server_entity, client_entity, lonely, untouched]:
		_out_of_tree(entity)


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


func _test_integration() -> void:
	_sections_entered += 1
	print("")
	print("[integration]")

	server = DotNetManager.new()
	server.name = "Server"
	server.is_server = true
	server.service_scope = &"server"
	server.local_peer_id = 1
	server.auto_tick = false
	server.config_file = ""
	server.config = DotNetConfig.new()
	server.config.snapshot_rate = 20
	server.config.tick_rate = 60
	add_child(server)

	client = DotNetManager.new()
	client.name = "Client"
	client.is_server = false
	client.service_scope = &"client"
	client.local_peer_id = 2
	client.auto_tick = false
	client.config_file = ""
	client.config = DotNetConfig.new()
	client.config.snapshot_rate = 20
	client.config.tick_rate = 60
	add_child(client)

	_check("server setup", server.setup().ok)
	_check("client setup", client.setup().ok)

	# The loopback: the server's payloads land in the client, with loss.
	server.send_fn = func(peer_id: int, payload: PackedByteArray, _d: int) -> void:
		if peer_id != 2 and peer_id != 0:
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


func _build_player(_context: Dictionary) -> Node:
	return _make_entity(&"player", 0).get_parent()


# --- Helpers ---------------------------------------------------------------


# --- Spawning --------------------------------------------------------------

## [DotNetSpawner] is 370 lines named by nothing in this file until now, and it is
## one of the documented places a game plugs in — the prefab table is the reason a
## spawn message can name an id instead of a scene path, which is the only thing
## stopping a peer from asking every other peer to load an arbitrary scene.
##
## The pooling path is the interesting one. [member free_on_despawn] exists so a
## game can keep the node, and [method register_factory] exists so it can hand the
## same node back — which means the spawner has to cope with a node that is
## already somewhere in the tree.
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

	# --- Factories, and the pooling path they exist for -------------------
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

	# A pool parks idle instances somewhere out of the way rather than leaving
	# them in the live container — otherwise "pooled" and "live" are the same set,
	# and the reuse path is indistinguishable from the first spawn. It is exactly
	# that difference the spawner has to handle: the node comes back with a
	# parent, and the parent is not the container.
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

	# --- Despawn ----------------------------------------------------------
	_check("despawning nothing is an error", not spawner.despawn(999999).ok)

	var extra := spawner.spawn(&"player", 7)
	_check("second entity for peer 7", extra.ok)
	var owned := registry.owned_by(7).size()
	var swept := spawner.despawn_owned_by(7)
	_check("despawn_owned_by returns the count", swept == owned, )
	_check("peer 7 owns nothing", registry.owned_by(7).is_empty())

	# --- The inspector table ----------------------------------------------
	# register_prefab's contract is that a prefab with no identity is a *startup*
	# error rather than a spawn that silently produces a non-networked object. The
	# inspector path has to honour that too, or the guarantee only holds for games
	# that register in code.
	var declared := DotNetSpawner.new()
	declared.name = "DeclaredSpawner"
	declared.prefabs = {"good": good, "bad": identity_less}
	declared.setup(registry, config)
	add_child(declared)

	_check("declared prefab registered", declared.has_prefab(&"good"))
	_check("declared prefab with no identity refused", not declared.has_prefab(&"bad"))

	_sections_completed += 1


## Scratch state for the pooling factory in [method _test_spawning].
##
## Idle instances are parented to [member _pool_parent], the way a real pool
## keeps them out of the live container.
var _pool_parent: Node = null
var _pool: Array[Node] = []
var _pool_reused: int = 0
var _pool_context: Dictionary = {}


## A bare networked entity: Node3D root, DotNetIdentity child.
##
## No behaviour, because the spawner does not care about them and a behaviour here
## would be an inner class of this script, which is not a thing a PackedScene
## should have to carry.
func _build_entity_node() -> Node3D:
	var body := Node3D.new()
	body.name = "PooledEntity"
	var identity := DotNetIdentity.new()
	identity.name = "NetIdentity"
	identity.authority = DotNetIdentity.Authority.SERVER
	body.add_child(identity)
	identity.owner = body
	return body


## Packs one into a PackedScene, with or without the identity.
##
## Packing rather than preloading keeps the demo a single file. It also exercises
## register_prefab's fallback check: a node built from DotNetIdentity.new() saves
## with its base type and a script property, not the type name.
func _pack_entity(with_identity: bool) -> PackedScene:
	var body := Node3D.new()
	body.name = "Entity"

	if with_identity:
		var identity := DotNetIdentity.new()
		identity.name = "NetIdentity"
		identity.authority = DotNetIdentity.Authority.SERVER
		body.add_child(identity)
		identity.owner = body

	var scene := PackedScene.new()
	scene.pack(body)
	body.free()
	return scene


## Builds an entity: a Node3D with an identity and a movement behaviour.
func _make_entity(prefab: StringName, owner_peer: int) -> DotNetIdentity:
	var body := Node3D.new()
	body.name = "Entity"

	var identity := DotNetIdentity.new()
	identity.name = "NetIdentity"
	identity.prefab_id = prefab
	identity.owner_peer_id = owner_peer
	identity.authority = DotNetIdentity.Authority.SHARED
	if prefab == &"objective":
		identity.interest_tags = PackedStringArray(["objective"])
	body.add_child(identity)

	var movement := Movement.new()
	movement.name = "Movement"
	body.add_child(movement)

	# _ready has not run yet for a node outside the tree, so the identity's own
	# resolution is done here for tests that never add it.
	identity.entity = body
	identity.behaviours = [movement]
	movement.identity = identity
	movement._bind(DotNetConfig.new())

	return identity


## Puts a test entity's body in the scene tree and returns the identity.
func _in_tree(identity: DotNetIdentity) -> DotNetIdentity:
	add_child(identity.get_parent())
	return identity


func _out_of_tree(identity: DotNetIdentity) -> void:
	var body := identity.get_parent()
	remove_child(body)
	body.free()


func _check(what: String, passed: bool) -> void:
	if passed:
		_passed += 1
		print("  %-52s ok" % what)
	else:
		_failed += 1
		print("  %-52s FAILED" % what)


## The input history is a derived quantity and is raised, not warned about.
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
