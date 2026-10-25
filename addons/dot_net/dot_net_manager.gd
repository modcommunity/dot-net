@tool
class_name DotNetManager
extends Node

## Drives the netcode. One per network session; place it and it runs.
##
## Owns the tick loop and wires the pieces together — clock, registry, spawner,
## interest, budget, interpolator, predictor, history. Every one of them is reachable
## and replaceable: a game that wants its own interest rule assigns
## [member interest], one that wants a different spawner points
## [member spawner_ref] elsewhere, and one that wants none of the tick loop can call
## [method server_tick] and [method client_tick] itself.
##
## [codeblock]
## var net := DotNetManager.new()
## net.config = my_config
## net.is_server = true
## add_child(net)
##
## net.spawner.register_prefab(&"player", preload("res://player.tscn"))
## net.interest = DotNetInterestGrid.new()
##
## net.messages.register(&"game.chat", ChatMessage)
## net.messages.on(&"game.chat", _on_chat)
##
## net.start(multiplayer_peer)
## [/codeblock]
##
## [b]Transport-agnostic.[/b] It sends through a [Callable] rather than owning a
## socket, so it runs over dot-core's transports, over dot-server's existing
## connection, over Godot's raw multiplayer, or over a loopback in a test. See
## [member send_fn].

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
## Suites only: a pooled build treats its peer as never having acknowledged anything, so the
## threads-on run must come out different from the threads-off one. What proves the byte
## comparison is armed, and that it compares the pooled path at all.
var _test_skew_pooled: bool = false

var _running: bool = false
var _ticks_since_snapshot: int = 0
var _reassembler := DotNetPacket.Reassembler.new()
var _message_limiter: DotRateLimiter = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	DotRegistry.register(_service_name(), self)


func _exit_tree() -> void:
	DotRegistry.unregister_instance(_service_name(), self)


func _service_name() -> StringName:
	return DotRegistry.scoped_name(SERVICE, service_scope)


# --- Lifecycle -------------------------------------------------------------

## Prepares everything. Call before [method start], or let [method start] call it.
func setup() -> DotResult:
	if config == null:
		config = DotNetConfig.new()

	if config_file != "":
		var loaded := config.apply_json_file(config_file)
		if not loaded.ok:
			return loaded

	config.apply_env()
	config.apply_cli()

	var valid := config.validate()
	if not valid.ok:
		return valid

	clock = DotNetClock.new(config.tick_rate, is_server)
	clock.input_margin_ticks = config.input_margin_ticks
	clock.adaptive_margin = config.adaptive_input_margin
	clock.lead_slack_ticks = config.input_lead_slack_ticks

	registry = DotNetRegistry.new(is_server, local_peer_id)
	messages = DotNetMessageRegistry.new()
	messages.peer_refused.connect(_on_peer_refused)
	budget = DotNetBudget.new(config)
	stats = DotNetStats.new()

	if interest == null:
		var distance := DotNetInterestDistance.new()
		distance.radius = config.interest_radius
		distance.far_every = config.far_every
		distance.far_distance = config.far_distance
		interest = distance
	elif interest is DotNetInterestGrid:
		# The config's knob, documented since the first version and applied by
		# nothing: a host that assigned a grid got the grid's own default whatever
		# the config said.
		(interest as DotNetInterestGrid).cell_size = config.interest_cell_size

	if is_server:
		history = DotNetHistory.new(config)
		_message_limiter = DotRateLimiter.new(
			float(config.client_message_rate),
			float(config.client_message_rate)
		)
	else:
		interpolator = DotNetInterpolator.new(config)
		predictor = DotNetPredictor.new(config)
		_local_inputs = DotNetInput.Buffer.new(config.input_history_ticks)

	_resolve_spawner()

	DotLog.info(
		CHANNEL,
		"netcode ready",
		{
			"role": "server" if is_server else "client",
			"tick_rate": config.tick_rate,
			"snapshot_rate": config.snapshot_rate,
			"interest": interest.strategy_name,
		}
	)

	return DotResult.success(self)


func _resolve_spawner() -> void:
	if spawner_ref == null:
		spawner_ref = DotNodeRef.of_created(&"Spawner", DotNetSpawner)

	var resolved := spawner_ref.resolve(self)

	if resolved.ok:
		spawner = resolved.value as DotNetSpawner
	else:
		DotLog.warn(
			CHANNEL, "could not resolve a spawner; creating one",
			{"ref": spawner_ref.describe()}
		)
		spawner = DotNetSpawner.new()
		spawner.name = "Spawner"
		add_child(spawner)

	spawner.setup(registry, config)
	spawner.spawned.connect(func(identity: DotNetIdentity) -> void:
		entity_spawned.emit(identity))
	spawner.despawned.connect(func(net_id: int) -> void:
		_forget_entity(net_id)
		entity_despawned.emit(net_id))


## Starts ticking.
func start() -> DotResult:
	if _running:
		return DotResult.success(self)

	if clock == null:
		var prepared := setup()
		if not prepared.ok:
			return prepared

	messages.seal()
	_running = true

	DotLog.info(
		CHANNEL, "started", {"schema": messages.schema_hash().substr(0, 12)}
	)

	# A client tells the server what it speaks as soon as it can speak at all. The server
	# is the end that decides whether the two can play, and it is told first so that a
	# refusal arrives before anything else the join would have sent.
	if not is_server:
		announce_schema(1)
	for peer_id in _peers:
		announce_schema(peer_id)

	return DotResult.success(self)


## Sends this end's message schema to a peer, through [member send_fn]. See
## [method DotNetMessageRegistry.schema_payload].
##
## [b]Automatic, and callable again.[/b] A server announces to a peer in [method add_peer]
## and a client to the server in [method start], both through [member send_fn] with
## RELIABLE delivery, which every game in this family already routes to its event and
## request calls. A host whose reliable route to a peer did not exist yet at that moment
## -- a client scene built after the server added the peer -- calls this again once it
## does. Adopting a table twice is harmless; the latest one counts.
##
## Nothing is lost if it never arrives: a message's wire id is derived from its type's
## name, so decoding does not wait for the table. What waits for it is the check that
## refuses a peer missing a REQUIRED type.
func announce_schema(peer_id: int) -> bool:
	if not send_fn.is_valid() or messages == null:
		return false

	var payload := messages.schema_payload()
	send_fn.call(peer_id, payload, DotNetMessage.Delivery.RELIABLE)
	stats.note_sent(payload.size(), 1)
	return true


func _on_peer_refused(peer_id: int, error: DotError) -> void:
	DotLog.warn(CHANNEL, "peer cannot play with this schema", {
		"peer": peer_id, "why": error.message, "detail": error.detail,
	})
	peer_schema_refused.emit(peer_id, error)


func stop() -> void:
	_running = false
	_peers.clear()
	_input_buffers.clear()
	_acks.clear()
	_ack_wired.clear()
	_peer_added_tick.clear()
	_starved_ticks.clear()
	_last_inputs.clear()
	_snapshot_heard_tick = -1
	_last_snapshot_tick = 0
	_applied_snapshot_tick = 0
	_receiving_tick = -1
	_receiving_mask = 0
	_receiving_total = 0
	_seen_ticks.clear()
	_pending_reconcile.clear()

	if registry != null:
		registry.clear()
	if interpolator != null:
		interpolator.clear()
	if predictor != null:
		predictor.clear()
	if history != null:
		history.clear()

	DotLog.info(CHANNEL, "stopped")


func is_running() -> bool:
	return _running


# --- Peers -----------------------------------------------------------------

## Registers a connected peer. Server side.
func add_peer(peer_id: int) -> void:
	if _peers.has(peer_id):
		return

	_peers.append(peer_id)
	_input_buffers[peer_id] = DotNetInput.Buffer.new(config.input_history_ticks)
	_acks[peer_id] = 0
	_ack_wired[peer_id] = false
	_peer_added_tick[peer_id] = _last_snapshot_tick
	_starved_ticks[peer_id] = 0

	DotLog.debug(CHANNEL, "peer added", {"peer": peer_id})

	if _running:
		announce_schema(peer_id)


## Ticks in [param seconds], or a number no silence reaches when it is 0 (never hold).
func _hold_ticks(seconds: float) -> int:
	if seconds <= 0.0:
		return 1 << 30
	return maxi(1, ceili(seconds * config.tick_rate))


## Removes a peer and everything it owned.
func remove_peer(peer_id: int) -> Array[DotNetIdentity]:
	_peers.erase(peer_id)
	_input_buffers.erase(peer_id)
	_acks.erase(peer_id)
	_ack_wired.erase(peer_id)
	_peer_added_tick.erase(peer_id)
	_starved_ticks.erase(peer_id)
	_last_inputs.erase(peer_id)

	if messages != null:
		messages.forget_peer(peer_id)

	budget.forget_peer(peer_id)
	interest.forget_peer(peer_id)
	if _native != null:
		_native.forget_peer(peer_id)

	# Every behaviour that ever replicated to this peer holds a record of what it
	# was believed to have. Nothing else will ever clear it, so a server churning
	# through players would grow one per player per behaviour for as long as the
	# entity lives.
	for identity in registry.all():
		for behaviour in identity.behaviours:
			behaviour.forget_peer(peer_id)

	var released := registry.take_owned_by(peer_id)

	DotLog.debug(
		CHANNEL, "peer removed", {"peer": peer_id, "entities": released.size()}
	)

	return released


func peers() -> Array[int]:
	return _peers.duplicate()


func input_buffer_for(peer_id: int) -> DotNetInput.Buffer:
	if not _input_buffers.has(peer_id):
		_input_buffers[peer_id] = DotNetInput.Buffer.new(config.input_history_ticks)
	return _input_buffers[peer_id]


func local_inputs() -> DotNetInput.Buffer:
	return _local_inputs


# --- Tick loop -------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or not _running or not auto_tick:
		return

	# Before step(), and unconditionally: the rolling rates have to close their
	# window even on a frame with no traffic, or a peer that stopped sending
	# keeps reporting the throughput it had when it stopped.
	if stats != null:
		stats.roll()

	step(delta)


## Advances by a frame's worth of time, running as many ticks as are due.
func step(delta: float) -> void:
	var ticks := clock.advance(delta)

	for _i in range(ticks):
		if is_server:
			server_tick(clock.tick)
		else:
			client_tick(clock.tick)

		ticked.emit(clock.tick)


## One authoritative tick: consume input, simulate, record history, maybe send.
func server_tick(tick: int) -> void:
	# [b]The clock follows the tick it is driven at.[/b] A host that ticks this itself
	# (`auto_tick = false`, which is every game in the family) never advanced the server's
	# clock, so `clock.tick` read 0 for the life of the server — and every game's HELLO
	# hands a joiner exactly that number to sync from. The joiner's first input timeline
	# was millions of ticks in the past, every command it sent was discarded as late, and
	# it stayed that way until the first snapshot snapped the clock.
	if is_server:
		clock.tick = maxi(clock.tick, tick)

	var identities := registry.all()

	for peer_id in _peers:
		var buffer: DotNetInput.Buffer = _input_buffers[peer_id]
		var input := buffer.take(tick)

		if input == null:
			# The consumer repeats the last input, so a lost packet keeps the player moving;
			# past the hold it is given that input neutralised, so a blackout does not.
			buffer.note_starved()
			var starved: int = _starved_ticks.get(peer_id, 0) + 1
			_starved_ticks[peer_id] = starved
			if starved > _hold_ticks(config.starved_input_hold_sec) and _last_inputs.has(peer_id):
				_apply_input(peer_id, (_last_inputs[peer_id] as DotNetInput).neutralised(tick), tick)
			continue

		_starved_ticks[peer_id] = 0
		_last_inputs[peer_id] = input
		_apply_input(peer_id, input, tick)

	var step := clock.tick_duration()
	var started := Time.get_ticks_usec()
	_perf_server_ticks += 1

	# [b]The list was taken before anything ran, and a behaviour can change the world.[/b] A
	# round that re-lays its map inside a player's `_net_simulate` unregisters the old map's
	# entities and takes their nodes out of the tree; walking on simulated each of them once
	# more, against a node with no transform (history.md 30: six `!is_inside_tree()` per
	# round in mg-deathrun), and recorded and sent them in this tick's snapshot after a
	# client may already have been told they were gone.
	var changed := false
	for identity in identities:
		if registry.get_identity(identity.net_id) != identity:
			changed = true
			continue
		if not identity.can_simulate():
			continue
		for behaviour in identity.behaviours:
			behaviour._net_simulate(tick, step)

	for identity in identities:
		if changed:
			break
		changed = registry.get_identity(identity.net_id) != identity
	if changed:
		identities = _still_registered(identities)

	var period := config.ticks_per_snapshot()
	var simulated := Time.get_ticks_usec()
	_perf_server_sim_usec += simulated - started

	# Staggered: some peers every tick, each on its own phase. See
	# [member DotNetConfig.stagger_snapshots].
	if config.stagger_snapshots and period > 1:
		history.record(identities, tick)
		_send_snapshots(tick, identities, posmod(tick, period), period)
		_perf_server_send_usec += Time.get_ticks_usec() - simulated
		return

	_ticks_since_snapshot += 1

	if _ticks_since_snapshot >= period:
		_ticks_since_snapshot = 0
		history.record(identities, tick)
		_send_snapshots(tick, identities)
		_perf_server_send_usec += Time.get_ticks_usec() - simulated


## Those of [param identities] still registered as themselves. An entity registered during
## the tick is not added: it is in the next tick's list, as it always was.
func _still_registered(identities: Array[DotNetIdentity]) -> Array[DotNetIdentity]:
	var out: Array[DotNetIdentity] = []
	for identity in identities:
		if registry.get_identity(identity.net_id) == identity:
			out.append(identity)
	return out


## Hands an input to the entities a peer owns.
##
## Sanitised first, on the server, because everything in it came from a client.
func _apply_input(peer_id: int, input: DotNetInput, tick: int) -> void:
	input.sanitise(config.tick_rate)

	for identity in registry.owned_by(peer_id):
		for behaviour in identity.behaviours:
			if behaviour.has_method("_net_apply_input"):
				behaviour.call("_net_apply_input", input, tick)


## One client tick: sample input, predict, interpolate.
func client_tick(tick: int) -> void:
	if not clock.is_synced():
		# Predicting before the clock is aligned produces inputs stamped with ticks
		# the server has already passed, every one of which is discarded.
		return

	flush_reconcile()
	var started := Time.get_ticks_usec()
	predictor.predict(registry.predicted(), tick, clock.tick_duration())
	_perf_predict_usec += Time.get_ticks_usec() - started
	_perf_client_ticks += 1


## One predicted tick for a host that records its own command and simulates it, which is
## what a game with its own [code]client_tick[/code] does (game-arena's bridge): the snapshots
## read since the last tick are reconciled first ([method flush_reconcile]), then every
## predicted entity is handed [param input] and simulated for [param tick].
##
## [b]Through the predictor, not around it.[/b] A host that looped over
## [method DotNetRegistry.predicted] and called [code]_net_simulate[/code] itself predicted
## the same thing, but the predictor never saw those ticks: with
## [member DotNetConfig.skip_matching_replays] nothing they produced was remembered, so a
## snapshot for any tick a replay had not covered could never match and replayed the whole
## lead, and [method perf_counters] said the forward prediction cost nothing. (API 10.)
func predict_tick(tick: int, input: DotNetInput = null) -> void:
	if not clock.is_synced():
		return
	flush_reconcile()
	var started := Time.get_ticks_usec()
	# Neutralised in place: the buffered and sent input is this same object, so the server
	# and the replays see the held one too.
	if input != null and _snapshot_heard_tick >= 0 \
			and tick - _snapshot_heard_tick > _hold_ticks(config.prediction_hold_sec):
		input._neutralise()
		_held_ticks += 1
	# The buffered input is this same object, so its replays run on the rounded one too.
	if input != null and config.predict_wire_input:
		input.round_trip()
	predictor.predict(registry.predicted(), tick, clock.tick_duration(), input)
	_perf_predict_usec += Time.get_ticks_usec() - started
	_perf_client_ticks += 1


## Running totals of what a client spends on the network side of a frame, for a
## frame-time readout (DotMenuNetStat) or a benchmark to difference between two reads.
## Totals rather than per-frame figures because the reader decides the window: a graph
## wants the last second, a benchmark the whole run, and neither can be rebuilt from a
## value that was overwritten every frame. Microseconds of wall-clock time:
## [code]snapshot_usec[/code] reading and applying snapshots (the reconcile included when
## it is not deferred), [code]reconcile_usec[/code] rewinding and replaying the predicted
## entities, [code]replayed_ticks[/code] how many ticks those replays re-simulated (the
## cost that grows with latency: the lead is a round trip of ticks), and
## [code]predict_usec[/code] / [code]client_ticks[/code] the forward prediction.
func perf_counters() -> Dictionary:
	return {
		&"snapshots": _perf_snapshots,
		&"snapshot_usec": _perf_snapshot_usec,
		&"reconciles": _perf_reconciles,
		&"reconcile_usec": _perf_reconcile_usec,
		&"replayed_ticks": _perf_replayed_ticks,
		# Reconciles that found the prediction already right and replayed nothing
		# (DotNetConfig.skip_matching_replays); counted in `reconciles` too.
		&"skipped": predictor.skipped() if predictor != null else 0,
		&"client_ticks": _perf_client_ticks,
		&"predict_usec": _perf_predict_usec,
		# How far the prediction runs ahead of the newest snapshot: what each replay re-runs.
		&"lead_ticks": clock.input_tick() - clock.received_tick() if clock != null else 0,
		# Server side: ticks run, time simulating them (the game's tick runs inside a
		# behaviour's _net_simulate), and time recording history and sending snapshots.
		&"server_ticks": _perf_server_ticks,
		&"server_sim_usec": _perf_server_sim_usec,
		&"server_send_usec": _perf_server_send_usec,
	}


## When [method interpolate_frame] last ran, for the interpolation buffer's rate limit.
var _last_frame_usec: int = 0


## Applies interpolation. Call from [method Node._process], not the tick loop.
##
## Rendering runs at frame rate and simulation at tick rate; interpolating on the
## tick would quantise remote motion to the tick rate and undo the point of it.
##
## [b]Which is what it did, because the tick asked for was a whole one.[/b]
## [method DotNetClock.server_tick] returns an int and only moves inside
## [method DotNetClock.advance], which a host calls from its physics loop — so every
## frame in the same physics step sampled the same instant, and consecutive steps
## sampled instants a whole tick apart. The interpolator did all its work correctly
## between two snapshots and was then asked for the answer at a quantised time, so
## remote players stepped at the tick rate no matter how smoothly they were
## interpolated. Calling this once a frame was necessary and never sufficient.
##
## [param alpha] is how far this frame sits into the current tick. Left negative it is
## [method DotNetClock.render_alpha]: the engine's fraction of the physics frame, plus what
## is left of the last slip. That needs the host to advance the clock once per physics
## frame [b]with the engine's physics rate equal to the tick rate[/b] (a client puts itself
## on the server's rate when it learns it; see `G2GNetBridge._adopt_tick_rate`), and it
## stays right while the clock drifts, where the engine's fraction alone did not: after a
## physics frame that ran no tick the render time went back a tick, and after one that ran
## two forward two (see render_alpha).
##
## A suite that steps by hand and wants the old behaviour passes 0.0.
func interpolate_frame(alpha: float = -1.0) -> void:
	if is_server or interpolator == null or not clock.is_synced():
		return

	flush_reconcile()

	if alpha < 0.0:
		alpha = clock.render_alpha()

	# The buffer follows its target at a bounded rate, on the frame's own time, so it
	# never moves the render time backwards. See DotNetInterpolator._target_snapshots.
	var now_usec := Time.get_ticks_usec()
	var elapsed := 0.0 if _last_frame_usec == 0 else float(now_usec - _last_frame_usec) / 1e6
	_last_frame_usec = now_usec
	interpolator.advance(minf(elapsed, 0.25))

	# The RECEIVE timeline, not the server's tick: an interpolation delay is counted back
	# from the newest snapshot this client holds. Counted from the server's tick it lost
	# the flight time out of the buffer -- see `DotNetClock.render_tick`.
	# -1 to 2, not 0 to 1: the clock's render alpha carries a slip (a physics frame that ran
	# no tick or two) for a moment, and the render time has to keep it or it steps a tick
	# back or forward (see DotNetClock.render_alpha). The receive timeline moved with the
	# same ticks the slip counts.
	# And what the receive timeline moved by re-anchoring that the drawing has not followed
	# yet (DotNetClock.receive_slip): a whole tick at once otherwise.
	var server_tick_now := float(clock.received_tick()) + clampf(alpha, -1.0, 2.0) \
		+ clock.receive_slip()

	for identity in registry.all():
		interpolator.apply(identity, server_tick_now)


# --- Snapshots -------------------------------------------------------------

## Observers frozen by [method _freeze_job] because they were registered after the tick's
## identity list was read; thawed with the rest.
var _late_frozen: Array[DotNetIdentity] = []


## Builds and sends a snapshot to every peer, filtered and prioritised per peer.
## [param phase] and [param period]: only the peers whose id falls on this phase, when
## snapshots are staggered ([member DotNetConfig.stagger_snapshots]); -1 is every peer.
func _send_snapshots(
	tick: int, identities: Array[DotNetIdentity], phase: int = -1, period: int = 1
) -> void:
	# The clock read once for the whole snapshot, for interest's cache and every rate limit:
	# read per peer, two peers either side of a millisecond could be answered differently in
	# one snapshot, and a snapshot built on workers could not be compared with one built here.
	var now_ms := Time.get_ticks_msec()
	var context := {"tick": tick, "config": config, "now_ms": now_ms}
	var prep_started := Time.get_ticks_usec()

	var workers := _snapshot_workers()
	var pooled := workers > 0 and send_fn.is_valid() and not _peers.is_empty()
	var native := _native_for_snapshot()

	# Before [method DotNetInterest._prepare], which reads positions too (a grid indexes
	# them): from here to the thaw every interest question is about one instant. Inline too:
	# a transform read per entity per peer was a third of a 100-player snapshot's interest.
	for identity in identities:
		identity.freeze_position()

	interest._prepare(identities, context)
	interest.index_snapshot(identities)

	_last_snapshot_tick = tick

	# There is deliberately no world-wide baseline snapshot here any more. One was
	# built and stored every snapshot tick — a full read of every replicated property
	# of every entity — against the day whole-snapshot deltas landed, and nothing
	# ever read it. Baselines are per peer instead, and they have to be: interest
	# management means no two peers were sent the same set of entities, so a single
	# world baseline is not a baseline for anybody. See [DotNetBehaviour.PeerView].

	var sent_to := 0

	# Each property read once for this snapshot rather than once per peer; see
	# [member DotNetBehaviour._snapshot_reads]. For workers, read all of them now.
	if native == null:
		for identity in identities:
			for behaviour in identity.behaviours:
				behaviour.begin_snapshot_reads(now_ms, pooled)

	if native != null:
		_snapshot_prep_usec_total += Time.get_ticks_usec() - prep_started
		sent_to = _send_snapshots_native(native, tick, identities, phase, period, context, workers)
	elif pooled:
		_snapshot_prep_usec_total += Time.get_ticks_usec() - prep_started
		sent_to = _send_snapshots_pooled(tick, identities, phase, period, context, workers)
	else:
		for peer_id in _peers:
			if phase >= 0 and posmod(peer_id, period) != phase:
				continue

			budget.begin_tick(peer_id)

			var observer := _observer_for(peer_id)
			var relevant := interest.relevant_for(
				observer, identities, peer_id, context
			)
			if interest.thins():
				var kept: Array[DotNetIdentity] = []
				interest.thin_into(kept, observer, relevant, peer_id, context)
				relevant = kept

			var scores := interest.scores_for(observer, relevant, context)

			# Both caps at once — see [method DotNetConfig.entity_cap]. max_tracked_entities
			# was documented from the first version and enforced by nothing; it is applied
			# HERE rather than by a score sort of our own, because prioritise is what pins
			# always_relevant and a plain sort would cut the observer's own entity.
			relevant = interest.prioritise(
				observer, relevant, config.entity_cap(), context, peer_id, scores
			)
			relevant = budget.accumulate(peer_id, relevant, scores)
			if config.peer_send_budget > 0 and relevant.size() > config.peer_send_budget:
				var kept: Array[DotNetIdentity] = []
				_within_send_budget(kept, relevant, observer)
				relevant = kept

			if _send_to_peer(peer_id, tick, relevant):
				sent_to += 1

	if native == null:
		for identity in identities:
			for behaviour in identity.behaviours:
				behaviour.end_snapshot_reads()

	interest.index_snapshot([])
	for identity in identities:
		identity.thaw_position()
	if pooled or native != null:
		for identity in _late_frozen:
			if is_instance_valid(identity):
				identity.thaw_position()
		_late_frozen.clear()

	snapshot_sent.emit(tick, sent_to)


## The worker count this snapshot is built with: 0 (here, on the calling thread) unless
## [member DotNetConfig.snapshot_workers] asks for workers, [method DotParallel.available] and
## the interest strategy says [method DotNetInterest.is_thread_safe]. The reason it is 0 when
## asked for is logged once per change, and kept for [method describe_lines].
func _snapshot_workers() -> int:
	var reason := ""
	var workers := 0
	if config == null or config.snapshot_workers == 0:
		reason = "off"
	elif not DotParallel.available():
		reason = "no worker threads on this platform"
	elif interest == null or not interest.is_thread_safe():
		reason = "interest strategy %s is not thread-safe" % (
			interest.strategy_name if interest != null else "none")
	else:
		workers = DotParallel.resolve_workers(config.snapshot_workers)
	if reason != _snapshot_threads_reason:
		_snapshot_threads_reason = reason
		if reason != "off" and reason != "":
			_snapshot_threads_note = "snapshots are built inline (%s)" % reason
		elif reason == "":
			_snapshot_threads_note = (
				"snapshot workers active: %d; interest %s pooled; custom DotNetVar codecs pooled"
				% [workers, interest.strategy_name])
		if reason != "off":
			# INFO, once per change: an operator who turned this on wants to see it took or why not.
			DotLog.info(CHANNEL, _snapshot_threads_note, {
				"workers": workers, "asked": config.snapshot_workers if config != null else 0,
			})
	return workers


## The native core for this snapshot, made the first time [member DotNetConfig.native] is on,
## or null for the GDScript path. Turned off, the behaviours it held are handed back.
func _native_for_snapshot() -> Object:
	if config == null or not config.native:
		if _native != null:
			_reset_send_views()
			_native = null
			_native_tried = false
			_native_note = "off"
		return null
	if _native == null and not _native_tried:
		_native_tried = true
		var res := DotNetNative.make_core(config)
		if res.ok:
			_reset_send_views()
			_native = res.value
			_native_note = "on (%s)" % DotNetNative.describe()["from"]
			DotLog.info(CHANNEL, "snapshots are built natively", DotNetNative.describe())
		else:
			_native_note = "asked, GDScript in use: %s" % res.error.message
			DotLog.warn(CHANNEL, "native snapshots asked for but unavailable; GDScript in use",
				{"reason": res.error.message})
	return _native


## Every behaviour's send records dropped, GDScript's and the native core's hold on them: each
## path keeps its own acks, so after a switch the other's are stale and everything is resent.
func _reset_send_views() -> void:
	for identity in registry.all():
		for behaviour in identity.behaviours:
			behaviour._native_core = null
			behaviour._views.clear()


## [method _send_snapshots]'s peers built by [param core]: interest and the budget's ranking
## here (or on [param workers] as the pooled path does), every peer's parts in the core, then
## sent in peer order. The same bytes as either GDScript path.
func _send_snapshots_native(
	core: Object, tick: int, identities: Array[DotNetIdentity], phase: int, period: int,
	context: Dictionary, workers: int
) -> int:
	var oldest_pending: int = tick - config.ack_window_snapshots * config.ticks_per_snapshot()
	core.begin_snapshot(identities, PackedInt64Array([
		tick, int(context["now_ms"]), config.mtu, oldest_pending, workers,
		DotNetIdentity.Authority.SHARED,
	]))
	var jobs: Array[SnapshotJob] = []
	if workers > 0 and send_fn.is_valid():
		for peer_id in _peers:
			if phase >= 0 and posmod(peer_id, period) != phase:
				continue
			budget.begin_tick(peer_id)
			jobs.append(_freeze_job(peer_id, tick))
		if not jobs.is_empty():
			var chunks := mini(workers, jobs.size())
			var cap := config.entity_cap()
			var interest_task := func(chunk: int) -> Array:
				return _interest_chunk(jobs, chunk, chunks, identities, context, cap)
			DotParallel.run(interest_task, chunks, &"net.snapshot", workers)
	else:
		for peer_id in _peers:
			if phase >= 0 and posmod(peer_id, period) != phase:
				continue
			budget.begin_tick(peer_id)
			var observer := _observer_for(peer_id)
			var relevant := interest.relevant_for(observer, identities, peer_id, context)
			if interest.thins():
				var kept: Array[DotNetIdentity] = []
				interest.thin_into(kept, observer, relevant, peer_id, context)
				relevant = kept
			var scores := interest.scores_for(observer, relevant, context)
			relevant = interest.prioritise(
				observer, relevant, config.entity_cap(), context, peer_id, scores
			)
			relevant = budget.accumulate(peer_id, relevant, scores)
			if config.peer_send_budget > 0 and relevant.size() > config.peer_send_budget:
				var kept: Array[DotNetIdentity] = []
				_within_send_budget(kept, relevant, observer)
				relevant = kept
			if not send_fn.is_valid():
				continue
			var job := SnapshotJob.new()
			job.peer_id = peer_id
			if _input_buffers.has(peer_id):
				job.lead = (_input_buffers[peer_id] as DotNetInput.Buffer).take_lead_sample()
			job.send_lead = job.lead.x != DotNetInput.Buffer.LEAD_NONE \
				and messages.peer_supports(peer_id, DotNetMessageRegistry.FEATURE_INPUT_LEAD)
			job.compact = messages.peer_supports(peer_id, DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS)
			job.acked_tick = int(_acks.get(peer_id, 0))
			job.strict = bool(_ack_wired.get(peer_id, false))
			job.remaining_bytes = budget.remaining(peer_id)
			job.peer_budget = budget.for_peer(peer_id)
			job.ordered = relevant
			jobs.append(job)

	for job in jobs:
		core.submit_peer(job.ordered, PackedInt64Array([
			job.peer_id, job.acked_tick, 1 if job.strict else 0, 1 if job.compact else 0,
			job.remaining_bytes, 1 if job.send_lead else 0, job.lead.x, job.lead.y,
		]), job.peer_budget.accumulators, job.peer_budget.starved_ticks)
	var started := Time.get_ticks_usec()
	var results: Array = core.finish_snapshot()
	_snapshot_join_usec = Time.get_ticks_usec() - started
	_snapshot_join_usec_total += _snapshot_join_usec

	var applying := Time.get_ticks_usec()
	for i in results.size():
		var job := jobs[i]
		var r: Array = results[i]
		var peer_id := job.peer_id
		var peer_budget := job.peer_budget
		if not job.answer.is_empty():
			interest.commit_relevance(peer_id, job.answer)
			interest.note_cap(peer_id, job.cap_count, config.entity_cap(), context)
		peer_budget.starved_this_tick += int(r[3])
		peer_budget.total_starved += int(r[3])
		peer_budget.bytes_this_second += int(r[4])
		if bool(r[5]):
			snapshots_split += 1
		unchanged_listed += int(r[6])
		unchanged_bytes_saved += int(r[7])
		input_leads_sent += int(r[8])
		if not _warned_oversize and int(r[9]) >= 0:
			_warned_oversize = true
			var big := registry.get_identity(int(r[9]))
			DotLog.warn(CHANNEL, "an entity's state alone is bigger than the snapshot MTU; it is sent oversized", {
				"net_id": int(r[9]), "prefab": str(big.prefab_id) if big != null else "",
				"bytes": int(r[10]), "mtu": config.mtu,
			})
		var payloads: Array = r[1]
		var counts: PackedInt32Array = r[2]
		for index in payloads.size():
			var payload: PackedByteArray = payloads[index]
			send_fn.call(peer_id, payload, DotNetMessage.Delivery.UNRELIABLE)
			largest_part_bytes = maxi(largest_part_bytes, payload.size())
			budget.note_packet(peer_id, payload.size())
			stats.note_sent(payload.size(), counts[index])
	_snapshot_apply_usec_total += Time.get_ticks_usec() - applying
	return results.size()


## What one peer's snapshot is built from: everything about the peer that lives in a shared
## table or needs this thread, read before the fork.
class SnapshotJob extends RefCounted:
	var peer_id: int = 0
	var observer: DotNetIdentity = null
	var lead := Vector2i(DotNetInput.Buffer.LEAD_NONE, -1)
	var send_lead: bool = false
	var compact: bool = false
	var acked_tick: int = 0
	var strict: bool = false
	var oldest_pending: int = 0
	var remaining_bytes: int = 0
	var peer_budget: DotNetBudget.PeerBudget = null
	## Set by the interest phase ([method _interest_chunk]): what the build writes, in order.
	var ordered: Array = []
	var answer: Array = []
	var cap_count: int = 0


## One peer's snapshot, built and not yet sent: the payloads, and what the build found that
## lives in a table every peer shares, for [method _apply_build] on the manager's thread.
## The peer's own records (its views, its budget) were written by the build itself.
class SnapshotBuild extends RefCounted:
	var peer_id: int = 0
	var payloads: Array[PackedByteArray] = []
	## Entities in each payload, as [DotNetStats] counts them (the unchanged list included).
	var entity_counts: PackedInt32Array = []
	## [method DotNetInterest.relevance]'s answer, to commit.
	var relevance: Array = []
	## Relevant entities before the entity cap, for [method DotNetInterest.note_cap].
	var cap_count: int = 0
	var split: bool = false
	var unchanged_listed: int = 0
	var unchanged_bytes_saved: int = 0
	var input_leads_sent: int = 0
	## The first oversized entity's fields, for the one warning; empty when none was.
	var oversize: Dictionary = {}


## Snapshots for every peer on this phase, built on [param workers] worker threads and sent
## from here in peer order. Returns how many peers were sent one.
##
## [b]Each task writes its own peers' records in place.[/b] A peer's [DotNetBehaviour.PeerView]s
## and its budget record are touched by the one task that owns the peer, so they need no copy;
## what is made here first is every record a build would otherwise insert into a table the
## tasks share (a view for each behaviour and peer, the peer's budget record). An earlier
## version built into copies of the views and installed them afterwards, so that a build could
## be run twice and compared ([member DotParallel.verify]); the copies made each build dearer
## than the inline one and the install cost 4 ms at 32 players and 15 at 64, more than the
## workers saved. The tasks are not pure, so no [code]compare[/code] is given and verify never
## re-runs them: netcode_demo's [snapshot threads] compares a whole game built on workers with
## the same game built inline instead.
##
## [b]One task per worker, never one per peer.[/b] A group task is handed only an item index,
## not which worker runs it, so a per-worker cache cannot be picked by worker; one task owning
## a contiguous run of peers creates its own [DotNetBehaviour.EncodeCache]s and shares each
## entity's encoding among its own peers, which is most of what the cache saved on one thread.
func _send_snapshots_pooled(
	tick: int, identities: Array[DotNetIdentity], phase: int, period: int,
	context: Dictionary, workers: int
) -> int:
	var prep_started := Time.get_ticks_usec()
	var jobs: Array[SnapshotJob] = []
	for peer_id in _peers:
		if phase >= 0 and posmod(peer_id, period) != phase:
			continue
		budget.begin_tick(peer_id)
		jobs.append(_freeze_job(peer_id, tick))

	if jobs.is_empty():
		return 0

	var chunks := mini(workers, jobs.size())
	var cap := config.entity_cap()

	# Interest first, on the workers, so a view is made only for what a peer is sent (as the
	# inline path does) and not for every entity of every peer.
	var interest_task := func(chunk: int) -> Array:
		return _interest_chunk(jobs, chunk, chunks, identities, context, cap)
	DotParallel.run(interest_task, chunks, &"net.snapshot", workers)
	for job in jobs:
		for identity: DotNetIdentity in job.ordered:
			for behaviour in identity.behaviours:
				var _view := behaviour.view_for(job.peer_id)

	var task := func(chunk: int) -> Array:
		return _build_chunk(jobs, chunk, chunks, tick)

	var started := Time.get_ticks_usec()
	_snapshot_prep_usec_total += started - prep_started
	var results := DotParallel.run(task, chunks, &"net.snapshot", workers)
	_snapshot_join_usec = Time.get_ticks_usec() - started
	_snapshot_join_usec_total += _snapshot_join_usec
	_snapshot_pooled += 1
	_snapshot_pooled_peers = jobs.size()
	_snapshot_pooled_workers = chunks

	var sent_to := 0
	var applying := Time.get_ticks_usec()
	for builds: Array in results:
		for build: SnapshotBuild in builds:
			_apply_build(build, context)
			sent_to += 1
	_snapshot_apply_usec_total += Time.get_ticks_usec() - applying
	return sent_to


## Relevance, ranking and the budget's accumulation for peers [code][chunk * n / chunks,
## (chunk + 1) * n / chunks)[/code] of [param jobs], stored on each job. Runs on a worker:
## reads the frozen world and writes only the job and its peer's budget record.
func _interest_chunk(
	jobs: Array[SnapshotJob], chunk: int, chunks: int, identities: Array[DotNetIdentity],
	context: Dictionary, cap: int
) -> Array:
	var from := chunk * jobs.size() / chunks
	var to := (chunk + 1) * jobs.size() / chunks
	for j in range(from, to):
		var job := jobs[j]
		var answer := interest.relevance(job.observer, identities, job.peer_id, context)
		var relevant: Array = answer[0]
		if interest.thins():
			var kept: Array = []
			interest.thin_into(kept, job.observer, relevant, job.peer_id, context)
			relevant = kept

		var scores := interest.scores_for(job.observer, relevant, context)

		job.cap_count = relevant.size()
		relevant = interest.ranked(job.observer, relevant, cap, context, scores)
		if _test_skew_pooled:
			job.acked_tick = 0
		job.ordered = budget.accumulate_record(job.peer_budget, relevant, scores)
		if config.peer_send_budget > 0 and job.ordered.size() > config.peer_send_budget:
			var kept: Array = []
			_within_send_budget(kept, job.ordered, job.observer)
			job.ordered = kept
		job.answer = answer
	return []


## The first [member DotNetConfig.peer_send_budget] of [param ordered] (accumulator order) into
## [param out], and every later one [param observer]'s owner owns. Those left out keep their
## accumulated priority and lead a later snapshot. Reads fields only, so a worker may run it.
func _within_send_budget(out: Array, ordered: Array, observer: DotNetIdentity) -> void:
	var limit := config.peer_send_budget
	var owner := observer.owner_peer_id if observer != null else -1
	for i in ordered.size():
		var identity: DotNetIdentity = ordered[i]
		if i < limit or (owner > 0 and identity.owner_peer_id == owner):
			out.append(identity)


## Builds the snapshots of peers [code][chunk * n / chunks, (chunk + 1) * n / chunks)[/code]
## of [param jobs] from what [method _interest_chunk] stored. Runs on a worker: reads the
## frozen world, and writes only what it creates and its own peers' records.
func _build_chunk(jobs: Array[SnapshotJob], chunk: int, chunks: int, tick: int) -> Array:
	var out: Array = []
	var from := chunk * jobs.size() / chunks
	var to := (chunk + 1) * jobs.size() / chunks
	var caches := {}
	for j in range(from, to):
		var job := jobs[j]
		var build := _build_peer(job, tick, job.ordered, caches)
		build.relevance = job.answer
		build.cap_count = job.cap_count
		out.append(build)
	return out


## The per-peer half of [method _send_snapshots] for a caller that has already filtered,
## prioritised and accumulated [param relevant]: builds the snapshot on this thread, into the
## live records, and sends it.
##
## [b]The path every snapshot takes unless [member DotNetConfig.snapshot_workers] is on, kept
## as it was before workers existed[/b], rather than [method _build_peer] then
## [method _apply_build] with a [SnapshotJob] and a [SnapshotBuild] in between: those cost the
## inline path about 14% at 32 and 64 players (g2gfast's load probe), for a split only the
## pooled path needs. [method _build_peer] is the same build for a worker; a change to one is
## a change to both, and netcode_demo's [snapshot threads] section compares them byte for byte.
func _send_to_peer(
	peer_id: int,
	tick: int,
	relevant: Array[DotNetIdentity]
) -> bool:
	if not send_fn.is_valid():
		return false

	# [b]A snapshot bigger than [member DotNetConfig.mtu] goes out as several parts, each a
	# whole snapshot of its own entities.[/b] Godot's ENet peer fragments an unreliable packet
	# over its MTU (1392 bytes of payload) into unreliable fragments, and losing any one of
	# them loses the whole packet: a two-fragment snapshot is lost about twice as often on a
	# native client, and the one most often lost is the biggest, the one after a round's
	# spawn. Cutting it here instead means a lost part loses only the entities in it, which
	# the acknowledgement path already re-sends. See docs/wire.md#snapshot-parts.
	#
	# The cut is decided before an entity is written, from its exact encoded size
	# ([method DotNetBehaviour.state_bits]), because writing has side effects on the peer's
	# record that cannot be taken back, and the encoding of anything byte-aligned depends on
	# the bit it starts at, so a written entity cannot be moved to another packet afterwards.
	var limit_bits := config.mtu * 8 - SNAPSHOT_PART_TRAILER_BITS

	# How early this peer's commands have been arriving, for its clock to steer by: in every
	# part, so a lost part does not lose it, behind an empty tail where the part has none.
	# Taken whether or not it is sent, so a sample never describes more than one period.
	var lead := Vector2i(DotNetInput.Buffer.LEAD_NONE, -1)
	if _input_buffers.has(peer_id):
		lead = (_input_buffers[peer_id] as DotNetInput.Buffer).take_lead_sample()
	var send_lead := lead.x != DotNetInput.Buffer.LEAD_NONE \
		and messages.peer_supports(peer_id, DotNetMessageRegistry.FEATURE_INPUT_LEAD)
	if send_lead:
		limit_bits -= _unchanged_tail_bits(PackedInt32Array()) + INPUT_LEAD_BITS

	var parts: Array[DotNetWriter] = []
	var counts: PackedInt32Array = []
	var writer := _begin_snapshot_part(tick)
	parts.append(writer)
	counts.append(0)

	var written := 0
	var remaining_bytes := budget.remaining(peer_id)
	var peer_budget := budget.for_peer(peer_id)

	# Entities with nothing to say, listed by id at the end of a part rather than written with
	# an empty body, for a peer that has said it reads the list. See
	# docs/wire.md#unchanged-entities.
	var compact := messages.peer_supports(peer_id, DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS)
	var unchanged: PackedInt32Array = []
	var unchanged_header_bits := 0

	var acked_tick := int(_acks.get(peer_id, 0))
	var strict := bool(_ack_wired.get(peer_id, false))
	# Anything sent longer ago than this is resolved one way or the other, so a peer
	# that stops acknowledging costs a bounded window rather than a growing record.
	var oldest_pending: int = tick - config.ack_window_snapshots * config.ticks_per_snapshot()

	for identity in relevant:
		# The entity this peer predicts. Its client reads a property's absence as "the
		# server's is unchanged" and rewinds to what it last received, so for this entity
		# alone a property stays owed until the peer has confirmed it — see
		# [method DotNetBehaviour.collect_dirty]. One entity per peer, usually.
		var predicted_by_peer := identity.owner_peer_id == peer_id \
			and identity.authority == DotNetIdentity.Authority.SHARED

		var dirties: Array = []
		for behaviour in identity.behaviours:
			# Resolve what this peer has confirmed before deciding what is dirty, so
			# a property whose only send was lost is dirty again and goes out here:
			# sync_peer_acks, trim_pending and collect_dirty, as one call.
			dirties.append(behaviour.collect_for_peer(
				peer_id, acked_tick, strict, oldest_pending, predicted_by_peer))

		if compact:
			var anything := false
			for dirty: Array in dirties:
				if not dirty.is_empty():
					anything = true
					break
			if not anything:
				# Nothing to write, so nothing for the budget or the parts to weigh: it costs
				# its share of a run of ids. It still counts as served, for the accumulator.
				unchanged.append(identity.net_id)
				unchanged_header_bits += DotNetRegistry.ID_BITS + 6 + 6 * identity.behaviours.size()
				budget.note_sent(peer_id, identity.net_id, 0)
				continue

		# A full update's guess, for the budget and the part cut: only for an entity being written.
		var estimated := 0
		for behaviour in identity.behaviours:
			estimated += behaviour.estimated_bits(peer_id)
		estimated = (estimated + 7) >> 3

		# After the dirty check, not before: an entity with nothing to say is not one the
		# budget needs to hold back. Resolving acks first for one that is then held back is
		# harmless -- the same resolution happens next snapshot either way.
		if written > 0 and estimated > remaining_bytes:
			budget.note_starved(peer_id)
			continue

		# Measured only near the end of a part: an entity is rarely more than twice its full
		# update's estimate plus 32 bytes (only a long string or a custom codec could be), and
		# the exact figure is a lookup per behaviour per entity per peer, which at 64 players
		# is four thousand a snapshot for an answer that is "it fits" nearly every time.
		if counts[counts.size() - 1] > 0 \
				and writer.bit_length() + estimated * 16 + 256 > limit_bits \
				and _entity_end_bit(writer.bit_length(), identity, dirties) > limit_bits:
			if parts.size() >= MAX_SNAPSHOT_PARTS:
				# Out of parts: what does not fit waits, exactly as the budget makes it wait,
				# and the accumulator puts it at the front next time.
				budget.note_starved(peer_id)
				continue
			writer = _begin_snapshot_part(tick)
			parts.append(writer)
			counts.append(0)

		var before := writer.byte_length()

		# The id and then the behaviour count, as one field: bits are written low first, so
		# this is the same bits as the two writes, for one call per entity per peer.
		writer.write_bits(identity.net_id & ((1 << DotNetRegistry.ID_BITS) - 1) \
			| ((identity.behaviours.size() & 0x3F) << DotNetRegistry.ID_BITS),
			DotNetRegistry.ID_BITS + 6)

		for b in identity.behaviours.size():
			identity.behaviours[b].write_state(writer, dirties[b], peer_id, tick)

		if not _warned_oversize and writer.bit_length() > limit_bits:
			_warned_oversize = true
			DotLog.warn(CHANNEL, "an entity's state alone is bigger than the snapshot MTU; it is sent oversized", {
				"net_id": identity.net_id,
				"prefab": str(identity.prefab_id),
				"bytes": (writer.bit_length() + 7) >> 3,
				"mtu": config.mtu,
			})

		var spent := writer.byte_length() - before
		remaining_bytes -= spent
		# budget.note_sent, inlined: a call and a lookup of the same record per entity.
		peer_budget.accumulators[identity.net_id] = 0.0
		peer_budget.starved_ticks[identity.net_id] = 0
		peer_budget.bytes_this_second += spent
		counts[counts.size() - 1] += 1
		written += 1

	# A part that ended up empty (only possible as the last, when everything after the cut
	# was starved) is not sent: a part with no entities would still be a part the client
	# waits for before it acknowledges the tick. The first part is kept even when empty: a
	# snapshot of nothing still goes out, see below.
	if parts.size() > 1 and counts[counts.size() - 1] == 0:
		parts.pop_back()
		counts.remove_at(counts.size() - 1)

	# [b]A snapshot goes out every snapshot tick, even with nothing in it.[/b] It is the
	# client's clock: `sync_from_server`, the receive timeline and the interpolation buffer are
	# all fed from snapshot arrivals, and the acknowledgement that resolves what is pending
	# rides on a snapshot applied. When every relevant entity was written each time this could
	# only be empty with nothing relevant; now that unchanged entities cost a few bits, a quiet
	# world is a small snapshot, never a missing one. Six bytes, read by every client version.

	# The unchanged list goes at the end of the last part when it fits there, else in a part of
	# its own, else (sixteen parts already) not at all: those entities then miss one refresh,
	# exactly as a starved entity does.
	var tail_part := -1
	var runs := _unchanged_runs(unchanged)
	if not runs.is_empty():
		var tail_bits := _unchanged_tail_bits(runs)
		if parts[parts.size() - 1].bit_length() + tail_bits <= limit_bits + SNAPSHOT_PART_TRAILER_BITS:
			tail_part = parts.size() - 1
		elif parts.size() < MAX_SNAPSHOT_PARTS:
			parts.append(_begin_snapshot_part(tick))
			counts.append(0)
			tail_part = parts.size() - 1
		else:
			budget.note_starved(peer_id)
		if tail_part >= 0:
			unchanged_listed += unchanged.size()
			unchanged_bytes_saved += maxi(0, (unchanged_header_bits - tail_bits) >> 3)

	var total := parts.size()
	if total > 1:
		snapshots_split += 1

	for index in total:
		var part := parts[index]
		# Only a split snapshot carries the trailer, so one that fits is byte for byte what
		# this addon sent before parts existed -- unless it lists unchanged entities, whose tail
		# always ends in one.
		if index == tail_part:
			_write_unchanged_tail(part, runs)
			part.write_uint(index, 4)
			part.write_uint(total - 1, 4)
		elif send_lead:
			_write_unchanged_tail(part, PackedInt32Array())
			part.write_uint(index, 4)
			part.write_uint(total - 1, 4)
		elif total > 1:
			part.write_uint(index, 4)
			part.write_uint(total - 1, 4)

		if send_lead:
			var span := 1 << (INPUT_LEAD_FIELD_BITS - 1)
			part.write_int(clampi(lead.x, -span, span - 1), INPUT_LEAD_FIELD_BITS)
			part.write_int(clampi(lead.y - tick, -span, span - 1), INPUT_LEAD_FIELD_BITS)
			input_leads_sent += 1

		var payload := part.to_bytes()

		# Patch the count in now that it is known. The header is byte-aligned by
		# construction, so this is a plain byte edit rather than a bit splice.
		var count_byte := SNAPSHOT_COUNT_BIT >> 3
		var count := counts[index]
		if count_byte + 1 < payload.size():
			payload[count_byte] = count & 0xFF
			payload[count_byte + 1] = (payload[count_byte + 1] & 0xF0) | ((count >> 8) & 0x0F)

		send_fn.call(peer_id, payload, DotNetMessage.Delivery.UNRELIABLE)

		largest_part_bytes = maxi(largest_part_bytes, payload.size())
		budget.note_packet(peer_id, payload.size())
		stats.note_sent(payload.size(), count + (unchanged.size() if index == tail_part else 0))

	return true


## Everything [method _build_peer] needs from shared tables and from this thread.
func _freeze_job(peer_id: int, tick: int) -> SnapshotJob:
	var job := SnapshotJob.new()
	job.peer_id = peer_id
	job.observer = _observer_for(peer_id)
	# [b]The observer may not be in [code]identities[/code][/b], which was read before input
	# and simulation: a peer's first entity registered during this tick (a join, a respawn) is
	# found by [method _observer_for] but was never frozen, and interest would read its
	# [code]global_position[/code] on a worker. Frozen here, on the main thread.
	if job.observer != null and not job.observer.is_position_frozen():
		job.observer.freeze_position()
		_late_frozen.append(job.observer)

	# How early this peer's commands have been arriving, for its clock to steer by: in every
	# part, so a lost part does not lose it, behind an empty tail where the part has none.
	# Taken whether or not it is sent, so a sample never describes more than one period.
	if _input_buffers.has(peer_id):
		job.lead = (_input_buffers[peer_id] as DotNetInput.Buffer).take_lead_sample()
	job.send_lead = job.lead.x != DotNetInput.Buffer.LEAD_NONE \
		and messages.peer_supports(peer_id, DotNetMessageRegistry.FEATURE_INPUT_LEAD)

	# Entities with nothing to say, listed by id at the end of a part rather than written with
	# an empty body, for a peer that has said it reads the list. See
	# docs/wire.md#unchanged-entities.
	job.compact = messages.peer_supports(peer_id, DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS)

	job.acked_tick = int(_acks.get(peer_id, 0))
	job.strict = bool(_ack_wired.get(peer_id, false))
	# Anything sent longer ago than this is resolved one way or the other, so a peer
	# that stops acknowledging costs a bounded window rather than a growing record.
	job.oldest_pending = tick - config.ack_window_snapshots * config.ticks_per_snapshot()
	job.remaining_bytes = budget.remaining(peer_id)
	job.peer_budget = budget.for_peer(peer_id)
	return job


## [method _send_to_peer] on a worker: one peer's snapshot parts, built into the peer's live
## [DotNetBehaviour.PeerView]s and budget record (made before the fork, and touched by no other
## task, since each peer belongs to one), with [param caches] (behaviour ->
## [DotNetBehaviour.EncodeCache]) the task's own memo. Everything shared (the counters, the
## interest cache, the log, the send) comes back in the build for [method _apply_build].
## A copy of [method _send_to_peer], not a generalisation of it: see that method.
func _build_peer(
	job: SnapshotJob,
	tick: int,
	relevant: Array,
	caches: Dictionary
) -> SnapshotBuild:
	var build := SnapshotBuild.new()
	var peer_id := job.peer_id
	build.peer_id = peer_id
	var peer_budget := job.peer_budget

	# [b]A snapshot bigger than [member DotNetConfig.mtu] goes out as several parts, each a
	# whole snapshot of its own entities.[/b] Godot's ENet peer fragments an unreliable packet
	# over its MTU (1392 bytes of payload) into unreliable fragments, and losing any one of
	# them loses the whole packet: a two-fragment snapshot is lost about twice as often on a
	# native client, and the one most often lost is the biggest, the one after a round's
	# spawn. Cutting it here instead means a lost part loses only the entities in it, which
	# the acknowledgement path already re-sends. See docs/wire.md#snapshot-parts.
	#
	# The cut is decided before an entity is written, from its exact encoded size
	# ([method DotNetBehaviour.state_bits]), because writing has side effects on the peer's
	# record that cannot be taken back, and the encoding of anything byte-aligned depends on
	# the bit it starts at, so a written entity cannot be moved to another packet afterwards.
	var limit_bits := config.mtu * 8 - SNAPSHOT_PART_TRAILER_BITS

	var lead := job.lead
	var send_lead := job.send_lead
	if send_lead:
		limit_bits -= _unchanged_tail_bits(PackedInt32Array()) + INPUT_LEAD_BITS

	var parts: Array[DotNetWriter] = []
	var counts: PackedInt32Array = []
	var writer := _begin_snapshot_part(tick)
	parts.append(writer)
	counts.append(0)

	var written := 0
	var remaining_bytes := job.remaining_bytes

	var compact := job.compact
	var unchanged: PackedInt32Array = []
	var unchanged_header_bits := 0

	var acked_tick := job.acked_tick
	var strict := job.strict
	var oldest_pending := job.oldest_pending

	var starved := 0
	var entity_views: Array = []
	var entity_caches: Array = []

	for identity: DotNetIdentity in relevant:
		# The entity this peer predicts. Its client reads a property's absence as "the
		# server's is unchanged" and rewinds to what it last received, so for this entity
		# alone a property stays owed until the peer has confirmed it — see
		# [method DotNetBehaviour.collect_dirty]. One entity per peer, usually.
		var predicted_by_peer := identity.owner_peer_id == peer_id \
			and identity.authority == DotNetIdentity.Authority.SHARED

		var dirties: Array = []
		entity_views.clear()
		entity_caches.clear()
		for behaviour in identity.behaviours:
			# Made on the manager's thread before the fork ([method _send_snapshots_pooled]):
			# a read here, never an insert into the behaviour's shared table.
			var view: DotNetBehaviour.PeerView = behaviour._views[peer_id]
			var cache: DotNetBehaviour.EncodeCache = caches.get(behaviour)
			if cache == null:
				cache = DotNetBehaviour.EncodeCache.new()
				caches[behaviour] = cache
			entity_views.append(view)
			entity_caches.append(cache)
			# Resolve what this peer has confirmed before deciding what is dirty, so
			# a property whose only send was lost is dirty again and goes out here:
			# sync_peer_acks, trim_pending and collect_dirty, as one call.
			dirties.append(behaviour.collect_for_view(
				view, peer_id, acked_tick, strict, oldest_pending, predicted_by_peer, cache))

		if compact:
			var anything := false
			for dirty: Array in dirties:
				if not dirty.is_empty():
					anything = true
					break
			if not anything:
				# Nothing to write, so nothing for the budget or the parts to weigh: it costs
				# its share of a run of ids. It still counts as served, for the accumulator.
				unchanged.append(identity.net_id)
				unchanged_header_bits += DotNetRegistry.ID_BITS + 6 + 6 * identity.behaviours.size()
				peer_budget.accumulators[identity.net_id] = 0.0
				peer_budget.starved_ticks[identity.net_id] = 0
				continue

		# A full update's guess, for the budget and the part cut: only for an entity being written.
		var estimated := 0
		for behaviour in identity.behaviours:
			estimated += behaviour.estimated_bits(peer_id)
		estimated = (estimated + 7) >> 3

		# After the dirty check, not before: an entity with nothing to say is not one the
		# budget needs to hold back. Resolving acks first for one that is then held back is
		# harmless -- the same resolution happens next snapshot either way.
		if written > 0 and estimated > remaining_bytes:
			starved += 1
			continue

		# Measured only near the end of a part: an entity is rarely more than twice its full
		# update's estimate plus 32 bytes (only a long string or a custom codec could be), and
		# the exact figure is a lookup per behaviour per entity per peer, which at 64 players
		# is four thousand a snapshot for an answer that is "it fits" nearly every time.
		if counts[counts.size() - 1] > 0 \
				and writer.bit_length() + estimated * 16 + 256 > limit_bits \
				and _entity_end_bit_cached(writer.bit_length(), identity, dirties, entity_caches) > limit_bits:
			if parts.size() >= MAX_SNAPSHOT_PARTS:
				# Out of parts: what does not fit waits, exactly as the budget makes it wait,
				# and the accumulator puts it at the front next time.
				starved += 1
				continue
			writer = _begin_snapshot_part(tick)
			parts.append(writer)
			counts.append(0)

		var before := writer.byte_length()

		# The id and then the behaviour count, as one field: bits are written low first, so
		# this is the same bits as the two writes, for one call per entity per peer.
		writer.write_bits(identity.net_id & ((1 << DotNetRegistry.ID_BITS) - 1) \
			| ((identity.behaviours.size() & 0x3F) << DotNetRegistry.ID_BITS),
			DotNetRegistry.ID_BITS + 6)

		for b in identity.behaviours.size():
			identity.behaviours[b].write_for_view(
				writer, dirties[b], entity_views[b], tick, entity_caches[b])

		if writer.bit_length() > limit_bits and build.oversize.is_empty():
			build.oversize = {
				"net_id": identity.net_id,
				"prefab": str(identity.prefab_id),
				"bytes": (writer.bit_length() + 7) >> 3,
				"mtu": config.mtu,
			}

		var spent := writer.byte_length() - before
		remaining_bytes -= spent
		peer_budget.accumulators[identity.net_id] = 0.0
		peer_budget.starved_ticks[identity.net_id] = 0
		peer_budget.bytes_this_second += spent
		counts[counts.size() - 1] += 1
		written += 1

	# A part that ended up empty (only possible as the last, when everything after the cut
	# was starved) is not sent: a part with no entities would still be a part the client
	# waits for before it acknowledges the tick. The first part is kept even when empty: a
	# snapshot of nothing still goes out, see below.
	if parts.size() > 1 and counts[counts.size() - 1] == 0:
		parts.pop_back()
		counts.remove_at(counts.size() - 1)

	# [b]A snapshot goes out every snapshot tick, even with nothing in it.[/b] It is the
	# client's clock: `sync_from_server`, the receive timeline and the interpolation buffer are
	# all fed from snapshot arrivals, and the acknowledgement that resolves what is pending
	# rides on a snapshot applied. When every relevant entity was written each time this could
	# only be empty with nothing relevant; now that unchanged entities cost a few bits, a quiet
	# world is a small snapshot, never a missing one. Six bytes, read by every client version.

	# The unchanged list goes at the end of the last part when it fits there, else in a part of
	# its own, else (sixteen parts already) not at all: those entities then miss one refresh,
	# exactly as a starved entity does.
	var tail_part := -1
	var runs := _unchanged_runs(unchanged)
	if not runs.is_empty():
		var tail_bits := _unchanged_tail_bits(runs)
		if parts[parts.size() - 1].bit_length() + tail_bits <= limit_bits + SNAPSHOT_PART_TRAILER_BITS:
			tail_part = parts.size() - 1
		elif parts.size() < MAX_SNAPSHOT_PARTS:
			parts.append(_begin_snapshot_part(tick))
			counts.append(0)
			tail_part = parts.size() - 1
		else:
			starved += 1
		if tail_part >= 0:
			build.unchanged_listed += unchanged.size()
			build.unchanged_bytes_saved += maxi(0, (unchanged_header_bits - tail_bits) >> 3)

	var total := parts.size()
	build.split = total > 1

	for index in total:
		var part := parts[index]
		# Only a split snapshot carries the trailer, so one that fits is byte for byte what
		# this addon sent before parts existed -- unless it lists unchanged entities, whose tail
		# always ends in one.
		if index == tail_part:
			_write_unchanged_tail(part, runs)
			part.write_uint(index, 4)
			part.write_uint(total - 1, 4)
		elif send_lead:
			_write_unchanged_tail(part, PackedInt32Array())
			part.write_uint(index, 4)
			part.write_uint(total - 1, 4)
		elif total > 1:
			part.write_uint(index, 4)
			part.write_uint(total - 1, 4)

		if send_lead:
			var span := 1 << (INPUT_LEAD_FIELD_BITS - 1)
			part.write_int(clampi(lead.x, -span, span - 1), INPUT_LEAD_FIELD_BITS)
			part.write_int(clampi(lead.y - tick, -span, span - 1), INPUT_LEAD_FIELD_BITS)
			build.input_leads_sent += 1

		var payload := part.to_bytes()

		# Patch the count in now that it is known. The header is byte-aligned by
		# construction, so this is a plain byte edit rather than a bit splice.
		var count_byte := SNAPSHOT_COUNT_BIT >> 3
		var count := counts[index]
		if count_byte + 1 < payload.size():
			payload[count_byte] = count & 0xFF
			payload[count_byte + 1] = (payload[count_byte + 1] & 0xF0) | ((count >> 8) & 0x0F)

		build.payloads.append(payload)
		build.entity_counts.append(count + (unchanged.size() if index == tail_part else 0))

	peer_budget.starved_this_tick += starved
	peer_budget.total_starved += starved
	return build


## Makes [param build]'s shared changes and sends its parts. The manager's thread, in peer order.
func _apply_build(build: SnapshotBuild, context: Dictionary) -> void:
	var peer_id := build.peer_id

	interest.commit_relevance(peer_id, build.relevance)
	interest.note_cap(peer_id, build.cap_count, config.entity_cap(), context)

	if not _warned_oversize and not build.oversize.is_empty():
		_warned_oversize = true
		DotLog.warn(CHANNEL, "an entity's state alone is bigger than the snapshot MTU; it is sent oversized",
			build.oversize)

	if build.split:
		snapshots_split += 1
	unchanged_listed += build.unchanged_listed
	unchanged_bytes_saved += build.unchanged_bytes_saved
	input_leads_sent += build.input_leads_sent

	for index in build.payloads.size():
		var payload := build.payloads[index]
		send_fn.call(peer_id, payload, DotNetMessage.Delivery.UNRELIABLE)
		largest_part_bytes = maxi(largest_part_bytes, payload.size())
		budget.note_packet(peer_id, payload.size())
		stats.note_sent(payload.size(), build.entity_counts[index])


## [param ids] (in the order they were served) as runs of consecutive ids, sorted:
## [code][start, length, start, length, ...][/code].
static func _unchanged_runs(ids: PackedInt32Array) -> PackedInt32Array:
	var out: PackedInt32Array = []
	if ids.is_empty():
		return out
	var sorted := ids.duplicate()
	sorted.sort()
	var start := sorted[0]
	var length := 1
	for i in range(1, sorted.size()):
		var id := sorted[i]
		if id == start + length:
			length += 1
		elif id >= start + length:
			out.append(start)
			out.append(length)
			start = id
			length = 1
	out.append(start)
	out.append(length)
	return out


## Bits [method _write_unchanged_tail] writes for [param runs], plus the part trailer after it.
static func _unchanged_tail_bits(runs: PackedInt32Array) -> int:
	var bits := 8 + _gamma_bits(runs.size() >> 1) + SNAPSHOT_PART_TRAILER_BITS
	var cursor := 0
	for i in range(0, runs.size(), 2):
		bits += _gamma_bits(runs[i] - cursor) + _gamma_bits(runs[i + 1] - 1)
		cursor = runs[i] + runs[i + 1]
	return bits


## The mark, the number of runs, and each run as the gap from the end of the one before and
## its length less one, all Elias gamma: a contiguous block of ids costs a few bits whatever
## its size, a scattered set a few bits an entity. See docs/wire.md#unchanged-entities.
static func _write_unchanged_tail(writer: DotNetWriter, runs: PackedInt32Array) -> void:
	writer.write_uint(UNCHANGED_TAIL_MARK, 8)
	_write_gamma(writer, runs.size() >> 1)
	var cursor := 0
	for i in range(0, runs.size(), 2):
		_write_gamma(writer, runs[i] - cursor)
		_write_gamma(writer, runs[i + 1] - 1)
		cursor = runs[i] + runs[i + 1]


## Elias gamma of [code]value + 1[/code], so zero is one bit: as many zero bits as the number
## has bits after its leading one, then the number from its leading one down. Written
## most-significant bit first, one bit at a time, because the reader counts zeros to learn
## the width.
static func _write_gamma(writer: DotNetWriter, value: int) -> void:
	var n := value + 1
	var width := 0
	while (n >> (width + 1)) != 0:
		width += 1
	if width > 0:
		writer.write_bits(0, width)
	for bit in range(width, -1, -1):
		writer.write_bits((n >> bit) & 1, 1)


static func _gamma_bits(value: int) -> int:
	var n := value + 1
	var width := 0
	while (n >> (width + 1)) != 0:
		width += 1
	return 2 * width + 1


## The reader's half of [method _write_gamma]. -1, with the reader failed or not, for a width
## past [constant DotNetRegistry.ID_BITS]: no id, gap or run needs more, and a stream of zeros
## from a broken packet must not become a long loop.
static func _read_gamma(reader: DotNetReader) -> int:
	var width := 0
	while reader.read_bits(1) == 0:
		if not reader.ok():
			return -1
		width += 1
		if width > DotNetRegistry.ID_BITS:
			return -1
	var n := 1
	for _i in width:
		n = (n << 1) | reader.read_bits(1)
	if not reader.ok():
		return -1
	return n - 1


## A snapshot part's header: the tick, and a count patched in once the entities are written.
## Writing the count first would mean guessing how many fit.
func _begin_snapshot_part(tick: int) -> DotNetWriter:
	var writer := DotNetWriter.new()
	writer.write_uint(tick, 32)
	writer.write_uint(0, 12)
	return writer


## Where an entity would end if written at [param from_bit] with [param dirties] (one array of
## declarations per behaviour), exactly. Each behaviour's encoding depends on the bit of a
## byte it starts at, so they are measured in order.
func _entity_end_bit(from_bit: int, identity: DotNetIdentity, dirties: Array) -> int:
	var at := from_bit + DotNetRegistry.ID_BITS + 6
	for b in identity.behaviours.size():
		at += identity.behaviours[b].state_bits(dirties[b], at & 7)
	return at


## [method _entity_end_bit] with each behaviour's [DotNetBehaviour.EncodeCache], for
## [method _build_peer].
func _entity_end_bit_cached(
	from_bit: int, identity: DotNetIdentity, dirties: Array, caches: Array
) -> int:
	var at := from_bit + DotNetRegistry.ID_BITS + 6
	for b in identity.behaviours.size():
		at += identity.behaviours[b].state_bits_cached(dirties[b], at & 7, caches[b])
	return at


## Applies a snapshot payload. Client side.
func receive_snapshot(payload: PackedByteArray) -> DotResult:
	var started := Time.get_ticks_usec()
	var result := _receive_snapshot(payload)
	if result.ok:
		_snapshot_heard_tick = clock.input_tick()
	_perf_snapshot_usec += Time.get_ticks_usec() - started
	_perf_snapshots += 1
	return result


func _receive_snapshot(payload: PackedByteArray) -> DotResult:
	if is_server:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "A server does not receive snapshots."
		)

	stats.note_received(payload.size())

	var reader := DotNetReader.new(payload)

	var tick := reader.read_uint(32)
	var count := reader.read_uint(12)

	if not reader.ok():
		stats.note_decode_failure()
		return DotResult.fail(DotError.CODE_PARSE, "Truncated snapshot header.")

	# In snapshots, not ticks: a gap of one period is no loss at all. Set every time,
	# because a client adopts the server's tick rate after it started.
	stats.snapshot_interval_ticks = config.ticks_per_snapshot()

	# Once per tick, not once per part: the second part of a snapshot is neither a repeat
	# nor a late arrival making up for a loss. See [member _seen_ticks].
	if not _seen_ticks.has(tick):
		_seen_ticks.append(tick)
		if _seen_ticks.size() > SEEN_TICKS_KEPT:
			_seen_ticks.pop_front()
		stats.note_snapshot(tick)

	if tick < _receiving_tick:
		# Older than one already read. Snapshots carry state, not events, so a late one
		# is not merely out of order — it is superseded, and applying it would write a
		# stale value over a newer one for every property the interpolator does not own.
		# The clock is not fed from it either: an arrival time attached to an old tick
		# reads as a sudden lead. A late PART of an older tick is superseded the same way;
		# what it carried is re-sent, because the tick it belongs to is never acknowledged.
		return DotResult.success(_applied_snapshot_tick)

	if tick == _receiving_tick and _applied_snapshot_tick == tick:
		# Every part of this tick is in: anything more is a repeat. (A repeat of one part of
		# a tick still missing another is applied again, which writes the same values; it
		# cannot be told from the missing part until its trailer is read.)
		return DotResult.success(_applied_snapshot_tick)

	if tick > _receiving_tick:
		_receiving_tick = tick
		_receiving_mask = 0
		_receiving_total = 0
		# The first part of a tick to arrive is the snapshot's arrival, for timing. A
		# second part is the same send, a few microseconds later.
		interpolator.note_arrival()
		clock.sync_from_server(tick, stats.rtt_percentile(0.5))
		interpolator.note_lateness(tick, clock.received_tick())

	for _i in range(count):
		var net_id := reader.read_uint(DotNetRegistry.ID_BITS)
		var behaviour_count := reader.read_uint(6)

		if not reader.ok():
			stats.note_decode_failure()
			return DotResult.fail(DotError.CODE_PARSE, "Truncated snapshot entry.")

		var identity := registry.get_identity(net_id)

		if identity == null:
			# Either an entity we have not been told to spawn yet, or one already
			# despawned. Both are normal in flight; neither is recoverable here,
			# because skipping a variable-length body needs the declarations.
			if not registry.was_recently_removed(net_id):
				DotLog.debug(
					CHANNEL, "state for an unknown entity", {"net_id": net_id}
				)
			return DotResult.success(tick)

		var applied := _apply_entity(identity, tick, reader, behaviour_count)
		if not applied.ok:
			stats.note_decode_failure()
			return applied

	# Which part this was, and whether it lists unchanged entities. Only a split snapshot, or
	# one with an unchanged list, has anything after its entities (see [method _send_to_peer]):
	# what is left of any other is under a byte of padding, a bare trailer is 8 bits more, and
	# a tail is the mark, the runs and a trailer, at least UNCHANGED_TAIL_MIN_BITS.
	var part := 0
	var total := 1
	if reader.bits_remaining() >= UNCHANGED_TAIL_MIN_BITS:
		var listed := _apply_unchanged_tail(reader, tick)
		if not listed.ok:
			stats.note_decode_failure()
			return listed
		part = reader.read_uint(4)
		total = reader.read_uint(4) + 1
		if not reader.ok() or part >= total:
			stats.note_decode_failure()
			return DotResult.fail(
				DotError.CODE_PARSE, "Bad snapshot part trailer.",
				"part %d of %d" % [part, total]
			)
		# What follows a tail's trailer is under a byte of padding, or the input lead: how
		# early this client's commands are reaching the server. See [method
		# DotNetClock.note_input_lead].
		if reader.bits_remaining() >= INPUT_LEAD_BITS:
			var arrival := reader.read_int(INPUT_LEAD_FIELD_BITS)
			var input_tick := tick + reader.read_int(INPUT_LEAD_FIELD_BITS)
			if reader.ok():
				clock.note_input_lead(input_tick, arrival)
	elif reader.bits_remaining() >= SNAPSHOT_PART_TRAILER_BITS:
		part = reader.read_uint(4)
		total = reader.read_uint(4) + 1
		if not reader.ok() or total < 2 or part >= total:
			stats.note_decode_failure()
			return DotResult.fail(
				DotError.CODE_PARSE, "Bad snapshot part trailer.",
				"part %d of %d" % [part, total]
			)

	_receiving_total = total
	_receiving_mask |= 1 << part

	# Only here, and deliberately not on any early return above, and only once every part
	# of the tick is in. An acknowledgement tells the server it may stop re-sending
	# everything in this snapshot, so it has to mean the whole snapshot was applied. The
	# unknown-entity path abandons the rest of the packet — it cannot skip a
	# variable-length body — and acknowledging that would strand every entity after it at
	# a value this peer never received. A tick with a part missing is never acknowledged,
	# so on the next acknowledgement the server re-sends what that part carried (and what
	# the parts that did arrive carried: the ack is one tick, not a list, and the redundant
	# re-send is the price of keeping it four bytes in every game's input packet).
	if _receiving_mask == (1 << total) - 1:
		_applied_snapshot_tick = tick

	snapshot_applied.emit(tick)
	return DotResult.success(tick)


## One entity of a snapshot, client side: its body read from [param reader], or, with a null
## reader, an entity the snapshot listed as unchanged, applied exactly as an empty body would
## be ([method DotNetBehaviour.apply_unchanged]). Either way the predictor or the interpolator
## hears about it at this tick, which is what keeps a still entity's rewind and its
## interpolation samples the same whether the server wrote it out or listed it.
func _apply_entity(
	identity: DotNetIdentity, tick: int, reader: DotNetReader, behaviour_count: int
) -> DotResult:
	var values := {}

	for b in range(behaviour_count):
		if b >= identity.behaviours.size():
			return DotResult.fail(
				DotError.CODE_VERSION,
				"Behaviour count mismatch.",
				"entity %d: sent %d, local has %d"
					% [identity.net_id, behaviour_count, identity.behaviours.size()]
			)

		var behaviour := identity.behaviours[b]

		# A predicted entity's state goes to reconciliation rather than being
		# applied: applying it directly would undo everything predicted since.
		#
		# [b]And what goes is the server's whole state, not the properties.[/b] A
		# snapshot carries only what changed, and on the owning client the properties
		# hold its own prediction between snapshots — so reading them back here, which
		# is what this did, made "the server has nothing new to say" into "the server
		# agrees with you", and the replay then ran the lead a second time on top of
		# it. A client the server held still — a server-only freeze, a wall only the
		# server has, any refusal that changes nothing replicated — walked away at
		# twice its speed and was never pulled back: 113 units in game-hungario's
		# naive admin control, 530 in the lobby's. `rewind` puts what the snapshot
		# left out back to what the server last sent, before the game's
		# `_net_state_applied` copies the properties into its simulation.
		if identity.is_predicted():
			# Deferred, the prediction stays in the properties until the flush: reading
			# writes the server's (older) state into them, and anything drawn or ticked
			# before the flush would otherwise see the entity a round trip back.
			var held := {}
			if config.reconcile_once_per_frame:
				for declaration in behaviour.net_vars:
					held[declaration.property] = behaviour._net_read_property(declaration.property)
			var applied: DotResult = DotResult.success(0)
			if reader == null:
				behaviour.apply_unchanged(tick, true)
			else:
				applied = behaviour.read_state(reader, tick, true)
			if not applied.ok:
				return applied
			values.merge(behaviour.authoritative_values(), true)
			for property: StringName in held:
				behaviour._net_write_property(property, held[property])
		else:
			var applied2: DotResult = DotResult.success(0)
			if reader == null:
				behaviour.apply_unchanged(tick)
			else:
				applied2 = behaviour.read_state(reader, tick)
			if not applied2.ok:
				return applied2

			# [b]What the server last SENT, not what the property holds.[/b] Between
			# snapshots an interpolated property holds the interpolator's own output —
			# `apply` writes the blend into it every frame — so reading it back here
			# handed the interpolator its own half-way value as the server's word for
			# every property this snapshot did not carry. Anything interpolated that
			# changed once and then stood still froze part of the way there: a remote
			# player who turned to 90 degrees was drawn at 82.5 for ever, and one who
			# stopped was drawn short of where they stopped. The same shape as #17 on
			# the other path. It hid while the render delay was in the wrong unit
			# (#18), because a render time past the newest snapshot answers with the
			# newest values and never a blend.
			var received := behaviour.received_values()
			for declaration in behaviour.net_vars:
				if declaration.interpolate and received.has(declaration.property):
					values[declaration.property] = received[declaration.property]

	if identity.is_predicted():
		if config.reconcile_once_per_frame:
			# The newest tick wins; `values` is the server's whole state (absent filled from
			# what came before), so an older snapshot's has nothing the newer one lacks.
			var waiting: Array = _pending_reconcile.get(identity.net_id, [])
			if not waiting.is_empty():
				if int(waiting[1]) > tick:
					return DotResult.success(tick)
				_reconciles_coalesced += 1
			_pending_reconcile[identity.net_id] = [identity, tick, values]
		else:
			_reconcile(identity, tick, values)
	elif not values.is_empty():
		interpolator.push(identity.net_id, tick, values)

	return DotResult.success(tick)


## The unchanged list in a snapshot part's tail (see [method _write_unchanged_tail]): every id
## in it applied as an entity whose body was empty. An id this client does not hold is
## skipped, which, unlike a body, it can be: there is nothing to step over. Leaves the reader
## at the part trailer.
func _apply_unchanged_tail(reader: DotNetReader, tick: int) -> DotResult:
	var mark := reader.read_uint(8)
	if not reader.ok() or mark != UNCHANGED_TAIL_MARK:
		return DotResult.fail(DotError.CODE_PARSE, "Bad snapshot tail.", "mark %d" % mark)

	var run_count := _read_gamma(reader)
	if run_count < 0 or run_count > MAX_UNCHANGED_LISTED:
		return DotResult.fail(DotError.CODE_PARSE, "Bad unchanged-entity list.")

	var ids: PackedInt32Array = []
	var cursor := 0
	for _r in run_count:
		var gap := _read_gamma(reader)
		var length := _read_gamma(reader) + 1
		if gap < 0 or length < 1 or ids.size() + length > MAX_UNCHANGED_LISTED:
			return DotResult.fail(DotError.CODE_PARSE, "Bad unchanged-entity run.")
		var first := cursor + gap
		if first + length > (1 << DotNetRegistry.ID_BITS):
			return DotResult.fail(DotError.CODE_PARSE, "Unchanged-entity run out of range.")
		for id in range(first, first + length):
			ids.append(id)
		cursor = first + length

	# Read whole before applying any: a list that turns out truncated must change nothing.
	for net_id in ids:
		var identity := registry.get_identity(net_id)
		if identity == null:
			continue
		var applied := _apply_entity(identity, tick, null, identity.behaviours.size())
		if not applied.ok:
			return applied

	return DotResult.success(ids.size())


# --- Acknowledgements ------------------------------------------------------

## The newest snapshot tick this client has applied in full. Client side.
##
## Zero until one has been. Send it to the server — see [method encode_ack] — and
## hand it to [method receive_ack] there.
func ack_tick() -> int:
	return _applied_snapshot_tick


## The current acknowledgement as a payload. Client side.
##
## [b]This addon does not send it for you[/b], for the same reason it does not send
## inputs: it owns no client-to-server channel, and inventing one would either need a
## second socket or make every payload ambiguous with a message. A host already ships
## an input packet every tick, and the cheapest place for four bytes is inside it.
##
## [codeblock]
## # client, once per tick, alongside the inputs it already sends
## socket.send(my_input_packet + net.encode_ack())
##
## # server, on receipt
## net.receive_ack_payload(peer_id, ack_bytes)
## [/codeblock]
##
## Wiring it is optional and additive. Without it the server assumes an unconfirmed
## snapshot arrived once it ages out, which is what it did before this existed; with
## it, a property lost to a dropped packet is re-sent instead of being stranded at a
## stale value until it happens to change again. See [method receive_ack].
func encode_ack() -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_uint(_applied_snapshot_tick, 32)
	return writer.to_bytes()


## Records that a peer has applied every snapshot up to [param tick]. Server side.
##
## [b]What this buys.[/b] Snapshots go out unreliably and carry only what changed.
## Without acknowledgements the server has to assume every one arrived, so a property
## written into a packet that was dropped is never sent again — it stays at whatever
## the client last received until it happens to change. For a position that moves
## every tick nothing is visible; for health, a team, a weapon or a name, the client
## is simply wrong, indefinitely. With acknowledgements the server knows which sends
## landed, and re-sends the rest in the next snapshot it was sending anyway.
##
## [b][param tick] is untrusted.[/b] It comes from a client, and one naming a tick
## the server has not built yet would confirm state that was never sent — which
## costs that client its own updates, but is still a claim the server should not
## take. It is refused past [member _last_snapshot_tick], and going backwards is
## ignored rather than refused, because reordering makes a stale acknowledgement
## ordinary rather than hostile.
func receive_ack(peer_id: int, tick: int) -> DotResult:
	if not is_server:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "Only a server receives acknowledgements."
		)

	if not _acks.has(peer_id):
		return DotResult.fail(
			DotError.CODE_STATE, "No such peer.", "peer %d" % peer_id
		)

	if tick < 0 or tick > _last_snapshot_tick:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Acknowledged a snapshot that was never sent.",
			"peer %d claimed tick %d; the newest is %d"
				% [peer_id, tick, _last_snapshot_tick]
		)

	if not bool(_ack_wired.get(peer_id, false)):
		_ack_wired[peer_id] = true
		# Sends that aged out before this first ack were assumed delivered, which a client
		# still loading is not: it skips snapshots naming entities it has not been told of.
		# Start over once, so state that never changes again (health, alive) is re-sent.
		var window := config.ack_window_snapshots * config.ticks_per_snapshot()
		if _last_snapshot_tick - int(_peer_added_tick.get(peer_id, 0)) > window:
			for identity in registry.all():
				for behaviour in identity.behaviours:
					behaviour.forget_peer(peer_id)
		DotLog.debug(
			CHANNEL,
			"peer is acknowledging snapshots; lost state will be re-sent",
			{"peer": peer_id}
		)

	if tick > int(_acks.get(peer_id, 0)):
		_acks[peer_id] = tick

	return DotResult.success(int(_acks[peer_id]))


## Decodes an acknowledgement produced by [method encode_ack]. Server side.
func receive_ack_payload(peer_id: int, payload: PackedByteArray) -> DotResult:
	var reader := DotNetReader.new(payload)
	var tick := reader.read_uint(32)

	if not reader.ok():
		return DotResult.fail(DotError.CODE_PARSE, "Truncated acknowledgement.")

	return receive_ack(peer_id, tick)


## Whether a peer's acknowledgements are arriving, so losses can be recovered.
func peer_acks_wired(peer_id: int) -> bool:
	return bool(_ack_wired.get(peer_id, false))


func _observer_for(peer_id: int) -> DotNetIdentity:
	var owned := registry.owned_by(peer_id)
	return owned[0] if not owned.is_empty() else null


func _reconcile(identity: DotNetIdentity, tick: int, values: Dictionary) -> void:
	var started := Time.get_ticks_usec()
	predictor.reconcile(
		identity, tick, values, _local_inputs, clock.tick,
		clock.tick_duration()
	)
	_local_inputs.acknowledge(tick)
	_perf_reconcile_usec += Time.get_ticks_usec() - started
	_perf_reconciles += 1
	_perf_replayed_ticks += predictor._last_replay_ticks


## Reconciles every predicted entity against the newest snapshot read for it since the
## last flush. Nothing to do unless [member DotNetConfig.reconcile_once_per_frame] is on;
## [method client_tick] and [method interpolate_frame] call it, so a host only does when it
## predicts without either and must see the correction first.
func flush_reconcile() -> void:
	if _pending_reconcile.is_empty():
		return
	var waiting := _pending_reconcile
	_pending_reconcile = {}
	for net_id: int in waiting:
		var entry: Array = waiting[net_id]
		var identity: DotNetIdentity = entry[0]
		# Unregistered (or freed) since the snapshot: nothing left to correct.
		if not is_instance_valid(identity) or registry.get_identity(net_id) != identity:
			continue
		_reconcile(identity, int(entry[1]), entry[2])


func _forget_entity(net_id: int) -> void:
	_pending_reconcile.erase(net_id)
	if interpolator != null:
		interpolator.forget(net_id)
	if predictor != null:
		predictor.forget(net_id)
	if history != null:
		history.forget(net_id)


# --- Messages --------------------------------------------------------------

## Sends a message to a peer, or to everyone when [param peer_id] is 0.
func send(message: DotNetMessage, peer_id: int = 0) -> DotResult:
	if not send_fn.is_valid():
		return DotResult.fail(
			DotError.CODE_STATE, "No send function is set."
		)

	var writer := DotNetWriter.new()
	var encoded := messages.encode(message, writer)

	if not encoded.ok:
		return encoded

	var payload := writer.to_bytes()
	send_fn.call(peer_id, payload, messages.delivery_of(message.type_name()))
	stats.note_sent(payload.size(), 1)

	return DotResult.success(payload.size())


## Decodes and dispatches an incoming message payload.
##
## Rate-limited per peer on the server: every client-to-server message costs work,
## and a client sending thousands a second is broken or hostile.
func receive(payload: PackedByteArray, from_peer_id: int) -> DotResult:
	stats.note_received(payload.size())

	if is_server:
		if payload.size() > config.max_client_payload:
			stats.note_decode_failure()
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Payload from a client is too large.",
				"%d bytes from peer %d" % [payload.size(), from_peer_id]
			)

		if not _message_limiter.allow(from_peer_id):
			stats.note_rate_limited()
			return DotResult.fail(
				DotError.CODE_RATE_LIMITED,
				"Peer is sending too fast.",
				"peer %d" % from_peer_id
			)

	var reader := DotNetReader.new(payload)
	var decoded := messages.decode(reader, from_peer_id, is_server)

	if not decoded.ok:
		if decoded.code() == DotError.CODE_FORBIDDEN:
			stats.note_direction_violation()
		elif decoded.code() != DotError.CODE_VERSION:
			# A refused schema is not a decode failure: it decoded, and said the two ends
			# cannot play. It is reported through `peer_schema_refused`, not as noise.
			stats.note_decode_failure()
		return decoded

	# Null is a message there is nothing to hand a game: a peer's schema table, a type this
	# end does not have, or anything from a peer whose schema was refused. Not an error --
	# a peer one build ahead sends exactly this, and must be able to.
	if decoded.value == null:
		return DotResult.success(false)

	messages.dispatch(decoded.value)
	return DotResult.success(true)


# --- Reporting -------------------------------------------------------------

func describe() -> Dictionary:
	var d := {
		"role": "server" if is_server else "client",
		"running": _running,
		"peers": _peers.size(),
		"entities": registry.count() if registry != null else 0,
		"clock": clock.describe() if clock != null else {},
		"stats": stats.describe() if stats != null else {},
		"interest": interest.describe() if interest != null else {},
	}

	if not is_server:
		d["held_ticks"] = _held_ticks

	if is_server:
		d["snapshots_split"] = snapshots_split
		d["largest_part_bytes"] = largest_part_bytes
		d["mtu"] = config.mtu if config != null else 0
		d["unchanged_listed"] = unchanged_listed
		d["unchanged_bytes_saved"] = unchanged_bytes_saved
		d["input_leads_sent"] = input_leads_sent
		d["snapshot_threads"] = {
			"configured": config.snapshot_workers if config != null else 0,
			"why_inline": _snapshot_threads_reason,
			"pooled": _snapshot_pooled,
			"last_peers": _snapshot_pooled_peers,
			"last_tasks": _snapshot_pooled_workers,
			"last_join_usec": _snapshot_join_usec,
			"mean_prep_usec": _snapshot_prep_usec_total / maxi(1, _snapshot_pooled),
			"mean_join_usec": _snapshot_join_usec_total / maxi(1, _snapshot_pooled),
			"mean_apply_usec": _snapshot_apply_usec_total / maxi(1, _snapshot_pooled),
		}

	if interpolator != null:
		d["interpolation"] = interpolator.describe()
	if predictor != null:
		d["prediction"] = predictor.describe()
		if config != null and config.reconcile_once_per_frame:
			d["prediction"]["coalesced"] = _reconciles_coalesced
	if history != null:
		d["lag_compensation"] = history.describe()

	return d


## Lines for a `net_status` console command.
func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("role       %s" % ("server" if is_server else "client"))
	out.append("entities   %d" % (registry.count() if registry != null else 0))

	if clock != null:
		out.append("tick       %d (%s)" % [
			clock.tick, "synced" if clock.is_synced() else "SYNCING"
		])
		out.append("rtt        %d ms, jitter %d ms" % [
			int(clock.rtt_ms()), int(clock.jitter_ms())
		])
		if not is_server:
			out.append("lead       %s" % clock.describe_lead())

	if is_server and config != null:
		out.append("snapshots  %d split, largest part %d B of %d" % [
			snapshots_split, largest_part_bytes, config.mtu
		])
		out.append("unchanged  %d listed, %d B of headers saved" % [
			unchanged_listed, unchanged_bytes_saved
		])
		out.append("leads      %d sent to clients" % input_leads_sent)
		if _native_note != "":
			out.append("native     %s" % _native_note)
		if config.snapshot_workers != 0:
			var n := maxi(1, _snapshot_pooled)
			out.append("threads    %d asked, %d snapshots pooled%s; last %d peers in %d tasks; mean us: prep %d, join %d, apply %d" % [
				config.snapshot_workers, _snapshot_pooled,
				(", inline: " + _snapshot_threads_reason) if _snapshot_threads_reason != "" else "",
				_snapshot_pooled_peers, _snapshot_pooled_workers,
				_snapshot_prep_usec_total / n, _snapshot_join_usec_total / n, _snapshot_apply_usec_total / n,
			])
			for line in DotParallel.describe_lines():
				out.append("  " + line)

	if stats != null:
		out.append("")
		out.append_array(stats.describe_lines())

	if interpolator != null:
		out.append("")
		out.append("interpolation:")
		var interp := interpolator.describe()
		for key in interp:
			out.append("  %-18s %s" % [str(key), str(interp[key])])

	if predictor != null:
		out.append("")
		out.append("prediction:")
		var pred := predictor.describe()
		for key in pred:
			out.append("  %-18s %s" % [str(key), str(pred[key])])

	if budget != null and is_server:
		out.append("")
		out.append_array(budget.describe_lines())

	return out
