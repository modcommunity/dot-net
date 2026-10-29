class_name DotNetPredictor
extends RefCounted

## Client-side prediction and server reconciliation. [b]Why prediction.[/b] Without it, pressing
## forward does nothing until the input reaches the server and the resulting state comes back — a full
## round trip.

const CHANNEL := "net.predict"

var config: DotNetConfig

## net_id -> {offset: Vector3, at_ms: int}
##
## Outstanding visual corrections being eased out.
var _corrections: Dictionary = {}

var _replays: int = 0
var _corrections_applied: int = 0
var _snaps: int = 0
var _last_replay_ticks: int = 0
var _worst_error: float = 0.0
var _skipped: int = 0

## Why a reconcile could not be skipped: property name -> count, plus [code]&"(no prediction)"[/code]
## for a server tick this client never remembered predicting. The first property that differed
## is the one counted. What says which part of a game's state the prediction gets wrong.
var _mismatches: Dictionary = {}
## Reconciles that rewound and did not replay, because the entity was not predicting
## (DotNetBehaviour._net_predicts).
var _unpredicted := 0
## net_id -> whether its last reconcile left it predicting. A reconcile from a state that was not
## a prediction (a dead player the server respawned) moves it, but is not a misprediction.
var _was_predicting: Dictionary = {}
## Reconciles that moved an entity from a state it was not predicting: counted apart.
var _unpredicted_moves := 0
## The newest of them, with both values: whether a mismatch is a real divergence or a
## rounding one is the first question and the counts cannot answer it.
var _last_mismatch: Dictionary = {}

## net_id -> {tick: {property: value}}: what each predicted tick produced, for
## [member DotNetConfig.skip_matching_replays]. Trimmed to the unacknowledged window.
var _predicted: Dictionary = {}


func _init(p_config: DotNetConfig) -> void:
	config = p_config


## Simulates one tick for every predicted entity. Called on the client each tick, after the input for
## that tick has been recorded.
func predict(
	identities: Array[DotNetIdentity],
	tick: int,
	delta: float,
	input: DotNetInput = null
) -> void:
	if not config.enable_prediction:
		return

	for identity in identities:
		if not identity.is_predicted():
			continue

		for behaviour in identity.behaviours:
			if input != null and behaviour.has_method("_net_apply_input"):
				behaviour.call("_net_apply_input", input, tick)
			behaviour._net_simulate(tick, delta)
		_remember(identity, tick)


## Keeps what [param tick] produced for [param identity], when replays may be skipped.
func _remember(identity: DotNetIdentity, tick: int) -> void:
	if not config.skip_matching_replays or not config.reconcile_once_per_frame:
		return
	var values := {}
	for behaviour in identity.behaviours:
		for declaration in behaviour.net_vars:
			values[declaration.property] = behaviour._net_read_property(declaration.property)
	var ticks: Dictionary = _predicted.get(identity.net_id, {})
	if ticks.is_empty():
		_predicted[identity.net_id] = ticks
	ticks[tick] = values
	# Bounded by the input history: an older tick could never be replayed from anyway.
	var oldest := tick - config.input_history_ticks
	if ticks.size() > config.input_history_ticks:
		for t: int in ticks.keys():
			if t < oldest:
				ticks.erase(t)


## Whether the server's [param values] for [param server_tick] are what this client
## predicted for that tick, every property of it.
func _predicted_matches(identity: DotNetIdentity, server_tick: int, values: Dictionary) -> bool:
	var ticks: Dictionary = _predicted.get(identity.net_id, {})
	var mine: Dictionary = ticks.get(server_tick, {})
	if mine.is_empty():
		_note_mismatch(&"(no prediction)")
		return false
	var compared := 0
	for behaviour in identity.behaviours:
		for declaration in behaviour.net_vars:
			if not values.has(declaration.property):
				continue
			if not mine.has(declaration.property):
				_note_mismatch(declaration.property)
				return false
			if not declaration.matches(mine[declaration.property], values[declaration.property]):
				_note_mismatch(declaration.property)
				_last_mismatch = {"tick": server_tick, "property": declaration.property,
					"predicted": mine[declaration.property], "received": values[declaration.property]}
				return false
			compared += 1
	return compared > 0


func _note_mismatch(property: StringName) -> void:
	_mismatches[property] = int(_mismatches.get(property, 0)) + 1


## Drops the remembered ticks up to [param through]: acknowledged, never compared again.
func _forget_through(net_id: int, through: int) -> void:
	var ticks: Dictionary = _predicted.get(net_id, {})
	for t: int in ticks.keys():
		if t <= through:
			ticks.erase(t)


## Accepts an authoritative state and replays everything since. [param authoritative_values] is what
## the server said for [param server_tick].
func reconcile(
	identity: DotNetIdentity,
	server_tick: int,
	authoritative_values: Dictionary,
	input_buffer: DotNetInput.Buffer,
	current_tick: int,
	tick_delta: float
) -> DotResult:
	if not identity.is_predicted():
		return DotResult.success(0)

	# The prediction already reached this state: a rewind and a replay would compute what the entity
	# holds now. See DotNetConfig.skip_matching_replays.
	if config.skip_matching_replays and config.reconcile_once_per_frame \
			and _predicted_matches(identity, server_tick, authoritative_values):
		# [b]The properties hold the prediction again; the game's simulation does not.[/b] Reading the
		# snapshot ran `_net_state_applied` with the server's state (that hook is where every game rewinds
		# its simulation, by copying the properties into it).
		for behaviour in identity.behaviours:
			behaviour._net_state_applied(server_tick)
		_forget_through(identity.net_id, server_tick)
		_was_predicting[identity.net_id] = true
		_skipped += 1
		_last_replay_ticks = 0
		return DotResult.success(0)

	# What the client currently shows, before rewinding. Needed to measure the
	# correction so it can be eased rather than snapped.
	var before := _capture_visual(identity)

	# 1. Rewind: adopt the server's state wholesale.
	var applied := 0
	for behaviour in identity.behaviours:
		for declaration in behaviour.net_vars:
			if not authoritative_values.has(declaration.property):
				continue
			behaviour._net_write_property(
				declaration.property, authoritative_values[declaration.property]
			)
			applied += 1

	if applied == 0:
		# Nothing the server has ever said about this entity: no state has arrived for it yet, so there is
		# nothing to rewind to and leaving the prediction alone is correct.
		return DotResult.success(0)

	# 2. Replay every input the server has not confirmed yet, unless nothing of the entity
	# would simulate (DotNetBehaviour._net_predicts): then the rewound state is the answer.
	var replayed := 0
	var replay_tick := server_tick + 1
	var predicting := false
	for behaviour in identity.behaviours:
		if behaviour._net_predicts():
			predicting = true
			break
	if not predicting:
		_unpredicted += 1
	var from_prediction: bool = _was_predicting.get(identity.net_id, true)
	_was_predicting[identity.net_id] = predicting

	while predicting and replay_tick <= current_tick:
		var input := input_buffer.peek(replay_tick)

		# [b]A hole is not a gap.[/b] A tick with no input, but older and newer ones in the buffer, is a
		# tick the client never generated a command for -- its clock jumped forward over it (`DotNetClock`'s
		# catch-up) -- and the server ran it on the player's previous command.
		if input == null:
			var previous := input_buffer.latest_before(replay_tick)
			# A hole has inputs on BOTH sides. Past the newest input are ticks this client has not played yet
			# (a lockstep host reconciles before it records the tick), and replaying those on the last command
			# predicted them twice: game-arena's headless_net push check went 0.2 m -> 1.5 m off the server.
			if previous != null and not input_buffer.since(replay_tick + 1).is_empty():
				input = previous

		# A missing input means the client discarded it — the buffer is too short
		# for this latency. Simulating with no input diverges, so stop and let the
		# next snapshot correct it rather than compounding the error.
		if input == null and replay_tick < current_tick:
			DotLog.debug(
				CHANNEL,
				"replay gap; input history is too short for this latency",
				{
					"tick": replay_tick,
					"history": config.input_history_ticks,
				}
			)
			break

		# Put the tick's own input back before simulating it.
		if input != null:
			for behaviour in identity.behaviours:
				if behaviour.has_method("_net_apply_input"):
					behaviour.call("_net_apply_input", input, replay_tick)

		for behaviour in identity.behaviours:
			behaviour._net_simulate(replay_tick, tick_delta)
		# The replay is the prediction now; what the first pass remembered is not.
		_remember(identity, replay_tick)

		replayed += 1
		replay_tick += 1

		# Bounded so a client that fell far behind cannot spend an unbounded frame
		# catching up — which would make it fall further behind.
		if replayed > config.input_history_ticks:
			break

	_replays += 1
	_last_replay_ticks = replayed
	if config.skip_matching_replays:
		_forget_through(identity.net_id, server_tick)
		# A replay that stopped short left the ticks after it as the old prediction had them.
		var ticks: Dictionary = _predicted.get(identity.net_id, {})
		for t: int in ticks.keys():
			if t >= replay_tick:
				ticks.erase(t)

	# 3. Measure how wrong the prediction was.
	var after := _capture_visual(identity)
	var error := _visual_error(before, after)

	if not from_prediction:
		if error > config.reconcile_position_epsilon:
			_unpredicted_moves += 1
	else:
		_worst_error = maxf(_worst_error, error)
		if error > config.reconcile_position_epsilon:
			_corrections_applied += 1

	# [b]Every move a reconciliation makes is eased, not only the ones it counts.[/b] The epsilon decides
	# what is a misprediction worth reporting; it is not a size below which a jump is invisible.
	if error > 0.0:
		_begin_correction(identity, before, after, error)

	return DotResult.success(replayed)


## Records the offset to ease out, or snaps when it is too large.
func _begin_correction(
	identity: DotNetIdentity,
	before: Dictionary,
	after: Dictionary,
	error: float
) -> void:
	if error > config.reconcile_snap_distance:
		# Too far to hide. A correction this size means the prediction was wrong
		# about something structural — a teleport, a respawn, a collision the client
		# never saw — and easing across it drags the entity through geometry.
		_snaps += 1
		_corrections.erase(identity.net_id)

		DotLog.debug(
			CHANNEL,
			"correction snapped",
			{"net_id": identity.net_id, "error": "%.2f m" % error}
		)
		return

	var position_before: Vector3 = before.get("position", Vector3.ZERO)
	var position_after: Vector3 = after.get("position", Vector3.ZERO)

	# [b]Added to what is still being eased, not put in its place.[/b] A renderer draws the entity plus
	# [method visual_offset]; replacing an offset that has not finished decaying moves the drawing by
	# whatever was left of it, which is the very jump this exists to hide.
	var offset := visual_offset(identity.net_id) + (position_before - position_after)

	if offset.length() > config.reconcile_snap_distance:
		_corrections.erase(identity.net_id)
		return

	_corrections[identity.net_id] = {
		# The entity is left where the server says it is, and the renderer is
		# offset by the difference — which then decays to zero. The simulation
		# stays authoritative while the visuals catch up.
		"offset": offset,
		"at_ms": Time.get_ticks_msec(),
	}


## The visual offset for an entity, decaying toward zero. A renderer adds this to the entity's
## position.
func visual_offset(net_id: int) -> Vector3:
	if not _corrections.has(net_id):
		return Vector3.ZERO

	var correction: Dictionary = _corrections[net_id]
	var elapsed := float(Time.get_ticks_msec() - int(correction["at_ms"])) / 1000.0

	if config.reconcile_smooth_sec <= 0.0 or elapsed >= config.reconcile_smooth_sec:
		_corrections.erase(net_id)
		return Vector3.ZERO

	var remaining := 1.0 - (elapsed / config.reconcile_smooth_sec)

	# Eased rather than linear: a linear decay has a visible corner at the end,
	# where the correction stops moving all at once.
	return (correction["offset"] as Vector3) * (remaining * remaining)


func has_pending_correction(net_id: int) -> bool:
	return _corrections.has(net_id)


func _capture_visual(identity: DotNetIdentity) -> Dictionary:
	var out := {"position": identity.world_position()}

	if identity.entity is Node3D:
		out["rotation"] = (identity.entity as Node3D).global_basis.get_rotation_quaternion()

	return out


static func _visual_error(before: Dictionary, after: Dictionary) -> float:
	var a: Vector3 = before.get("position", Vector3.ZERO)
	var b: Vector3 = after.get("position", Vector3.ZERO)
	return a.distance_to(b)


func clear() -> void:
	_corrections.clear()
	_was_predicting.clear()
	_predicted.clear()


func forget(net_id: int) -> void:
	_corrections.erase(net_id)
	_was_predicting.erase(net_id)
	_predicted.erase(net_id)


## Reconciliations skipped because the prediction already matched the server.
func skipped() -> int:
	return _skipped


## Fraction of replays that needed a visible correction. The number that says whether prediction is
## working.
func correction_rate() -> float:
	if _replays == 0:
		return 0.0
	return float(_corrections_applied) / float(_replays)


func describe() -> Dictionary:
	return {
		"enabled": config.enable_prediction,
		"replays": _replays,
		"skipped": _skipped,
		"last_replay_ticks": _last_replay_ticks,
		"corrections": _corrections_applied,
		"snaps": _snaps,
		"correction_rate": "%.1f%%" % (correction_rate() * 100.0),
		"worst_error": "%.3f m" % _worst_error,
		"pending": _corrections.size(),
		"mismatches": _mismatches.duplicate(),
		"unpredicted": _unpredicted,
		"unpredicted_moves": _unpredicted_moves,
		"last_mismatch": _last_mismatch.duplicate(),
	}
