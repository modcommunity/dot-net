class_name DotNetHistory
extends RefCounted

## Past positions of every entity, so the server can judge a shot the way the
## shooter saw it.
##
## [b]The problem lag compensation solves.[/b] A client renders remote players
## interpolated into the past — one buffer-length behind the server, plus half a round
## trip of travel time. When the player aims at a head and fires, that head was there
## on their screen, and it is not there now on the server. Judging the shot against
## the server's present means a player with 100 ms of latency must lead every target
## by a body width, which is unplayable and unfair in a way players correctly perceive
## as the game being broken.
##
## [b]The fix, and who pays for it.[/b] The server rewinds every other entity to where
## the shooter saw them, tests the shot there, and restores. The shooter gets the hit
## they earned. The victim occasionally dies after reaching cover — they moved during
## the shooter's latency window, and someone has to absorb that. Every competitive
## shooter makes the same trade in the same direction, because the alternative
## penalises the player who did nothing wrong.
##
## [b]The bound matters.[/b] [member DotNetConfig.max_rewind_sec] caps how far back a
## client's claim is honoured. Without it, a client that lies about its latency can
## rewind arbitrarily far and shoot targets that were somewhere else a full second
## ago.

const CHANNEL := "net.lagcomp"

## One recorded moment for one entity.
class Sample extends RefCounted:
	var tick: int
	var position: Vector3
	var rotation: Quaternion
	## Extra state a game records alongside the transform — a crouch flag changing
	## hitbox height, an animation frame, a vehicle seat.
	var extra: Dictionary

	func _init(
		p_tick: int,
		p_position: Vector3,
		p_rotation: Quaternion,
		p_extra: Dictionary = {}
	) -> void:
		tick = p_tick
		position = p_position
		rotation = p_rotation
		extra = p_extra


## One entity's recorded history, as a ring buffer.
class Track extends RefCounted:
	var net_id: int
	var samples: Array[Sample] = []
	var capacity: int

	func _init(p_net_id: int, p_capacity: int) -> void:
		net_id = p_net_id
		capacity = maxi(2, p_capacity)

	func record(sample: Sample) -> void:
		# Ticks only ever move forward on the authority, so appending keeps the
		# array sorted without a search.
		if not samples.is_empty() and samples[samples.size() - 1].tick >= sample.tick:
			samples[samples.size() - 1] = sample
			return

		samples.append(sample)

		while samples.size() > capacity:
			samples.pop_front()

	## The state at a tick, interpolating between the two recorded around it.
	##
	## Interpolated rather than nearest: at a 20 Hz record rate the nearest sample can
	## be 25 ms wrong, which at running speed is a third of a metre — the difference
	## between a hit and a miss.
	func sample_at(tick: float) -> Sample:
		if samples.is_empty():
			return null

		if tick <= float(samples[0].tick):
			return samples[0]

		var newest := samples[samples.size() - 1]
		if tick >= float(newest.tick):
			return newest

		for i in range(samples.size() - 1):
			var older := samples[i]
			var newer := samples[i + 1]

			if tick >= float(older.tick) and tick <= float(newer.tick):
				var span := float(newer.tick - older.tick)
				if span <= 0.0:
					return older

				var alpha := (tick - float(older.tick)) / span

				return Sample.new(
					int(tick),
					older.position.lerp(newer.position, alpha),
					older.rotation.slerp(newer.rotation, alpha),
					# Extra state is not interpolated: a crouch flag halfway between
					# standing and crouched is neither, and a hitbox built from it
					# would be wrong in both directions.
					(older.extra if alpha < 0.5 else newer.extra)
				)

		return newest

	func oldest_tick() -> int:
		return samples[0].tick if not samples.is_empty() else -1

	func newest_tick() -> int:
		return samples[samples.size() - 1].tick if not samples.is_empty() else -1


var config: DotNetConfig

## net_id -> Track
var _tracks: Dictionary = {}

## Entities currently rewound, so [method restore] can put them back.
var _rewound: Dictionary = {}

var _rewinds: int = 0
var _refused: int = 0


func _init(p_config: DotNetConfig) -> void:
	config = p_config


# --- Recording -------------------------------------------------------------

## Records the current state of every entity. Called once per snapshot on the server.
##
## Recording at the snapshot rate rather than the tick rate is deliberate: the client
## only ever saw snapshot-rate positions, so finer history records moments nobody
## could have been aiming at, at several times the memory.
func record(identities: Array[DotNetIdentity], tick: int) -> void:
	if not config.enable_lag_compensation:
		return

	for identity in identities:
		if identity.entity == null:
			continue

		var rotation := Quaternion.IDENTITY
		if identity.entity is Node3D:
			rotation = (identity.entity as Node3D).global_basis.get_rotation_quaternion()

		var extra := {}
		for behaviour in identity.behaviours:
			if behaviour.has_method("_net_record_history"):
				var contributed: Variant = behaviour.call("_net_record_history")
				if contributed is Dictionary:
					extra.merge(contributed as Dictionary, true)

		_track_for(identity.net_id).record(
			Sample.new(tick, identity.world_position(), rotation, extra)
		)


func _track_for(net_id: int) -> Track:
	if not _tracks.has(net_id):
		_tracks[net_id] = Track.new(net_id, config.history_samples())
	return _tracks[net_id]


# --- Rewinding -------------------------------------------------------------

## Moves entities to where they were at [param target_tick].
##
## [b]Must be paired with [method restore].[/b] Leaving the world rewound means every
## subsequent operation that tick — physics, other players' shots, the next
## snapshot — happens in the past. The pattern is rewind, test, restore, with nothing
## that can return early in between.
##
## [param exclude_net_id] leaves the shooter alone; rewinding the entity doing the
## shooting would move its own muzzle.
func rewind(
	identities: Array[DotNetIdentity],
	target_tick: int,
	current_tick: int,
	exclude_net_id: int = 0
) -> DotResult:
	if not config.enable_lag_compensation:
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED, "Lag compensation is disabled."
		)

	if not _rewound.is_empty():
		return DotResult.fail(
			DotError.CODE_STATE,
			"The world is already rewound.",
			"restore() before rewinding again"
		)

	var behind := current_tick - target_tick

	if behind < 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Cannot rewind to a future tick.",
			"target %d, current %d" % [target_tick, current_tick]
		)

	# The bound that stops a client claiming an arbitrary latency. A claim past it is
	# clamped rather than refused: a player on a genuinely terrible connection should
	# still get compensation, just not unlimited compensation.
	var max_ticks := config.max_rewind_ticks()
	var clamped_tick := target_tick

	if behind > max_ticks:
		_refused += 1
		clamped_tick = current_tick - max_ticks
		DotLog.debug(
			CHANNEL,
			"rewind clamped to the maximum",
			{"asked": behind, "max": max_ticks}
		)

	for identity in identities:
		if identity.net_id == exclude_net_id or identity.entity == null:
			continue

		if not _tracks.has(identity.net_id):
			continue

		var sample := (_tracks[identity.net_id] as Track).sample_at(float(clamped_tick))
		if sample == null:
			continue

		_rewound[identity.net_id] = {
			"identity": identity,
			"position": identity.world_position(),
			"rotation": _current_rotation(identity),
		}

		_apply(identity, sample.position, sample.rotation)

	_rewinds += 1

	return DotResult.success({
		"rewound": _rewound.size(),
		"tick": clamped_tick,
		"ticks_back": current_tick - clamped_tick,
	})


## Puts every rewound entity back where it was.
##
## Safe to call when nothing is rewound, so it can go in a deferred block without a
## guard.
func restore() -> int:
	var count := _rewound.size()

	for net_id in _rewound:
		var entry: Dictionary = _rewound[net_id]
		var identity: DotNetIdentity = entry["identity"]

		if is_instance_valid(identity) and identity.entity != null:
			_apply(identity, entry["position"], entry["rotation"])

	_rewound.clear()
	return count


## Runs [param body] with the world rewound, restoring afterwards.
##
## The safe form, and the one to use. A hand-written rewind/restore pair leaves the
## world in the past the first time somebody adds an early return between them.
func with_rewind(
	identities: Array[DotNetIdentity],
	target_tick: int,
	current_tick: int,
	exclude_net_id: int,
	body: Callable
) -> Variant:
	var rewound := rewind(identities, target_tick, current_tick, exclude_net_id)

	if not rewound.ok:
		# Still run the test, against the present. A refused rewind should not mean a
		# shot silently does nothing.
		return body.call()

	var result: Variant = body.call()
	restore()
	return result


static func _current_rotation(identity: DotNetIdentity) -> Quaternion:
	if identity.entity is Node3D:
		return (identity.entity as Node3D).global_basis.get_rotation_quaternion()
	return Quaternion.IDENTITY


static func _apply(
	identity: DotNetIdentity,
	position: Vector3,
	rotation: Quaternion
) -> void:
	var entity := identity.entity

	if entity is Node3D:
		var node := entity as Node3D
		node.global_position = position
		node.global_basis = Basis(rotation)
	elif entity is Node2D:
		(entity as Node2D).global_position = Vector2(position.x, position.y)


# --- Queries ---------------------------------------------------------------

## Where an entity was at a tick, without moving anything.
##
## For tests that do their own maths rather than using the physics engine — a hitscan
## against a capsule, a proximity check.
func position_at(net_id: int, tick: float) -> Variant:
	if not _tracks.has(net_id):
		return null

	var sample := (_tracks[net_id] as Track).sample_at(tick)
	return sample.position if sample != null else null


## The tick a client was rendering, given its ping and the interpolation delay.
##
## What a shot should be judged against: the client saw the world half a round trip
## ago, delayed by its own interpolation buffer on top.
func client_view_tick(
	current_tick: int,
	rtt_ms: float,
	interpolation_delay_ticks: float
) -> int:
	var latency_ticks := (rtt_ms * 0.5) / 1000.0 * float(config.tick_rate)
	return current_tick - int(roundf(latency_ticks + interpolation_delay_ticks))


func forget(net_id: int) -> void:
	_tracks.erase(net_id)
	_rewound.erase(net_id)


func clear() -> void:
	restore()
	_tracks.clear()


func is_rewound() -> bool:
	return not _rewound.is_empty()


func describe() -> Dictionary:
	var samples := 0
	for net_id in _tracks:
		samples += (_tracks[net_id] as Track).samples.size()

	return {
		"enabled": config.enable_lag_compensation,
		"tracks": _tracks.size(),
		"samples": samples,
		"max_rewind_ms": int(config.max_rewind_sec * 1000.0),
		"rewinds": _rewinds,
		"clamped": _refused,
		"currently_rewound": _rewound.size(),
	}
