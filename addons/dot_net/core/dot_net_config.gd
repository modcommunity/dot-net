@tool
class_name DotNetConfig
extends DotConfig

## Everything configurable about netcode. Layered like every [DotConfig]: exported defaults, then a
## JSON file, then [code]DOT_NET_*[/code] environment variables, then [code]--net-*[/code] arguments.

@export_group("Simulation")

## Simulation ticks per second. The rate at which authoritative state advances.
@export_range(1, 240, 1) var tick_rate: int = 60

## State broadcasts per second. Must divide into [member tick_rate]. Usually lower than the tick rate:
## simulating at 60 and sending at 20 is standard, because interpolation hides the difference and
## bandwidth is the scarce resource.
@export_range(1, 240, 1) var snapshot_rate: int = 20

## Spreads each snapshot's peers over the ticks between snapshots, instead of sending every peer its
## snapshot on the same tick.
@export var stagger_snapshots: bool = false

## Whether peers in step share one dirty set per entity per snapshot ([method
## DotNetBehaviour.collect_dirty]).
@export var share_dirty_sets: bool = true

## Worker threads that build per-peer snapshots: 0 builds every peer's on the thread that ticks (the
## default), -1 is the processor count less one (at most [constant DotParallel.AUTO_MAX]), n is at most
## n.
@export_range(-1, 64) var snapshot_workers: int = 0

## Build server snapshots in the optional native library ([DotNetNative]): the same bytes, several
## times cheaper. Falls back to GDScript, logged once, where it cannot load. See docs/native.md.
## Environment [code]DOT_NET_NATIVE[/code], command line [code]--net-native[/code].
@export var native: bool = false

## Where the native library's [code].cfg[/code] is; empty is the addon's own
## ([code]addons/dot_net/native/dot_net_native.cfg[/code]), then [code]dot_net_native/[/code] next
## to the executable. Environment [code]DOT_NET_NATIVE_PATH[/code].
@export var native_path: String = ""

## With [member native], also run [DotNetInterestDistance]'s selection and the budget's ordering in
## the library: the same bytes. Ignored for any other strategy. Environment
## [code]DOT_NET_NATIVE_INTEREST[/code], command line [code]--net-native-interest[/code].
@export var native_interest: bool = false

## Ticks a client's input timeline runs ahead of the server, beyond half the RTT.
##
## See [DotNetClock]. Higher costs input latency and reduces late commands.
@export_range(0, 20, 1) var input_margin_ticks: int = 2

## Grow the input margin from measured jitter.
@export var adaptive_input_margin: bool = true

## Ticks early a client's commands should reach the server, once the server says how early they do (a
## server and client that both read [code]FEATURE_INPUT_LEAD[/code]). Replaces the two settings above
## from the first report on: the lead is then measured, not estimated from the round trip.
@export_range(0, 20, 1) var input_lead_slack_ticks: int = 2

@export_group("Interpolation")

## Snapshots of delay before rendering — a count of SNAPSHOTS, not of ticks. The buffer that absorbs
## jitter and loss.
@export_range(0.0, 10.0, 0.5) var interpolation_buffer: float = 2.0

## Adjust the buffer from observed jitter and loss.
@export var adaptive_interpolation: bool = true

## Longest extrapolation when snapshots stop arriving, in seconds. Extrapolation is guessing, and it is
## wrong in a way that produces rubber-banding when it is corrected.
@export_range(0.0, 1.0, 0.05) var max_extrapolation_sec: float = 0.2

@export_group("Prediction")

## Predict locally-owned entities rather than waiting for the server. Off means a full round
## trip of latency before anything moves, unplayable above about 50 ms.
@export var enable_prediction: bool = true

## Inputs kept for replay during reconciliation. Must exceed the worst round trip in ticks, or a
## correction arrives for an input already discarded and the client cannot replay from it.
@export_range(8, 512, 8) var input_history_ticks: int = 120

## Reconcile a predicted entity once a frame, against the newest snapshot, rather than once per
## snapshot as each arrives. Every reconciliation rewinds and replays every unacknowledged input, so
## its cost is the input lead in ticks times one simulation.
@export var reconcile_once_per_frame: bool = false

## Skip a reconciliation whose server state the client already predicted. The predictor keeps what each
## predicted tick produced.
@export var skip_matching_replays: bool = false

## Whether [method DotNetManager.predict_tick] rounds each input to the wire
## ([method DotNetInput.round_trip]) before it is simulated, so the prediction runs on
## the command the server decodes. On by default; off only to measure what it costs not to.
@export var predict_wire_input: bool = true

## Position error before a predicted entity is corrected, in metres. Below this the prediction is
## treated as right, which stops floating-point noise from producing constant micro-corrections.
@export_range(0.0, 1.0, 0.001) var reconcile_position_epsilon: float = 0.01

## Smooth a correction over this many seconds instead of snapping. A snapped correction is a visible
## teleport.
@export_range(0.0, 1.0, 0.01) var reconcile_smooth_sec: float = 0.1

## Error beyond which a correction snaps rather than smoothing. A large divergence means the prediction
## was wrong about something structural — a collision the client missed, a teleport, a respawn — and
## smoothing across it drags the entity through geometry.
@export_range(0.1, 100.0, 0.1) var reconcile_snap_distance: float = 2.0

## Longest a client carries a remote entity along its replicated velocity when predicting against it,
## in seconds ([method DotNetBehaviour.extrapolated_value]). 0, the default, predicts against where it
## was last heard.
@export_range(0.0, 1.0, 0.01) var remote_extrapolation_sec: float = 0.0

## Seconds the server repeats a silent peer's last input before it applies that input
## neutralised ([method DotNetInput._neutralise]): a lost packet keeps the player moving, a
## blackout does not run them on for its whole length. 0 repeats for ever.
@export_range(0.0, 5.0, 0.05) var starved_input_hold_sec: float = 0.25

## Seconds without a snapshot after which a client predicts on its input neutralised, so a
## blackout's correction is bounded by about speed x (this + [member starved_input_hold_sec])
## rather than by its length (docs/prediction.md, "Blackouts"). 0 never holds.
@export_range(0.0, 5.0, 0.05) var prediction_hold_sec: float = 0.5

@export_group("Lag compensation")

## Rewind the world to a client's view when validating its actions. What makes hit registration feel
## right on a laggy connection.
@export var enable_lag_compensation: bool = true

## Longest rewind permitted, in seconds. Also the ceiling on how far behind a client's claim may be.
@export_range(0.0, 2.0, 0.05) var max_rewind_sec: float = 1.0

## Seconds of transform history kept per entity. Must exceed [member max_rewind_sec] plus the send
## interval, or a rewind lands before the oldest sample.
@export_range(0.1, 5.0, 0.1) var history_sec: float = 1.5

@export_group("World bounds")

## World extent used for position quantisation, in metres from the origin. [b]Positions outside this
## are clamped, not wrapped.[/b] Set it to comfortably contain your playable space — too small silently
## pins entities at the boundary, too large wastes bits.
@export var world_extent: float = 2048.0

## Position resolution in metres. 1 cm is well below what a player can perceive on another character
## and costs about 19 bits per axis over a 4 km world.
@export_range(0.0001, 1.0, 0.0001) var position_step: float = 0.01

## Bits per rotation component in the smallest-three encoding.
@export_range(6, 16, 1) var rotation_bits: int = 9

## Bits per velocity component. Velocity tolerates more error than position — it is integrated, and the
## next snapshot corrects it — so it gets fewer bits.
@export_range(6, 24, 1) var velocity_bits: int = 12

## Maximum representable speed, in metres per second.
@export var max_speed: float = 100.0

@export_group("Bandwidth")

## The largest snapshot payload [DotNetManager] hands to [member DotNetManager.send_fn]. A snapshot
## that would be bigger is sent as several parts, each a snapshot of its own entities that applies
## without the others, so a lost part loses only what was in it (docs/wire.md#snapshot-parts).
@export_range(256, 8192, 64) var mtu: int = 1200

## Bytes per second sent to one client. 0 is unlimited. The budget interest management and
## prioritisation work within.
@export var per_client_budget: int = 65536

## Packets per second to one client. 0 is unlimited.
@export_range(0, 240, 1) var per_client_packet_rate: int = 60

## Snapshots a send may stay unconfirmed before it is resolved without an acknowledgement. The bound on
## how much unconfirmed state the server tracks per peer.
@export_range(4, 256, 1) var ack_window_snapshots: int = 32

@export_group("Interest management")

## Radius within which entities are always replicated, in metres.
@export var interest_radius: float = 200.0

## Cell size for the grid strategy, in metres. Should be near [member interest_radius]: much smaller
## and the query touches many cells, much larger and it returns far more than it needs.
@export var interest_cell_size: float = 128.0

## Entities past [member far_distance] from a peer are sent in one snapshot of this many. 1 is off.
## Applied to the default distance strategy ([member DotNetInterest.far_every]); a game that builds
## its own strategy sets it there.
@export_range(1, 16, 1) var far_every: int = 1

## Metres beyond which an entity is far for [member far_every]. 0 is never far.
@export var far_distance: float = 0.0

## Entities replicated to one client per snapshot, at most. 0 is unlimited. The backstop when interest
## management is not enough — a thousand entities in one room.
@export_range(0, 4096, 16) var max_entities_per_snapshot: int = 256

## Entities built into one peer's snapshot, at most, taken in the budget's accumulated-priority order;
## the rest wait their turn, so each entity's update rate follows its score ([member
## DotNetInterest.distance_falloff]). What the peer owns always goes. 0 is off.
@export_range(0, 4096, 1) var peer_send_budget: int = 0

@export_group("Limits")

## Messages one client may send per second before being throttled. Every client-to-server message costs
## the server work, so a client that sends a thousand a second is either broken or hostile.
@export_range(10, 10000, 10) var client_message_rate: int = 240

## Largest payload accepted from a client, in bytes.
@export_range(256, 65536, 256) var max_client_payload: int = 4096

## Entities one client may be told about at once. 0 is unlimited.
@export_range(0, 65536, 64) var max_tracked_entities: int = 4096


func env_prefix() -> String:
	return "DOT_NET_"


func cli_prefix() -> String:
	return "--net-"


func validate() -> DotResult:
	if snapshot_workers < -1:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"snapshot_workers must be -1 (automatic), 0 (off) or a worker count.",
			str(snapshot_workers)
		)

	if snapshot_rate > tick_rate:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"snapshot_rate must not exceed tick_rate.",
			"%d > %d" % [snapshot_rate, tick_rate]
		)

	if tick_rate % snapshot_rate != 0:
		# Not fatal — it works — but the send spacing is uneven and shows up as
		# jitter that no interpolator can remove, so it is worth saying loudly.
		DotLog.warn(
			"net",
			"tick_rate is not a multiple of snapshot_rate; sends will be unevenly "
			+ "spaced and will look like jitter",
			{"tick_rate": tick_rate, "snapshot_rate": snapshot_rate}
		)

	if history_sec <= max_rewind_sec:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"history_sec must exceed max_rewind_sec.",
			"a rewind would land before the oldest sample"
		)

	if world_extent <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID, "world_extent must be positive."
		)

	if reconcile_snap_distance <= reconcile_position_epsilon:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"reconcile_snap_distance must exceed reconcile_position_epsilon.",
			"otherwise every correction snaps"
		)

	# Raised rather than warned about: the history is a derived quantity — twice the rewind, in ticks —
	# and every host that raised the tick rate from the 60 the default was sized for got the warning and
	# nothing else.
	var input_ticks_needed := mini(int(max_rewind_sec * float(tick_rate)) * 2, 512)
	if input_history_ticks < input_ticks_needed:
		DotLog.info(
			"net",
			"input_history_ticks raised to cover the configured rewind",
			{"was": input_history_ticks, "now": input_ticks_needed}
		)
		input_history_ticks = input_ticks_needed

	return DotResult.success(null)


## Ticks between state broadcasts.
func ticks_per_snapshot() -> int:
	return maxi(1, tick_rate / maxi(1, snapshot_rate))


## Seconds between state broadcasts.
func snapshot_interval() -> float:
	return 1.0 / float(maxi(1, snapshot_rate))


## Interpolation delay in seconds, from the buffer setting. Measured in the snapshots the manager
## actually sends — every [method ticks_per_snapshot] ticks, an integer — so it agrees with [method
## DotNetInterpolator.delay_ms] when the snapshot rate does not divide the tick rate.
func interpolation_delay() -> float:
	return interpolation_buffer * float(ticks_per_snapshot()) / float(maxi(1, tick_rate))


## Bits used per position axis, derived from the world size and step.
func position_bits() -> int:
	return DotNetWriter.bits_for_step(
		-world_extent, world_extent, position_step
	)


## Transform history samples kept per entity. Sized from [member tick_rate] rather than [member
## snapshot_rate] even though history is normally recorded per snapshot.
func history_samples() -> int:
	return maxi(2, int(ceilf(history_sec * float(tick_rate))) + 2)


func max_rewind_ticks() -> int:
	return int(max_rewind_sec * float(tick_rate))


## A summary of what the settings cost, for a `net_status` command. The numbers most likely to be a
## surprise: how many bits a transform takes and what that means per client per second at the
## configured rates.
func describe_budget() -> PackedStringArray:
	var pos_bits := position_bits()
	var transform_bits := pos_bits * 3 + rotation_bits * 3 + 2

	var out := PackedStringArray()
	out.append("tick rate         %d Hz" % tick_rate)
	out.append("snapshot rate     %d Hz (every %d ticks)" % [
		snapshot_rate, ticks_per_snapshot()
	])
	out.append("interp delay      %d ms" % int(interpolation_delay() * 1000.0))
	out.append("position          %d bits/axis (%.0f cm over +/-%.0f m)" % [
		pos_bits, position_step * 100.0, world_extent
	])
	out.append("transform         %d bits (%.1f bytes)" % [
		transform_bits, float(transform_bits) / 8.0
	])
	out.append("per-entity/sec    %.0f bytes at %d Hz" % [
		float(transform_bits) / 8.0 * float(snapshot_rate), snapshot_rate
	])

	if per_client_budget > 0:
		var entities := int(
			float(per_client_budget) /
			(float(transform_bits) / 8.0 * float(snapshot_rate))
		)
		out.append("budget            %s/s ≈ %d entities/client" % [
			DotPaths.format_bytes(per_client_budget), entities
		])

	return out


## The most entities one snapshot may name: the tighter of [member max_entities_per_snapshot] and
## [member max_tracked_entities], where 0 means "no limit" on either.
func entity_cap() -> int:
	if max_entities_per_snapshot <= 0:
		return maxi(max_tracked_entities, 0)
	if max_tracked_entities <= 0:
		return max_entities_per_snapshot
	return mini(max_entities_per_snapshot, max_tracked_entities)
