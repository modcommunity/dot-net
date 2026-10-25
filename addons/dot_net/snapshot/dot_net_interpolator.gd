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
	## What [method DotNetInterpolator.apply] still adds to each position it draws: the
	## part of a jump out of an extrapolation not yet eased away. property -> Vector3/2.
	var offsets: Dictionary = {}
	## The two samples the last drawn frame extrapolated from, or empty when it was
	## between two samples. See [method DotNetInterpolator._ease_resume].
	var ahead_from: Array[Dictionary] = []

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

## Current delay in SNAPSHOTS, adapted from observed arrival spacing.
##
## [b]Snapshots, and converted to ticks in exactly one place.[/b] This field was called
## `_delay_ticks` and was documented, adapted and reported as a number of snapshots — the
## config says "snapshots of delay", [method _adapt] computes it in snapshot intervals and
## [method delay_ms] multiplied it by one — and was then subtracted, unconverted, from a
## TICK number in [method sample]. At the default 60/20 that is a third of the buffer
## anybody asked for; at 128 ticks and 20 snapshots it is under a sixth, less than one
## snapshot interval, so the render time sat past the newest snapshot most of the time and
## every remote entity in the family was extrapolated rather than interpolated — 1,684
## extrapolated frames in six seconds of one game. Nothing failed: extrapolation is
## bounded, the positions were plausible, and the checks that sampled at hand-picked ticks
## were written in the same confused unit. [method delay_ticks] is the conversion, and the
## only thing [method sample] subtracts.
var _delay_snapshots: float = 2.0

## Rolling estimate of the gap between arrivals, in milliseconds.
var _arrival_interval_ms: float = 0.0
var _arrival_jitter_ms: float = 0.0
var _last_arrival_ms: int = 0

## Counters a suite and an operator read, not only [method describe]. [member _samples] is
## every call to [method sample] that had two or more samples to choose between — the
## denominator, without which a count of extrapolations means nothing. [member _stalls] is
## the render time at or past the newest snapshot (extrapolating or holding), and
## [member _extrapolations] the subset that guessed past it. On a healthy connection both
## are near zero; a steady share of frames in either is a buffer too short for the link —
## or, as it was here, a buffer in the wrong unit.
var _samples: int = 0
var _stalls: int = 0
var _extrapolations: int = 0

## Where the buffer is heading, in snapshots; [member _delay_snapshots] is the buffer
## drawn with, and follows this at a bounded rate once frames drive it.
##
## [b]Two numbers, because growing the buffer at once moves every remote player
## backwards.[/b] The render time is the receive timeline minus the buffer, so a buffer
## that jumps from 1.3 snapshots to 2.2 puts the render time back 3.6 ticks in one frame:
## measured in game-g2gfast's `headless_feel` at 128 ticks, the render timeline stepped
## back 11 times in eight seconds by up to 3.45 ticks when a 30..80 ms link replaced a
## steady one -- a runner drawn a third of a metre back and then forward. Followed at
## [constant GROW_RATE], the render time only ever slows down.
var _target_snapshots: float = 2.0

## How fast the drawn buffer may follow its target, in ticks of buffer per tick of time.
## 0.2 means the render timeline runs at 80% speed (or 120%, shrinking) while it moves:
## a remote player slowed for a moment, never one sent backwards.
const GROW_RATE := 0.2

## The last frame's length, from [method advance]: what eases a resumed stream. Zero until
## a host drives frames, which leaves the easing off.
var _frame_elapsed: float = 0.0

## How long a jump out of an extrapolation takes to ease away, in seconds (the time constant
## of an exponential: 63% gone after this, 95% after three times it).
##
## [b]Without it a resumed stream was a snap.[/b] Extrapolating past the newest snapshot
## guesses along a straight line; when the next one lands the drawing jumps to where it says,
## and the guess was off by however far the entity turned. Measured in game-arena's
## `headless_feel` over 5% loss, 30..80 ms: 33 of 864 frames drew a runner more than 2 cm off
## its motion, the worst 17 cm in one frame; eased, the same distance is covered over a tenth
## of a second, a few millimetres a frame.
const RESUME_EASE_SEC := 0.06

## A jump larger than this, in metres, is a teleport and is drawn at once.
const RESUME_EASE_MAX := 1.5

## Whether [method advance] has ever been called. Until a host drives the buffer per
## frame it follows its target at once, as it always did, so a host that samples by hand
## and never calls [method advance] is not left on the initial buffer for ever.
var _frame_driven: bool = false

## How late each recent snapshot arrived, in ticks behind the receive timeline, and
## whether a snapshot was missing just before it. See [method note_lateness].
const LATENESS_WINDOW := 64
var _lateness: Array[float] = []
var _lost: Array[bool] = []
var _last_late_tick: int = -1
var _late_fed: bool = false


func _init(p_config: DotNetConfig) -> void:
	config = p_config
	_delay_snapshots = config.interpolation_buffer
	_target_snapshots = _delay_snapshots


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

	# A host that also reports lateness adapts from there, once per arrival.
	if config.adaptive_interpolation and not _late_fed:
		_adapt()


## Notes how late the snapshot for [param tick] arrived: [param received_tick] is the
## clock's receive timeline once it has seen it ([method DotNetClock.received_tick]),
## which the quickest arrivals set, so this is the time the packet spent over the
## quickest, in ticks.
##
## [b]What the buffer actually has to cover.[/b] A render time R is drawn between two
## snapshots only if the one after R has arrived, and that one is up to a snapshot
## interval past R and arrives as late as its packet was. So the buffer needs the
## interval, plus how late packets are, plus one more interval when one goes missing --
## and sizing it from the spread of arrival gaps alone, as it was, measured about two
## thirds of the way there: 37% of frames extrapolated through 30..80 ms with 5% loss at
## 128 ticks (game-g2gfast `headless_feel`), and 12% at 64 (game-arena `headless_lossy`).
func note_lateness(tick: int, received_tick: int) -> void:
	_late_fed = true
	var period := _snapshot_ticks()

	_lateness.append(maxf(0.0, float(received_tick - tick)))
	# A gap of more than one period before this snapshot is one that never came.
	_lost.append(_last_late_tick >= 0 and float(tick - _last_late_tick) > period * 1.5)
	_last_late_tick = maxi(_last_late_tick, tick)

	if _lateness.size() > LATENESS_WINDOW:
		_lateness.remove_at(0)
		_lost.remove_at(0)

	if config.adaptive_interpolation:
		_adapt()


## The 95th percentile of recent lateness, in ticks.
func _late_ticks() -> float:
	if _lateness.is_empty():
		return 0.0
	var sorted := _lateness.duplicate()
	sorted.sort()
	return sorted[clampi(int(ceilf(0.95 * float(sorted.size() - 1))), 0, sorted.size() - 1)]


## Moves the drawn buffer toward its target by at most [constant GROW_RATE] of the time
## that passed. Called once a frame, before sampling, by
## [method DotNetManager.interpolate_frame].
func advance(elapsed_sec: float) -> void:
	_frame_driven = true
	_frame_elapsed = maxf(0.0, elapsed_sec)
	var period := maxf(1.0, _snapshot_ticks())
	var step := GROW_RATE * maxf(0.0, elapsed_sec) * float(maxi(1, config.tick_rate)) / period
	_delay_snapshots = move_toward(_delay_snapshots, _target_snapshots, step)


## Grows the buffer quickly and shrinks it slowly.
##
## Asymmetric on purpose. Growing late means a visible stall; shrinking late means
## slightly more latency than necessary. The first is much worse, so the buffer is
## quick to add and reluctant to give back.
func _adapt() -> void:
	# Lateness alone is enough to size it; the gap estimate needs two arrivals.
	if _arrival_interval_ms <= 0.0 and _lateness.is_empty():
		return

	var interval_ms := _snapshot_ticks() / float(maxi(1, config.tick_rate)) * 1000.0

	# Cover the nominal interval plus two jitter deviations, expressed in snapshots.
	var needed := 1.0 + (_arrival_jitter_ms * 2.0) / maxf(1.0, interval_ms)

	# And, where the host reports it, what lateness says: one interval to the snapshot
	# after the render time, how late recent ones came, and one more interval if any recent
	# snapshot went missing. See [method note_lateness]. Not a tick more for the frame's
	# fraction, which would be exact and cost every clean link a tick of delay to cover
	# what the bounded extrapolation already draws within millimetres: measured at 64
	# ticks, a steady link's buffer was 4.1 ticks with it and 3.0 without, against 2.5
	# before any of this, with nothing extrapolated in any of them.
	if not _lateness.is_empty():
		var period := maxf(1.0, _snapshot_ticks())
		var ticks := period + _late_ticks()
		if _lost.has(true):
			ticks += period
		needed = maxf(needed, ticks / period)

	needed = clampf(needed, 1.0, 10.0)

	var before := _delay_snapshots

	if needed > _target_snapshots:
		_target_snapshots = needed
	else:
		_target_snapshots = lerpf(_target_snapshots, needed, 0.01)

	if not _frame_driven:
		_delay_snapshots = _target_snapshots

	# [b]Reported on whole snapshots crossed, not on every adjustment.[/b] This runs on
	# every arrival and the shrink is a 1% lerp, so a line per change is a line twenty
	# times a second that never says anything. A whole snapshot of buffer is the unit
	# that matters: it is what the player pays in latency, and it is what lag
	# compensation on the server has to rewind by.
	#
	# DEBUG, and a state transition rather than a fault -- the buffer growing is this
	# class absorbing a connection's jitter, which is its whole job. It is also the
	# answer to "everything remote feels delayed", which nothing else in the process
	# reports.
	if floori(_delay_snapshots) != floori(before):
		DotLog.debug(CHANNEL, "the interpolation buffer moved", {
			"from": "%.2f snapshots" % before,
			"to": "%.2f snapshots (%.1f ticks)" % [_delay_snapshots, delay_ticks()],
			"jitter": "%.1f ms" % _arrival_jitter_ms,
			"interval": "%.1f ms" % _arrival_interval_ms,
		})


# --- Sampling --------------------------------------------------------------

## Interpolated values for an entity at the current render time.
##
## Returns an empty dictionary when there is nothing to show yet — a newly-spawned
## entity with one sample cannot be interpolated, and showing it at a guessed
## position is worse than showing it at its only known one.
## [param server_tick] is deliberately a float. A renderer runs between ticks and the
## whole point of this class is to answer for the moment it is drawing, not for the
## last whole tick that happened to have passed — see
## [method DotNetManager.interpolate_frame], which is where the fraction comes from.
func sample(net_id: int, server_tick: float) -> Dictionary:
	if not _tracks.has(net_id):
		return {}

	var track: Track = _tracks[net_id]

	if track.is_empty():
		return {}

	# Ticks, because [param server_tick] is one. See [member _delay_snapshots].
	var render_tick := float(server_tick) - delay_ticks()

	if track.samples.size() == 1:
		return (track.samples[0]["values"] as Dictionary).duplicate()

	_samples += 1

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


## [param property] of an entity as it was drawn at [param render_tick] (already behind by the
## delay): the bracketing samples blended, the newest past the end, null when unknown or older
## than the buffer. With [param cut] > 0 a jump longer than it between two samples after
## [param render_tick] is a teleport, and nothing before it is known either (null). Counts
## nothing and never extrapolates, so a replay gets the first answer again. What a predicting
## client collides with when the server rewinds to the same view tick
## (docs/prediction.md#bumping-a-remote).
func value_at(net_id: int, property: StringName, render_tick: float, cut: float = 0.0) -> Variant:
	var track: Track = _tracks.get(net_id)
	if track == null or track.is_empty():
		return null
	var samples := track.samples
	var last := samples.size() - 1
	if render_tick >= float(samples[last]["tick"]):
		return (samples[last]["values"] as Dictionary).get(property)
	if render_tick < float(samples[0]["tick"]):
		return null
	for i in range(last):
		var newer_tick := float(samples[i + 1]["tick"])
		if render_tick > newer_tick:
			continue
		if cut > 0.0 and _jumps_after(samples, i, property, cut):
			return null
		var older_tick := float(samples[i]["tick"])
		var a: Variant = (samples[i]["values"] as Dictionary).get(property)
		var b: Variant = (samples[i + 1]["values"] as Dictionary).get(property)
		if a == null or b == null:
			return b if b != null else a
		var alpha := 0.0 if newer_tick <= older_tick else (render_tick - older_tick) / (newer_tick - older_tick)
		if (a is Vector3 and b is Vector3) or (a is Vector2 and b is Vector2) or (a is float and b is float):
			return lerp(a, b, alpha)
		return a if alpha < 0.5 else b
	return (samples[last]["values"] as Dictionary).get(property)


## Whether [param property] moves further than [param cut] between any two neighbouring
## samples from index [param from] on: a teleport [method value_at] does not reach across.
static func _jumps_after(samples: Array, from: int, property: StringName, cut: float) -> bool:
	var before: Variant = null
	for j in range(from, samples.size()):
		var now: Variant = (samples[j]["values"] as Dictionary).get(property)
		if now == null:
			continue
		if before != null and ((now is Vector3 and before is Vector3) or (now is Vector2 and before is Vector2)):
			if (now - before).length() > cut:
				return true
		before = now
	return false


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

	return _continue(newest, track.samples[track.samples.size() - 2], render_tick)


## The straight line through [param previous] and [param newest], at [param render_tick]:
## positions only, and none past `max_extrapolation_sec` (held at the newest). What
## [method _extrapolate] draws, counted nowhere, so [method _ease_resume] can ask what an
## extrapolation from two samples would have drawn now.
func _continue(newest: Dictionary, previous: Dictionary, render_tick: float) -> Dictionary:
	var values: Dictionary = newest["values"]
	var ahead_ticks := render_tick - float(newest["tick"])
	var max_ticks := config.max_extrapolation_sec * float(config.tick_rate)
	if ahead_ticks <= 0.0 or ahead_ticks > max_ticks:
		return values.duplicate()

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
func apply(identity: DotNetIdentity, server_tick: float) -> void:
	if identity == null or identity.is_predicted():
		# A predicted entity is driven by prediction, not by interpolation. Writing
		# interpolated state over it would fight the predictor every frame.
		return

	var values := sample(identity.net_id, server_tick)
	if values.is_empty():
		return
	values = _ease_resume(_tracks.get(identity.net_id), values, float(server_tick) - delay_ticks())

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
		# Truncated for the hook, which is a tick number a game may index with; the
		# fraction did its work above, inside the blend.
		if wrote:
			behaviour._net_interpolated(int(server_tick))


## Draws [param values] with what is left of any jump out of an extrapolation added, and
## notes what this frame extrapolated from. Positions (Vector3, Vector2) only.
##
## [b]The jump is measured exactly[/b]: what the extrapolation the last frame drew would draw
## now, less what is drawn now. Between two samples the drawing is continuous on its own
## (a straight line through each pair, meeting at every sample), and into an extrapolation
## it is too (the line goes on); only leaving one, or the newest sample changing under it,
## jumps. Off until a host drives frames ([method advance]), and for a jump the size of a
## teleport.
func _ease_resume(track: Track, values: Dictionary, render_tick: float) -> Dictionary:
	if track == null or _frame_elapsed <= 0.0:
		return values

	var ahead := track.samples.size() >= 2 and render_tick >= float(track.newest_tick())
	var newest: Dictionary = track.samples[track.samples.size() - 1] if ahead else {}

	if not track.ahead_from.is_empty() and (not ahead or newest["tick"] != track.ahead_from[0]["tick"]):
		var was := _continue(track.ahead_from[0], track.ahead_from[1], render_tick)
		for property in values:
			var now: Variant = values[property]
			var then: Variant = was.get(property)
			if (now is Vector3 and then is Vector3) or (now is Vector2 and then is Vector2):
				var jump: Variant = then - now
				var total: Variant = track.offsets.get(property, now * 0.0) + jump
				if total.length() <= RESUME_EASE_MAX:
					track.offsets[property] = total
				else:
					track.offsets.erase(property)

	track.ahead_from.clear()
	if ahead:
		track.ahead_from.append(newest)
		track.ahead_from.append(track.samples[track.samples.size() - 2])

	if track.offsets.is_empty():
		return values

	var keep := exp(-_frame_elapsed / RESUME_EASE_SEC)
	var out := values.duplicate()
	for property in track.offsets.keys():
		var offset: Variant = track.offsets[property] * keep
		if offset.length() < 0.0005 or not out.has(property):
			track.offsets.erase(property)
			continue
		track.offsets[property] = offset
		out[property] = out[property] + offset
	return out


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


## The buffer in snapshots: what [member DotNetConfig.interpolation_buffer] sets and what
## [method _adapt] adjusts.
func delay_snapshots() -> float:
	return _delay_snapshots


## The buffer in TICKS: how far behind its [code]server_tick[/code] [method sample] renders,
## and the number [method DotNetHistory.client_view_tick] wants as its
## [code]interpolation_delay_ticks[/code]. Until the unit was fixed this returned the
## snapshot count under this name, and [method sample] subtracted it as though it were this.
func delay_ticks() -> float:
	return _delay_snapshots * _snapshot_ticks()


func delay_ms() -> float:
	return delay_ticks() / float(maxi(1, config.tick_rate)) * 1000.0


## Ticks between two snapshots, as the server actually sends them.
##
## [method DotNetConfig.ticks_per_snapshot], not tick_rate / snapshot_rate: the manager
## sends every [code]ticks_per_snapshot()[/code] ticks and that is an integer division, so
## at 128 ticks and 20 snapshots it sends every 6 ticks rather than every 6.4, and "two
## snapshots of buffer" should be two of the snapshots that actually arrive.
func _snapshot_ticks() -> float:
	return float(config.ticks_per_snapshot())


## Calls to [method sample] with at least two samples to choose between.
func sample_count() -> int:
	return _samples


## Of those, how many rendered at or past the newest snapshot.
func stall_count() -> int:
	return _stalls


## Of the stalls, how many guessed past the newest snapshot rather than holding it.
func extrapolation_count() -> int:
	return _extrapolations


## Zeroes the counters above, so a probe can measure one window of its own.
func reset_counts() -> void:
	_samples = 0
	_stalls = 0
	_extrapolations = 0


func track_count() -> int:
	return _tracks.size()


func describe() -> Dictionary:
	return {
		"tracks": _tracks.size(),
		"delay_snapshots": "%.2f" % _delay_snapshots,
		"target_snapshots": "%.2f" % _target_snapshots,
		"late_p95_ticks": "%.1f" % _late_ticks(),
		"lost_in_window": _lost.count(true),
		"delay_ticks": "%.2f" % delay_ticks(),
		"delay_ms": int(delay_ms()),
		"arrival_ms": int(_arrival_interval_ms),
		"jitter_ms": int(_arrival_jitter_ms),
		"samples": _samples,
		"stalls": _stalls,
		"extrapolations": _extrapolations,
	}
