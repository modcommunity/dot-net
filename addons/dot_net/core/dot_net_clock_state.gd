extends RefCounted

## The constants and state of [DotNetClock], kept in a base so the file with the logic stays
## readable. Nothing here is used on its own.

const CHANNEL := "net.clock"

## Largest correction applied per tick, as a fraction of tick duration. 5% is imperceptible in
## motion and closes a 100 ms error in about two seconds at 60 Hz; larger reads as a speed-up,
## smaller never catches a drifting clock.
const MAX_DRIFT_RATE := 0.05

## Error beyond which the clock gives up on smoothing and snaps, in SECONDS: a suspended client
## (a sleeping phone, an alt-tabbed tab) is a different session. A duration, not a tick count,
## or a 128-tick server snapped on a half-second hitch and a snap discards everything predicted.
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

## Extra ticks the input timeline runs ahead, on top of half the round trip, to absorb jitter
## (2 at 60 Hz lets a command arrive 33 ms late). Raising it costs latency, lowering it costs
## discarded commands. [member adaptive_margin] tunes it from observed jitter.
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

## How fast a slip is taken up, in ticks per tick of time: twice the most drift can make
## ([constant MAX_DRIFT_RATE]) so slips never pile up, and slow enough to read as a slight
## change of speed rather than a one-tick jump.
const SLIP_RECOVERY := 0.1

## The most slip carried, in ticks: room for a second slip while the first is taken up.
const MAX_SLIP := 2.0

## How fast slips are taken up now: [constant SLIP_RECOVERY], or twice what the drift makes while
## faster than [constant MAX_DRIFT_RATE] (a lead raise, up to [constant LEAD_RAISE_RATE]). Slower,
## they pile up to the clamp and the tick past it is drawn as a jump.
var _slip_recovery: float = SLIP_RECOVERY

## The newest snapshot tick as the quickest recent arrivals place it, advanced locally: the RECEIVE
## timeline. It must advance between samples (or [method render_tick] steps at the snapshot rate)
## and follow the quickest arrivals only: a late sample moves nothing, [constant SETTLE_SAMPLES] of them take it back one tick.
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

## Whether the clock has ever been anchored with a real round-trip measurement. The first sample
## often precedes any measurement (dot-net owns no transport), so the next one that carries one
## is adopted outright, once, rather than smoothed toward over seconds of discarded input.
var _synced_with_rtt: bool = false
var _snap_count: int = 0
var _catch_up_count: int = 0

# Once the server says how early this client's commands reach it ([method note_input_lead]),
# the input timeline is steered by that, not by the round trip. See
# docs/timelines.md#the-input-lead-the-server-reports.

## How early (ticks) a command should reach the server, at the worst arrival of the last
## [constant LEAD_WINDOW_SECONDS]. [code]DotNetConfig.input_lead_slack_ticks[/code].
var lead_slack_ticks: int = 2

## Seconds of reports the lead is held at the most of: long enough to see a link's jitter many
## times over, short enough that a link which got quicker gives the latency back within a couple
## of seconds.
const LEAD_WINDOW_SECONDS := 1.0

## The most a tick is shortened to raise the lead, as a fraction of its length (12% faster). A
## latency rise is a few ticks, gained in a fraction of a second; slowing stays at
## [constant MAX_DRIFT_RATE], since too large a lead costs latency, not commands.
const LEAD_RAISE_RATE := 0.12

## Fraction of the lead's error corrected per tick (a time constant of ten ticks), capped at
## the rates above.
const LEAD_GAIN := 0.1

## A deficit bigger than [constant LEAD_RAISE_RATE] can gain in this long jumps instead
## ([member _catch_up_count]): a stall, not a link getting slower, and every tick of smoothing
## it would be a command the server throws away. About 60 ms of lead at any tick rate.
const LEAD_SMOOTH_SECONDS := 0.5

## The most a report may put the input timeline past where the round trip would: a sanity bound,
## not a setting (measured leads sit below the round trip's). It stops a clock running away from
## reports about commands it did not stamp, as a host stamping its own lead would see.
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

# The engine runs at most `max_physics_steps_per_frame` physics steps a frame and drops the
# time past that without a word, so a clock handed only the step's delta never sees it. See
# docs/timelines.md#time-the-engine-drops.

## Credit the time the engine drops to local time and both timelines, measured from the wall clock
## at a frame's first physics step ([method note_engine_frame]) and before each snapshot is read
## ([method note_engine_time]), at time scale 1. A test driving time by hand clears it.
var follow_engine_time: bool = true

## Engine steps of slack before a gap between wall clock and steps run counts as dropped time: the
## engine's accumulator holds up to a step, its jitter fix moves half a step, and the wall clock
## is read after a frame begins. Inside it nothing is credited; a stall is hundreds of steps.
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
## Wall time (seconds) between the starts of frames with a physics step in the last
## [constant LEAD_WINDOW_SECONDS], as [code]Vector2(wall clock at its end, seconds)[/code]: how
## long a frame's commands wait to be sent ([method _discount_long_frame]).
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
