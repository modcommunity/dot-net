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

	## Whether a tick moves the entity's node too, as a game's does. The predictor measures
	## a correction off the node ([method DotNetIdentity.world_position]); off by default
	## so every section written before it sees the node it always saw.
	var moves_body: bool = false

	## Whether the simulation runs on state of its own, copied into the properties after
	## each tick and back out of them in [method _net_state_applied], as every game's
	## controller does. Off by default: the sections before it simulate on the properties.
	var keeps_own_state: bool = false
	## False plays a dead player: DotNetBehaviour._net_predicts.
	var predicts: bool = true
	var _sim_position: Vector3 = Vector3.ZERO
	var _sim_velocity: Vector3 = Vector3.ZERO

	func _net_predicts() -> bool:
		return predicts

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
		if keeps_own_state:
			if current_input != null:
				_sim_velocity.x = current_input.move.x * 10.0
				_sim_velocity.z = current_input.move.y * 10.0
			_sim_position += _sim_velocity * delta
			position = _sim_position
			velocity = _sim_velocity
			return
		if current_input != null:
			velocity.x = current_input.move.x * 10.0
			velocity.z = current_input.move.y * 10.0

		position += velocity * delta
		if moves_body:
			_move_body()

	func _net_state_applied(_tick: int) -> void:
		if keeps_own_state:
			_sim_position = position
			_sim_velocity = velocity

	func _move_body() -> void:
		var body := get_parent() as Node3D
		if body != null and body.is_inside_tree():
			body.global_position = position

	func _net_record_history() -> Dictionary:
		return {"grounded": grounded}


## A behaviour that records what the interpolator told it.
##
## Exists because the interesting question about interpolation is not whether it computes
## a smooth value — [method DotNetInterpolator.sample] is checked directly above — but
## whether anything is ever told about it. A game copies replicated state into a node from
## a hook, and if the only hook it has is the one a snapshot fires, every remote entity
## moves at the snapshot rate while the interpolated value sits in a property nobody read.
## Counts the engine's own errors while installed. The only way a suite can assert that
## something produced NO `Condition "!is_inside_tree()"` line: those go to stderr, change no
## exit code, and a green run that prints ten of them is the shape this family keeps
## finding in its logs.
class EngineErrors extends Logger:
	var _lock := Mutex.new()
	var _seen := PackedStringArray()

	func _log_error(
		_function: String, _file: String, _line: int, code: String, _rationale: String,
		_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]
	) -> void:
		_lock.lock()
		_seen.append(code)
		_lock.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func count() -> int:
		_lock.lock()
		var n := _seen.size()
		_lock.unlock()
		return n


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


## A [Movement] that counts its own ticks and, once, unregisters another entity and takes it
## out of the tree from inside its `_net_simulate`: a round re-laying its map mid-tick (#30).
class Unregisters extends Movement:
	var host: DotNetManager = null
	var victim: DotNetIdentity = null
	var simulated: int = 0

	func _net_simulate(tick: int, delta: float) -> void:
		simulated += 1
		super._net_simulate(tick, delta)
		if victim != null and host != null:
			var _gone := host.registry.unregister(victim.net_id)
			var body := victim.get_parent()
			if body != null and body.get_parent() != null:
				body.get_parent().remove_child(body)
			victim = null


## A [Movement] that records every snapshot that told it anything, as a game's per-snapshot
## bookkeeping does (`last_state_tick`, a relevance check, a redraw).
class Counted extends Movement:
	var applied: int = 0
	var last_applied: int = -1

	func _net_state_applied(tick: int) -> void:
		applied += 1
		last_applied = tick


## A [Counted] with the property kinds the pooled build has to encode the same as the inline
## one: a string and a byte array (byte-aligned, so their bits depend on where they start),
## and a property limited to a rate far too slow to send twice in a run.
class Rich extends Counted:
	var title: String = ""
	var blob: PackedByteArray = PackedByteArray()
	var rated: int = 0

	func _register_net_vars() -> void:
		super._register_net_vars()
		replicate(&"title", DotNetVar.Type.STRING)
		replicate(&"blob", DotNetVar.Type.BYTES)
		replicate(&"rated", DotNetVar.Type.UINT).bits(16).at_most(0.01)


## A [Movement] that, on one tick and from inside its `_net_simulate`, spawns the first entity
## a peer owns: that peer's observer is registered after the tick's identity list was read.
class SpawnsFirst extends Movement:
	var host: DotNetManager = null
	var peer: int = 0
	var at_tick: int = 3
	var spawned: bool = false

	func _net_simulate(tick: int, delta: float) -> void:
		super._net_simulate(tick, delta)
		if not spawned and tick == at_tick and host != null:
			spawned = true
			var _made := host.spawner.spawn(&"counted", peer, Transform3D.IDENTITY, tick)


## Distance interest that records whether it was ever asked about an observer whose position
## was not frozen, from any thread: the worker's read the freeze exists to prevent.
class FrozenProbe extends DotNetInterestDistance:
	var unfrozen_asks: int = 0
	var asks_with_observer: int = 0

	func _is_relevant(observer: DotNetIdentity, entity: DotNetIdentity, context: Dictionary) -> bool:
		if observer != null:
			asks_with_observer += 1
			if not observer.is_position_frozen():
				unfrozen_asks += 1
		return super._is_relevant(observer, entity, context)

	func is_thread_safe() -> bool:
		return true


## A bot the server walks back and forth along x at a constant speed, reversing at once at
## each end: a pure function of the tick ([method at]), so the server's truth at any tick is
## known without asking the server. On a receiving client it records what it last heard.
class Pacer extends DotNetBehaviour:
	const NEAR_X := 1.5
	const FAR_X := 5.5

	var position: Vector3 = Vector3(FAR_X, 0.0, 0.0)
	var velocity: Vector3 = Vector3.ZERO
	var speed: float = 4.0

	## The snapshot tick the client last heard this bot at, and where. -1 until then.
	var heard_tick: int = -1
	var heard_position: Vector3 = Vector3.ZERO

	func _register_net_vars() -> void:
		replicate(&"position", DotNetVar.Type.VECTOR3_POSITION).interpolated()
		replicate(&"velocity", DotNetVar.Type.VECTOR3_VELOCITY)

	## Where the server has it after simulating [param tick]: from the far end toward the
	## player, back, and again.
	func at(tick: int, delta: float) -> Array:
		var span := FAR_X - NEAR_X
		var travelled := fposmod(float(tick) * delta * speed, 2.0 * span)
		if travelled < span:
			return [Vector3(FAR_X - travelled, 0.0, 0.0), Vector3(-speed, 0.0, 0.0)]
		return [Vector3(NEAR_X + travelled - span, 0.0, 0.0), Vector3(speed, 0.0, 0.0)]

	func _net_simulate(tick: int, delta: float) -> void:
		var now := at(tick, delta)
		position = now[0]
		velocity = now[1]

	func _net_state_applied(tick: int) -> void:
		var said := received_values()
		heard_tick = tick
		heard_position = said.get(&"position", heard_position)


## A predicted player that walks +x into a [Pacer] and is pushed back out of it along x:
## the smallest simulation in which a client predicts a bump against something it does not
## predict. [member obstacle_at] answers where the bot is
## for a tick, `Vector3.INF` for "collide with nothing"; the server's answer is the truth,
## the client's is whatever estimate is under test.
class Bumper extends DotNetBehaviour:
	## Two capsule radii, 0.35 m each, as dot-player-controller's standing hull.
	const APART := 0.7
	const WALK := 3.0

	var position: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var current_input: DemoInput = null
	var obstacle_at: Callable = Callable()

	func _register_net_vars() -> void:
		replicate(&"position", DotNetVar.Type.VECTOR3_POSITION).interpolated()
		replicate(&"velocity", DotNetVar.Type.VECTOR3_VELOCITY)

	func _net_apply_input(input: DotNetInput, _tick: int) -> void:
		current_input = input as DemoInput

	func _net_simulate(tick: int, delta: float) -> void:
		if current_input != null:
			velocity = Vector3(current_input.move.x, 0.0, current_input.move.y) * WALK
		position += velocity * delta
		if not obstacle_at.is_valid():
			return
		var bot: Vector3 = obstacle_at.call(tick)
		if not bot.is_finite():
			return
		# Along x only, as in a corridor one hull wide: the quantised position carries a few
		# millimetres of z, and a disc push would turn them into a sideways slide.
		if absf(position.x - bot.x) < APART:
			position.x = bot.x + signf(position.x - bot.x + 0.0001) * APART


## Relevant unless excluded, by net id. What "it walked out of view" is to a test.
class ExcludeInterest extends DotNetInterest:
	var excluded := {}

	func _init() -> void:
		strategy_name = "all-but"
		evaluation_interval_sec = 0.0

	func _is_relevant(
		_observer: DotNetIdentity,
		entity: DotNetIdentity,
		_context: Dictionary
	) -> bool:
		return not excluded.has(entity.net_id)


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


## [code]demo.chat[/code] one build later: a field appended, read behind has_more().
class ChatMessageV2 extends DotNetMessage:
	var text: String = ""
	var colour: int = 7

	func _type_name() -> StringName:
		return &"demo.chat"

	func _write(w: DotNetWriter) -> void:
		w.write_string(text, 128)
		w.write_uint(colour, 8)

	func _read(r: DotNetReader) -> void:
		text = r.read_string(128)
		if r.has_more():
			colour = r.read_uint(8)


## A type one end has and the other does not, which a peer can do without.
class ExtraMessage extends DotNetMessage:
	var value: int = 0

	func _type_name() -> StringName:
		return &"demo.extra"

	func _write(w: DotNetWriter) -> void:
		w.write_uint(value, 16)

	func _read(r: DotNetReader) -> void:
		value = r.read_uint(16)


## A type one end has and REQUIRES, which a peer cannot do without.
class VitalMessage extends DotNetMessage:
	func _type_name() -> StringName:
		return &"demo.vital"

	func _write(_w: DotNetWriter) -> void:
		pass

	func _read(_r: DotNetReader) -> void:
		pass


# --- Harness ---------------------------------------------------------------

var _passed := 0
var _failed := 0

## Every check this suite makes, the last one included. The section counter below cannot
## see a check that never ran inside a section that had already announced itself — a
## runtime error aborts the rest of that function and the counter is satisfied — so the
## total is compared with this. Raise it with every check added.
const CHECKS := 444

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
	_test_count_limits()
	print("dot-net self-test")
	print("")

	_test_wire()
	_test_bit_runs()
	_test_quantisation()
	_test_messages()
	_test_mismatched_schemas()
	_test_packets()
	_test_clock()
	await _test_replication()
	_test_interest()
	_test_budget()
	await _test_interpolation()
	_test_render_delay()
	_test_lag_compensation()
	_test_prediction()
	_test_correction_offsets()
	_test_buffer_growth()
	_test_drawing_through_slips()
	_test_spawning()
	_test_freed_entity()
	_test_unregistered_mid_tick()
	_test_acked_baselines()
	_test_shared_dirty_sets()
	_test_standing_still()
	_test_remote_bumps()
	_test_reconcile_once_per_frame()
	_test_skip_matching_replays(false)
	_test_skip_matching_replays(true)
	_test_staggered_snapshots()
	_test_reordered_and_repeated()
	_test_snapshot_parts()
	_test_unchanged_entities()
	_test_snapshot_threads()
	_test_input_batches()
	_test_input_lead()
	_test_dropped_time()
	_test_join_hitch()
	await _test_dropped_time_live()
	await _test_integration()

	print("")
	_check(
		"every suspending section ran to completion (%d/%d)"
			% [_sections_completed, _sections_entered],
		_sections_completed == _sections_entered
	)

	_check(
		"every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS],
		_passed + _failed + 1 == CHECKS
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

	# An unknown id is a type this end does not have -- what a peer one build ahead
	# sends. It is skipped, by its framed length, and is not an error.
	var bogus := DotNetWriter.new()
	bogus.write_uint(4000, DotNetMessageRegistry.ID_BITS)
	bogus.write_varint(0)
	var before := registry.skipped
	var unknown := registry.decode(bogus.to_reader(), 3, true)
	_check(
		"an unknown id is skipped rather than refused",
		unknown.ok and unknown.value == null and registry.skipped == before + 1
	)

	# A body claiming more bits than the payload holds is truncated, and that still is an
	# error: the length is what makes skipping possible, so it has to be believable.
	var short := DotNetWriter.new()
	short.write_uint(registry.id_of(&"demo.chat"), DotNetMessageRegistry.ID_BITS)
	short.write_varint(4000)
	_check(
		"a body longer than the payload is a parse failure",
		registry.decode(short.to_reader(), 3, true).code() == DotError.CODE_PARSE
	)

	# Dispatch.
	var received: Array[String] = []
	registry.on(&"demo.chat", func(m: DotNetMessage) -> void:
		received.append((m as ChatMessage).text))
	registry.dispatch(decoded.value)
	_check("dispatched to the handler", received.size() == 1)


## Two ends built from different sources: the point of deriving ids from names.
##
## "Old" registers less than "new". Old must skip what it does not have and carry on --
## mid-batch included -- a field appended to a shared type must cross in both directions,
## and a REQUIRED type one end lacks must be refused with a sentence rather than a
## decode error an hour later.
func _test_mismatched_schemas() -> void:
	print("")
	print("[mismatched schemas]")

	var old := DotNetMessageRegistry.new()
	old.register(&"demo.chat", ChatMessage)
	old.seal()

	var new := DotNetMessageRegistry.new()
	new.register(&"demo.chat", ChatMessageV2)
	new.register(&"demo.extra", ExtraMessage, DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.BOTH, false)
	new.seal()

	_check(
		"a type has the same wire id whatever else is registered",
		old.id_of(&"demo.chat") == new.id_of(&"demo.chat")
			and old.id_of(&"demo.chat") == DotNetMessageRegistry.wire_id_for(&"demo.chat")
	)
	_check(
		"an extra OPTIONAL type does not change the schema hash",
		old.schema_hash() == new.schema_hash()
	)

	# The tables cross, both ways, and neither end refuses.
	_check(
		"the old end adopts the new end's table",
		old.adopt_peer_schema(1, _schema_body(new.schema_payload()), false).ok
	)
	_check(
		"and the new end adopts the old end's",
		new.adopt_peer_schema(5, _schema_body(old.schema_payload()), true).ok
	)
	_check(
		"each knows what the other has",
		old.peer_has(1, &"demo.extra") and not new.peer_has(5, &"demo.extra")
	)

	# New sends [extra, chat, extra] in one batch. Old has no idea what an extra is.
	var batch := DotNetPacket.Batch.new(9)
	var e1 := ExtraMessage.new()
	e1.value = 1234
	batch.add(e1, 4)
	var line := ChatMessageV2.new()
	line.text = "still here"
	line.colour = 42
	batch.add(line, 16)
	batch.add(ExtraMessage.new(), 4)

	var encoded := DotNetPacket.encode_batch(batch, new)
	var skipped_before := old.skipped
	var decoded := DotNetPacket.decode_batch(encoded.value, old, 1, false)
	var got: Array = (decoded.value as Dictionary)["messages"] if decoded.ok else []
	_check(
		"the old end skips both unknown messages and keeps the one between them",
		decoded.ok and got.size() == 1 and old.skipped == skipped_before + 2
	)
	_check(
		"reading the fields it knows of a newer version of its own type",
		got.size() == 1 and (got[0] as ChatMessage).text == "still here"
	)

	# And the other way: an old chat into a new reader, whose appended field keeps its
	# default because the older sender never wrote it.
	var old_line := ChatMessage.new()
	old_line.text = "from the past"
	var ow := DotNetWriter.new()
	old.encode(old_line, ow)
	var into_new := new.decode(ow.to_reader(), 5, true)
	_check(
		"a newer reader gets the old fields",
		into_new.ok and (into_new.value as ChatMessageV2).text == "from the past"
	)
	_check(
		"and keeps its default for the field the old sender did not write (%s)"
			% (str((into_new.value as ChatMessageV2).colour) if into_new.ok else "-"),
		into_new.ok and (into_new.value as ChatMessageV2).colour == 7
	)

	# A REQUIRED type one end lacks. The old client meets a server that requires
	# demo.vital, in both of the places the check runs.
	var strict := DotNetMessageRegistry.new()
	strict.register(&"demo.chat", ChatMessageV2)
	strict.register(&"demo.vital", VitalMessage)
	strict.seal()

	_check(
		"a REQUIRED type changes the schema hash",
		strict.schema_hash() != old.schema_hash()
	)

	var refusals: Array = []
	strict.peer_refused.connect(func(peer: int, err: DotError) -> void: refusals.append([peer, err]))

	var at_server := strict.adopt_peer_schema(5, _schema_body(old.schema_payload()), true)
	_check(
		"the server refuses a client missing a type it requires",
		not at_server.ok and at_server.code() == DotError.CODE_VERSION
	)
	_check(
		"with a sentence a player can act on (%s)" % (at_server.error.message if not at_server.ok else ""),
		not at_server.ok and at_server.error.message == "This server's game needs a newer game client."
	)
	_check(
		"and the type named where an operator reads it",
		not at_server.ok and at_server.error.detail.contains("demo.vital")
	)
	_check("it says so on its signal", refusals.size() == 1 and int(refusals[0][0]) == 5)

	var at_client := old.adopt_peer_schema(1, _schema_body(strict.schema_payload()), false)
	_check(
		"and the client refuses it too, from its side (%s)" % (at_client.error.message if not at_client.ok else ""),
		not at_client.ok and at_client.error.message == "This server's game needs a newer game client."
	)

	# Nothing from a refused peer is handed to a game.
	var cw := DotNetWriter.new()
	var after := ChatMessageV2.new()
	after.text = "ignored"
	strict.encode(after, cw)
	var from_refused := old.decode(cw.to_reader(), 1, false)
	_check(
		"and nothing a refused peer sends is decoded",
		from_refused.ok and from_refused.value == null
	)

	# Forgetting the peer clears the refusal, so a reconnect is judged afresh.
	old.forget_peer(1)
	_check("forgetting a peer forgets its refusal", not old.is_refused(1) and not old.knows_peer(1))

	# The manager: a server announces as it adds a peer, the client as it starts, and a
	# refusal reaches the host on the manager's own signal.
	var s := DotNetManager.new()
	s.is_server = true
	s.auto_tick = false
	s.config_file = ""
	s.service_scope = &"schema_server"
	var c := DotNetManager.new()
	c.is_server = false
	c.local_peer_id = 3
	c.auto_tick = false
	c.config_file = ""
	c.service_scope = &"schema_client"
	add_child(s)
	add_child(c)
	s.setup()
	c.setup()
	s.messages.register(&"demo.chat", ChatMessageV2)
	s.messages.register(&"demo.vital", VitalMessage)
	c.messages.register(&"demo.chat", ChatMessage)

	var wire: Array = []
	s.send_fn = func(peer: int, payload: PackedByteArray, _d: int) -> void: wire.append([1, peer, payload])
	c.send_fn = func(peer: int, payload: PackedByteArray, _d: int) -> void: wire.append([3, peer, payload])

	var manager_refusals: Array = []
	s.peer_schema_refused.connect(func(peer: int, err: DotError) -> void: manager_refusals.append([peer, err.message]))

	s.start()
	c.start()
	s.add_peer(3)

	_check("both ends announced a table (%d payloads)" % wire.size(), wire.size() == 2)

	for w in wire:
		if int(w[0]) == 1:
			c.receive(w[2], 1)
		else:
			s.receive(w[2], 3)

	_check(
		"the server's manager reports the client it cannot play with",
		manager_refusals.size() == 1 and int(manager_refusals[0][0]) == 3
	)
	_check(
		"and a refused schema is not counted as a decode failure",
		s.stats.decode_failures == 0
	)

	s.stop()
	c.stop()
	remove_child(s)
	remove_child(c)
	s.free()
	c.free()


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

	# Small drift corrects by changing tick length, not by jumping. One tick behind is
	# inside the margin: a command still lands in time, so nothing is lost by smoothing.
	var before := follower.tick
	follower.sync_from_server(1001, 100.0)
	_check("small drift does not snap", absi(follower.tick - before) < 5)
	_check("drift correction applied", absf(follower.drift_percent()) > 0.0)

	# A huge error is not drift; it must snap.
	follower.sync_from_server(50000, 100.0)
	_check("large error snaps", follower.tick > 49000)

	# [b]The threshold is a DURATION, and every check above runs at the rate it was
	# written as a tick count for.[/b] 60 ticks is one second at 60 Hz and 0.47 s at 128,
	# so a 128-tick server -- the rate this genre runs and the rate g2gfast ships --
	# snapped on any half-second hitch: a map change, a stalled frame, a browser tab
	# doing layout. A snap discards everything predicted, so the world jumps, and it
	# jumped only on the one game nothing was tested at.
	var fast := DotNetClock.new(128, false)
	fast.sync_from_server(10000, 0.0)
	fast.sync_from_server(10000, 20.0)

	var fast_before := fast.tick
	# Half a second AHEAD: 64 ticks at 128. A client ahead of its target only adds input
	# latency, and stepping back would re-stamp ticks already sent, so it is drift.
	fast.sync_from_server(fast.server_tick() - 64, 20.0)
	_check(
		"a client half a second ahead at 128 ticks drifts back, not a snap",
		absi(fast.tick - fast_before) < 5
	)

	# [b]Half a second BEHIND is not drift, and smoothing it was the bug.[/b] That is what
	# a hitch does — the engine drops every physics step past eight in a frame, so the
	# clock loses the stall's length — and a client behind its target stamps every
	# command for a tick the server has already simulated. At 5% that took ten seconds at
	# 128 ticks, every command of them discarded: a browser's first connect, where every
	# load and shader compile is a stall, was a player who could not steer until the
	# clock crawled back. Armed: smoothing this leaves the clock 60 ticks short.
	var behind := DotNetClock.new(128, false)
	behind.sync_from_server(10000, 0.0)
	behind.sync_from_server(10000, 20.0)
	var lead := behind.tick - behind.server_tick()
	behind.sync_from_server(behind.server_tick() + 64, 20.0)
	_check(
		"a client half a second BEHIND catches up at once (%d ahead of the server)"
			% (behind.tick - behind.server_tick()),
		behind.tick - behind.server_tick() == lead
	)

	# Two seconds is a different session, at any rate.
	var before_snap := behind.tick
	behind.sync_from_server(behind.server_tick() + 256, 20.0)
	_check("and two seconds still snaps", absi(behind.tick - before_snap) > 200)

	# The same, at 60.
	var slow := DotNetClock.new(60, false)
	slow.sync_from_server(10000, 0.0)
	slow.sync_from_server(10000, 20.0)
	var slow_before := slow.tick
	slow.sync_from_server(slow.server_tick() - 30, 20.0)
	_check(
		"half a second ahead at 60 ticks is drift too, as it always was",
		absi(slow.tick - slow_before) < 5
	)

	_check(
		"the threshold is one second whatever the rate",
		fast.snap_threshold_ticks() == 128 and slow.snap_threshold_ticks() == 60
	)

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

	# The buffer is 2 snapshots, and at the default 60 ticks / 20 snapshots a snapshot is 3
	# ticks, so this renders 6 ticks behind: tick 101, a tenth of the way from 100 to 110.
	# This comment used to say "2 ticks of delay in this unit", which is the bug
	# `_test_render_delay` is about written down as a fact; the check below it passed either
	# way, because x=7 is also between the two snapshots.
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

	# A sample moves it TO the sample, never by it -- and only forward, at once.
	clock.sync_from_server(1010, 0.0)
	_check(
		"a quicker packet moves it forward to the sample, not by it (%d)" % clock.server_tick(),
		clock.server_tick() == 1010
	)

	# [b]A late packet is not the server going back in time.[/b] It was: every sample
	# re-anchored the timeline absolutely, so on a link whose packets take 30..80 ms the
	# render timeline went back and forth with each one -- measured through a real relay
	# on ENet, 35 times backwards in ten seconds by up to 3.9 ticks.
	clock.sync_from_server(1004, 0.0)
	_check(
		"one late packet does not pull it back (%d)" % clock.server_tick(),
		clock.server_tick() == 1010
	)
	# A frame apart: a burst read in one frame counts once (see the dropped-time section).
	for _i in range(DotNetClock.SETTLE_SAMPLES):
		var _none := clock.advance(0.0001)
		clock.sync_from_server(1004, 0.0)
	_check(
		"a whole window of them does, by one tick (%d)" % clock.server_tick(),
		clock.server_tick() == 1009
	)

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

	# Adaptive buffering must grow under jitter.
	var adaptive := DotNetInterpolator.new(DotNetConfig.new())
	var initial := adaptive.delay_ticks()
	for i in range(40):
		adaptive.note_arrival()
		# Irregular arrivals.
		await get_tree().process_frame
	_check("adaptive buffer responds", adaptive.delay_ticks() >= initial * 0.5)
	_sections_completed += 1


## The interpolation buffer is a count of SNAPSHOTS and a render time is a TICK.
##
## [method DotNetInterpolator.sample] used to subtract the one from the other unconverted,
## so a "two snapshot" buffer was two ticks: at 128 ticks and 20 snapshots, under a sixth of
## what the config asked for and less than one snapshot interval. The render time then sat
## past the newest snapshot most of the time and every remote entity in the family was
## extrapolated rather than interpolated — 1,684 extrapolated frames in six seconds of
## game-playground. Nothing above could see it: every sample there is at a hand-picked tick,
## chosen by somebody holding the same confusion.
##
## So this drives it the way a game does — a server at 128 ticks sending 20 snapshots, a
## client whose clock is anchored by those snapshots and advanced by its own ticks, and
## [method DotNetManager.interpolate_frame] four times a tick at the fractions a renderer
## would pass — and asserts on the interpolator's own extrapolation count, which is what
## an operator reads when a remote player looks wrong. Synchronous: nothing here suspends.
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

	# The third leg is clean and on a 120 ms round trip. The render time is counted back
	# from the newest snapshot the client HOLDS, not from the tick the server is on: counted
	# from the server's tick, the flight time came out of the buffer -- ten ticks of these
	# twelve -- and three frames in four were drawn past the newest snapshot (measured
	# through a real relay on ENet, game-arena's `headless_lossy`). Snapshots in this loop
	# arrive the instant they are sent, so a buffer that is right here is right because of
	# where it is measured from, not because the link was kind.
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

	# And then they stop. The last snapshot that moves them carries the stop; every one after
	# it carries nothing for `position`, because nothing changed. What the client is drawing
	# a second later has to be where the server left them — not the blend it happened to be
	# drawing when the stop arrived, which is what a property read back after the
	# interpolator had written into it used to hand the next snapshot as the server's word.
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

	# A hole in the history: the client's clock jumped forward over ticks 14-16 (a
	# catch-up), so it never made commands for them and the server ran them on tick 13's,
	# as it runs any tick whose command never came. The replay has to do the same, not
	# stop at the hole: stopping left game-arena's predicted player 2 m short of the
	# server at 20% loss (2026-10-09).
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
	_out_of_tree(dead)

	for entity in [server_entity, client_entity, lonely, untouched, holed_server, holed_client]:
		_out_of_tree(entity)


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


# --- The buffer growing ----------------------------------------------------

## A link that turns jittery: the interpolation buffer has to grow, and it must not move
## the render time backwards to do it -- and once grown it has to cover how late the
## snapshots actually are. 128 ticks, a snapshot every 4, played tick by tick with the
## receive timeline on the quickest arrivals, as `DotNetClock` keeps it.
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


## What is drawn between ticks stays continuous through the three things that move a
## client's timelines in jumps: a physics frame that ran no tick or two (the clock drifting),
## the receive timeline re-anchoring a tick at a time, and a snapshot stream resuming after an
## extrapolation. Each is played at 144 frames a second against 64 ticks, and each against
## its control: the same frames drawn the way they were before (the engine's fraction alone,
## the receive timeline as it is, no easing), which has to show the jump these remove.
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



# --- Shared dirty sets -----------------------------------------------------

## A behaviour with nothing that keeps its dirty sets apart (no epsilon, no rate limit), and
## one of everything else that decides them: an owner-only, an observers-only and a
## spawn-only property, and a string, whose encoding depends on the bit it starts at.
class Sharing extends DotNetBehaviour:
	var position: Vector3 = Vector3.ZERO
	var health: int = 100
	var tag: String = ""
	var secret: bool = false
	var seen: int = 0
	var kind: int = 1

	func _register_net_vars() -> void:
		replicate(&"position", DotNetVar.Type.VECTOR3_POSITION).interpolated()
		replicate(&"health", DotNetVar.Type.UINT).bits(8)
		replicate(&"tag", DotNetVar.Type.STRING)
		replicate(&"secret", DotNetVar.Type.BOOL).to_owner_only()
		replicate(&"seen", DotNetVar.Type.UINT).bits(4).to_observers_only()
		replicate(&"kind", DotNetVar.Type.UINT).bits(4).once()


var _share_rng := RandomNumberGenerator.new()


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


const STILL_LEAD := 3
const STILL_INTERVAL := 3
const STILL_STOP_AT := 60


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


## [b]Bumping a remote under loss.[/b] A client predicts its own player against the others at
## an estimate of where they are; the server pushes it out of where they really are. The gap
## between the two is the prediction error a bump costs, and this section measures it for each
## way of making the estimate (docs/prediction.md#bumping-a-remote).
##
## A [Bumper] walks at 3 m/s into a [Pacer] that comes at it, pushes it back, turns at once
## and walks away, at [constant BUMP_SPEEDS]. Snapshots are lost at random, the same draws for
## every estimate. The gap is taken at each tick as first predicted, which is where the
## player is drawn before any correction.
##
## The estimates: `heard`, where the bot was last heard (what every game does); `ignore`, no
## bot in the prediction at all; `line`, the interpolator's line through the last two
## positions sampled at the input tick; `extrapolated`, [method DotNetBehaviour.extrapolated_value]
## with [member DotNetConfig.remote_extrapolation_sec] at [constant BUMP_EXTRAPOLATE_SEC]; and
## `default`, the same call with the setting left at its default.
const BUMP_LEAD := 6
const BUMP_TICKS := 1200
const BUMP_SPEEDS: Array[float] = [4.0, 8.0]
const BUMP_LOSSES: Array[float] = [0.0, 0.05, 0.15]
## The lead plus one snapshot interval, 9 ticks at 60 Hz.
const BUMP_EXTRAPOLATE_SEC := 0.15
const BUMP_ESTIMATES: Array[StringName] = [
	&"oracle", &"heard", &"ignore", &"line", &"extrapolated", &"default"
]


func _test_remote_bumps() -> void:
	print("")
	print("[bumping a remote under loss]")

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


## [member DotNetConfig.reconcile_once_per_frame]: snapshots that arrive together are
## reconciled once, against the newest, and land exactly where reconciling each would.
##
## Two clients read the same payloads from one server in bursts of [constant BURST] (what a
## WebSocket hands over after a long frame): A reconciles every snapshot as it is read, B
## defers and flushes once a burst. B must replay once a burst, not once a snapshot, touch
## nothing until it flushes, and end every burst where A is -- the coalescing is only worth
## having if it is the same answer.
const BURST := 4


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
## trip ago (game-arena's headless_feel, 2026-10-16: 300 mm, 31 corrections at 40 ms).
func _test_skip_matching_replays(own_state: bool) -> void:
	print("")
	print("[replays skipped when the prediction matched%s]" % (", own simulation state" if own_state else ""))
	const TICKS := 96
	const LEAD := 6

	var host := DotNetManager.new()
	host.name = "SkipServer"
	host.is_server = true
	host.service_scope = &"skip_server"
	host.local_peer_id = 1
	host.auto_tick = false
	host.config_file = ""
	host.config = DotNetConfig.new()
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


## Snapshots that arrive OUT OF ORDER and TWICE, through two real managers with
## acknowledgements wired end to end.
##
## [b]Nothing here had ever seen either.[/b] Over WebSocket "unreliable" is reliable and in
## order, so every client so far received every snapshot once, in sequence; a native client
## on ENet (dot-server's dual stack, 2026-10-07) gets real UDP. A late snapshot is ignored
## by tick, as superseded -- which loses whatever only it carried, unless the server re-sends
## it once the client acknowledges a newer one. That recovery is checked behaviour by
## behaviour in [acked baselines]; this is the whole path: the encoder, the wire, the
## receiver's tick rule, the client's acknowledgement and the server's resend.
var _reorder_rng := RandomNumberGenerator.new()
var _reorder_held_change := false

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


## A snapshot bigger than [member DotNetConfig.mtu] goes out in parts, each applying alone.
##
## Godot's ENet peer fragments an unreliable packet over its MTU, and losing any fragment
## loses the packet: a game whose snapshots ran past it (mg-buses-from-hell, at a round's
## spawn) lost about twice as many on a native client, and nothing here measured a size.
## Every check below is armed: [member DotNetConfig.mtu] was declared and read by nothing.
func _test_snapshot_parts() -> void:
	print("")
	print("[snapshot parts]")

	const ENTITIES := 40
	const MTU := 256

	var host := _parts_manager("PartsServer", true, MTU)
	var watcher := _parts_manager("PartsClient", false, MTU)

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

	var on_server: Array[Movement] = []
	var on_client: Array[Movement] = []
	for i in ENTITIES:
		var spawned := host.spawner.spawn(&"player", 3, Transform3D.IDENTITY, 0)
		var server_entity: DotNetIdentity = spawned.value
		var _mirror := watcher.spawner.spawn_remote(&"player", server_entity.net_id, 3, Transform3D.IDENTITY, 0)
		on_server.append(server_entity.behaviours[0] as Movement)
		on_client.append(watcher.registry.get_identity(server_entity.net_id).behaviours[0] as Movement)

	var deliver := func(payload: PackedByteArray) -> void:
		var _r := watcher.receive_snapshot(payload)
		var _a := host.receive_ack_payload(2, watcher.encode_ack())

	var at := func(m: Movement) -> float:
		return float((m.received_values().get(&"position", Vector3.ZERO) as Vector3).x)

	# --- Over the MTU: parts, each under it, every entity in exactly one ---------

	for i in ENTITIES:
		on_server[i].position = Vector3(1.0 + i, 0, 0)
	host.server_tick(3)
	var first := sent.duplicate()
	sent.clear()

	var largest := 0
	var total_bytes := 0
	var total_entities := 0
	for payload in first:
		largest = maxi(largest, payload.size())
		total_bytes += payload.size()
		total_entities += _part_count(payload)
	_check("a snapshot over the MTU is sent in parts (%d)" % first.size(), first.size() > 1)
	_check("every part is within the MTU (largest %d of %d)" % [largest, MTU], largest <= MTU)
	_check("each entity is in one part (%d of %d)" % [total_entities, ENTITIES], total_entities == ENTITIES)
	_check("parts are full, not one entity each (%d B in %d)" % [total_bytes, first.size()],
		first.size() * MTU < total_bytes + MTU * 2)

	for payload in first:
		deliver.call(payload)
	var arrived := 0
	for i in ENTITIES:
		if absf(at.call(on_client[i]) - (1.0 + i)) < 0.02:
			arrived += 1
	_check("every part applies: all %d entities arrive (%d)" % [ENTITIES, arrived], arrived == ENTITIES)
	_check("the whole tick is acknowledged once every part is in (%d)" % watcher.ack_tick(),
		watcher.ack_tick() == 3)
	_check("a second part is not a repeated or late snapshot to the stats (%d)" % watcher.stats.out_of_order,
		watcher.stats.out_of_order == 0 and watcher.stats.snapshots_lost == 0)
	_check("and the decode is clean (%d)" % watcher.stats.decode_failures,
		watcher.stats.decode_failures == 0)

	# --- A lost part loses its own entities and nothing else -------------------

	for i in ENTITIES:
		on_server[i].position = Vector3(100.0 + i, 0, 0)
	host.server_tick(6)
	var second := sent.duplicate()
	sent.clear()
	var lost_count := _part_count(second[1]) if second.size() > 1 else -1
	for index in second.size():
		if index != 1:
			deliver.call(second[index])
	var moved := 0
	var stayed := 0
	for i in ENTITIES:
		var x: float = at.call(on_client[i])
		if absf(x - (100.0 + i)) < 0.02:
			moved += 1
		elif absf(x - (1.0 + i)) < 0.02:
			stayed += 1
	_check("with part 1 lost, the other parts' entities still arrive (%d moved)" % moved,
		moved == ENTITIES - lost_count)
	_check("only the lost part's entities are stale (%d of %d)" % [stayed, lost_count],
		lost_count > 0 and stayed == lost_count)
	_check("a tick with a part missing is not acknowledged (%d)" % watcher.ack_tick(),
		watcher.ack_tick() == 3)

	# A late copy of the lost part, after a newer tick: superseded, not applied.
	on_server[0].position = Vector3(200.0, 0, 0)
	host.server_tick(9)
	for payload in sent:
		deliver.call(payload)
	sent.clear()
	_check("the next, complete tick is acknowledged (%d)" % watcher.ack_tick(), watcher.ack_tick() == 9)
	var current := func() -> int:
		var n := 0
		for i in range(1, ENTITIES):
			if absf(at.call(on_client[i]) - (100.0 + i)) < 0.02:
				n += 1
		return n
	var before_late: int = current.call()
	deliver.call(second[1])
	var after_late: int = current.call()
	_check("a late part of an older tick is superseded (%d, was %d)" % [after_late, before_late],
		after_late == before_late and before_late < ENTITIES - 1)

	# The acknowledgement of 9 resolves 6 as lost, so what part 1 carried goes again.
	host.server_tick(12)
	for payload in sent:
		deliver.call(payload)
	sent.clear()
	var caught_up := 0
	for i in range(1, ENTITIES):
		if absf(at.call(on_client[i]) - (100.0 + i)) < 0.02:
			caught_up += 1
	_check("the lost part's entities are re-sent and arrive (%d of %d)" % [caught_up, ENTITIES - 1],
		caught_up == ENTITIES - 1)

	# A part of an older tick that turns up after a part of a newer, still incomplete one
	# is superseded too: entities are not in the same part every tick (the order is the
	# priority accumulator's), so it can carry an entity the newer part already moved.
	for i in ENTITIES:
		on_server[i].position = Vector3(400.0 + i, 0, 0)
	host.server_tick(13)
	var older := sent.duplicate()
	sent.clear()
	for i in ENTITIES:
		on_server[i].position = Vector3(500.0 + i, 0, 0)
	host.server_tick(14)
	var newer := sent.duplicate()
	sent.clear()
	deliver.call(newer[0])
	deliver.call(older[older.size() - 1])
	var went_back := 0
	for i in ENTITIES:
		if absf(at.call(on_client[i]) - (400.0 + i)) < 0.02:
			went_back += 1
	_check("an older part after a newer incomplete tick is not applied (%d)" % went_back,
		older.size() > 1 and newer.size() > 1 and went_back == 0)
	for index in range(1, newer.size()):
		deliver.call(newer[index])

	# --- Under the MTU: one packet, byte for byte the format before parts --------

	host.config.mtu = 8192
	for i in ENTITIES:
		on_server[i].position = Vector3(300.0 + i, 0, 0)
	host.server_tick(15)
	_check("under the MTU a snapshot is one packet (%d)" % sent.size(), sent.size() == 1)
	if sent.size() == 1:
		var whole := sent[0]
		var reader := DotNetReader.new(whole)
		var _tick := reader.read_uint(32)
		var count := reader.read_uint(12)
		# Walk the entities with the client's own declarations, then look at what is left.
		var _applied := watcher.receive_snapshot(whole)
		_check("and it carries no part trailer (%d entities, %d B)" % [count, whole.size()],
			count == ENTITIES and whole.size() * 8 - _bits_before_trailer(whole, watcher) < 8)
	sent.clear()

	# --- More than sixteen parts' worth: the rest waits, nothing is malformed ----

	host.config.mtu = MTU
	host.config.max_entities_per_snapshot = 0
	for i in 200:
		var spawned := host.spawner.spawn(&"player", 3, Transform3D.IDENTITY, 0)
		var extra: DotNetIdentity = spawned.value
		var _mirror := watcher.spawner.spawn_remote(&"player", extra.net_id, 3, Transform3D.IDENTITY, 0)
	host.server_tick(18)
	var widest := 0
	for payload in sent:
		widest = maxi(widest, payload.size())
	_check("a snapshot is cut into at most %d parts (%d)" % [DotNetManager.MAX_SNAPSHOT_PARTS, sent.size()],
		sent.size() == DotNetManager.MAX_SNAPSHOT_PARTS and widest <= MTU)
	var failures_before := watcher.stats.decode_failures
	for payload in sent:
		deliver.call(payload)
	_check("and every one of them decodes", watcher.stats.decode_failures == failures_before)
	sent.clear()

	host.stop()
	watcher.stop()
	remove_child(host)
	remove_child(watcher)
	host.free()
	watcher.free()


## [b]An entity with nothing to say is listed, not written.[/b] Every relevant entity used to
## go out every snapshot with its 24-bit id and a 6-bit count per behaviour even when nothing
## had changed: about 396 of mg-buses-from-hell's 429 steady bytes, 88 entities of headers.
## A client that announces [constant DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS] is sent
## those as runs of ids in the part's tail and applies each exactly as an empty body, so
## `_net_state_applied`, the interpolator and relevance all read as before. Armed, each fix
## reverted in turn: the send side off sends 149 B against 149 B and writes all 30; the
## receive side ignoring the list fires the hook for 1 of 30, splits fail to apply, and
## [method _test_standing_still]'s listed run walks 19.5 m off (#17's shape); the old early
## return sends 0 B to a peer with nothing relevant and its acknowledgement stays at 9.
func _test_unchanged_entities() -> void:
	print("")
	print("[unchanged entities]")

	const ENTITIES := 30

	var host := _parts_manager("QuietServer", true, 1200)
	var fresh := _parts_manager("QuietClient", false, 1200)
	var legacy := _parts_manager("QuietLegacy", false, 1200)
	legacy.local_peer_id = 3
	# A client from before the lists: it announces no features, as its table had none.
	legacy.messages.features = 0
	var exclude := ExcludeInterest.new()
	host.interest = exclude

	var sent := {2: [], 3: []}
	host.send_fn = func(peer_id: int, payload: PackedByteArray, d: int) -> void:
		var to: DotNetManager = fresh if peer_id == 2 else legacy
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var _schema := to.receive(payload, 1)
			return
		(sent[peer_id] as Array).append(payload)
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
	for m in [host, fresh, legacy]:
		(m as DotNetManager).spawner.register_factory(&"counted", _build_counted)

	_check("the new client says it reads unchanged lists, the old one does not",
		host.messages.peer_supports(2, DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS)
			and not host.messages.peer_supports(3, DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS))

	var on_server: Array[Counted] = []
	var on_fresh: Array[Counted] = []
	var on_legacy: Array[Counted] = []
	for i in ENTITIES:
		# Owned by nobody here, so both clients interpolate them.
		var spawned: DotNetIdentity = host.spawner.spawn(&"counted", 9, Transform3D.IDENTITY, 0).value
		# Out of view means out at once, not after the boundary's grace period.
		spawned.interest_linger_sec = 0.0
		var _f := fresh.spawner.spawn_remote(&"counted", spawned.net_id, 9, Transform3D.IDENTITY, 0)
		var _l := legacy.spawner.spawn_remote(&"counted", spawned.net_id, 9, Transform3D.IDENTITY, 0)
		on_server.append(spawned.behaviours[0] as Counted)
		on_fresh.append(fresh.registry.get_identity(spawned.net_id).behaviours[0] as Counted)
		on_legacy.append(legacy.registry.get_identity(spawned.net_id).behaviours[0] as Counted)

	var deliver := func(tick: int) -> void:
		host.server_tick(tick)
		for payload: PackedByteArray in sent[2]:
			var _r := fresh.receive_snapshot(payload)
		for payload: PackedByteArray in sent[3]:
			var _r := legacy.receive_snapshot(payload)
		var _a := host.receive_ack_payload(2, fresh.encode_ack())
		var _b := host.receive_ack_payload(3, legacy.encode_ack())

	var sizes := func(peer: int) -> int:
		var n := 0
		for payload: PackedByteArray in sent[peer]:
			n += payload.size()
		return n

	var all_at := func(list: Array[Counted], tick: int) -> int:
		var n := 0
		for c in list:
			if c.last_applied == tick:
				n += 1
		return n

	# Everything once, then only entity 0 moves.
	for i in ENTITIES:
		on_server[i].position = Vector3(1.0 + i, 0, 0)
	deliver.call(3)
	sent[2].clear()
	sent[3].clear()
	on_server[0].position = Vector3(50, 0, 0)
	deliver.call(6)

	var compact_bytes: int = sizes.call(2)
	var legacy_bytes: int = sizes.call(3)
	# 29 entities of 36 bits is 130 bytes of headers; the list of them is a few bits.
	_check("29 unchanged entities cost a few bits, not 130 B (%d B, old format %d B)"
			% [compact_bytes, legacy_bytes],
		compact_bytes + 120 <= legacy_bytes)
	_check("and only the moving entity is written (%d)" % _part_count(sent[2][0]),
		sent[2].size() == 1 and _part_count(sent[2][0]) == 1)
	_check("every entity's per-snapshot hook fired at the new tick (%d of %d)"
			% [all_at.call(on_fresh, 6), ENTITIES],
		all_at.call(on_fresh, 6) == ENTITIES)
	_check("as it does on the old format (%d of %d)" % [all_at.call(on_legacy, 6), ENTITIES],
		all_at.call(on_legacy, 6) == ENTITIES)
	var tracked := 0
	for i in ENTITIES:
		var track: Variant = fresh.interpolator._tracks.get(on_fresh[i].identity.net_id)
		if track != null and int(track.newest_tick()) == 6:
			tracked += 1
	_check("the interpolator holds a sample at that tick for each (%d)" % tracked, tracked == ENTITIES)
	_check("and both acknowledge it (%d, %d)" % [fresh.ack_tick(), legacy.ack_tick()],
		fresh.ack_tick() == 6 and legacy.ack_tick() == 6)

	# Out of view: neither written nor listed, so it hears nothing, on either format.
	exclude.excluded[on_server[5].identity.net_id] = true
	sent[2].clear()
	sent[3].clear()
	deliver.call(9)
	_check("an entity that left relevance is not listed (last %d, others %d of %d)"
			% [on_fresh[5].last_applied, all_at.call(on_fresh, 9), ENTITIES - 1],
		on_fresh[5].last_applied == 6 and all_at.call(on_fresh, 9) == ENTITIES - 1
			and on_legacy[5].last_applied == 6)

	# Nothing relevant at all: a snapshot still goes, for the clock and the acknowledgement.
	for c in on_server:
		exclude.excluded[c.identity.net_id] = true
	sent[2].clear()
	sent[3].clear()
	deliver.call(12)
	_check("with nothing relevant a header-only snapshot is still sent (%d B, %d B)"
			% [sizes.call(2), sizes.call(3)],
		sent[2].size() == 1 and sent[3].size() == 1 and _part_count(sent[2][0]) == 0
			and (sent[2][0] as PackedByteArray).size() == 6 and (sent[3][0] as PackedByteArray).size() == 6)
	_check("and it feeds the clock and is acknowledged (%d, %d)" % [fresh.ack_tick(), legacy.ack_tick()],
		fresh.ack_tick() == 12 and legacy.ack_tick() == 12 and fresh.clock.received_tick() >= 12)
	exclude.excluded.clear()

	# Over the MTU with a list: every part applies and the tick is acknowledged.
	host.config.mtu = 96
	for i in range(0, ENTITIES, 3):
		on_server[i].position = Vector3(500.0 + i, 0, 0)
	sent[2].clear()
	sent[3].clear()
	var failures := fresh.stats.decode_failures
	deliver.call(15)
	_check("split with a list: %d parts, all applied, tick acknowledged (%d)" % [sent[2].size(), fresh.ack_tick()],
		sent[2].size() > 1 and fresh.ack_tick() == 15 and all_at.call(on_fresh, 15) == ENTITIES
			and fresh.stats.decode_failures == failures)
	host.config.mtu = 1200

	# An old client handed a tail by mistake refuses it as a bad part trailer, not a misread.
	var mark := DotNetManager.UNCHANGED_TAIL_MARK
	_check("the tail's mark reads to an old client as an impossible trailer",
		(mark & 0xF) >= (mark >> 4) + 1)

	# The run codec, against sets a contiguous block, a scatter and a mix.
	var codec_ok := true
	var sets := [[1, 2, 3, 4, 5], [7, 100, 4000, 16000000], [3, 4, 9, 10, 11, 12, 40], [1]]
	for ids_set: Array in sets:
		var ids := PackedInt32Array(ids_set)
		var runs := DotNetManager._unchanged_runs(ids)
		var w := DotNetWriter.new()
		DotNetManager._write_unchanged_tail(w, runs)
		var r := w.to_reader()
		var got: Array = []
		var _m := r.read_uint(8)
		var count := DotNetManager._read_gamma(r)
		var cursor := 0
		for _k in count:
			var first := cursor + DotNetManager._read_gamma(r)
			var length := DotNetManager._read_gamma(r) + 1
			for id in range(first, first + length):
				got.append(id)
			cursor = first + length
		if got != ids_set or w.bit_length() + DotNetManager.SNAPSHOT_PART_TRAILER_BITS \
				!= DotNetManager._unchanged_tail_bits(runs):
			codec_ok = false
	_check("unchanged runs round-trip, and their size is known before writing", codec_ok)

	# A truncated list changes nothing and is a decode failure.
	var bad := DotNetWriter.new()
	bad.write_uint(20, 32)
	bad.write_uint(0, 12)
	bad.write_uint(DotNetManager.UNCHANGED_TAIL_MARK, 8)
	DotNetManager._write_gamma(bad, 1)
	DotNetManager._write_gamma(bad, on_fresh[0].identity.net_id)
	bad.write_bits(0, 12)
	var before := on_fresh[0].applied
	var refused := fresh.receive_snapshot(bad.to_bytes())
	_check("a truncated list is refused and applies nothing",
		not refused.ok and on_fresh[0].applied == before)

	host.stop()
	fresh.stop()
	legacy.stop()
	for m in [host, fresh, legacy]:
		remove_child(m)
		(m as DotNetManager).free()


func _build_counted(_context: Dictionary) -> Node:
	var identity := _make_entity(&"counted", 0)
	var body := identity.get_parent()
	var old := identity.behaviours[0]
	body.remove_child(old)
	old.free()
	var counted := Counted.new()
	counted.name = "Movement"
	body.add_child(counted)
	identity.behaviours = [counted]
	counted.identity = identity
	counted._bind(DotNetConfig.new())
	return body


func _build_rich(context: Dictionary) -> Node:
	var body := _build_counted(context)
	var identity := body.get_node("NetIdentity") as DotNetIdentity
	var old := identity.behaviours[0]
	body.remove_child(old)
	old.free()
	var rich := Rich.new()
	rich.name = "Movement"
	body.add_child(rich)
	identity.behaviours = [rich]
	rich.identity = identity
	rich._bind(DotNetConfig.new())
	return body


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
	for variant: String in ["cache", "grid"]:
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

	for variant: String in extra:
		var runs: Array = extra[variant]
		var serial: Dictionary = runs[0]
		_check("%s: the scenario sent snapshots under a held cache, linger and stagger (%d payloads, %d cached peers)"
				% [variant, (serial["payloads"] as Array).size(), serial["cache_hits"]],
			(serial["payloads"] as Array).size() > 100 and int(serial["cache_hits"]) > 0)
		for k in [1, 2]:
			var other: Dictionary = runs[k]
			_check("%s: %s workers send the same payloads and state as the inline path (payloads: %s; state: %s; pooled %d)"
					% [variant, "three" if k == 1 else "two (verify on)", _first_difference(serial["payloads"], other["payloads"]),
						_first_difference(serial["states"], other["states"]), other["pooled"]],
				_first_difference(serial["payloads"], other["payloads"]) == ""
					and _first_difference(serial["states"], other["states"]) == ""
					and (not DotParallel.available() or int(other["pooled"]) > 0))

	_test_first_entity_mid_tick()


## A peer's first entity registered inside a tick, with workers on: the observer is found by
## the snapshot but was not in the list that was frozen, so interest must be asked about a
## frozen one. Fails (unfrozen asks) if the job takes the observer as it finds it.
func _test_first_entity_mid_tick() -> void:
	var host := _parts_manager("MidTick", true, 1200)
	host.config.snapshot_workers = 2
	var probe := FrozenProbe.new()
	probe.radius = 50.0
	probe.evaluation_interval_sec = 0.0
	host.interest = probe
	var sent := {}
	host.send_fn = func(peer_id: int, _payload: PackedByteArray, _d: int) -> void:
		sent[peer_id] = int(sent.get(peer_id, 0)) + 1
	host.start()
	host.spawner.register_factory(&"counted", _build_counted)
	var modern := host.messages.schema_payload()
	for peer in [2, 3]:
		host.add_peer(peer)
		var _adopted := host.receive(modern, peer)
	var keep: Array = []
	for peer in [2, 3, 0, 0]:
		var identity: DotNetIdentity = host.spawner.spawn(&"counted", peer, Transform3D.IDENTITY, 0).value
		keep.append(identity)

	# The spawner is the one that spawns peer 3's... a third peer, joined with no entity.
	host.add_peer(4)
	var _adopted4 := host.receive(modern, 4)
	var spawner_identity := _make_entity(&"counted", 0)
	var driver := SpawnsFirst.new()
	driver.name = "Driver"
	spawner_identity.get_parent().add_child(driver)
	spawner_identity.behaviours = [driver]
	driver.identity = spawner_identity
	driver._bind(DotNetConfig.new())
	driver.host = host
	driver.peer = 4
	driver.at_tick = 3
	var registered := host.registry.register(spawner_identity, 0, 0, host.config)
	_check("mid-tick: the driver entity registered", registered.ok)
	keep.append(spawner_identity)

	for tick in range(1, 7):
		host.server_tick(tick)
	var pooled_runs: int = host._snapshot_pooled
	_check("mid-tick: peer 4's entity exists, spawned during tick 3", driver.spawned
		and not host.registry.owned_by(4).is_empty())
	_check("mid-tick: the snapshots were built on workers (%d)" % pooled_runs,
		not DotParallel.available() or pooled_runs > 0)
	_check("mid-tick: interest asked about the late observer (%d asks)" % probe.asks_with_observer,
		probe.asks_with_observer > 0)
	_check("mid-tick: never asked about an observer that was not frozen (%d asks)" % probe.unfrozen_asks,
		not DotParallel.available() or probe.unfrozen_asks == 0)
	_check("mid-tick: every freeze was undone",
		not host.registry.owned_by(4)[0].is_position_frozen())

	for identity: DotNetIdentity in host.registry.all():
		var body := identity.get_parent()
		if body != null and body.is_inside_tree():
			body.get_parent().remove_child(body)
	remove_child(host)
	host.free()


## One run of [method _test_snapshot_threads]'s game; everything it sent and kept, as bytes.
func _threads_scenario(label: String, workers: int, skew: bool, variant: String = "") -> Dictionary:
	const PEERS := 10
	const ENTITIES := 40
	const TICKS := 40

	var host := _parts_manager(label, true, 320)
	host.config.snapshot_workers = workers
	# 1500 B per window of ten ticks (the window is scripted below): well under what the
	# entities in view want, so the accumulator decides who waits.
	host.config.per_client_budget = 1500
	var distance := DotNetInterestDistance.new()
	distance.radius = 14.0
	distance.evaluation_interval_sec = 0.0
	host.interest = distance
	host._test_skew_pooled = skew
	var rich := variant != ""
	if rich:
		# A cached answer is kept for good and expired by hand below (a wall-clock interval
		# would expire at a different tick in each run); a leaver lingers for good.
		var strategy: DotNetInterest = distance
		if variant == "grid":
			var grid := DotNetInterestGrid.new()
			grid.cell_size = 8.0
			grid.radius = 14.0
			strategy = grid
			host.interest = grid
		strategy.evaluation_interval_sec = 1.0e6
		# Staggered: three phases, a peer a tick each third.
		host.config.snapshot_rate = 20
		host.config.stagger_snapshots = true

	var payloads: Array = []
	var peers_fed := {}
	host.send_fn = func(peer_id: int, payload: PackedByteArray, d: int) -> void:
		if d == DotNetMessage.Delivery.UNRELIABLE:
			payloads.append([peer_id, payload])
			peers_fed[peer_id] = true
	host.start()
	host.spawner.register_factory(&"counted", _build_rich if rich else _build_counted)

	var modern := host.messages.schema_payload()
	host.messages.features = 0
	var legacy := host.messages.schema_payload()
	host.messages.features = DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS | DotNetMessageRegistry.FEATURE_INPUT_LEAD
	for i in PEERS:
		var peer := 2 + i
		host.add_peer(peer)
		var _adopted := host.receive(modern if i % 2 == 0 else legacy, peer)

	var behaviours: Array[Counted] = []
	for i in PEERS + ENTITIES:
		# The first ten are the peers' own (the observers interest measures from).
		var owner := 2 + i if i < PEERS else 0
		var spawned: DotNetIdentity = host.spawner.spawn(&"counted", owner, Transform3D.IDENTITY, 0).value
		spawned.interest_linger_sec = 1.0e6 if rich else 0.0
		# Two always-relevant entities: the pinned path under a cache hit.
		spawned.always_relevant = rich and i >= PEERS and i < PEERS + 2
		behaviours.append(spawned.behaviours[0] as Counted)

	var states: Array = []
	var starved := 0
	var split := 0
	for tick in range(1, TICKS + 1):
		for i in behaviours.size():
			var c := behaviours[i]
			# A pure function of (entity, tick): a slow circle per entity, the peers' own
			# drifting through the crowd so the set in view changes.
			var phase := float(i) * 0.7 + float(tick) * (0.05 if i >= PEERS else 0.12)
			var r := 4.0 + float(i % 7) * 3.0
			var p := Vector3(cos(phase) * r, 0.0, sin(phase) * r)
			c.position = p
			(c.identity.get_parent() as Node3D).position = p
			if tick % 3 != i % 3:
				c.velocity = Vector3(float((i + tick) % 5), 0.0, 0.0)
			if (tick + i) % 7 == 0:
				c.health = 100 - ((tick * 3 + i) % 60)
			c.grounded = (tick + i) % 4 != 0
			if c is Rich:
				var r2 := c as Rich
				r2.title = "unit-%d" % ((tick + i) % 6)
				r2.blob = PackedByteArray([i % 256, tick % 256, (i * tick) % 256]).slice(0, 1 + (tick + i) % 3)
				r2.rated = tick * 7 + i

		# The budget's window is a wall-clock second, which one run can cross at a different
		# tick from another; hold it open and roll it every ten ticks instead.
		for i in PEERS:
			var w := host.budget.for_peer(2 + i)
			w.window_started_ms = Time.get_ticks_msec()
			if tick % 10 == 1:
				w.bytes_this_second = 0
		if rich and tick % 8 == 0:
			for cached: Dictionary in host.interest._cache.values():
				cached["at_ms"] = 0
		var before := payloads.size()
		host.server_tick(tick)
		var per_peer := {}
		for k in range(before, payloads.size()):
			var peer: int = payloads[k][0]
			per_peer[peer] = int(per_peer.get(peer, 0)) + 1
		for peer: int in per_peer:
			if int(per_peer[peer]) > 1:
				split += 1

		# Lossy acks: each peer loses a different third, and the last never acks at all.
		for i in PEERS - 1:
			if (tick + i) % 3 != 0:
				var _acked := host.receive_ack(2 + i, tick)

		var state := []
		for i in PEERS:
			var b := host.budget.for_peer(2 + i)
			starved += b.starved_this_tick
			state.append([b.accumulators, b.starved_ticks, b.bytes_this_second])
		for c in behaviours:
			for i in PEERS:
				var view_state := c.peer_view_snapshot(2 + i)
				# The wall-clock times of a rate-limited send differ between runs; which
				# properties have one does not.
				if view_state.has("last_sent_ms"):
					for key in view_state["last_sent_ms"]:
						view_state["last_sent_ms"][key] = true
				state.append(view_state)
		states.append(var_to_bytes(state))

	var out := {
		"payloads": payloads, "states": states, "peers_fed": peers_fed.size(),
		"starved": starved, "split": split, "pooled": host._snapshot_pooled,
		"snapshots": TICKS, "cache_hits": 0,
	}
	if rich:
		# Hits that happened: a cache entry older than the first tick's can only be a hit.
		out["cache_hits"] = host.interest._cache.size()
	for c in behaviours:
		var body := c.identity.get_parent()
		if body.is_inside_tree():
			body.get_parent().remove_child(body)
		body.free()
	remove_child(host)
	host.free()
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


## The stuck-on-the-spawn-pad report (game-g2gfast, 2026-10-14): a browser's first visit stalls
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

	# A load hitch shorter than the engine's step cap: no time is dropped, so nothing is credited,
	# and every command produced in the frame after it was produced a hitch late and reached the
	# server that much early. Steered by those reports, game-g2gfast's client at 128 ran 18 ticks
	# early after a 0.3 s hitch and gave them back at the slow drift rate over three seconds.
	var short: Dictionary = _first_visit(128, 8, [0.3], true, 3.0, 1000.0 / 240.0, false, 1000.0 / 240.0)
	var early: int = most_early.call(short, 1000.0, 3000.0)
	print("    128 ticks, 0.3 s hitch: at most %d early after 1 s, %d late" % [early, int(short["late"])])
	_check("a 0.3 s hitch at 128 leaves commands at most slack+2 early within 1 s (%d, slack %d)"
			% [early, slack], early <= slack + 2 and early >= 0)
	_check("and none late (%d)" % int(short["late"]), int(short["late"]) == 0)

	# The same hitch at 60 is past the step cap (8 steps are 0.13 s), so the dropped part is
	# credited as well. The reports of the commands the credit produces still raise the lead
	# for a second (9 early, against 16 before the long frame was discounted and the clock slowed
	# fast), so this asks only that it is back within the slack by 2.5 s, where it was 9 early.
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
	Engine.max_physics_steps_per_frame = cap_was
	_sections_completed += 1


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
## [b]An entity whose node is freed before the netcode stops.[/b] A game change frees the
## old world's scene before the module that registered its entities stops its manager, so
## `clear()` meets identities that are already gone. Each one was a script error
## ("Trying to assign invalid previously freed instance") and 171 of them printed on one
## `changelevel` away from mg-buses-from-hell, on a run that passed.
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


## [b]An entity unregistered by another behaviour inside the same server tick[/b] (#30): a
## round that re-lays its map from a player's `_net_simulate` takes the old map's entities out
## of the registry and the tree while the manager is still walking the list it took first.
## Each was simulated once more against a node with no transform, and recorded and sent.
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
