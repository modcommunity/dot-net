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

## Error beyond which the clock gives up on smoothing and snaps, in SECONDS.
##
## A client that was suspended (an alt-tabbed browser tab, a phone that slept) can be
## minutes out, and smoothing that at 5% would take hours. Past this it is not drift,
## it is a different session.
##
## [b]In seconds because it is a duration, and it was a tick count.[/b] The reasoning has
## always been about time -- "suspended", "a different session" -- but the number was 60
## ticks, which is one second only on a server running the default rate. A 128-tick
## server snapped at 0.47 s, and a map change or a stalled frame is comfortably that
## long: g2gfast logged `error_ticks=62` and `error_ticks=64` on a browser client, both
## of them a half-second hitch that a one-second threshold would have SMOOTHED and this
## one threw a whole predicted state away for.
##
## That is the difference a player feels. Drift correction is invisible by design; a snap
## discards everything predicted, so the world jumps -- and it jumped on the one game
## here that runs 128, which is the rate the genre runs and the rate this was never
## tried at.
const SNAP_THRESHOLD_SECONDS := 1.0

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

## Ticks the drawing is behind (+) or ahead (-) of where one tick per physics frame would put
## it, after physics frames that ran no tick or two. See [method render_alpha].
var _slip: float = 0.0

## Ticks the receive timeline moved by re-anchoring (not by advancing) that the drawing has
## not followed yet, negative when it moved forward. See [method receive_slip].
var _receive_slip: float = 0.0

## How fast the drawing follows a re-anchored receive timeline: ticks of slip taken up per
## tick of time. 0.2 is the interpolation buffer's own [code]GROW_RATE[/code]: everything
## remote runs at 80% or 120% speed for a moment instead of jumping.
const RECEIVE_RECOVERY := 0.2

## How fast a slip is taken up, in ticks per tick of time: twice the most slips drift can
## make ([constant MAX_DRIFT_RATE]), so they never pile up, and little enough to read as a
## slight change of speed: the drawing runs a tenth slow or fast for ten ticks, not a tick
## at once.
const SLIP_RECOVERY := 0.1

## How fast slips are taken up now: [constant SLIP_RECOVERY], or twice what the drift makes
## while it is faster than [constant MAX_DRIFT_RATE] (raising a reported lead, up to
## [constant LEAD_RAISE_RATE]). Slower than the drift makes them, they pile up to the clamp
## and the tick past it is drawn as a jump: game-arena's `headless_feel` caught one, 3-5 cm in
## one frame, at 20% loss while the clock ran 8% fast.
var _slip_recovery: float = SLIP_RECOVERY

## The newest snapshot tick, as the quickest recent arrivals place it, advanced locally:
## the RECEIVE timeline. [method server_tick] is this plus the flight time; the render
## timeline is this less the interpolation delay.
##
## [b]It has to advance between samples.[/b] A snapshot arrives twenty times a second and
## frames render far more often; an estimate that only moved when one arrived would make
## [method server_tick] — and therefore [method render_tick], and therefore every
## interpolated position — a step function of arrivals. The interpolator would compute a
## new value only on the frames a packet happened to land on, which is the 20 Hz stepping
## it exists to remove.
##
## [b]And it follows the quickest arrivals, not every one.[/b] It was re-anchored to
## [code]sample + one_way[/code] on every snapshot, which is right on a link that delivers
## every packet in the same time and nowhere else: a packet held up 25 ms put the whole
## timeline back 25 ms, and the next one on time put it forward again. Measured through a
## real UDP relay with 30..80 ms each way (game-arena's `headless_lossy`): the render
## timeline went BACKWARDS 35 to 48 times in ten seconds, by up to 3-4 ticks, and lurched
## by up to 5 -- a remote player drawn half a metre back and then forward, with every
## position it was asked for correct, so nothing that compared positions could see it.
## Now a sample later than the timeline moves it forward at once (that packet came as
## quickly as packets can, so the server is at least there), a sample behind it moves
## it nothing, and a whole [constant SETTLE_SAMPLES] of samples behind it takes it back
## by a single tick -- the path really did get slower. Late packets are the interpolation
## buffer's to absorb, which is what it measures and is sized for.
var _received_tick: int = 0

## Samples in a window of arrivals all behind the receive timeline. The step back is one
## tick whatever the window saw: stepping by how far behind they were would bring back the
## render timeline jumping backwards that this replaced. See [member _received_tick].
const SETTLE_SAMPLES := 16
var _settle_count: int = 0
var _settle_open: bool = false
## [member _stepped_ticks] at the last sample counted into the window: one a frame.
var _settle_local: float = -1.0
## Local time as [method advance] has been handed it, without the drops credited: what changes
## from one frame to the next, and not within one.
var _stepped_ticks: float = 0.0
## The window's first sample and local time then: whether a window far behind keeps pace.
var _settle_first_sample: int = 0
var _settle_first_local: float = 0.0

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
var _catch_up_count: int = 0

# --- The input lead the server reports ---------------------------------------
#
# Once the server says how early this client's commands reach it ([method note_input_lead]),
# the input timeline is steered by that, not by the round trip. See
# docs/timelines.md#the-input-lead-the-server-reports.

## How early (ticks) a command should reach the server, at the worst arrival of the last
## [constant LEAD_WINDOW_SECONDS]. [code]DotNetConfig.input_lead_slack_ticks[/code].
var lead_slack_ticks: int = 2

## Seconds of reports the lead is held at the most of. Long enough to see a link's jitter
## many times over (32 reports at 32 snapshots a second); short enough that a link which got
## quicker gives the latency back within a couple of seconds (the window, then slowing at
## [constant MAX_DRIFT_RATE]).
const LEAD_WINDOW_SECONDS := 1.0

## The most a tick is shortened to raise the lead, as a fraction of its length: 12% faster
## for a moment. A latency rise is a few ticks, so it is gained in a fraction of a second, and
## the drawing (which [method render_alpha] keeps continuous through the extra ticks) runs an
## eighth fast instead of jumping. Slowing stays at [constant MAX_DRIFT_RATE]: a lead that is
## too large costs latency, not commands.
const LEAD_RAISE_RATE := 0.12

## Fraction of the lead's error corrected per tick (a time constant of ten ticks), capped at
## the rates above.
const LEAD_GAIN := 0.1

## A deficit bigger than [constant LEAD_RAISE_RATE] can gain in this long jumps instead
## ([member _catch_up_count]): a stall, not a link getting slower, and every tick of smoothing
## it would be a command the server throws away. About 60 ms of lead at any tick rate.
const LEAD_SMOOTH_SECONDS := 0.5

## The most a report may put the input timeline past where the round trip would: the lead
## from the round trip, another flight time, and this many ticks. A sanity bound, not a
## setting: measured leads sit below the round trip's (game-arena at 40 ms each way: 4-5
## ticks against 8). It stops a clock from running away from reports about commands it did
## not stamp: a host (a test, so far) that stamps its own lead instead of [method input_tick]
## sees each report ask one tick more than the clock has, forever.
const LEAD_CAP_TICKS := 4

## Input ticks whose lead is remembered: far more than a round trip's worth at any rate.
const LEAD_HISTORY := 512

## Local time, in ticks at this clock's nominal rate: what [method advance] has been handed,
## never scaled by the drift and including the ticks a stall dropped.
var _local_ticks: float = 0.0

## For each input tick produced, by [code]tick % LEAD_HISTORY[/code]: the tick, and how far
## ahead of [member _local_ticks] it was when it was produced (and sent).
var _lead_tick: PackedInt64Array = []
var _lead_at: PackedFloat64Array = []

## Reports in the window, as [code]Vector2(local ticks when it came, lead needed)[/code], and
## the most of them: the input timeline is steered to [code]_local_ticks + _lead_target[/code].
var _lead_samples: Array[Vector2] = []
var _lead_target: float = 0.0

## Whether a report has come: from then on the lead is the server's, not the round trip's.
var _lead_live: bool = false

## Ticks the receive timeline has run past real time because the drift shortened or
## lengthened the ticks it advances by, not yet taken back. See [method _steer_lead].
var _receive_excess: float = 0.0

var _lead_reports: int = 0
var _lead_late_reports: int = 0
var _last_arrival_lead: int = 0
var _floor_count: int = 0

# --- Time the engine dropped -------------------------------------------------
#
# The engine runs at most `max_physics_steps_per_frame` physics steps a frame and drops the
# time past that without a word, so a clock handed only the step's delta never sees it. See
# docs/timelines.md#time-the-engine-drops.

## Credit the time the engine drops to local time and both timelines, measured from the wall
## clock at a frame's first physics step ([method note_engine_frame]) and before each snapshot
## is read ([method note_engine_time]), from the engine's own numbers, at a time scale of 1. A
## test that drives time by hand clears it and calls the two itself.
var follow_engine_time: bool = true

## Engine steps of slack before a gap between the wall clock and the steps run counts as
## dropped time: the engine's own accumulator holds up to a step, its jitter fix moves half a
## step between frames, and the wall clock is read a little after each frame begins. Time
## inside it is never credited; a stall is hundreds of steps.
const DROP_MARGIN_STEPS := 3

var _engine_frame: int = -1
## The engine's physics step at the last [method advance] the engine drove.
var _engine_last_step: int = -1
var _engine_rate: int = 0
var _engine_wall0: int = 0
var _engine_physics0: int = 0
var _engine_prev_wall: int = 0
var _engine_credited: float = 0.0
## The input tick when each of the last two frames with a physics step began, newest last: the
## commands produced since the older are the ones a stall credited now may not have been sent
## before ([method _credit_dropped]).
var _engine_frame_ticks: PackedInt64Array = [0, 0]
var _lost_seconds: float = 0.0
var _lost_count: int = 0


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

	if not is_authority:
		if Engine.is_in_physics_frame() and Engine.get_physics_frames() != _engine_last_step:
			# One call a physics step: the engine is what drives this clock.
			_engine_last_step = Engine.get_physics_frames()
			_follow_engine()
		elif follow_engine_time:
			# Called outside a physics step, or twice in one: a host (a test) driving time by
			# hand, whose wall clock says nothing about this clock. Forget the reference, so the
			# hand-driven stretch is never credited as a stall. (Cleared, the host hands the
			# engine's numbers over itself and keeps its reference.)
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
			_slip = clampf(_slip + float(1 - steps), -1.0, 1.0)

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


## The engine's frame counter, the wall clock (microseconds), the physics steps it has run
## (counting the one running now), its physics rate and its step cap, at the first physics step
## of a frame. [method advance] passes the engine's own while [member follow_engine_time] is set;
## a test drives it by hand. Wall time no step covers, beyond [constant DROP_MARGIN_STEPS], is
## time the engine DROPPED, and local time and both timelines move on by it ([method
## _credit_dropped]).
##
## [b]Why the clock has to look at the wall.[/b] The engine runs at most
## `max_physics_steps_per_frame` steps a frame and drops the rest; [method advance] is handed
## each step's delta, so local time ran slow by exactly what was dropped. With the reports
## steering the lead, every report about a command sent after a drop said how much later it
## had to be, but a round trip later: a first visit in a browser (seconds of loading and
## shader compiling, then slow frames) stayed behind by the drift times that delay and the
## server discarded nearly every command as late (game-g2gfast: the player stood on the spawn
## pad).
##
## [b]Two measurements.[/b] The steps a frame runs cover the wall time up to that frame's start,
## so the gap up to the PREVIOUS frame's start is exact once this frame begins (the engine's
## accumulator and its jitter fix are inside the margin). And a frame that drops runs exactly
## its cap, so the gap up to NOW less a whole cap of steps is dropped for certain, which says so
## before the frame's commands are stamped rather than a frame after. Credited a frame late,
## every command of the frame between was recorded as that much further ahead than it was, the
## reports about them asked for the whole stall again as lead, and the clock ran off to its cap.
func note_engine_frame(frame: int, wall_usec: int, physics_frames: int, physics_rate: int,
		max_steps: int = 8) -> void:
	if is_authority or frame == _engine_frame:
		return
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
		# [b]The reference frame's own steps are not counted.[/b] They cover the time up to its
		# start, which is the reference: counted, a reference taken on a frame that was catching
		# up (eight steps after a long one) put the engine eight steps ahead of the wall for good,
		# and every drop after it was credited 133 ms short.
		_engine_physics0 = before
	var settled := float(_engine_prev_wall - _engine_wall0) / 1000000.0 \
		- float(before - _engine_physics0) / float(physics_rate)
	_engine_prev_wall = wall_usec
	# The commands of the last two frames may have gone out after whatever stalled the previous
	# one: a host flushes a frame's packets at its end, or at the next frame's poll.
	var sent_after := _engine_frame_ticks[0]
	_engine_frame_ticks = [_engine_frame_ticks[1], tick]
	_credit_dropped(maxf(settled, _uncovered(wall_usec, before, physics_rate, max_steps)), sent_after)


## The same, at any moment outside a physics step: the wall clock, the physics steps run so far,
## the physics rate and the step cap. [method sync_from_server] calls it with the engine's own
## before it reads a snapshot.
##
## [b]A stall is usually seen here first.[/b] A host reads its packets in its frame's process,
## after the physics steps, and a stall (a scene loading, a shader compiling) happens there too.
## The snapshots read after it say where the server is now; credited only at the next frame's
## first step, the drop was added again on top of the receive timeline and the floor those
## snapshots had already moved, and the clock ran a stall ahead and snapped back.
func note_engine_time(wall_usec: int, physics_frames: int, physics_rate: int,
		max_steps: int = 8) -> void:
	if is_authority or _engine_frame < 0 or _engine_physics0 < 0 or physics_rate != _engine_rate:
		return
	# This frame's commands go out at its end, after this, and the previous frame's may have
	# waited for this frame's poll.
	_credit_dropped(_uncovered(wall_usec, physics_frames, physics_rate, max_steps), _engine_frame_ticks[0])


## Hands the engine's own numbers to [method note_engine_frame] inside a physics step, or to
## [method note_engine_time] outside one, while [member follow_engine_time] is set, time runs
## at its own speed, and the engine's physics steps are what advance this clock (one [method
## advance] a step, the latest included).
func _follow_engine() -> void:
	if not follow_engine_time or is_authority or Engine.time_scale != 1.0:
		return
	if _engine_last_step < 0 or Engine.get_physics_frames() - _engine_last_step > 1:
		# Only while the engine's physics steps advance this clock: the latest step did. A test
		# harness that sets `tick` itself and feeds snapshots in one long loop is a stall by the
		# wall clock; credited as one, the clock moved under it (game-arena's `headless_net`, a
		# wall route predicted 0.19 m off). Counted in steps, not frames: a client drawing
		# faster than it steps has frames with none, and a stall in one of them went uncredited
		# until the snapshots after it had been read.
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
## past the margin and not credited already. The commands produced after [param sent_after] may
## not have gone out before the drop.
##
## [b]After a stall, those commands are recorded as that much less far ahead.[/b] A report is
## measured against how far ahead of local time its command was sent ([member _lead_at]), and
## the lead was recorded when the command was produced, so the time between producing and
## sending (the rest of the frame) is in every report, and the lead covers it. A STALL between
## them is not a frame to cover: one command produced before a three-second hitch and sent
## after it reached the server the whole stall late, its report asked for the stall as lead on
## top of the credit that had already restored local time, and the clock jumped a stall ahead
## and snapped back a second later (netcode_demo, 176 ticks at 60). So a drop longer than
## [constant LEAD_SMOOTH_SECONDS] (a stall, as the steering already counts one) moves those
## commands' leads back by itself: the last two frames', because a host may flush a frame's
## packets at the next frame's poll (game-g2gfast at 60, a 2.5 s hitch: the clock 134 ticks
## ahead and snapped back with only the stalled frame's moved). One that went out before the
## stall reads as needing less, which the window's most never steers by. A shorter one is a slow frame that will come again, and
## moving its commands back steered every command of a client on steady slow frames late by
## the drop (netcode_demo at 128 with 150 ms frames: all of them, 10 ticks late).
func _credit_dropped(gap: float, sent_after: int) -> void:
	var lost := gap - _engine_credited - float(DROP_MARGIN_STEPS) / float(_engine_rate)
	if lost <= 0.0:
		return
	_engine_credited += lost
	_lost_seconds += lost
	_lost_count += 1
	if lost > LEAD_SMOOTH_SECONDS and not _lead_tick.is_empty():
		for t in range(maxi(sent_after + 1, tick - LEAD_HISTORY + 1), tick + 1):
			var slot := posmod(t, LEAD_HISTORY)
			if _lead_tick[slot] == t:
				_lead_at[slot] -= lost * float(tick_rate)
	# Local time and both timelines move on by it: the steps that would have carried them never
	# ran. The tick moves here rather than by the steering because before the first report
	# nothing steers it until the next snapshot, and every command until then was late by the
	# drop. The receive timeline moves too, as it does for the ticks [method advance] drops: left
	# behind, the cap on the lead ([method _lead_position]) sat the whole stall back until the
	# next snapshot.
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
			{"seconds": snappedf(lost, 0.001), "ticks": snappedf(ticks, 0.1)})


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
## [b]Not the number a renderer wants, despite how this reads.[/b] It is the leftover
## in [member _accumulator], which only changes inside [method advance] — and a host
## calls that from its physics loop. So it is constant across every frame drawn within
## one physics step, which is precisely the stepping a renderer is trying to remove; on
## a machine drawing faster than it steps physics, using this would quantise motion to
## the physics rate instead of the tick rate and look no better.
##
## A renderer wants [code]Engine.get_physics_interpolation_fraction()[/code], which is
## measured at render time. [method DotNetManager.interpolate_frame] and
## [code]DotFpsController.render_state[/code] both use that.
##
## Kept because it is the honest answer to "how far through the current tick is the
## simulation", which a diagnostic or a fixed-step consumer may still want.
func alpha() -> float:
	return clampf(_accumulator / tick_duration(), 0.0, 1.0)


## What to add to [method received_tick] for anything DRAWN on the receive timeline (an
## interpolation buffer's render time), in ticks: the re-anchoring it has not followed yet,
## taken up at [constant RECEIVE_RECOVERY] (within the frame as well, from the engine's
## physics fraction).
##
## [b]The receive timeline moves in whole ticks[/b] when a packet comes quicker than any
## before it (forward at once) or a window of them all came slower (back one). Drawn from it
## as it is, every remote entity jumps a tick forward or back at that moment: game-arena's
## `headless_feel` counted 2 to 4 frames a window drawn behind the frame before after its
## link's delay changed, by a tick each. The timeline itself, and the buffer sizing that
## reads it, still move at once; only what is drawn follows gently.
func receive_slip(physics_fraction: float = -1.0, physics_delta: float = -1.0) -> float:
	if _receive_slip == 0.0:
		return 0.0
	if physics_fraction < 0.0:
		physics_fraction = Engine.get_physics_interpolation_fraction()
	if physics_delta <= 0.0:
		physics_delta = 1.0 / float(maxi(1, Engine.physics_ticks_per_second))
	return move_toward(_receive_slip, 0.0,
		RECEIVE_RECOVERY * float(tick_rate) * clampf(physics_fraction, 0.0, 1.0) * physics_delta)


## How far through the newest tick's step a frame drawn NOW is, in ticks, for anything
## drawn between this clock's last two ticks: the engine's physics fraction ([param
## physics_fraction] of a [param physics_delta]-second physics frame, both from the engine
## when left negative), plus what is left of the last slip. Usually 0..1; from -1 to 2
## while a slip is taken up.
##
## [b]A slip is a physics frame that ran no tick, or two.[/b] The engine's fraction is through
## a PHYSICS frame, which is a fraction through a tick only while every physics frame runs
## exactly one. A client's clock stretches or shrinks its ticks while it settles on the
## server (drift, up to [constant MAX_DRIFT_RATE]), so now and then a physics frame runs none
## and a later one two. Drawn at the engine's fraction alone, the frame after one with none
## goes back over the step it just drew (the eye stands still) and the frame after one with
## two skips a step (it moves double): measured in game-arena's `headless_feel` at 60 Hz
## against 64 ticks while the clock settled, 8 frames in 5 s 10 to 15 cm off their motion,
## every one after a physics frame that ran 0 or 2 ticks. So a slip moves this by the tick
## the frame gained or lost, which keeps the drawing where it was, and that is taken back at
## [constant SLIP_RECOVERY]: the drawing runs a tenth slow or fast for ten ticks instead of
## jumping one.
##
## Past 1 the frame is later than the newest tick (a renderer extrapolates along the last
## step, an interpolation buffer samples there); below 0 it is between the two before it.
## [b]Not a fraction of the clock's own accumulator[/b], which would be continuous too but puts
## the drawing anywhere up to a tick past the newest tick all the time, not only after a slip:
## tried, it extrapolated through every landing and wall.
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
	return frac + move_toward(_slip, 0.0, _slip_recovery * float(tick_rate) * frac * physics_delta)


# --- Client synchronisation ------------------------------------------------

## Feeds a sample from the server: the tick it reported and the round trip.
##
## Called whenever a packet carrying a server tick arrives. The estimate is
## [code]server_tick + half the round trip[/code], because the tick the server sent
## is already one-way-latency old by the time it arrives.
func sync_from_server(server_tick: int, rtt_ms: float) -> void:
	if is_authority:
		return

	# Before the snapshot is read: see [method note_engine_time].
	_follow_engine()

	_note_rtt(rtt_ms)

	var first := not _synced or (not _synced_with_rtt and _rtt_ms > 0.0)
	_follow_arrival(server_tick, first)

	if _lead_live and not first:
		# The input timeline is the server's report's to steer ([method _steer_lead], every
		# frame). The round trip still places the receive timeline and has a say in a snap.
		#
		# [b]Never behind the server.[/b] Each report is a round trip old, and a clock that fell
		# behind faster than they could say (a stall, time the engine dropped) stamped every
		# command for a tick the server had already simulated until they caught up: with the
		# absolute catch-up skipped here, a client on slow frames never did (game-g2gfast,
		# stuck on the spawn pad). A command stamped for a tick no later than the newest
		# snapshot this client holds is late whatever the link does, so behind that the clock
		# jumps to the reported lead, or past the floor by the margin if that is further, and
		# the next reports take it from there.
		#
		# [b]Nothing here is from the round trip.[/b] The round trip a game measures around a
		# stall holds the stall (749 ms on a 100 ms link while g2gfast joined at 128, three
		# seconds across a three-second hitch): a floor that added a flight time to the receive
		# timeline fired on every join, and a jump to the round trip's target put the clock a
		# second ahead, then snapped it back. Local time, which the reported lead is measured
		# against, follows the wall clock ([method note_engine_frame]), so the reported lead is
		# right after a stall as soon as the drop is credited.
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
			DotLog.warn(CHANNEL, "clock snapped; predicted state is stale",
				{"error_ticks": behind, "snaps": _snap_count})
			tick += behind
			_drift_scale = 1.0
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
		DotLog.warn(
			CHANNEL,
			"clock snapped; predicted state is stale",
			{"error_ticks": error, "snaps": _snap_count}
		)
		tick = target
		_drift_scale = 1.0
		return

	if error > catch_up_threshold_ticks():
		# [b]Behind by more than the margin, and that is not drift to be smoothed.[/b] A
		# client behind its target stamps every command for a tick the server has
		# already simulated; the server discards each one as late and repeats the last
		# command it had, so the player cannot steer and the prediction is pulled back
		# a few times a second. Smoothing that at [constant MAX_DRIFT_RATE] is 3 ticks a
		# second at 60 Hz and 6.4 at 128 — a half-second hitch was ten seconds of a
		# client that could not play, which is exactly what a browser's first connect
		# looked like: the engine drops every physics step past eight in a frame, so
		# each load or shader-compile stall put the clock behind by its own length.
		#
		# Forward is cheap. The ticks jumped over are never sent, the server repeats the
		# last command for them as it would for a lost packet, and the predictor finds a
		# hole in its history once. Backward is not, which is why an error the OTHER way
		# — a client ahead of its target — is still smoothed below.
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
		# [b]One a frame.[/b] A burst read in one frame is one arrival time: the snapshots a stall
		# held up arrive together, oldest first, behind a timeline the stall was credited to
		# ([method _credit_dropped]), and counted one by one they were six windows of a path
		# that had got slower, and one more than a second behind.
		return
	_settle_local = _stepped_ticks

	_settle_count += 1

	if _settle_count >= SETTLE_SAMPLES:
		_settle_open = false
		if ahead < -snap_threshold_ticks():
			# More than a second behind for a whole window of frames. [b]Never on one sample,
			# and never while the samples gain on local time.[/b] The snapshots a stall held up
			# arrive after the clock has credited the stall ([method _credit_dropped]), oldest
			# first, and over a socket that hands a frame only part of the backlog they drain for
			# many frames, each far behind and each newer than the last by more than the frame:
			# anchored to one of them, the timeline went back the whole stall and the cap on the
			# lead with it, and the clock snapped back a stall (game-g2gfast at 60 after five
			# seconds, then 34 jumps forward as the backlog drained). Samples that keep pace
			# with local time a second behind are a different session, and anchor.
			if float(sampled - _settle_first_sample) <= _local_ticks - _settle_first_local + 2.0:
				_received_tick = sampled
				_receive_slip = 0.0
			return
		_received_tick -= 1
		_receive_slip += 1.0


## What the server said about this client's commands: the one for [param input_tick] was the
## latest to arrive in the last period, [param arrival_lead] ticks before the server needed
## it (0 just in time, below 0 late). Called by [method DotNetManager.receive_snapshot] for a
## server that reports it.
##
## [b]Why the server has to say it.[/b] Before this, the lead was half the round trip plus a
## margin, and the round trip a game feeds is ENet's smoothed one (an eighth of each new
## sample) through a median of sixteen: when the path got 30 ms slower each way, the lead
## followed over seconds and every command meanwhile reached the server after its tick. In
## game-arena's `headless_feel` (40 to 70 ms each way): 97-120 late in 5 s, 47-61 prediction
## corrections, the eye going backwards on 63-85 frames.
##
## [b]Measured against the time the command was sent, not the tick it is now.[/b] The lead it
## needed is the lead it was sent with ([member _lead_at]), less what it arrived with, plus
## [member lead_slack_ticks]. That already counts every correction made since it was sent, so
## a report a round trip old never makes the clock correct twice. Nothing about the
## downlink is in it either: the receive timeline is for drawing, the lead only for commands.
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
		DotLog.info(CHANNEL, "input lead follows the server's reports",
			{"lead": tick - server_tick(), "arrival_lead": arrival_lead})


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
	# In the units [method _steer_lead] steers: the timeline's continuous position (the tick
	# and the fraction of the next one already run) ahead of local time. The tick alone is up
	# to a tick behind that, and a report measured against it settled a tick short of the
	# slack asked for.
	_lead_at[slot] = float(produced) + _accumulator / tick_duration() - _local_ticks


## Steers the input timeline to the reported lead, once a frame: shorter ticks while it is
## short of it (up to [constant LEAD_RAISE_RATE]), longer while past it (up to [constant
## MAX_DRIFT_RATE]), a jump forward for a deficit too big to gain in [constant
## LEAD_SMOOTH_SECONDS].
##
## [b]And the receive timeline is held to real time while it does.[/b] It advances by the
## same ticks as the input timeline, so ticks 12% short would carry it 12% ahead of the
## snapshots, where it waits a whole [constant SETTLE_SAMPLES] a tick to come back and
## everything remote is extrapolated meanwhile. What the drift adds to it is taken back a
## tick at a time through [member _receive_slip], which the drawing follows at [constant
## RECEIVE_RECOVERY].
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

	var correction := clampf(error * LEAD_GAIN, -MAX_DRIFT_RATE, LEAD_RAISE_RATE)
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


## How far behind its target the input timeline may fall before it jumps forward, in ticks.
##
## The margin itself: within it a command still lands before its tick, so smoothing loses
## nothing; past it every tick of smoothing is a command the server throws away. See
## [method sync_from_server].
func catch_up_threshold_ticks() -> int:
	return maxi(1, _target_lead() - one_way_ticks())


## [constant SNAP_THRESHOLD_SECONDS] in ticks, at this clock's rate.
##
## At least one tick, so a clock configured with an absurdly low rate still snaps on a
## genuinely different session rather than trying to smooth it.
func snap_threshold_ticks() -> int:
	return maxi(1, int(roundf(SNAP_THRESHOLD_SECONDS * float(tick_rate))))


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

## The tick this client believes the server is simulating right now: the receive
## timeline plus the flight time.
func server_tick() -> int:
	return _received_tick + one_way_ticks() if not is_authority else tick


## The newest snapshot tick this client expects to hold now, as the quickest recent
## arrivals place it. What the render timeline is measured back from: an interpolation
## delay is "this many snapshots behind the newest", and the newest is the one that has
## ARRIVED, not the one the server is building. See [member _received_tick].
func received_tick() -> int:
	return _received_tick if not is_authority else tick


## The tick inputs are being generated for. Ahead of the server.
func input_tick() -> int:
	return tick


## The tick to render, given an interpolation delay in ticks: that far behind the newest
## snapshot this client holds ([method received_tick]), not behind the tick the server is
## on. The two differ by the flight time, and a delay counted from the server's tick spent
## the first [method one_way_ticks] of itself waiting for a snapshot still in flight --
## measured through a real relay at 110-160 ms round trip, 93-100% of frames were drawn
## past the newest snapshot and extrapolated, where 0-14% are now.
##
## Never returns a tick ahead of the receive timeline: rendering ahead means
## interpolating toward a snapshot that has not arrived, which is extrapolation with
## none of the guards.
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
