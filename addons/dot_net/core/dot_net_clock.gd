class_name DotNetClock
extends "dot_net_clock_state.gd"

## Fixed-tick simulation time, and keeping a client's copy aligned with the server's.
##
## Three timelines: render (behind, interpolates), server (estimated), input (ahead, so commands arrive before the server needs them). Drift is corrected by scaling the tick length, never by jumping; see docs/timelines.md.


func _init(p_tick_rate: int = 60, p_is_authority: bool = false) -> void:
	tick_rate = maxi(1, p_tick_rate)
	is_authority = p_is_authority
	if is_authority:
		_counted_as_server = true
		_servers_in_process += 1


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _counted_as_server:
		_counted_as_server = false
		_servers_in_process -= 1


## Authority clocks alive in this process: a server that runs on this engine's steps.
##
## While one exists no clock follows the engine: a same-process server stalls with the client, so crediting the dropped time would put the client ticks ahead of it.
static var _servers_in_process: int = 0
var _counted_as_server: bool = false


## Whether a server's clock is alive in this process, so this clock does not follow the
## engine's dropped time ([member _servers_in_process]).
static func server_in_process() -> bool:
	return _servers_in_process > 0


## How much wall time of physics steps a client keeps up with, in seconds: [method adopt_tick_rate]
## raises the engine's step cap to cover this at the new rate.
const SLOW_FRAME_SECONDS := 0.25


## Sets the engine's physics rate to [param rate] and lets it run a quarter second of ticks in one frame. Call it where a client adopts the server's tick rate, in place of setting [code]Engine.physics_ticks_per_second[/code] alone.
##
## The engine silently drops time past [code]max_physics_steps_per_frame[/code]; the cap is raised, never lowered. (API 7.)
static func adopt_tick_rate(rate: int) -> void:
	if rate <= 0:
		return
	var steps := ceili(SLOW_FRAME_SECONDS * float(rate))
	var raised := Engine.max_physics_steps_per_frame < steps
	if raised:
		Engine.max_physics_steps_per_frame = steps
	Engine.physics_ticks_per_second = rate
	DotLog.debug(CHANNEL, "adopted a tick rate", {
		"rate": rate, "max_steps": Engine.max_physics_steps_per_frame, "raised": raised,
	})


## Seconds in one tick.
func tick_duration() -> float:
	return 1.0 / float(tick_rate)


## Advances by a frame's worth of time and returns how many ticks to simulate. Loop over the return
## value: 0 on a short frame, more than 1 after a long one.
func advance(delta: float, max_ticks: int = 8) -> int:
	_accumulator += delta

	if not is_authority:
		if Engine.is_in_physics_frame() and Engine.get_physics_frames() != _engine_last_step:
			# One call a physics step: the engine is what drives this clock.
			_engine_last_step = Engine.get_physics_frames()
			_follow_engine()
		elif follow_engine_time:
			# Called outside a physics step, or twice in one: a host driving time by hand.
			# Forget the reference so that stretch is never credited as a stall.
			_engine_frame = -1
		_local_ticks += delta * float(tick_rate)
		_stepped_ticks += delta * float(tick_rate)
		if _lead_live and _synced:
			_steer_lead(delta)

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
		_received_tick += steps

	# A physics frame that ran other than one tick moves what is drawn by the tick it gained
	# or lost, and the slip left from before is taken up by this frame's time. A tick number
	# that jumped (a snap, a catch-up) is a jump whatever is drawn, so not a slip.
	if not is_authority:
		_receive_slip = move_toward(_receive_slip, 0.0, RECEIVE_RECOVERY * float(tick_rate) * delta)
		_slip_recovery = maxf(SLIP_RECOVERY, 2.0 * absf(1.0 / _drift_scale - 1.0))
		_slip = move_toward(_slip, 0.0, _slip_recovery * float(tick_rate) * delta)
		if steps != 1 and absi(steps - 1) <= 1:
			# Within 2, not 1: a second slip often lands while the first is still being taken up,
			# and clamped at 1 the rest was lost. Bounded so a run of slips cannot carry the drawing away.
			_slip = clampf(_slip + float(1 - steps), -MAX_SLIP, MAX_SLIP)

	if _accumulator >= step:
		# Still behind after the cap. Discard the backlog rather than carrying it
		# into the next frame, where it would produce another oversized burst.
		var dropped := int(_accumulator / step)
		_accumulator = fmod(_accumulator, step)

		# Dropped from both timelines. Advancing the input tick past an estimate that
		# stayed put would read as a lead that grew by the length of the stall, and the
		# next sample would correct it as drift rather than as the stall it was.
		if not is_authority and _synced:
			_received_tick += dropped

		DotLog.debug(
			CHANNEL, "dropped ticks to avoid a catch-up spiral", {"ticks": dropped}
		)

	# Every command this frame produced goes out now, so each is measured from where the
	# timeline stands at the end of the frame, less the ticks produced after it.
	if not is_authority:
		for produced in range(tick - steps + 1, tick + 1):
			_note_produced(produced)

	return steps


## The engine's frame counter, wall clock (microseconds), physics steps run (counting the current one), physics rate and step cap, at a frame's first physics step.
##
## Wall time no step covers, beyond [constant DROP_MARGIN_STEPS], is time the engine DROPPED; local time and both timelines move on by it ([method _credit_dropped]). A frame that drops runs exactly its cap, so the gap less a whole cap is dropped for certain, before the frame's commands are stamped.
func note_engine_frame(frame: int, wall_usec: int, physics_frames: int, physics_rate: int,
		max_steps: int = 8) -> void:
	if is_authority or frame == _engine_frame:
		return
	_last_wall_usec = wall_usec
	# Steps that ran before this frame: the engine counts the step running now.
	var before := physics_frames - 1
	if _engine_frame < 0 or physics_rate != _engine_rate or physics_rate <= 0:
		# The first frame, or the engine's rate changed (a client adopting the server's): a new
		# reference, nothing to compare against.
		_engine_frame = frame
		_engine_rate = physics_rate
		_engine_wall0 = wall_usec
		_engine_physics0 = -1
		_engine_prev_wall = wall_usec
		_engine_credited = 0.0
		return
	_engine_frame = frame
	if _engine_physics0 < 0:
		# The reference frame's own steps are not counted: they cover the time up to the reference,
		# and counting them put the engine ahead of the wall for good.
		_engine_physics0 = before
	var settled := float(_engine_prev_wall - _engine_wall0) / 1000000.0 \
		- float(before - _engine_physics0) / float(physics_rate)
	# The commands of the last two frames may have gone out after whatever stalled the previous
	# one: a host flushes a frame's packets at its end, or at the next frame's poll.
	var sent_after := _engine_frame_ticks[0]
	_engine_frame_ticks = [_engine_frame_ticks[1], tick]
	_note_stall(wall_usec, float(wall_usec - _engine_prev_wall) / 1000000.0)
	_credit_dropped(maxf(settled, _uncovered(wall_usec, before, physics_rate, max_steps)))
	_discount_long_frame(wall_usec, float(wall_usec - _engine_prev_wall) / 1000000.0, sent_after)
	_engine_prev_wall = wall_usec


## The same, at any moment outside a physics step. [method sync_from_server] calls it before it reads a snapshot, so a stall seen first in the receive phase is credited once, not again at the next step.
func note_engine_time(wall_usec: int, physics_frames: int, physics_rate: int,
		max_steps: int = 8) -> void:
	if is_authority or _engine_frame < 0 or _engine_physics0 < 0 or physics_rate != _engine_rate:
		return
	_last_wall_usec = wall_usec
	# This frame's commands go out at its end, after this, and the previous frame's may have
	# waited for this frame's poll.
	_credit_dropped(_uncovered(wall_usec, physics_frames, physics_rate, max_steps))


## Hands the engine's numbers to [method note_engine_frame] inside a physics step, or [method note_engine_time] outside one, while [member follow_engine_time] is set.
func _follow_engine() -> void:
	if not follow_engine_time or is_authority or Engine.time_scale != 1.0:
		return
	if _servers_in_process > 0:
		# The server beside this client stalled with it ([member _servers_in_process]).
		_engine_frame = -1
		return
	if _engine_last_step < 0 or Engine.get_physics_frames() - _engine_last_step > 1:
		# Only while the engine's steps advance this clock. A harness that sets `tick` itself looks
		# like a stall by the wall clock. Counted in steps, not frames: a frame may have none.
		return
	if Engine.is_in_physics_frame():
		note_engine_frame(Engine.get_process_frames(), Time.get_ticks_usec(),
			Engine.get_physics_frames(), Engine.physics_ticks_per_second,
			Engine.max_physics_steps_per_frame)
	else:
		note_engine_time(Time.get_ticks_usec(), Engine.get_physics_frames(),
			Engine.physics_ticks_per_second, Engine.max_physics_steps_per_frame)


## Seconds of wall time since the reference that [param ran] steps (all the steps before the
## next frame begins) and a whole cap more cannot cover: dropped for certain.
func _uncovered(wall_usec: int, ran: int, physics_rate: int, max_steps: int) -> float:
	return float(wall_usec - _engine_wall0) / 1000000.0 \
		- float(ran - _engine_physics0 + maxi(1, max_steps)) / float(physics_rate)


## Credits what of [param gap] (seconds the engine's steps left uncovered since the reference) is
## past the margin and not credited already. What it does to the commands sent after it is
## [method _discount_long_frame]'s.
func _credit_dropped(gap: float) -> void:
	var lost := gap - _engine_credited - float(DROP_MARGIN_STEPS) / float(_engine_rate)
	if lost <= 0.0:
		return
	_engine_credited += lost
	_note_stall(_last_wall_usec, lost)
	_lost_seconds += lost
	_lost_count += 1
	# The steps that would have carried local time and both timelines never ran. The tick moves
	# here because nothing steers it before the first report; the receive timeline moves so the
	# lead cap does not sit the whole stall back.
	var ticks := lost * float(tick_rate)
	_local_ticks += ticks
	if _synced:
		var whole := floorf(ticks)
		tick += int(whole)
		_received_tick += int(whole)
		_accumulator += (ticks - whole) * tick_duration() * _drift_scale
		# A window of late samples opened before a stall says nothing about the timeline after
		# it: one that spanned the credit read as samples keeping pace with local time a second
		# behind, and anchored the timeline back to the backlog (game-g2gfast at 60).
		if lost > LEAD_SMOOTH_SECONDS:
			_settle_open = false
	if ticks >= 1.0:
		DotLog.debug(CHANNEL, "the engine dropped time; local time follows the wall clock",
			{"seconds": snappedf(lost, 0.001), "ticks": snappedf(ticks, 0.1),
			"tick": tick, "received": _received_tick, "synced": _synced})


## A frame with a physics step just ended at [param wall_usec], [param seconds] after it began; commands produced after [param sent_after] may have waited all of it to be sent.
##
## A frame longer than any in the last [constant LEAD_WINDOW_SECONDS] is not lead to keep: those commands' leads are moved back by the excess, so the wait that recurs stays in and a one-off stall does not.
func _discount_long_frame(wall_usec: int, seconds: float, sent_after: int) -> void:
	var now := float(wall_usec) / 1000000.0
	# The frames that ended in the window before this one began: this one is not its own measure.
	var oldest := now - seconds - LEAD_WINDOW_SECONDS
	while not _frame_waits.is_empty() and _frame_waits[0].x < oldest:
		_frame_waits.pop_front()
	# The second longest: one frame is not a wait that recurs, two are. The longest let a
	# three-second stall make the two-second one after it a second later look like the frames
	# to expect, and its commands asked for two seconds of lead (game-g2gfast's first visit).
	var longest := 0.0
	var second := 0.0
	for wait in _frame_waits:
		if wait.y > longest:
			second = longest
			longest = wait.y
		elif wait.y > second:
			second = wait.y
	_frame_waits.append(Vector2(now, seconds))
	longest = second
	var excess := (seconds - longest) * float(tick_rate)
	if excess <= 0.0 or longest <= 0.0 or _lead_tick.is_empty():
		# The first frame measured has nothing to say what recurs.
		return
	# Every slot, not the last LEAD_HISTORY ticks: a credited stall of more than that (4 s at 128)
	# moved `tick` past the held commands, which then kept a lead of the whole stall and the
	# clock jumped a stall ahead.
	for slot in LEAD_HISTORY:
		var t := _lead_tick[slot]
		if t > sent_after and t <= tick:
			_lead_at[slot] -= excess


## Seconds of wall time the engine dropped that [method note_engine_frame] and [method
## note_engine_time] credited, and how many times they found any.
func lost_seconds() -> float:
	return _lost_seconds


func lost_count() -> int:
	return _lost_count


## Times the input timeline was found behind the absolute floor ([method sync_from_server])
## and jumped, while the reports steered it.
func floor_count() -> int:
	return _floor_count


## Interpolation factor between the previous tick and the current one, 0..1.
##
## Not what a renderer wants: it only changes inside [method advance], so it is constant across frames drawn within one physics step. Use [method render_alpha] or the engine's physics fraction.
func alpha() -> float:
	return clampf(_accumulator / tick_duration(), 0.0, 1.0)


## What to add to [method received_tick] for anything DRAWN on the receive timeline, in ticks: the re-anchoring it has not followed yet, taken up at [constant RECEIVE_RECOVERY].
##
## The timeline moves in whole ticks; drawn as it is, remote entities would jump a tick. Only what is drawn follows gently.
func receive_slip(physics_fraction: float = -1.0, physics_delta: float = -1.0) -> float:
	if _receive_slip == 0.0:
		return 0.0
	if physics_fraction < 0.0:
		physics_fraction = Engine.get_physics_interpolation_fraction()
	if physics_delta <= 0.0:
		physics_delta = 1.0 / float(maxi(1, Engine.physics_ticks_per_second))
	return move_toward(_receive_slip, 0.0,
		RECEIVE_RECOVERY * float(tick_rate) * clampf(physics_fraction, 0.0, 1.0) * physics_delta)


## How far through the newest tick's step a frame drawn NOW is, in ticks: the engine's physics fraction ([param physics_fraction] of a [param physics_delta]-second frame, both read when negative) plus what is left of the last slip. Usually 0..1; -1 to 2 while a slip is taken up.
##
## A slip is a physics frame that ran no tick, or two (drift stretches ticks). Drawn at the engine's fraction alone the eye would step back or double; a slip moves this by the tick gained or lost and [constant SLIP_RECOVERY] takes it back. Not a fraction of the clock's accumulator: that extrapolates through landings and walls.
func render_alpha(physics_fraction: float = -1.0, physics_delta: float = -1.0) -> float:
	if physics_fraction < 0.0:
		physics_fraction = Engine.get_physics_interpolation_fraction()
	var frac := clampf(physics_fraction, 0.0, 1.0)
	if _slip == 0.0:
		return frac
	# Taken up within the frame as well as across frames, so the drawing is continuous at
	# every physics frame and not just on average.
	if physics_delta <= 0.0:
		physics_delta = 1.0 / float(maxi(1, Engine.physics_ticks_per_second))
	# Clamped to -1..2: never more than a tick before the frame's first tick, nor a tick past
	# the extrapolation a renderer already allows past 1.
	return clampf(frac + move_toward(_slip, 0.0, _slip_recovery * float(tick_rate) * frac * physics_delta),
		-1.0, 2.0)


## Feeds a sample from the server: the tick it reported and the round trip.
##
## The estimate is [code]server_tick + half the round trip[/code]: the tick is one-way-latency old on arrival.
func sync_from_server(server_tick: int, rtt_ms: float) -> void:
	if is_authority:
		return

	# Before the snapshot is read: see [method note_engine_time].
	_follow_engine()

	_note_rtt(rtt_ms)

	var first := not _synced or (not _synced_with_rtt and _rtt_ms > 0.0)
	_follow_arrival(server_tick, first)
	if DotLog.enabled(DotLog.Level.TRACE, CHANNEL):
		var traced := _state_fields()
		traced["server_tick"] = server_tick
		traced["rtt_in"] = snappedf(rtt_ms, 0.1)
		DotLog.trace(CHANNEL, "snapshot sampled", traced)

	if _lead_live and not first:
		_follow_reported_lead()
		return

	var target := server_tick() + _target_lead()
	var error := target - tick

	if first:
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

	if absi(error) > snap_threshold_ticks():
		# Not drift — a suspended process, or a reconnect. Smoothing would take
		# hours, and everything predicted is stale regardless.
		_snap_count += 1
		var snap_fields := _state_fields()
		snap_fields["error_ticks"] = error
		snap_fields["snaps"] = _snap_count
		DotLog.warn(CHANNEL, "clock snapped; predicted state is stale", snap_fields)
		tick = target
		_drift_scale = 1.0
		return

	if error > catch_up_threshold_ticks():
		# Behind by more than the margin is not drift to smooth. Every command would be stamped for a tick
		# the server already simulated and discarded as late; smoothing at [constant MAX_DRIFT_RATE] would
		# take seconds.
		_catch_up_count += 1
		DotLog.debug(
			CHANNEL,
			"clock caught up; it had fallen behind the server",
			{"behind_ticks": error, "catch_ups": _catch_up_count}
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


## [method sync_from_server]'s step once the server reports the input lead: steers the
## receive timeline and snaps or floors the clock, never the whole smoothing path.
func _follow_reported_lead() -> void:
	# The input timeline is the server's report's to steer ([method _steer_lead]). The round trip still
	# places the receive timeline and has a say in a snap.
	var round_trip := server_tick() + _target_lead()
	if tick <= _received_tick:
		var to := maxi(_received_tick + 1 + input_margin_ticks, int(ceilf(_lead_position())))
		_floor_count += 1
		_catch_up_count += 1
		DotLog.debug(CHANNEL, "clock caught up; it was behind the server",
			{"behind_ticks": to - tick, "floors": _floor_count})
		tick = to
		_drift_scale = 1.0
		return
	# A different session still snaps, when the round trip agrees on which way: the reported
	# lead alone can be a stall stale, and snapping back to it undid the floor above on every
	# snapshot.
	var behind := int(roundf(_lead_position())) - tick
	var snap := snap_threshold_ticks()
	if (behind > snap and round_trip - tick > snap) or (behind < -snap and round_trip - tick < -snap):
		_snap_count += 1
		var fields := _state_fields()
		fields["error_ticks"] = behind
		fields["snaps"] = _snap_count
		fields["round_trip_error"] = round_trip - tick
		DotLog.warn(CHANNEL, "clock snapped; predicted state is stale", fields)
		tick += behind
		_drift_scale = 1.0


## The numbers a clock decision was made from, for a log line: what a snap or a lead report is
## read against.
func _state_fields() -> Dictionary:
	return {
		"tick": tick, "received": _received_tick, "local": snappedf(_local_ticks, 0.1),
		"rtt": snappedf(_rtt_ms, 0.1), "jitter": snappedf(_jitter_ms, 0.1),
		"one_way": one_way_ticks(), "target_lead": _target_lead(),
		"reported": snappedf(_lead_target, 0.1), "live": _lead_live,
	}


## Moves the receive timeline for one snapshot that arrived carrying [param sampled]. See
## [member _received_tick] for why it is not simply set.
func _follow_arrival(sampled: int, anchor: bool) -> void:
	var ahead := sampled - _received_tick

	if anchor or ahead > snap_threshold_ticks():
		# The first sample, or a different session: nothing to filter against.
		_received_tick = sampled
		_receive_slip = 0.0
		_settle_open = false
		return

	if ahead >= 0:
		# As quick as any packet has come: the server is at least this far along.
		_received_tick = sampled
		_receive_slip -= float(ahead)
		_settle_open = false
		return

	# Behind the timeline: a late packet, or the path got slower. One window of them all
	# behind is the second, and the timeline goes back one tick at a time.
	if not _settle_open:
		_settle_open = true
		_settle_count = 0
		_settle_first_sample = sampled
		_settle_first_local = _local_ticks
	elif _stepped_ticks == _settle_local:
		# One a frame: a burst read in one frame is one arrival time, or the snapshots a stall
		# held up would count as several windows of a slower path.
		return
	_settle_local = _stepped_ticks

	_settle_count += 1

	if _settle_count >= SETTLE_SAMPLES:
		_settle_open = false
		if ahead < -snap_threshold_ticks():
			# More than a second behind for a whole window of frames. Never on one sample, and never while the samples gain on local time: a backlog draining after a credited stall would drag the timeline back the whole stall. Samples keeping pace with local time are a different session, and anchor.
			if float(sampled - _settle_first_sample) <= _local_ticks - _settle_first_local + 2.0:
				_received_tick = sampled
				_receive_slip = 0.0
			return
		_received_tick -= 1
		_receive_slip += 1.0


## What the server said about this client's commands: the one for [param input_tick] was the latest to arrive in the last period, [param arrival_lead] ticks before the server needed it (0 just in time, below 0 late). Called by [method DotNetManager.receive_snapshot].
##
## Measured against the time the command was sent ([member _lead_at]), less what it arrived with, plus [member lead_slack_ticks]: that already counts every correction since, so a report a round trip old never corrects twice. The downlink is not in it.
func note_input_lead(input_tick: int, arrival_lead: int) -> void:
	if is_authority or not _synced or _lead_tick.is_empty():
		return
	var slot := posmod(input_tick, LEAD_HISTORY)
	if _lead_tick[slot] != input_tick:
		# Not a tick this clock produced, or one long gone: nothing to measure it against.
		return

	var needed := _lead_at[slot] - float(arrival_lead) + float(lead_slack_ticks)
	_lead_samples.append(Vector2(_local_ticks, needed))
	_lead_reports += 1
	_last_arrival_lead = arrival_lead
	if arrival_lead < 0:
		_lead_late_reports += 1
	_trim_lead_samples()

	if not _lead_live:
		_lead_live = true
		_receive_excess = 0.0
		var live_fields := _state_fields()
		live_fields["lead"] = tick - server_tick()
		live_fields["arrival_lead"] = arrival_lead
		DotLog.info(CHANNEL, "input lead follows the server's reports", live_fields)


## Ticks the input timeline is behind (+) or ahead (-) of where it is being steered: the
## reported lead once there is one ([method is_lead_reported]), the round trip's before. What
## a suite asks to see the clock settle.
func lead_error() -> float:
	if _lead_live:
		return _lead_position() - (float(tick) + _accumulator / tick_duration())
	return float(server_tick() + _target_lead() - tick)


## Whether the input timeline is steered by the server's reports ([method note_input_lead])
## rather than by the round trip.
func is_lead_reported() -> bool:
	return _lead_live


## The lead the input timeline is steered to, in ticks ahead of local time: the most needed
## by any report in the last [constant LEAD_WINDOW_SECONDS]. 0 before the first report.
func reported_lead() -> float:
	return _lead_target


## Reports taken, and how many said a command had come late.
func lead_reports() -> int:
	return _lead_reports


func late_lead_reports() -> int:
	return _lead_late_reports


func _trim_lead_samples() -> void:
	var oldest := _local_ticks - LEAD_WINDOW_SECONDS * float(tick_rate)
	while not _lead_samples.is_empty() and _lead_samples[0].x < oldest:
		_lead_samples.pop_front()
	if _lead_samples.is_empty():
		# Nothing reported for a whole window (a server that went quiet): hold the last.
		return
	var most := _lead_samples[0].y
	for sample in _lead_samples:
		most = maxf(most, sample.y)
	_lead_target = most


## Where the input timeline is steered to: local time plus the reported lead, but never past
## [constant LEAD_CAP_TICKS] beyond a second flight time over the round trip's own lead.
func _lead_position() -> float:
	var reported := _local_ticks + _lead_target
	var cap := float(server_tick() + _target_lead() + one_way_ticks() + LEAD_CAP_TICKS)
	return minf(reported, cap)


## Remembers how far ahead of local time [param produced] was sent, at the end of the frame
## that produced it: what a report about it is measured against.
func _note_produced(produced: int) -> void:
	if _lead_tick.is_empty():
		_lead_tick.resize(LEAD_HISTORY)
		_lead_tick.fill(-1)
		_lead_at.resize(LEAD_HISTORY)
	var slot := posmod(produced, LEAD_HISTORY)
	_lead_tick[slot] = produced
	# In the units [method _steer_lead] steers: the timeline's continuous position ahead of local
	# time. The tick alone is up to a tick behind and settled short of the slack.
	_lead_at[slot] = float(produced) + _accumulator / tick_duration() - _local_ticks


## Steers the input timeline to the reported lead, once a frame: shorter ticks while short of it (up to [constant LEAD_RAISE_RATE]), longer while past it (up to [constant MAX_DRIFT_RATE]), a jump forward for a deficit too big to gain in [constant LEAD_SMOOTH_SECONDS].
##
## The receive timeline is held to real time meanwhile, or it would run ahead of the snapshots; the drift is taken back through [member _receive_slip].
func _steer_lead(delta: float) -> void:
	_trim_lead_samples()
	var at := float(tick) + _accumulator / tick_duration()
	var error := _lead_position() - at

	if error > LEAD_RAISE_RATE * LEAD_SMOOTH_SECONDS * float(tick_rate):
		var jump := int(ceilf(error))
		_catch_up_count += 1
		DotLog.debug(CHANNEL, "clock caught up to the reported lead",
			{"behind_ticks": jump, "catch_ups": _catch_up_count})
		tick += jump
		_drift_scale = 1.0
		return

	var correction := clampf(error * LEAD_GAIN, -_slowest(), LEAD_RAISE_RATE)
	_drift_scale = 1.0 - correction

	# Ticks this frame will run beyond real time: delta / (duration * scale) of them against
	# delta / duration.
	_receive_excess += delta * float(tick_rate) * (1.0 / _drift_scale - 1.0)
	while _receive_excess >= 1.0:
		_receive_excess -= 1.0
		_received_tick -= 1
		_receive_slip += 1.0
	while _receive_excess <= -1.0:
		_receive_excess += 1.0
		_received_tick += 1
		_receive_slip -= 1.0


## The most a tick is lengthened to give lead back: [constant MAX_DRIFT_RATE], or [constant LEAD_RAISE_RATE] while the latest report says its command arrived more than [constant LEAD_EARLY_TICKS] past the slack early.
##
## The drift rate alone is too slow to give back a large lead; a command that arrived that early says the lead really is too large.
func _slowest() -> float:
	if _last_arrival_lead - lead_slack_ticks <= LEAD_EARLY_TICKS:
		return MAX_DRIFT_RATE
	return LEAD_RAISE_RATE


## How far behind its target the input timeline may fall before it jumps forward, in ticks.
##
## Within it a command still lands before its tick; past it every tick of smoothing is a command the server throws away. See [method sync_from_server].
func catch_up_threshold_ticks() -> int:
	return maxi(1, _target_lead() - one_way_ticks())


## [constant SNAP_THRESHOLD_SECONDS] in ticks, at this clock's rate.
##
## At least one tick, so an absurdly low rate still snaps on a different session.
func snap_threshold_ticks() -> int:
	return maxi(1, int(roundf(SNAP_THRESHOLD_SECONDS * float(tick_rate))))


## Ticks a packet spends in flight, one way. Half the measured round trip.
##
## Zero until an RTT sample arrives: right on loopback, dangerous elsewhere. See [method sync_from_server].
func one_way_ticks() -> int:
	return int(roundf((_rtt_ms * 0.5) / 1000.0 * float(tick_rate)))


## How far ahead of the estimated server tick the input timeline should run.
##
## The flight time is part of the lead, not just the margin ([method one_way_ticks]): a timeline only [member input_margin_ticks] ahead produces commands that land after their tick, are discarded as late, and read as a broken predictor.
func _target_lead() -> int:
	var margin := input_margin_ticks

	if adaptive_margin:
		# Cover the jitter as well as the mean. A connection whose latency varies by
		# 40 ms needs that much extra margin or a fifth of its commands arrive late.
		var jitter_ticks := int(ceilf(_jitter_ms / 1000.0 * float(tick_rate)))
		margin = maxi(margin, jitter_ticks + 1)

	return one_way_ticks() + margin


## Remembers a frame or a dropped stretch of [param seconds] ending at [param wall_usec], when it
## is long enough for a round trip measured across it to be wrong ([method _across_stall]).
func _note_stall(wall_usec: int, seconds: float) -> void:
	if seconds < RTT_STALL_SECONDS:
		return
	_stalls.append(Vector2(float(wall_usec) / 1000000.0, seconds))
	if _stalls.size() > RTT_STALL_MEMORY:
		_stalls.pop_front()


## Whether a round trip of [param rtt_ms] that ended now spans a stall that explains how far it
## is past the median: the time a ping waited for this process to read its answer is not the
## link's ([method _note_rtt] holds it near the median). Without a wall clock to compare (nothing handed to [method note_engine_frame]) never.
func _across_stall(rtt_ms: float) -> bool:
	# No untouched sample yet: nothing to hold near, and holding would pin every sample at 250 ms.
	if _last_wall_usec <= 0 or _stalls.is_empty() or _rtt_base <= 0.0:
		return false
	var excess := (rtt_ms - _rtt_base) / 1000.0
	if excess <= RTT_STALL_SECONDS:
		return false
	var now := float(_last_wall_usec) / 1000000.0
	var from := now - rtt_ms / 1000.0 - 1.0
	for stall in _stalls:
		if stall.x >= from and stall.y >= 0.5 * excess:
			return true
	return false


## Round trip samples held down because a stall explains them.
func rtt_rejected() -> int:
	return _rtt_rejected


func _note_rtt(rtt_ms: float) -> void:
	if rtt_ms <= 0.0:
		return

	var held_down := _across_stall(rtt_ms)
	if not held_down:
		_hold_since_usec = 0
	elif _hold_since_usec == 0:
		_hold_since_usec = _last_wall_usec
	elif float(_last_wall_usec - _hold_since_usec) / 1000000.0 > RTT_HOLD_SECONDS:
		held_down = false
	if held_down:
		# Held to a quarter second past the median rather than dropped: the frames a stall
		# leaves behind do delay a command, and the spread it adds to the margin covers them.
		_rtt_rejected += 1
		var held := _rtt_base + RTT_STALL_SECONDS * 1000.0
		DotLog.debug(CHANNEL, "round trip held; a stall explains it",
			{"rtt": snappedf(rtt_ms, 0.1), "held": snappedf(held, 0.1), "base": snappedf(_rtt_base, 0.1),
			"held_count": _rtt_rejected})
		rtt_ms = held

	_rtt_samples.append(rtt_ms)
	if _rtt_samples.size() > RTT_SAMPLE_COUNT:
		_rtt_samples.pop_front()
	var untouched := not held_down

	# Median rather than mean: one 2-second stall from a Wi-Fi retransmit would drag
	# a mean far enough to add a hundred ms of input latency for the next minute.
	var sorted := _rtt_samples.duplicate()
	sorted.sort()
	_rtt_ms = sorted[sorted.size() / 2]
	if untouched:
		_rtt_base = _rtt_ms

	# Jitter as mean absolute deviation from the median — cheaper than a standard
	# deviation and less sensitive to the same outliers.
	var total := 0.0
	for sample in _rtt_samples:
		total += absf(sample - _rtt_ms)
	_jitter_ms = total / float(_rtt_samples.size())


## The tick this client believes the server is simulating right now: the receive
## timeline plus the flight time.
func server_tick() -> int:
	return _received_tick + one_way_ticks() if not is_authority else tick


## The newest snapshot tick this client expects to hold now, as the quickest recent arrivals place it.
##
## What the render timeline is measured back from: the newest that has ARRIVED, not the one the server is building. See [member _received_tick].
func received_tick() -> int:
	return _received_tick if not is_authority else tick


## The tick inputs are being generated for. Ahead of the server.
func input_tick() -> int:
	return tick


## The tick to render, given an interpolation delay in ticks: that far behind the newest snapshot held ([method received_tick]), not behind the server's tick.
##
## Counting from the server's tick spends the flight time waiting for a snapshot in flight, so most frames extrapolate. Never ahead of the receive timeline.
func render_tick(delay_ticks: int) -> int:
	return mini(received_tick() - delay_ticks, received_tick())


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
	_slip = 0.0
	_slip_recovery = SLIP_RECOVERY
	_receive_slip = 0.0
	_synced = false
	_synced_with_rtt = false
	_rtt_samples.clear()
	_rtt_ms = 0.0
	_jitter_ms = 0.0
	_received_tick = 0
	_settle_open = false
	_local_ticks = 0.0
	_lead_tick.clear()
	_lead_at.clear()
	_lead_samples.clear()
	_lead_target = 0.0
	_lead_live = false
	_receive_excess = 0.0
	_engine_frame = -1
	_engine_last_step = -1
	_engine_credited = 0.0
	_engine_frame_ticks = [0, 0]
	_frame_waits.clear()
	_settle_local = -1.0
	_stepped_ticks = 0.0


func describe() -> Dictionary:
	return {
		"tick": tick,
		"rate": tick_rate,
		"authority": is_authority,
		"synced": is_synced(),
		"server_tick": server_tick(),
		"received_tick": received_tick(),
		"lead": _target_lead(),
		"rtt_ms": int(_rtt_ms),
		"jitter_ms": int(_jitter_ms),
		"drift": "%.2f%%" % drift_percent(),
		"snaps": _snap_count,
		"rtt_held": _rtt_rejected,
		"catch_ups": _catch_up_count,
		"lead_reported": _lead_live,
		"last_arrival_lead": _last_arrival_lead,
		"lead_reports": _lead_reports,
		"late_reports": _lead_late_reports,
		"floors": _floor_count,
		"lost_ms": int(_lost_seconds * 1000.0),
	}


## One line on where the input lead comes from, for a `net_status`.
func describe_lead() -> String:
	if _lead_live:
		return "%d ticks, from the server's reports: the last said %d early (%d reports, %d late)" % [
			tick - server_tick(), _last_arrival_lead, _lead_reports, _lead_late_reports]
	return "%d ticks, from the round trip (the server does not report it)" % _target_lead()

