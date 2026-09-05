class_name DotNetPredictor
extends RefCounted

## Client-side prediction and server reconciliation.
##
## [b]Why prediction.[/b] Without it, pressing forward does nothing until the input
## reaches the server and the resulting state comes back — a full round trip. At
## 80 ms that is noticeable; at 150 ms it is unplayable. So the client applies the
## input immediately, to its own copy, and assumes the server will agree.
##
## [b]Why reconciliation.[/b] Sometimes it will not agree — the client missed a
## collision, or another player pushed it, or it was simply wrong. The server's answer
## for tick N arrives while the client is already at tick N+12. Snapping to it would
## undo twelve ticks of movement the player has already seen. Instead:
##
## [codeblock]
##   1. accept the server's state for tick N
##   2. replay inputs N+1 … N+12 through the same simulation
##   3. compare the result with what the client currently shows
##   4. if it differs, ease from the old position to the new one
## [/codeblock]
##
## Steps 1–3 are exact. Step 4 is the cosmetic part, and it is where a correction
## either feels like a small tug or like a teleport.
##
## [b]The determinism requirement.[/b] Replay only converges if
## [method DotNetBehaviour._net_simulate] produces the same result on both machines
## given the same input and starting state. Anything that differs between them —
## wall-clock time, unseeded random, another player's unpredicted position, a
## physics query against geometry only one side has loaded — makes the client
## disagree with the server every tick, and the correction never settles.

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


func _init(p_config: DotNetConfig) -> void:
	config = p_config


# --- Prediction ------------------------------------------------------------

## Simulates one tick for every predicted entity.
##
## Called on the client each tick, after the input for that tick has been recorded.
## The same code path the server runs, which is what makes the two agree.
func predict(
	identities: Array[DotNetIdentity],
	tick: int,
	delta: float
) -> void:
	if not config.enable_prediction:
		return

	for identity in identities:
		if not identity.is_predicted():
			continue

		for behaviour in identity.behaviours:
			behaviour._net_simulate(tick, delta)


# --- Reconciliation --------------------------------------------------------

## Accepts an authoritative state and replays everything since.
##
## [param authoritative_values] is what the server said for [param server_tick].
## [param input_buffer] holds the inputs the client has sent since. Returns how many
## ticks were replayed.
##
## [b]The replay is the expensive part[/b] — it is one simulation step per unacked
## tick, every time a correction arrives, which at 20 Hz snapshots and 100 ms latency
## is about six steps twenty times a second. Keeping [method DotNetBehaviour._net_simulate]
## cheap matters more here than anywhere else in the frame.
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
		# Nothing authoritative for this entity in this snapshot — it was not sent,
		# not that it did not move. Leaving the prediction alone is correct.
		return DotResult.success(0)

	# 2. Replay every input the server has not confirmed yet.
	var replayed := 0
	var replay_tick := server_tick + 1

	while replay_tick <= current_tick:
		var input := input_buffer.peek(replay_tick)

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

		# Put the tick's own input back before simulating it. Without this the
		# whole replay runs on whatever input the behaviour happens to be holding
		# — the newest one — which is not what the server simulated for these
		# ticks, so the replay converges on a state the server never computed and
		# the "correction" is measured against a fiction.
		#
		# It is silent whenever the player holds one direction for the entire
		# unacked window, which is most of a test and none of a game: it shows up
		# exactly when the input changes, which is exactly when a correction is
		# most visible. `DotNetManager._apply_input` does the same thing on the
		# server tick, and the two must match or determinism does not.
		if input != null:
			for behaviour in identity.behaviours:
				if behaviour.has_method("_net_apply_input"):
					behaviour.call("_net_apply_input", input, replay_tick)

		for behaviour in identity.behaviours:
			behaviour._net_simulate(replay_tick, tick_delta)

		replayed += 1
		replay_tick += 1

		# Bounded so a client that fell far behind cannot spend an unbounded frame
		# catching up — which would make it fall further behind.
		if replayed > config.input_history_ticks:
			break

	_replays += 1
	_last_replay_ticks = replayed

	# 3. Measure how wrong the prediction was.
	var after := _capture_visual(identity)
	var error := _visual_error(before, after)

	_worst_error = maxf(_worst_error, error)

	if error > config.reconcile_position_epsilon:
		_corrections_applied += 1
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

	_corrections[identity.net_id] = {
		# The entity is left where the server says it is, and the renderer is
		# offset by the difference — which then decays to zero. The simulation
		# stays authoritative while the visuals catch up.
		"offset": position_before - position_after,
		"at_ms": Time.get_ticks_msec(),
	}


## The visual offset for an entity, decaying toward zero.
##
## A renderer adds this to the entity's position. Returns zero when there is nothing
## outstanding, so it can be added unconditionally.
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


# --- Reporting -------------------------------------------------------------

func clear() -> void:
	_corrections.clear()


func forget(net_id: int) -> void:
	_corrections.erase(net_id)


## Fraction of replays that needed a visible correction.
##
## The number that says whether prediction is working. Near zero means the client and
## server agree; consistently high means the simulation is not deterministic, and no
## amount of smoothing will fix that.
func correction_rate() -> float:
	if _replays == 0:
		return 0.0
	return float(_corrections_applied) / float(_replays)


func describe() -> Dictionary:
	return {
		"enabled": config.enable_prediction,
		"replays": _replays,
		"last_replay_ticks": _last_replay_ticks,
		"corrections": _corrections_applied,
		"snaps": _snaps,
		"correction_rate": "%.1f%%" % (correction_rate() * 100.0),
		"worst_error": "%.3f m" % _worst_error,
		"pending": _corrections.size(),
	}
