@tool
extends Node

## State and constants of [DotNetManager], in a base so the snapshot code can sit in files of
## their own. Nothing here is used on its own.

const CHANNEL := "net"
const SERVICE := &"dot_net_manager"

## The most parts one snapshot is cut into, and the reason the part trailer is four bits a
## field. Entities that would need a seventeenth wait for the next snapshot.
const MAX_SNAPSHOT_PARTS := 16

## A split snapshot's trailer: the part's index and the part count less one, four bits each.
const SNAPSHOT_PART_TRAILER_BITS := 8

## Where a snapshot's 12-bit entity count starts, after the 32-bit tick.
const SNAPSHOT_COUNT_BIT := 32

## The first byte of a snapshot part's tail when it lists unchanged entities (see
## [code]docs/wire.md#unchanged-entities[/code]). Read by a client from before the tail as a
## part trailer, it is part 15 of 1, which that client refuses as a bad trailer rather than
## misreading; it is never sent to one, but a mistake in that gate fails loudly.
const UNCHANGED_TAIL_MARK := 0x0F

## A tail is the mark, the runs and an always-present part trailer, so at least this many bits
## follow the last entity. A part without one has a trailer of 8 bits or nothing, plus under a
## byte of padding: fewer than this. The receiver tells them apart by what is left.
const UNCHANGED_TAIL_MIN_BITS := 16

## The most entities one tail may list, on a client reading one. A bound on what a hostile
## or broken server can make a client loop over, far above any game's relevant set.
const MAX_UNCHANGED_LISTED := 1 << 16

## The input lead a snapshot part may end with, after its trailer: the least arrival lead
## (signed) and the input tick it was measured on less the snapshot's tick (signed), twelve
## bits each. Only to a client whose schema says [constant
## DotNetMessageRegistry.FEATURE_INPUT_LEAD], and only after a tail, so a part carrying one
## always has the tail form. See [code]docs/wire.md#the-input-lead[/code].
const INPUT_LEAD_FIELD_BITS := 12
const INPUT_LEAD_BITS := 2 * INPUT_LEAD_FIELD_BITS

## Snapshot ticks remembered for [member _seen_ticks]. More than a part arriving behind its
## tick's other parts could plausibly be late by.
const SEEN_TICKS_KEPT := 16

## Emitted each simulation tick, after entities have been simulated.
signal ticked(tick: int)

## Emitted on the server after a snapshot is built and sent.
signal snapshot_sent(tick: int, peer_count: int)

## Emitted on a client when a snapshot has been applied.
signal snapshot_applied(tick: int)

## Emitted when an entity is spawned or despawned, on every peer.
signal entity_spawned(identity: DotNetIdentity)
signal entity_despawned(net_id: int)

## A peer's message schema cannot work with this one: a type one end REQUIRES that the
## other does not have. [param error] is CODE_VERSION with a sentence a player can read.
##
## [b]dot-net cannot act on this and does not try.[/b] It owns no connection, so it cannot
## drop the peer; what it does is stop decoding anything that peer sends. The host is the
## one holding the socket, and a server should disconnect the peer with
## [code]error.message[/code] as the reason -- dot-game's [code]DotGameNetcode[/code] wires
## that to [code]DotServer.kick[/code], and a game building its own manager connects it
## itself. A client needs nothing: the server refuses it with the same sentence.
signal peer_schema_refused(peer_id: int, error: DotError)

@export_group("Role")

## Whether this process is the authority.
@export var is_server: bool = false

## This peer's id. 1 is the server in Godot's numbering.
@export var local_peer_id: int = 1:
	set(value):
		local_peer_id = value
		# The registry keeps its own copy, taken at setup, and decides `is_owner` — and so
		# `is_predicted` — from it when an entity registers. A client that learns its peer
		# id from a handshake after setup (a hello, say) otherwise
		# registers its own occupant as somebody else's, and walks a full round trip behind
		# its own keyboard with every check on a loopback that set the id first passing.
		if registry != null:
			registry.set_local_peer(value)

## Run the tick loop in [method Node._physics_process].
##
## Off when the host drives ticks itself — a dedicated server that already has a
## simulation loop, or a test stepping deterministically.
@export var auto_tick: bool = true

## Suffix for this manager's [DotRegistry] name.
##
## Two managers in one process — a listen server, or a test running both sides —
## would otherwise both claim [code]dot_net_manager[/code] and the second would
## displace the first. Set it to [code]"server"[/code] and [code]"client"[/code] and
## each registers under its own scoped name. See
## [method DotRegistry.register_scoped].
@export var service_scope: StringName = &""

@export_group("Configuration")

@export var config: DotNetConfig = null

@export var config_file: String = "user://dot_net.json"

@export_group("Strategies")

## Interest rule. Defaults to [DotNetInterestDistance].
##
## Swap freely, including at runtime — the cache is invalidated on assignment.
@export var interest: DotNetInterest = null:
	set(value):
		interest = value
		if value != null:
			value.invalidate()

@export_group("Wiring")

## Where to find or create the spawner.
@export var spawner_ref: DotNodeRef = null

var clock: DotNetClock = null
var registry: DotNetRegistry = null
var spawner: DotNetSpawner = null
var messages: DotNetMessageRegistry = null
var budget: DotNetBudget = null
var stats: DotNetStats = null

## Client-side only.
var interpolator: DotNetInterpolator = null
var predictor: DotNetPredictor = null

## Server-side only.
var history: DotNetHistory = null

## How a payload reaches a peer.
##
## Signature: [code]func(peer_id: int, payload: PackedByteArray, delivery: DotNetMessage.Delivery) -> void[/code].
## A peer id of 0 means broadcast. Set by the host; without it the manager simulates
## but sends nothing, which is exactly what a single-player or replay session wants.
var send_fn: Callable = Callable()

## peer_id -> DotNetInput.Buffer, on the server.
var _input_buffers: Dictionary = {}

## Local input history, on a client.
var _local_inputs: DotNetInput.Buffer = null

## net_id -> [identity, tick, values]: the newest snapshot's state for each predicted entity,
## waiting for [method flush_reconcile] ([member DotNetConfig.reconcile_once_per_frame]).
var _pending_reconcile: Dictionary = {}

## Reconciliations a flush saved by keeping only the newest snapshot's, for [method describe].
var _reconciles_coalesced: int = 0

# perf_counters(): running totals, never reset, so any reader can difference two reads.
var _perf_snapshots: int = 0
var _perf_snapshot_usec: int = 0
var _perf_reconciles: int = 0
var _perf_reconcile_usec: int = 0
var _perf_replayed_ticks: int = 0
var _perf_client_ticks: int = 0
var _perf_predict_usec: int = 0
var _perf_server_ticks: int = 0
var _perf_server_sim_usec: int = 0
var _perf_server_send_usec: int = 0

## peer_id -> newest snapshot tick they have acknowledged, on the server.
var _acks: Dictionary = {}

## peer_id -> whether that peer has ever acknowledged anything.
##
## Acknowledgements are optional: this addon does not own the client-to-server path
## (it does not carry inputs either — see [member send_fn]), so whether they arrive
## is up to the host. Until one does for a given peer, an unconfirmed snapshot is
## assumed delivered once it ages out of the window, which is the behaviour every
## host had before [method receive_ack] existed. See [DotNetBehaviour.PeerView].
var _ack_wired: Dictionary = {}

## peer_id -> the newest snapshot tick when the peer was added. Server side.
var _peer_added_tick: Dictionary = {}

## peer_id -> consecutive ticks with no input, and the last input it sent. Server side.
var _starved_ticks: Dictionary = {}
var _last_inputs: Dictionary = {}

## Input tick at which the newest snapshot arrived, and the ticks predicted on a held
## input since (DotNetConfig.prediction_hold_sec). Client side.
var _snapshot_heard_tick := -1
var _held_ticks := 0

## Newest tick a snapshot was built for, on the server.
##
## The bound on what a peer may claim to have acknowledged. An acknowledgement is
## client-controlled, and one naming a tick the server has not reached would promote
## state that was never sent.
var _last_snapshot_tick: int = 0

## Newest snapshot tick applied in full, on a client. What [method ack_tick] reports.
var _applied_snapshot_tick: int = 0

## Client side: the newest snapshot tick any part of which has been read, which parts of it
## have been applied in full (a bitmask), and how many parts it was sent in (0 until a part
## has been read to its end). -1 before any, so a first snapshot at tick 0 is not a repeat.
## See [method receive_snapshot].
var _receiving_tick: int = -1
var _receiving_mask: int = 0
var _receiving_total: int = 0

## Client side: the last few snapshot ticks seen, so a second part of a tick is not counted
## by [DotNetStats] as a repeated or a recovered snapshot.
var _seen_ticks: Array[int] = []

## Server side: snapshots that went out in more than one part, and the largest part sent.
## See [member DotNetConfig.mtu].
var snapshots_split: int = 0
var largest_part_bytes: int = 0

## Server side: entities listed as unchanged rather than written with an empty body, in all,
## and the bytes their headers would have cost (36 bits for a one-behaviour entity, against
## a few bits per run of ids). See [code]docs/wire.md#unchanged-entities[/code].
var unchanged_listed: int = 0
var unchanged_bytes_saved: int = 0

## Server side: snapshot parts that carried a client's input lead. See
## [code]docs/wire.md#the-input-lead[/code].
var input_leads_sent: int = 0

## Whether the one warning about an entity too big for [member DotNetConfig.mtu] on its own
## has been logged. Once per manager: it is a property of the game's declarations, not of
## a moment, and a warning per snapshot would be twenty a second.
var _warned_oversize: bool = false

## Connected peers, on the server.
var _peers: Array[int] = []

## Why the last snapshot was built on this thread when [member DotNetConfig.snapshot_workers]
## asked for workers ("" when it was not), for the one log line per change and for
## [method describe_lines].
var _snapshot_threads_reason: String = "off"
var _snapshot_threads_note: String = ""

## The native snapshot core ([DotNetNative]) while [member DotNetConfig.native] is on and it
## loaded; [member _native_note] is what happened, for [method describe_lines].
var _native: Object = null
var _native_note: String = ""
var _native_tried: bool = false
var _interest_fallback_logged: bool = false

## Snapshots built on workers, and the last one's peers, tasks and fork-to-join time.
var _snapshot_pooled: int = 0
var _snapshot_pooled_peers: int = 0
var _snapshot_pooled_workers: int = 0
var _snapshot_join_usec: int = 0
## Running totals over the pooled snapshots, split where the time goes: the main thread's
## freeze and property reads before the fork, the fork to join, and the apply after it. The
## fork-to-join part is the only one more workers shorten.
var _snapshot_prep_usec_total: int = 0
var _snapshot_join_usec_total: int = 0
var _snapshot_apply_usec_total: int = 0
## Native path only: interest and ranking for every peer (workers included), then handing the
## lists to the core. Both sit between prep and join, and were the unmeasured half of a snapshot.
var _snapshot_interest_usec_total: int = 0
var _snapshot_submit_usec_total: int = 0
## Suites only: a pooled build treats its peer as never having acknowledged anything, so the
## threads-on run must come out different from the threads-off one. What proves the byte
## comparison is armed, and that it compares the pooled path at all.
var _test_skew_pooled: bool = false

var _running: bool = false
var _ticks_since_snapshot: int = 0
var _reassembler := DotNetPacket.Reassembler.new()
var _message_limiter: DotRateLimiter = null


## When [method interpolate_frame] last ran, for the interpolation buffer's rate limit.
var _last_frame_usec: int = 0

## Observers frozen by [method _freeze_job] because they were registered after the tick's
## identity list was read; thawed with the rest.
var _late_frozen: Array[DotNetIdentity] = []


func _observer_for(peer_id: int) -> DotNetIdentity:
	var owned := registry.owned_by(peer_id)
	return owned[0] if not owned.is_empty() else null

