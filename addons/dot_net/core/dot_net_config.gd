@tool
class_name DotNetConfig
extends DotConfig

## Everything configurable about netcode.
##
## Layered like every [DotConfig]: exported defaults, then a JSON file, then
## [code]DOT_NET_*[/code] environment variables, then [code]--net-*[/code] arguments.
##
## [b]The defaults describe a 60 Hz shooter on a 4 km map.[/b] They are a starting
## point, not a recommendation for your game — a turn-based game wants a fraction of
## the tick rate, a racing game wants tighter position quantisation, a strategy game
## wants interest management doing far more work. Every one of these is here because
## a real game would need to change it.

@export_group("Simulation")

## Simulation ticks per second.
##
## The rate at which authoritative state advances. Higher means lower input latency
## and better hit registration, and costs CPU and bandwidth linearly.
@export_range(1, 240, 1) var tick_rate: int = 60

## State broadcasts per second. Must divide into [member tick_rate].
##
## Usually lower than the tick rate: simulating at 60 and sending at 20 is standard,
## because interpolation hides the difference and bandwidth is the scarce resource.
## A value that does not divide evenly produces uneven send spacing, which shows up
## as jitter no interpolator can smooth.
@export_range(1, 240, 1) var snapshot_rate: int = 20

## Ticks a client's input timeline runs ahead of the server, beyond half the RTT.
##
## See [DotNetClock]. Higher costs input latency and reduces late commands.
@export_range(0, 20, 1) var input_margin_ticks: int = 2

## Grow the input margin from measured jitter.
@export var adaptive_input_margin: bool = true

@export_group("Interpolation")

## Snapshots of delay before rendering, on top of the snapshot interval.
##
## The buffer that absorbs jitter and loss. One means a single dropped packet causes
## a visible stall; two is the usual compromise. See [DotNetInterpolator].
@export_range(0.0, 10.0, 0.5) var interpolation_buffer: float = 2.0

## Adjust the buffer from observed jitter and loss.
@export var adaptive_interpolation: bool = true

## Longest extrapolation when snapshots stop arriving, in seconds.
##
## Extrapolation is guessing, and it is wrong in a way that produces rubber-banding
## when it is corrected. Past a fifth of a second it is better to stop the entity and
## let it be visibly stale than to send it somewhere it never went.
@export_range(0.0, 1.0, 0.05) var max_extrapolation_sec: float = 0.2

@export_group("Prediction")

## Predict locally-owned entities rather than waiting for the server.
##
## Off means every input has a full round trip of latency before anything moves,
## which is unplayable above about 50 ms.
@export var enable_prediction: bool = true

## Inputs kept for replay during reconciliation.
##
## Must exceed the worst round trip in ticks, or a correction arrives for an input
## already discarded and the client cannot replay from it. 120 at 60 Hz covers a
## 2-second round trip.
@export_range(8, 512, 8) var input_history_ticks: int = 120

## Position error before a predicted entity is corrected, in metres.
##
## Below this the prediction is treated as right, which stops floating-point noise
## from producing constant micro-corrections. Above it the client rewinds and
## replays.
@export_range(0.0, 1.0, 0.001) var reconcile_position_epsilon: float = 0.01

## Smooth a correction over this many seconds instead of snapping.
##
## A snapped correction is a visible teleport. Smoothing hides small ones entirely;
## large ones still need to be visible, which is what
## [member reconcile_snap_distance] is for.
@export_range(0.0, 1.0, 0.01) var reconcile_smooth_sec: float = 0.1

## Error beyond which a correction snaps rather than smoothing.
##
## A large divergence means the prediction was wrong about something structural — a
## collision the client missed, a teleport, a respawn — and smoothing across it drags
## the entity through geometry.
@export_range(0.1, 100.0, 0.1) var reconcile_snap_distance: float = 2.0

@export_group("Lag compensation")

## Rewind the world to a client's view when validating its actions.
##
## What makes hit registration feel right on a laggy connection. The cost is that a
## victim can be hit after they think they reached cover — the standard trade, and
## the reason [member max_rewind_sec] is bounded.
@export var enable_lag_compensation: bool = true

## Longest rewind permitted, in seconds.
##
## Also the ceiling on how far behind a client's claim may be. A client claiming a
## hit 2 seconds in the past is either on a terrible connection or lying, and past
## this the claim is refused rather than honoured.
@export_range(0.0, 2.0, 0.05) var max_rewind_sec: float = 0.5

## Seconds of transform history kept per entity.
##
## Must exceed [member max_rewind_sec] plus the send interval, or a rewind lands
## before the oldest sample.
@export_range(0.1, 5.0, 0.1) var history_sec: float = 1.0

@export_group("World bounds")

## World extent used for position quantisation, in metres from the origin.
##
## [b]Positions outside this are clamped, not wrapped.[/b] Set it to comfortably
## contain your playable space — too small silently pins entities at the boundary,
## too large wastes bits. See [DotNetWriter.write_float_range].
@export var world_extent: float = 2048.0

## Position resolution in metres.
##
## 1 cm is well below what a player can perceive on another character and costs
## about 19 bits per axis over a 4 km world.
@export_range(0.0001, 1.0, 0.0001) var position_step: float = 0.01

## Bits per rotation component in the smallest-three encoding.
@export_range(6, 16, 1) var rotation_bits: int = 9

## Bits per velocity component.
##
## Velocity tolerates more error than position — it is integrated, and the next
## snapshot corrects it — so it gets fewer bits.
@export_range(6, 24, 1) var velocity_bits: int = 12

## Maximum representable speed, in metres per second.
@export var max_speed: float = 100.0

@export_group("Bandwidth")

## Payload bytes per packet before fragmenting.
@export_range(256, 8192, 64) var mtu: int = 1200

## Bytes per second sent to one client. 0 is unlimited.
##
## The budget interest management and prioritisation work within. 64 kB/s is a
## generous allowance for one player; multiply by your player count to size a server.
@export var per_client_budget: int = 65536

## Packets per second to one client. 0 is unlimited.
@export_range(0, 240, 1) var per_client_packet_rate: int = 60

## Snapshots a send may stay unconfirmed before it is resolved without an
## acknowledgement.
##
## The bound on how much unconfirmed state the server tracks per peer. It has to
## exceed the worst round trip the game tolerates — at the default snapshot rate of
## 20 Hz, 32 snapshots is 1.6 seconds — or a healthy client's acknowledgements
## arrive after their sends have already been resolved, and every property is either
## re-sent forever or confirmed without evidence, depending on
## [method DotNetManager.peer_acks_wired].
@export_range(4, 256, 1) var ack_window_snapshots: int = 32

@export_group("Interest management")

## Radius within which entities are always replicated, in metres.
@export var interest_radius: float = 200.0

## Cell size for the grid strategy, in metres.
##
## Should be near [member interest_radius]: much smaller and the query touches many
## cells, much larger and it returns far more than it needs.
@export var interest_cell_size: float = 128.0

## Entities replicated to one client per snapshot, at most. 0 is unlimited.
##
## The backstop when interest management is not enough — a thousand entities in one
## room. Prioritisation decides which ones make the cut.
@export_range(0, 4096, 16) var max_entities_per_snapshot: int = 256

@export_group("Limits")

## Messages one client may send per second before being throttled.
##
## Every client-to-server message costs the server work, so a client that sends a
## thousand a second is either broken or hostile.
@export_range(10, 10000, 10) var client_message_rate: int = 240

## Largest payload accepted from a client, in bytes.
@export_range(256, 65536, 256) var max_client_payload: int = 4096

## Entities one client may be told about at once. 0 is unlimited.
##
## Distinct from [member max_entities_per_snapshot] in intent — what a client may
## know about at all, rather than what fits in one packet — and applied through the
## same [method DotNetInterest.prioritise], because that is what pins
## [member DotNetIdentity.always_relevant] above everything else. See
## [method entity_cap].
@export_range(0, 65536, 64) var max_tracked_entities: int = 4096


func env_prefix() -> String:
	return "DOT_NET_"


func cli_prefix() -> String:
	return "--net-"


func validate() -> DotResult:
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

	# Raised rather than warned about: the history is a derived quantity — twice
	# the rewind, in ticks — and every host that raised the tick rate from the 60 the
	# default was sized for got the warning and nothing else. A correction arriving
	# for an input already discarded is a snap, and a snap is what the warning was
	# failing to prevent.
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


## Interpolation delay in seconds, from the buffer setting.
func interpolation_delay() -> float:
	return interpolation_buffer * snapshot_interval()


## Bits used per position axis, derived from the world size and step.
func position_bits() -> int:
	return DotNetWriter.bits_for_step(
		-world_extent, world_extent, position_step
	)


## Transform history samples kept per entity.
##
## Sized from [member tick_rate] rather than [member snapshot_rate] even though
## history is normally recorded per snapshot. Over-allocating costs a few hundred
## bytes per entity; under-allocating silently drops the oldest samples, so a rewind
## lands on the boundary instead of where the client was looking and every laggy
## player's shots quietly stop registering. One of those failure modes is visible in
## a memory graph and the other is not.
func history_samples() -> int:
	return maxi(2, int(ceilf(history_sec * float(tick_rate))) + 2)


func max_rewind_ticks() -> int:
	return int(max_rewind_sec * float(tick_rate))


## A summary of what the settings cost, for a `net_status` command.
##
## The numbers most likely to be a surprise: how many bits a transform takes and what
## that means per client per second at the configured rates.
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


## The most entities one snapshot may name: the tighter of
## [member max_entities_per_snapshot] and [member max_tracked_entities], where 0
## means "no limit" on either.
##
## [b]Both caps go through prioritisation rather than a slice.[/b] Sorting by score
## and truncating looks equivalent and is not: `prioritise` scores an
## `always_relevant` entity at 1e9 so the objective marker — and the observer's own
## entity — survive a cut that a plain score sort drops. That is the same shape as
## the interest cache that once dropped what the observer owned.
func entity_cap() -> int:
	if max_entities_per_snapshot <= 0:
		return maxi(max_tracked_entities, 0)
	if max_tracked_entities <= 0:
		return max_entities_per_snapshot
	return mini(max_entities_per_snapshot, max_tracked_entities)
