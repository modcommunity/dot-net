class_name DotNetClock
extends RefCounted

## Fixed-tick simulation time, and keeping a client's copy aligned with the server's.
##
## [b]Three timelines, not one.[/b] This is the part of netcode most often got wrong,
## so it is worth stating plainly. At any instant a client is dealing with three
## different tick numbers:
##
## [codeblock]
##   render tick        server tick        input tick
##   (behind)           (estimated)        (ahead)
##   ────────────────────────●────────────────────────>
##        ↑ interpolate           ↑ predict
##        snapshots have          commands must arrive
##        already arrived         BEFORE the server needs them
## [/codeblock]
##
## - [b]Input tick[/b] runs [i]ahead[/i] of the server. A command for tick N has to be
##   in the server's hands when the server simulates N, so the client must send it
##   half a round trip early plus a margin. Running level with the server means every
##   command arrives late and is discarded.
## - [b]Render tick[/b] runs [i]behind[/i]. Interpolating between two snapshots
##   requires both to have arrived, so rendering is delayed by roughly the snapshot
##   interval plus jitter. See [DotNetInterpolator].
## - [b]Server tick[/b] is the authority. A client only ever estimates it.
##
## [b]Drift is corrected by changing the length of a tick, not by jumping.[/b]
## Snapping the tick number teleports every predicted object and re-runs inputs that
## already applied. Instead the client's tick duration is scaled by a fraction of a
## percent until the estimate converges — the same trick a media player uses to stay
## in sync without dropping frames.

const CHANNEL := "net.clock"

## Largest correction applied per tick, as a fraction of tick duration.
##
## 5% is imperceptible in motion and closes a 100 ms error in about two seconds at
## 60 Hz. Larger corrections are visible as a speed-up; smaller ones never catch up
## with a drifting clock.
const MAX_DRIFT_RATE := 0.05

## Error beyond which the clock gives up on smoothing and snaps.
##
## A client that was suspended (an alt-tabbed browser tab, a phone that slept) can be
## minutes out, and smoothing that at 5% would take hours. Past this it is not drift,
## it is a different session.
const SNAP_THRESHOLD_TICKS := 60

## Round-trip samples kept for the estimate.
var _rtt_samples: Array[float] = []
const RTT_SAMPLE_COUNT := 16

## Simulation rate in ticks per second.
var tick_rate: int = 60

## Current simulation tick. Authoritative on the server, estimated on a client.
var tick: int = 0

## Whether this clock is the authority.
var is_authority: bool = false

## Extra ticks the input timeline runs ahead, on top of half the round trip.
##
## Absorbs jitter: with a margin of 2 at 60 Hz a command can arrive 33 ms late and
## still be in time. Raising it costs input latency, lowering it costs discarded
## commands. [member adaptive_margin] tunes it from observed jitter.
var input_margin_ticks: int = 2

## Adjust [member input_margin_ticks] from measured jitter.
var adaptive_margin: bool = true

## Fractional time carried between frames.
var _accumulator: float = 0.0

## Scale applied to tick duration while correcting drift. 1.0 is no correction.
var _drift_scale: float = 1.0

## Most recent estimate of the server's tick.
## Estimated tick the server is on, advanced locally and re-anchored on every sample.
##
## [b]It has to advance between samples.[/b] A snapshot arrives twenty times a second and
## frames render far more often; an estimate that only moved when one arrived would make
## [method server_tick] — and therefore [method render_tick], and therefore every
## interpolated position — a step function of arrivals. The interpolator would compute a
## new value only on the frames a packet happened to land on, which is the 20 Hz stepping
## it exists to remove.
var _estimated_server_tick: int = 0

var _rtt_ms: float = 0.0
var _jitter_ms: float = 0.0
var _synced: bool = false

## Whether the clock has ever been anchored with a real round-trip measurement.
##
## The first sample often arrives before anything has measured the link — dot-net does not
## own a transport and cannot measure it itself — so it anchors the timeline as though the
## connection were instant. The *next* sample that does carry a measurement is not drift
## from that; it is a different measurement, and smoothing toward it at
## [constant MAX_DRIFT_RATE] takes seconds during which every input is stamped for a tick
## the server has already passed and is discarded. So it is adopted outright, once.
var _synced_with_rtt: bool = false
var _snap_count: int = 0


func _init(p_tick_rate: int = 60, p_is_authority: bool = false) -> void:
	tick_rate = maxi(1, p_tick_rate)
	is_authority = p_is_authority


## Seconds in one tick.
func tick_duration() -> float:
	return 1.0 / float(tick_rate)


## Advances by a frame's worth of time and returns how many ticks to simulate.
##
## Returns 0 on frames shorter than a tick, and more than 1 when a frame ran long —
## which is why simulation must be in a loop over the return value rather than assuming
## one step per frame.
##
## [param max_ticks] bounds a catch-up burst. Without it, a process that stalled for
## two seconds tries to simulate 120 ticks in one frame, which stalls it further and
## spirals. Dropping time is the lesser evil, and the clock reports it.
func advance(delta: float, max_ticks: int = 8) -> int:
	_accumulator += delta

	# The drift scale stretches or compresses a tick, so a client can run slightly
	# fast or slow without its tick number ever jumping.
	var step := tick_duration() * (_drift_scale if not is_authority else 1.0)

	var steps := 0
	while _accumulator >= step and steps < max_ticks:
		_accumulator -= step
		tick += 1
		steps += 1

	# The estimate walks forward with the local clock and is re-anchored absolutely by
	# every sample. Without this it is whatever the last packet said, and everything
	# rendered from it moves in packet-sized jumps. See the note on the field.
	if not is_authority and _synced:
		_estimated_server_tick += steps

	if _accumulator >= step:
		# Still behind after the cap. Discard the backlog rather than carrying it
		# into the next frame, where it would produce another oversized burst.
		var dropped := int(_accumulator / step)
		_accumulator = fmod(_accumulator, step)

		# Dropped from both timelines. Advancing the input tick past an estimate that
		# stayed put would read as a lead that grew by the length of the stall, and the
		# next sample would correct it as drift rather than as the stall it was.
		if not is_authority and _synced:
			_estimated_server_tick += dropped

		DotLog.debug(
			CHANNEL, "dropped ticks to avoid a catch-up spiral", {"ticks": dropped}
		)

	return steps


## Interpolation factor between the previous tick and the current one, 0..1.
##
## What a renderer multiplies by to draw between two simulation states, so motion is
## smooth at any frame rate above or below the tick rate.
func alpha() -> float:
	return clampf(_accumulator / tick_duration(), 0.0, 1.0)


# --- Client synchronisation ------------------------------------------------

## Feeds a sample from the server: the tick it reported and the round trip.
##
## Called whenever a packet carrying a server tick arrives. The estimate is
## [code]server_tick + half the round trip[/code], because the tick the server sent
## is already one-way-latency old by the time it arrives.
func sync_from_server(server_tick: int, rtt_ms: float) -> void:
	if is_authority:
		return

	_note_rtt(rtt_ms)

	_estimated_server_tick = server_tick + one_way_ticks()

	var target := _estimated_server_tick + _target_lead()
	var error := target - tick

	if not _synced or (not _synced_with_rtt and _rtt_ms > 0.0):
		# Either the first sample, with nothing to smooth toward — or the first one that
		# knows how long the link actually is, which supersedes an anchor that assumed it
		# was instant rather than drifting from it.
		tick = target
		_synced = true
		_synced_with_rtt = _rtt_ms > 0.0
		_drift_scale = 1.0
		DotLog.info(
			CHANNEL,
			"clock synced",
			{"tick": tick, "rtt": int(_rtt_ms), "lead": _target_lead()}
		)
		return

	if absi(error) > SNAP_THRESHOLD_TICKS:
		# Not drift — a suspended process, or a reconnect. Smoothing would take
		# hours, and everything predicted is stale regardless.
		_snap_count += 1
		DotLog.warn(
			CHANNEL,
			"clock snapped; predicted state is stale",
			{"error_ticks": error, "snaps": _snap_count}
		)
		tick = target
		_drift_scale = 1.0
		return

	# Proportional correction, clamped. Positive error means we are behind the
	# target, so ticks must get shorter to catch up.
	var correction := clampf(
		float(error) / float(maxi(1, tick_rate)), -MAX_DRIFT_RATE, MAX_DRIFT_RATE
	)
	_drift_scale = 1.0 - correction


## Ticks a packet spends in flight, one way. Half the measured round trip.
##
## Zero until an RTT sample arrives, which is the correct answer for a loopback and the
## dangerous one everywhere else — see [method sync_from_server].
func one_way_ticks() -> int:
	return int(roundf((_rtt_ms * 0.5) / 1000.0 * float(tick_rate)))


## How far ahead of the estimated server tick the input timeline should run.
##
## [b]The flight time is part of the lead, not just the margin.[/b] A command stamped for
## tick N has to be in the server's hands before it simulates N, and it spends
## [method one_way_ticks] getting there — so a timeline only `input_margin_ticks` ahead
## of where the server *is* produces a command that lands `one_way - margin` ticks after
## its tick has passed. [DotNetInput.Buffer] discards it as late, the server repeats the
## last command it had, and the player moves on their own screen and nowhere else. There
## is no error at either end and the position is corrected back a few times a second, so
## it reads as a broken predictor.
##
## The class documentation on [member input_margin_ticks] always said "on top of half the
## round trip"; this is the half that was missing. Found by dot-a-room, whose loopback is
## the first harness in the family to simulate latency — dot-2d-hungry's delivers
## everything in the same flush and hand-stamps a lead of 2, so it could not see this.
func _target_lead() -> int:
	var margin := input_margin_ticks

	if adaptive_margin:
		# Cover the jitter as well as the mean. A connection whose latency varies by
		# 40 ms needs that much extra margin or a fifth of its commands arrive late.
		var jitter_ticks := int(ceilf(_jitter_ms / 1000.0 * float(tick_rate)))
		margin = maxi(margin, jitter_ticks + 1)

	return one_way_ticks() + margin


func _note_rtt(rtt_ms: float) -> void:
	if rtt_ms <= 0.0:
		return

	_rtt_samples.append(rtt_ms)
	if _rtt_samples.size() > RTT_SAMPLE_COUNT:
		_rtt_samples.pop_front()

	# Median rather than mean: one 2-second stall from a Wi-Fi retransmit would drag
	# a mean far enough to add a hundred ms of input latency for the next minute.
	var sorted := _rtt_samples.duplicate()
	sorted.sort()
	_rtt_ms = sorted[sorted.size() / 2]

	# Jitter as mean absolute deviation from the median — cheaper than a standard
	# deviation and less sensitive to the same outliers.
	var total := 0.0
	for sample in _rtt_samples:
		total += absf(sample - _rtt_ms)
	_jitter_ms = total / float(_rtt_samples.size())


# --- Timeline accessors ----------------------------------------------------

## The tick this client believes the server is simulating right now.
func server_tick() -> int:
	return _estimated_server_tick if not is_authority else tick


## The tick inputs are being generated for. Ahead of the server.
func input_tick() -> int:
	return tick


## The tick to render, given an interpolation delay in ticks. Behind the server.
##
## Never returns a tick ahead of the estimated server tick: rendering ahead means
## interpolating toward a snapshot that has not arrived, which is extrapolation with
## none of the guards.
func render_tick(delay_ticks: int) -> int:
	return mini(server_tick() - delay_ticks, server_tick())


func rtt_ms() -> float:
	return _rtt_ms


func jitter_ms() -> float:
	return _jitter_ms


func is_synced() -> bool:
	return is_authority or _synced


## Ticks of correction currently applied, for diagnostics.
func drift_percent() -> float:
	return (_drift_scale - 1.0) * 100.0


func seconds_to_ticks(seconds: float) -> int:
	return int(roundf(seconds * float(tick_rate)))


func ticks_to_seconds(ticks: int) -> float:
	return float(ticks) / float(tick_rate)


func reset(start_tick: int = 0) -> void:
	tick = start_tick
	_accumulator = 0.0
	_drift_scale = 1.0
	_synced = false
	_synced_with_rtt = false
	_rtt_samples.clear()
	_rtt_ms = 0.0
	_jitter_ms = 0.0


func describe() -> Dictionary:
	return {
		"tick": tick,
		"rate": tick_rate,
		"authority": is_authority,
		"synced": is_synced(),
		"server_tick": server_tick(),
		"lead": _target_lead(),
		"rtt_ms": int(_rtt_ms),
		"jitter_ms": int(_jitter_ms),
		"drift": "%.2f%%" % drift_percent(),
		"snaps": _snap_count,
	}
