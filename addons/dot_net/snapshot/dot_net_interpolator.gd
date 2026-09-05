class_name DotNetInterpolator
extends RefCounted

## Renders remote entities smoothly from snapshots that arrive unevenly.
##
## [b]The problem.[/b] Snapshots arrive 20 times a second, at uneven intervals,
## sometimes out of order, sometimes not at all. Frames render 60–240 times a second.
## Applying each snapshot as it lands produces motion that steps and stutters, and
## every dropped packet is a visible freeze.
##
## [b]The fix, and its cost.[/b] Render slightly in the past — far enough that the
## snapshots bracketing the render time have already arrived — and interpolate
## between them. Motion becomes exactly as smooth as the frame rate. The cost is
## latency: everything remote is displayed as it was one buffer-length ago, which is
## why lag compensation exists on the server side to rewind by the same amount.
##
## [codeblock]
##   snapshots:  ●--------●--------●--------●   arriving
##                             ↑
##                        render here            one interval + jitter behind
## [/codeblock]
##
## [b]Adaptive buffering.[/b] A fixed delay is either too small on a jittery
## connection (stalls) or needlessly large on a clean one (latency). The buffer grows
## when snapshots arrive late and shrinks slowly when they do not, so a player on a
## good connection sees less delay than one on a bad connection — which is the right
## way round.

const CHANNEL := "net.interp"

## Samples kept per entity.
##
## Enough to cover the buffer plus a burst of out-of-order arrivals. Beyond that,
## older samples can never be rendered.
const TRACK_CAPACITY := 32

## One entity's recent states, ordered by tick.
class Track extends RefCounted:
	var net_id: int
	## Array of {tick, at_ms, values}
	var samples: Array[Dictionary] = []
	## Last values written to the entity, so a change is only applied once.
	var applied: Dictionary = {}

	func _init(p_net_id: int) -> void:
		net_id = p_net_id

	func push(tick: int, values: Dictionary) -> void:
		# Out-of-order arrivals are normal on an unreliable channel. Inserting in
		# tick order rather than appending means the bracket search stays a simple
		# scan, and a late packet still contributes rather than being discarded.
		var entry := {
			"tick": tick,
			"at_ms": Time.get_ticks_msec(),
			"values": values,
		}

		var index := samples.size()
		while index > 0 and int(samples[index - 1]["tick"]) > tick:
			index -= 1

		if index > 0 and int(samples[index - 1]["tick"]) == tick:
			# A duplicate tick, usually a retransmit. Merge rather than replace:
			# a delta only carries changed properties.
			var existing: Dictionary = samples[index - 1]["values"]
			for property in values:
				existing[property] = values[property]
			return

		samples.insert(index, entry)

		while samples.size() > TRACK_CAPACITY:
			samples.pop_front()

	func newest_tick() -> int:
		return int(samples[samples.size() - 1]["tick"]) if not samples.is_empty() else -1

	func oldest_tick() -> int:
		return int(samples[0]["tick"]) if not samples.is_empty() else -1

	func is_empty() -> bool:
		return samples.is_empty()


var config: DotNetConfig

## net_id -> Track
var _tracks: Dictionary = {}

## Current delay in ticks, adapted from observed arrival spacing.
var _delay_ticks: float = 2.0

## Rolling estimate of the gap between arrivals, in milliseconds.
var _arrival_interval_ms: float = 0.0
var _arrival_jitter_ms: float = 0.0
var _last_arrival_ms: int = 0

var _stalls: int = 0
var _extrapolations: int = 0


func _init(p_config: DotNetConfig) -> void:
	config = p_config
	_delay_ticks = config.interpolation_buffer


# --- Receiving -------------------------------------------------------------

## Records a snapshot's values for an entity.
func push(net_id: int, tick: int, values: Dictionary) -> void:
	if not _tracks.has(net_id):
		_tracks[net_id] = Track.new(net_id)

	(_tracks[net_id] as Track).push(tick, values)


## Notes that a snapshot arrived, for the adaptive buffer.
##
## Called once per snapshot, not once per entity — the thing being measured is how
## regularly packets land, not how many entities they carried.
func note_arrival() -> void:
	var now := Time.get_ticks_msec()

	if _last_arrival_ms > 0:
		var gap := float(now - _last_arrival_ms)

		if _arrival_interval_ms <= 0.0:
			_arrival_interval_ms = gap
		else:
			# Exponential moving average. Cheap, and it forgets an old connection
			# state at about the right rate.
			_arrival_interval_ms = _arrival_interval_ms * 0.9 + gap * 0.1
			_arrival_jitter_ms = _arrival_jitter_ms * 0.9 \
				+ absf(gap - _arrival_interval_ms) * 0.1

	_last_arrival_ms = now

	if config.adaptive_interpolation:
		_adapt()


## Grows the buffer quickly and shrinks it slowly.
##
## Asymmetric on purpose. Growing late means a visible stall; shrinking late means
## slightly more latency than necessary. The first is much worse, so the buffer is
## quick to add and reluctant to give back.
func _adapt() -> void:
	if _arrival_interval_ms <= 0.0:
		return

	var interval_ms := config.snapshot_interval() * 1000.0

	# Cover the nominal interval plus two jitter deviations, expressed in snapshots.
	var needed := 1.0 + (_arrival_jitter_ms * 2.0) / maxf(1.0, interval_ms)
	needed = clampf(needed, 1.0, 10.0)

	if needed > _delay_ticks:
		_delay_ticks = needed
	else:
		_delay_ticks = lerpf(_delay_ticks, needed, 0.01)


# --- Sampling --------------------------------------------------------------

## Interpolated values for an entity at the current render time.
##
## Returns an empty dictionary when there is nothing to show yet — a newly-spawned
## entity with one sample cannot be interpolated, and showing it at a guessed
## position is worse than showing it at its only known one.
func sample(net_id: int, server_tick: int) -> Dictionary:
	if not _tracks.has(net_id):
		return {}

	var track: Track = _tracks[net_id]

	if track.is_empty():
		return {}

	var render_tick := float(server_tick) - _delay_ticks

	if track.samples.size() == 1:
		return (track.samples[0]["values"] as Dictionary).duplicate()

	# Newer than everything we have: the stream stalled. Extrapolate briefly, then
	# hold — see _extrapolate.
	if render_tick >= float(track.newest_tick()):
		_stalls += 1
		return _extrapolate(track, render_tick)

	# Older than everything we have. Happens after a long stall or a clock snap;
	# the oldest sample is the best available answer.
	if render_tick <= float(track.oldest_tick()):
		return (track.samples[0]["values"] as Dictionary).duplicate()

	for i in range(track.samples.size() - 1):
		var older: Dictionary = track.samples[i]
		var newer: Dictionary = track.samples[i + 1]

		var older_tick := float(older["tick"])
		var newer_tick := float(newer["tick"])

		if render_tick >= older_tick and render_tick <= newer_tick:
			var span := newer_tick - older_tick
			var alpha := 0.0 if span <= 0.0 else (render_tick - older_tick) / span
			return _blend(
				older["values"], newer["values"], clampf(alpha, 0.0, 1.0)
			)

	return (track.samples[track.samples.size() - 1]["values"] as Dictionary).duplicate()


## Continues past the newest sample, briefly.
##
## Bounded by [member DotNetConfig.max_extrapolation_sec]. Past that the entity holds
## position: a wrong guess that keeps moving ends up far from the truth and snaps
## back hard when the stream resumes, which reads as teleporting. A stationary stale
## entity reads as lag, which is what it is.
func _extrapolate(track: Track, render_tick: float) -> Dictionary:
	var newest: Dictionary = track.samples[track.samples.size() - 1]
	var values: Dictionary = newest["values"]

	var ahead_ticks := render_tick - float(newest["tick"])
	var max_ticks := config.max_extrapolation_sec * float(config.tick_rate)

	if ahead_ticks <= 0.0 or max_ticks <= 0.0 or track.samples.size() < 2:
		return values.duplicate()

	if ahead_ticks > max_ticks:
		return values.duplicate()

	_extrapolations += 1

	var previous: Dictionary = track.samples[track.samples.size() - 2]
	var previous_values: Dictionary = previous["values"]
	var span := float(newest["tick"]) - float(previous["tick"])

	if span <= 0.0:
		return values.duplicate()

	var out := values.duplicate()

	# Linear on position only. Extrapolating a rotation compounds error fast, and
	# extrapolating a discrete value is meaningless.
	for property in values:
		if not previous_values.has(property):
			continue

		var current: Variant = values[property]
		var before: Variant = previous_values[property]

		if current is Vector3 and before is Vector3:
			var velocity := ((current as Vector3) - (before as Vector3)) / span
			out[property] = (current as Vector3) + velocity * ahead_ticks
		elif current is Vector2 and before is Vector2:
			var velocity2 := ((current as Vector2) - (before as Vector2)) / span
			out[property] = (current as Vector2) + velocity2 * ahead_ticks

	return out


## Blends two value sets.
##
## Only continuous types are interpolated. A bool, a string or an enum jumps at the
## midpoint rather than being blended — interpolating a weapon index would produce
## weapons that do not exist.
func _blend(older: Dictionary, newer: Dictionary, alpha: float) -> Dictionary:
	var out := {}

	for property in newer:
		var to_value: Variant = newer[property]

		if not older.has(property):
			out[property] = to_value
			continue

		var from_value: Variant = older[property]
		out[property] = _blend_value(from_value, to_value, alpha)

	# Properties present only in the older sample are carried through: a delta only
	# names what changed, so absence means unchanged.
	for property in older:
		if not out.has(property):
			out[property] = older[property]

	return out


static func _blend_value(from_value: Variant, to_value: Variant, alpha: float) -> Variant:
	if typeof(from_value) != typeof(to_value):
		return to_value

	if from_value is float:
		return lerpf(from_value, to_value, alpha)

	if from_value is Vector3:
		return (from_value as Vector3).lerp(to_value as Vector3, alpha)

	if from_value is Vector2:
		return (from_value as Vector2).lerp(to_value as Vector2, alpha)

	if from_value is Quaternion:
		# Spherical, not linear: a linear blend of quaternions is not a rotation and
		# the result is a shortest-path arc only by accident.
		return (from_value as Quaternion).slerp(to_value as Quaternion, alpha)

	if from_value is Color:
		return (from_value as Color).lerp(to_value as Color, alpha)

	# Discrete. Switch at the midpoint so the change happens once, at a predictable
	# moment, rather than on the first or last frame of the interval.
	return to_value if alpha >= 0.5 else from_value


## Applies interpolated values to an entity's behaviours.
##
## Only properties declared [member DotNetVar.interpolate] are written here; the rest
## were applied directly when the snapshot arrived. Splitting them is what lets a
## health bar slide while a weapon index snaps.
func apply(identity: DotNetIdentity, server_tick: int) -> void:
	if identity == null or identity.is_predicted():
		# A predicted entity is driven by prediction, not by interpolation. Writing
		# interpolated state over it would fight the predictor every frame.
		return

	var values := sample(identity.net_id, server_tick)
	if values.is_empty():
		return

	for behaviour in identity.behaviours:
		var wrote := false

		for declaration in behaviour.net_vars:
			if not declaration.interpolate:
				continue
			if not values.has(declaration.property):
				continue
			behaviour._net_write_property(
				declaration.property, values[declaration.property]
			)
			wrote = true

		# Told, not left in the property. A game copies replicated state into a node or a
		# simulation from a hook; if the only hook it has is the one a snapshot fires,
		# every remote entity moves at the snapshot rate and everything computed here is
		# thrown away — which looks exactly like an interpolator that does not work.
		if wrote:
			behaviour._net_interpolated(server_tick)


# --- Housekeeping ----------------------------------------------------------

func forget(net_id: int) -> void:
	_tracks.erase(net_id)


func clear() -> void:
	_tracks.clear()
	_last_arrival_ms = 0
	_arrival_interval_ms = 0.0
	_arrival_jitter_ms = 0.0


## Drops tracks whose entity is gone, and samples nothing will render.
func prune(live_ids: PackedInt64Array) -> void:
	var live := {}
	for net_id in live_ids:
		live[net_id] = true

	for net_id in _tracks.keys():
		if not live.has(net_id):
			_tracks.erase(net_id)


func delay_ticks() -> float:
	return _delay_ticks


func delay_ms() -> float:
	return _delay_ticks * config.snapshot_interval() * 1000.0


func track_count() -> int:
	return _tracks.size()


func describe() -> Dictionary:
	return {
		"tracks": _tracks.size(),
		"delay_ticks": "%.2f" % _delay_ticks,
		"delay_ms": int(delay_ms()),
		"arrival_ms": int(_arrival_interval_ms),
		"jitter_ms": int(_arrival_jitter_ms),
		"stalls": _stalls,
		"extrapolations": _extrapolations,
	}
