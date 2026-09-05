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

## Emitted each simulation tick, after entities have been simulated.
signal ticked(tick: int)

## Emitted on the server after a snapshot is built and sent.
signal snapshot_sent(tick: int, peer_count: int)

## Emitted on a client when a snapshot has been applied.
signal snapshot_applied(tick: int)

## Emitted when an entity is spawned or despawned, on every peer.
signal entity_spawned(identity: DotNetIdentity)
signal entity_despawned(net_id: int)

@export_group("Role")

## Whether this process is the authority.
@export var is_server: bool = false

## This peer's id. 1 is the server in Godot's numbering.
@export var local_peer_id: int = 1

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

## Newest tick a snapshot was built for, on the server.
##
## The bound on what a peer may claim to have acknowledged. An acknowledgement is
## client-controlled, and one naming a tick the server has not reached would promote
## state that was never sent.
var _last_snapshot_tick: int = 0

## Newest snapshot tick applied in full, on a client. What [method ack_tick] reports.
var _applied_snapshot_tick: int = 0

## Connected peers, on the server.
var _peers: Array[int] = []

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

	registry = DotNetRegistry.new(is_server, local_peer_id)
	messages = DotNetMessageRegistry.new()
	budget = DotNetBudget.new(config)
	stats = DotNetStats.new()

	if interest == null:
		var distance := DotNetInterestDistance.new()
		distance.radius = config.interest_radius
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

	return DotResult.success(self)


func stop() -> void:
	_running = false
	_peers.clear()
	_input_buffers.clear()
	_acks.clear()
	_ack_wired.clear()
	_last_snapshot_tick = 0
	_applied_snapshot_tick = 0

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

	DotLog.debug(CHANNEL, "peer added", {"peer": peer_id})


## Removes a peer and everything it owned.
func remove_peer(peer_id: int) -> Array[DotNetIdentity]:
	_peers.erase(peer_id)
	_input_buffers.erase(peer_id)
	_acks.erase(peer_id)
	_ack_wired.erase(peer_id)

	budget.forget_peer(peer_id)
	interest.forget_peer(peer_id)

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
	var identities := registry.all()

	for peer_id in _peers:
		var buffer: DotNetInput.Buffer = _input_buffers[peer_id]
		var input := buffer.take(tick)

		if input == null:
			# No input for this tick. The last one is repeated by whatever consumes
			# it — a player whose packet was lost should keep moving rather than
			# stopping dead and jerking forward when it arrives.
			buffer.note_starved()
			continue

		_apply_input(peer_id, input, tick)

	var step := clock.tick_duration()

	for identity in identities:
		if not identity.can_simulate():
			continue
		for behaviour in identity.behaviours:
			behaviour._net_simulate(tick, step)

	_ticks_since_snapshot += 1

	if _ticks_since_snapshot >= config.ticks_per_snapshot():
		_ticks_since_snapshot = 0
		history.record(identities, tick)
		_send_snapshots(tick, identities)


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

	predictor.predict(registry.predicted(), tick, clock.tick_duration())


## Applies interpolation. Call from [method Node._process], not the tick loop.
##
## Rendering runs at frame rate and simulation at tick rate; interpolating on the
## tick would quantise remote motion to the tick rate and undo the point of it.
func interpolate_frame() -> void:
	if is_server or interpolator == null or not clock.is_synced():
		return

	var server_tick_now := clock.server_tick()

	for identity in registry.all():
		interpolator.apply(identity, server_tick_now)


# --- Snapshots -------------------------------------------------------------

## Builds and sends a snapshot to every peer, filtered and prioritised per peer.
func _send_snapshots(tick: int, identities: Array[DotNetIdentity]) -> void:
	var context := {"tick": tick, "config": config}

	interest._prepare(identities, context)

	_last_snapshot_tick = tick

	# There is deliberately no world-wide baseline snapshot here any more. One was
	# built and stored every snapshot tick — a full read of every replicated property
	# of every entity — against the day whole-snapshot deltas landed, and nothing
	# ever read it. Baselines are per peer instead, and they have to be: interest
	# management means no two peers were sent the same set of entities, so a single
	# world baseline is not a baseline for anybody. See [DotNetBehaviour.PeerView].

	var sent_to := 0

	for peer_id in _peers:
		budget.begin_tick(peer_id)

		var observer := _observer_for(peer_id)
		var relevant := interest.relevant_for(
			observer, identities, peer_id, context
		)

		var scores := {}
		for identity in relevant:
			scores[identity.net_id] = interest._score(observer, identity, context)

		# Both caps at once — see [method DotNetConfig.entity_cap]. max_tracked_entities
		# was documented from the first version and enforced by nothing; it is applied
		# HERE rather than by a score sort of our own, because prioritise is what pins
		# always_relevant and a plain sort would cut the observer's own entity.
		relevant = interest.prioritise(observer, relevant, config.entity_cap(), context)
		relevant = budget.accumulate(peer_id, relevant, scores)

		if _send_to_peer(peer_id, tick, relevant):
			sent_to += 1

	snapshot_sent.emit(tick, sent_to)


func _send_to_peer(
	peer_id: int,
	tick: int,
	relevant: Array[DotNetIdentity]
) -> bool:
	if not send_fn.is_valid():
		return false

	var writer := DotNetWriter.new()
	writer.write_uint(tick, 32)

	var count_position := writer.bit_length()
	# The count is written after the entities, once it is known — writing it first
	# would mean guessing how many fit in the budget.
	writer.write_uint(0, 12)

	var written := 0
	var remaining_bytes := budget.remaining(peer_id)

	var acked_tick := int(_acks.get(peer_id, 0))
	var strict := bool(_ack_wired.get(peer_id, false))
	# Anything sent longer ago than this is resolved one way or the other, so a peer
	# that stops acknowledging costs a bounded window rather than a growing record.
	var oldest_pending: int = tick - config.ack_window_snapshots * config.ticks_per_snapshot()

	for identity in relevant:
		var estimated := 0
		for behaviour in identity.behaviours:
			estimated += behaviour.estimated_bits(peer_id)
		estimated = (estimated + 7) >> 3

		if written > 0 and estimated > remaining_bytes:
			budget.note_starved(peer_id)
			continue

		var before := writer.byte_length()

		writer.write_uint(identity.net_id, DotNetRegistry.ID_BITS)
		writer.write_uint(identity.behaviours.size(), 6)

		for behaviour in identity.behaviours:
			# Resolve what this peer has confirmed before deciding what is dirty, so
			# a property whose only send was lost is dirty again and goes out here.
			behaviour.sync_peer_acks(peer_id, acked_tick, strict)
			behaviour.trim_pending(peer_id, oldest_pending)

			var dirty := behaviour.collect_dirty(peer_id, false)
			behaviour.write_state(writer, dirty, peer_id, tick)

		var spent := writer.byte_length() - before
		remaining_bytes -= spent
		budget.note_sent(peer_id, identity.net_id, spent)
		written += 1

	if written == 0:
		return false

	var payload := writer.to_bytes()

	# Patch the count in now that it is known. The header is byte-aligned by
	# construction, so this is a plain byte edit rather than a bit splice.
	var count_byte := count_position >> 3
	if count_byte + 1 < payload.size():
		payload[count_byte] = written & 0xFF
		payload[count_byte + 1] = (payload[count_byte + 1] & 0xF0) | ((written >> 8) & 0x0F)

	send_fn.call(peer_id, payload, DotNetMessage.Delivery.UNRELIABLE)

	budget.note_packet(peer_id, payload.size())
	stats.note_sent(payload.size(), written)

	return true


## Applies a snapshot payload. Client side.
func receive_snapshot(payload: PackedByteArray) -> DotResult:
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

	stats.note_snapshot(tick)

	if tick <= _applied_snapshot_tick and _applied_snapshot_tick > 0:
		# Older than one already applied. Snapshots carry state, not events, so a
		# late one is not merely out of order — it is superseded, and applying it
		# would write a stale value over a newer one for every property the
		# interpolator does not own. The clock is not fed from it either: an
		# arrival time attached to an old tick reads as a sudden lead.
		return DotResult.success(_applied_snapshot_tick)

	interpolator.note_arrival()
	clock.sync_from_server(tick, stats.rtt_percentile(0.5))

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

		var values := {}

		for b in range(behaviour_count):
			if b >= identity.behaviours.size():
				stats.note_decode_failure()
				return DotResult.fail(
					DotError.CODE_VERSION,
					"Behaviour count mismatch.",
					"entity %d: sent %d, local has %d"
						% [net_id, behaviour_count, identity.behaviours.size()]
				)

			var behaviour := identity.behaviours[b]

			# A predicted entity's state goes to reconciliation rather than being
			# applied: applying it directly would undo everything predicted since.
			if identity.is_predicted():
				var start := reader.bit_position()
				var applied := behaviour.read_state(reader, tick)
				if not applied.ok:
					stats.note_decode_failure()
					return applied
				values.merge(behaviour.snapshot_values(), true)
				var _unused := start
			else:
				var applied2 := behaviour.read_state(reader, tick)
				if not applied2.ok:
					stats.note_decode_failure()
					return applied2

				for declaration in behaviour.net_vars:
					if declaration.interpolate:
						values[declaration.property] = behaviour._net_read_property(
							declaration.property
						)

		if identity.is_predicted():
			predictor.reconcile(
				identity, tick, values, _local_inputs, clock.tick,
				clock.tick_duration()
			)
			_local_inputs.acknowledge(tick)
		elif not values.is_empty():
			interpolator.push(net_id, tick, values)

	# Only here, and deliberately not on any early return above. An acknowledgement
	# tells the server it may stop re-sending everything in this snapshot, so it has
	# to mean the whole snapshot was applied. The unknown-entity path abandons the
	# rest of the packet — it cannot skip a variable-length body — and acknowledging
	# that would strand every entity after it at a value this peer never received.
	_applied_snapshot_tick = tick

	snapshot_applied.emit(tick)
	return DotResult.success(tick)


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


func _forget_entity(net_id: int) -> void:
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
		else:
			stats.note_decode_failure()
		return decoded

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

	if interpolator != null:
		d["interpolation"] = interpolator.describe()
	if predictor != null:
		d["prediction"] = predictor.describe()
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
