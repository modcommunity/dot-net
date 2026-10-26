extends Node

## Fixtures, harness state and the helpers every section of netcode_demo.gd uses.

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


## A [Rich] with what only GDScript encodes for the native core (a custom codec that aligns, an
## int sent as a string) and the rotations it encodes itself, for [method _test_native].
class Coded extends Rich:
	var code: Array = []
	var turn: float = 0.0
	var facing: Quaternion = Quaternion.IDENTITY
	var aim: Vector3 = Vector3.FORWARD
	var label: int = 0

	func _register_net_vars() -> void:
		super._register_net_vars()
		replicate_custom(&"code", _write_code, _read_code)
		replicate(&"turn", DotNetVar.Type.ANGLE).bits(10)
		replicate(&"facing", DotNetVar.Type.QUATERNION)
		replicate(&"aim", DotNetVar.Type.DIRECTION).bits(11).with_epsilon(0.01)
		replicate(&"label", DotNetVar.Type.STRING)

	func _write_code(w: DotNetWriter, value: Variant) -> void:
		var parts: Array = value
		w.write_uint(parts.size(), 3)
		for part: String in parts:
			w.write_string(part)

	func _read_code(r: DotNetReader) -> Variant:
		var out: Array = []
		for _i in r.read_uint(3):
			out.append(r.read_string())
		return out


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


## A distance strategy subclassed without saying it is thread-safe.
class PlainDistance extends DotNetInterestDistance:
	pass


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

	func _neutralise() -> void:
		move = Vector2.ZERO
		fire = false


## A command-shaped member, as DotFpsCommand is in the games.
class DemoCommand extends RefCounted:
	var move := Vector2.ONE
	var yaw := 1.5
	var buttons := 7

	func neutralise() -> void:
		move = Vector2.ZERO
		buttons = 0


## An input with no _neutralise of its own: only members.
class MemberInput extends DotNetInput:
	var cmd := DemoCommand.new()
	var plain := 3

	func _write(_w: DotNetWriter) -> void:
		pass

	func _read(_r: DotNetReader) -> void:
		pass


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


## Observers-only state, as a game's alive/health pair: set once, never changing again.
class ObserverVars extends DotNetBehaviour:
	var alive: bool = false
	var hp: int = 0
	var armour: int = 0
	var wobble: int = 0

	func _register_net_vars() -> void:
		replicate(&"alive", DotNetVar.Type.BOOL).to_observers_only()
		replicate(&"hp", DotNetVar.Type.UINT).bits(8).to_observers_only()
		replicate(&"armour", DotNetVar.Type.UINT).bits(8)
		replicate(&"wobble", DotNetVar.Type.UINT).bits(8)


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


const STILL_LEAD := 3
const STILL_INTERVAL := 3
const STILL_STOP_AT := 60


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


## [member DotNetConfig.reconcile_once_per_frame]: snapshots that arrive together are
## reconciled once, against the newest, and land exactly where reconciling each would.
##
## Two clients read the same payloads from one server in bursts of [constant BURST] (what a
## WebSocket hands over after a long frame): A reconciles every snapshot as it is read, B
## defers and flushes once a burst. B must replay once a burst, not once a snapshot, touch
## nothing until it flushes, and end every burst where A is -- the coalescing is only worth
## having if it is the same answer.
const BURST := 4


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


func _build_rich(context: Dictionary, coded: bool = false) -> Node:
	var body := _build_counted(context)
	var identity := body.get_node("NetIdentity") as DotNetIdentity
	var old := identity.behaviours[0]
	body.remove_child(old)
	old.free()
	var rich: Rich = Coded.new() if coded else Rich.new()
	rich.name = "Movement"
	body.add_child(rich)
	identity.behaviours = [rich]
	rich.identity = identity
	rich._bind(DotNetConfig.new())
	return body


## An entity with an [ObserverVars] behaviour next to its movement one.
func _build_mirror(_context: Dictionary) -> Node:
	var identity := _make_entity(&"mirror", 0)
	var vars := ObserverVars.new()
	vars.name = "ObserverVars"
	identity.get_parent().add_child(vars)
	identity.behaviours.append(vars)
	vars.identity = identity
	vars._bind(DotNetConfig.new())
	return identity.get_parent()


## A manager with a config of its own and no tick loop, not yet in the tree.
func _bare_manager(as_server: bool, peer_id: int) -> DotNetManager:
	var m := DotNetManager.new()
	m.is_server = as_server
	m.service_scope = &"server" if as_server else &"client"
	m.local_peer_id = peer_id
	m.auto_tick = false
	m.config_file = ""
	m.config = DotNetConfig.new()
	return m


func _build_player(_context: Dictionary) -> Node:
	return _make_entity(&"player", 0).get_parent()


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
