@tool
class_name DotNetBehaviour
extends Node

## A component whose properties replicate. The class a game subclasses most.
##
## Declare what replicates in [method _register_net_vars] and the rest follows:
## dirty tracking, quantisation, audience filtering, rate limiting and change
## callbacks all come from the declaration.
##
## [codeblock]
## class_name PlayerMovement extends DotNetBehaviour
##
## var position: Vector3
## var velocity: Vector3
## var grounded: bool
##
## func _register_net_vars() -> void:
##     replicate(&"position", DotNetVar.Type.VECTOR3_POSITION) \
##         .interpolated().with_priority(5.0)
##     replicate(&"velocity", DotNetVar.Type.VECTOR3_VELOCITY) \
##         .with_epsilon(0.05)
##     replicate(&"grounded", DotNetVar.Type.BOOL)
##
## func _net_simulate(tick: int, delta: float) -> void:
##     # Runs only where this entity has authority.
##     velocity.y -= 9.8 * delta
##     position += velocity * delta
## [/codeblock]
##
## [b]Properties are read off this object by name.[/b] They can be plain variables,
## `@export`ed ones, or backed by getters — anything [method Object.get] resolves. A
## behaviour that would rather compute a value than store it can override
## [method _net_read_property].

const CHANNEL := "net.behaviour"

## The identity this belongs to. Set when the identity collects behaviours.
var identity: DotNetIdentity = null

## Declared properties, in registration order.
var net_vars: Array[DotNetVar] = []

## property -> last value received, on a receiving peer.
##
## The receive side only. The send side is [member _views], one entry per peer:
## see [PeerView] for why one shared dictionary could not do both jobs.
var _baseline: Dictionary = {}

## peer_id -> [PeerView]. The send side, kept per destination.
var _views: Dictionary = {}

var _registered: bool = false
var _config: DotNetConfig = null


## What one peer is believed to have, and what it has confirmed.
##
## [b]Why this is per peer.[/b] Dirty tracking used to be a single dictionary on the
## behaviour, updated by whichever send happened to run first. Snapshots are built
## one peer at a time, so the first peer to be served marked every property clean
## and [b]every other peer received nothing[/b] — a two-client game replicated to
## exactly one of them, and the third client to come into range of an entity saw
## only whatever changed after it arrived. Rate limiting had the same fault: one
## peer's send silenced the property for all of them.
##
## [b]Why there are three fields and not one.[/b] Snapshots go out unreliably, so a
## property written into a packet has not necessarily arrived:
##
## - [member acked] is what the peer has [i]confirmed[/i] receiving.
## - [member pending] is what has been sent since, still unconfirmed, oldest first.
## - [member believed] is [member acked] with [member pending] laid over it, and is
##   what dirty tracking compares against — so a property is sent once and not
##   re-sent every tick while its acknowledgement is in flight.
##
## When a snapshot is confirmed lost, its entry leaves [member pending] without ever
## reaching [member acked], [member believed] is rebuilt without it, and the
## properties it carried go dirty again and are re-sent. That is the whole loss
## recovery mechanism: no retransmit queue, no timers, and nothing on the wire but
## the next snapshot, which was going out anyway.
class PeerView extends RefCounted:
	## property -> value the peer has confirmed.
	var acked: Dictionary = {}

	## property -> value we believe the peer has or is about to have.
	var believed: Dictionary = {}

	## [code]{"tick": int, "values": Dictionary}[/code], ascending by tick.
	##
	## An [Array] rather than a tick-keyed [Dictionary] because it is only ever
	## appended to at the newest tick and consumed from the oldest, so insertion
	## order [i]is[/i] tick order and nothing has to sort it.
	var pending: Array[Dictionary] = []

	## property -> last send time in ms, for [member DotNetVar.max_rate].
	var last_sent_ms: Dictionary = {}

	## Newest tick this peer has acknowledged.
	var last_ack: int = 0

	## Whether acknowledgements are arriving for this peer.
	##
	## Until one does, an unconfirmed snapshot is assumed delivered once it ages out
	## of the window. That is what this addon did before acknowledgements existed and
	## it is what a host that has not wired [method DotNetManager.receive_ack] keeps
	## getting — the same bandwidth, and the same inability to recover a lost
	## property. Nothing degrades by adding the field; loss recovery is what turning
	## it on buys. See [method DotNetManager.receive_ack].
	var strict: bool = false


# --- Subclass interface ----------------------------------------------------

## Declare replicated properties here, with [method replicate].
func _register_net_vars() -> void:
	pass


## Called once this entity has a network id, on every peer.
##
## The place to do setup that needs to know [member DotNetIdentity.is_owner] or
## whether this peer is authoritative — neither is known in [method Node._ready].
func _net_ready() -> void:
	pass


## Called before the entity is removed from the network.
func _net_removed() -> void:
	pass


## Fixed-tick simulation. Runs only where this entity can be simulated.
##
## See [method DotNetIdentity.can_simulate]. On a predicted entity this runs on both
## the owning client and the server, with the same inputs, which is what makes
## reconciliation converge — so it must be deterministic given the same input and
## must not read anything that differs between machines (wall clock, random without a
## seeded stream, other players' unpredicted state).
func _net_simulate(_tick: int, _delta: float) -> void:
	pass


## Called on a receiving peer after a batch of properties is applied.
##
## For work that should happen once per update rather than once per property.
func _net_state_applied(_tick: int) -> void:
	pass


## Reads a property. Override to compute rather than store.
## Called after interpolation has written this behaviour's interpolated properties.
##
## [b]Distinct from [method _net_state_applied], and both are needed.[/b]
## `_net_state_applied` runs when a *snapshot* arrives — at the snapshot rate, a few times
## a second — and is where a game adopts authoritative state. This runs every *frame*, on
## a remote entity, after [DotNetInterpolator] has written the smoothed value of every
## property declared [method DotNetVar.interpolated].
##
## Without it the interpolator's work is computed and thrown away. A game that copies
## `net_position` into a node or a simulation state only from `_net_state_applied` moves
## every remote entity at the snapshot rate — 20 Hz, in steps — while the interpolated
## value sits in the property nobody read. It looks like the interpolator is broken; it is
## not, it is unread.
##
## It deliberately does not carry the bookkeeping `_net_state_applied` does. The tick is a
## *render* tick, behind the server's, and recording it as the newest state applied would
## make reconciliation rewind to a tick the server never sent.
func _net_interpolated(_tick: int) -> void:
	pass


func _net_read_property(property: StringName) -> Variant:
	return get(property)


## Writes a property. Override to validate or to trigger side effects.
func _net_write_property(property: StringName, value: Variant) -> void:
	set(property, value)


# --- Declaration -----------------------------------------------------------

## Declares a replicated property. Returns the [DotNetVar] for chaining.
func replicate(property: StringName, type: DotNetVar.Type) -> DotNetVar:
	var declaration := DotNetVar.make(property, type)
	declaration.bind_config(_config)
	net_vars.append(declaration)
	return declaration


## Declares a property with a custom codec.
##
## Shorthand for [code]replicate(name, CUSTOM).codec(w, r)[/code], which is the path
## for any type dot-net does not know about.
func replicate_custom(
	property: StringName,
	writer_fn: Callable,
	reader_fn: Callable
) -> DotNetVar:
	return replicate(property, DotNetVar.Type.CUSTOM).codec(writer_fn, reader_fn)


## Called by the manager before [method _register_net_vars].
func _bind(config: DotNetConfig) -> void:
	_config = config

	if _registered:
		return

	net_vars.clear()
	_register_net_vars()

	for declaration in net_vars:
		declaration.bind_config(config)

	_registered = true

	# A behaviour that declares nothing is legal — it may exist only for
	# _net_simulate — but it is also what a forgotten _register_net_vars looks like.
	if net_vars.is_empty():
		DotLog.debug(
			CHANNEL,
			"behaviour declares no replicated properties",
			{"node": name}
		)


func is_bound() -> bool:
	return _registered


# --- Sending ---------------------------------------------------------------

## Properties that changed since the last send [i]to this peer[/i].
##
## [param peer_id] decides both which properties are visible and which record of
## previously-sent values they are compared against — see [PeerView]. [param force]
## ignores dirty tracking and rate limits, which is what a spawn or a late-joining
## client needs.
##
## [b]The peer passed here must be the peer passed to [method write_state].[/b] They
## read and write the same [PeerView] and nothing can detect a mismatch: collecting
## for one peer and writing for another marks the wrong peer clean, so the right one
## is told nothing and the wrong one is never told again.
func collect_dirty(
	peer_id: int,
	force: bool = false
) -> Array[DotNetVar]:
	var out: Array[DotNetVar] = []
	var view := _view_for(peer_id)
	var now := Time.get_ticks_msec()

	for declaration in net_vars:
		if not declaration.visible_to(peer_id, identity.owner_peer_id):
			continue

		if declaration.on_spawn_only and not force:
			# Still sent when it changes — "spawn only" means "do not pay for it
			# every snapshot", not "never update".
			var current_once: Variant = _net_read_property(declaration.property)
			if not _is_dirty(view, declaration, current_once):
				continue

		if not force and declaration.max_rate > 0.0:
			var interval := 1000.0 / declaration.max_rate
			var last := float(view.last_sent_ms.get(declaration.property, -100000))
			if float(now) - last < interval:
				continue

		var current: Variant = _net_read_property(declaration.property)

		if not force and not _is_dirty(view, declaration, current):
			continue

		out.append(declaration)

	return out


func _is_dirty(
	view: PeerView,
	declaration: DotNetVar,
	current: Variant
) -> bool:
	if not view.believed.has(declaration.property):
		return true
	return declaration.differs(view.believed[declaration.property], current)


## Writes the given properties and records them as sent to [param peer_id].
##
## The record is updated here rather than at collection time, so a send that is
## dropped by the budget does not mark the property clean — it stays dirty and goes
## out next tick.
##
## [param tick] is the snapshot tick being written. Passing it is what makes loss
## recovery possible: the properties become an unconfirmed entry in the peer's
## [PeerView], to be promoted when the peer acknowledges that tick and discarded —
## and therefore re-sent — when it never does. A tick of 0 means "do not track",
## which is what a caller writing state outside a snapshot wants.
func write_state(
	writer: DotNetWriter,
	declarations: Array[DotNetVar],
	peer_id: int = 0,
	tick: int = 0
) -> void:
	var view := _view_for(peer_id)
	var now := Time.get_ticks_msec()
	var recorded := {}

	# An index per property rather than a full bitmask: with a handful of properties
	# the index is smaller, and it does not need the receiver to know the declaration
	# order beyond the shared registration.
	writer.write_uint(declarations.size(), 6)

	for declaration in declarations:
		var index := net_vars.find(declaration)
		if index < 0:
			continue

		var value: Variant = _net_read_property(declaration.property)

		writer.write_uint(index, 6)
		declaration.write(writer, value)

		view.believed[declaration.property] = value
		view.last_sent_ms[declaration.property] = now
		recorded[declaration.property] = value

	if recorded.is_empty():
		return

	if tick <= 0:
		# Untracked: assume delivered, which is the only assumption available when
		# the caller has not said which snapshot this belongs to.
		view.acked.merge(recorded, true)
		return

	view.pending.append({"tick": tick, "values": recorded})


## Resolves this peer's unconfirmed sends against the tick it has acknowledged.
##
## Called by [DotNetManager] immediately before [method collect_dirty], rather than
## being pushed to every behaviour the moment an acknowledgement arrives: an
## acknowledgement is one packet and a world is thousands of behaviours, so pushing
## costs a full sweep of the registry per peer per acknowledgement. Resolving lazily
## does the same work only for the entities actually about to be sent, which is the
## set the caller is already walking.
##
## [param acked_tick] is the newest snapshot the peer has confirmed applying in
## full. An entry at that tick is promoted to confirmed. Entries [i]older[/i] than it
## and still unconfirmed never arrived — the peer has since applied a later snapshot,
## so an older one is not merely late, it is superseded — and are dropped, which puts
## the properties they carried back in the dirty set.
##
## [param strict] is whether acknowledgements are known to be arriving at all. When
## they are not, an entry that ages out is assumed delivered rather than assumed
## lost; see [member PeerView.strict].
func sync_peer_acks(peer_id: int, acked_tick: int, strict: bool) -> void:
	var view := _view_for(peer_id)

	if strict:
		view.strict = true

	if acked_tick <= view.last_ack:
		return

	view.last_ack = acked_tick

	if view.pending.is_empty():
		return

	var kept: Array[Dictionary] = []
	var resolved := 0

	for entry in view.pending:
		var entry_tick := int(entry["tick"])

		if entry_tick > acked_tick:
			kept.append(entry)
			continue

		resolved += 1

		if entry_tick == acked_tick or not view.strict:
			view.acked.merge(entry["values"], true)
		# Otherwise: sent before a snapshot the peer has already applied, and still
		# unconfirmed. Dropped without promotion, so it goes out again.

	if resolved == 0:
		return

	view.pending = kept
	_rebuild_believed(view)


## Drops unconfirmed sends older than [param oldest_tick].
##
## The bound on how much unconfirmed state one peer can accumulate, so a client that
## stops acknowledging costs a window rather than a lifetime. What happens to an
## entry that ages out depends on whether acknowledgements are arriving at all: with
## them it is a loss and the properties re-send; without them there is no evidence
## either way and it is assumed delivered, which is what this addon did before
## acknowledgements existed.
func trim_pending(peer_id: int, oldest_tick: int) -> void:
	var view: PeerView = _views.get(peer_id)

	if view == null or view.pending.is_empty():
		return

	var kept: Array[Dictionary] = []

	for entry in view.pending:
		if int(entry["tick"]) >= oldest_tick:
			kept.append(entry)
			continue

		if not view.strict:
			view.acked.merge(entry["values"], true)

	if kept.size() == view.pending.size():
		return

	view.pending = kept
	_rebuild_believed(view)


## Forgets everything recorded for one peer.
##
## Called when a peer disconnects. Without it every behaviour that ever replicated to
## that peer keeps its [PeerView] for the lifetime of the entity, which on a server
## churning through players is a leak proportional to everyone who has ever
## connected rather than to everyone currently playing.
func forget_peer(peer_id: int) -> void:
	_views.erase(peer_id)


func _view_for(peer_id: int) -> PeerView:
	var view: PeerView = _views.get(peer_id)

	if view == null:
		view = PeerView.new()
		_views[peer_id] = view

	return view


## Rebuilds what a peer is believed to have from what it has confirmed.
##
## Confirmed state first, then every still-unconfirmed send in tick order, so a
## property sent twice is believed at its newest value and a property whose only
## send was dropped falls back to the confirmed one — or to absent, which reads as
## dirty and re-sends it.
func _rebuild_believed(view: PeerView) -> void:
	view.believed = view.acked.duplicate()

	for entry in view.pending:
		view.believed.merge(entry["values"], true)


## What is known about one peer. For diagnostics and tests.
func peer_view_state(peer_id: int) -> Dictionary:
	var view: PeerView = _views.get(peer_id)

	if view == null:
		return {}

	return {
		"acked": view.acked.size(),
		"believed": view.believed.size(),
		"pending": view.pending.size(),
		"last_ack": view.last_ack,
		"strict": view.strict,
	}


# --- Receiving -------------------------------------------------------------

## Reads properties and applies them, firing change handlers.
##
## Every failure here is reachable from the network, so an out-of-range index is
## treated as a corrupt or mismatched stream and stops the read — continuing would
## decode the following bytes as the wrong type.
func read_state(reader: DotNetReader, tick: int) -> DotResult:
	var count := reader.read_uint(6)

	if not reader.ok():
		return DotResult.fail(DotError.CODE_PARSE, "Truncated state header.")

	for _i in range(count):
		var index := reader.read_uint(6)

		if not reader.ok():
			return DotResult.fail(DotError.CODE_PARSE, "Truncated state entry.")

		if index >= net_vars.size():
			return DotResult.fail(
				DotError.CODE_VERSION,
				"State references an unknown property index.",
				"index %d, this behaviour has %d — the peers' declarations differ"
					% [index, net_vars.size()]
			)

		var declaration := net_vars[index]
		var value: Variant = declaration.read(reader)

		if not reader.ok():
			return DotResult.fail(
				DotError.CODE_PARSE,
				"Truncated property value.",
				String(declaration.property)
			)

		var previous: Variant = _baseline.get(declaration.property)

		_net_write_property(declaration.property, value)
		_baseline[declaration.property] = value

		if declaration.change_handler.is_valid():
			declaration.change_handler.call(previous, value)

	_net_state_applied(tick)
	return DotResult.success(count)


## Forgets what a peer is known to have, so the next collection sends everything.
##
## Used when a client's connection is re-established: it has no prior state, so a
## delta against a record of what it used to have would be meaningless.
##
## With no argument it forgets every peer and the receive-side record too, which is
## what this method meant before the send side became per-peer.
func reset_baseline(peer_id: int = -1) -> void:
	if peer_id < 0:
		_baseline.clear()
		_views.clear()
		return

	_views.erase(peer_id)


## The current value of every replicated property.
##
## For snapshots, for debugging, and for handing a whole entity to a late joiner.
func snapshot_values() -> Dictionary:
	var out := {}
	for declaration in net_vars:
		out[declaration.property] = _net_read_property(declaration.property)
	return out


## Estimated bits a full update costs, for the bandwidth budget.
func estimated_bits(peer_id: int) -> int:
	var total := 6
	for declaration in net_vars:
		if declaration.visible_to(peer_id, identity.owner_peer_id):
			total += 6 + declaration.estimated_bits()
	return total


func find_var(property: StringName) -> DotNetVar:
	for declaration in net_vars:
		if declaration.property == property:
			return declaration
	return null


func describe() -> Dictionary:
	var properties := []
	for declaration in net_vars:
		properties.append({
			"property": String(declaration.property),
			"type": DotNetVar.Type.keys()[declaration.type],
			"bits": declaration.estimated_bits(),
			"audience": DotNetVar.Audience.keys()[declaration.audience],
		})

	return {
		"node": name,
		"bound": _registered,
		"vars": properties,
	}
