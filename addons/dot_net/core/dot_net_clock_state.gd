extends RefCounted

## The constants and state of [DotNetClock], kept in a base so the file with the logic stays
## readable. Nothing here is used on its own.

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

## A frame this long (seconds) is a stall a round trip measured across may hold.
const RTT_STALL_SECONDS := 0.25

## Stalls remembered, as [code]Vector2(wall second it ended, seconds)[/code]: the newest few.
const RTT_STALL_MEMORY := 8

## Wall seconds a run of held samples may last before samples are believed again: a client whose
## every frame is a stall (a few frames a second) would otherwise never learn its real link.
const RTT_HOLD_SECONDS := 3.0

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

## The most slip carried, in ticks: room for a second slip while the first is taken up.
const MAX_SLIP := 2.0

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

## Ticks past [member lead_slack_ticks] the latest report's command must have arrived early by
## before the lead is given back faster than [constant MAX_DRIFT_RATE] ([method _slowest]).
const LEAD_EARLY_TICKS := 2

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
## The wall time (seconds) between the starts of the frames with a physics step in the last
## [constant LEAD_WINDOW_SECONDS] of wall time, as [code]Vector2(the wall clock when it ended,
## seconds)[/code] (the wall's, not local time's: a credited stall moves local time on by itself):
## how long a frame's commands recurrently wait to be sent ([method _discount_long_frame]).
var _frame_waits: Array[Vector2] = []
var _lost_seconds: float = 0.0
var _lost_count: int = 0
var _last_wall_usec: int = 0
var _stalls: Array[Vector2] = []
var _rtt_rejected: int = 0
var _hold_since_usec: int = 0
## The median of the samples no stall touched: what a held one is held near, so held ones do not
## raise it a step each.
var _rtt_base: float = 0.0
