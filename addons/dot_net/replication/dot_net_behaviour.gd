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

## property -> true, for what the most recent [method read_state] carried. The receive side
## only; [method authoritative_values] needs to tell "sent now" from "sent earlier".
var _read_now: Dictionary = {}

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

	## property -> true for a property whose send this peer never confirmed and which was
	## dropped as lost: owed until the peer confirms it, not merely until it is sent again.
	## See [method collect_dirty].
	var relost: Dictionary = {}

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


## property -> value, read once for the snapshot being written; empty outside one.
##
## [b]Every peer's snapshot reads every property of every entity it carries[/b], twice
## (once to decide whether it is dirty, once to write it), so a server of N players read
## each property 2N times a snapshot through a dynamic `get`. Nothing changes the world
## while a snapshot is being built, so the value is the same every time: the manager
## opens this with [method begin_snapshot_reads] before its peer loop and closes it with
## [method end_snapshot_reads] after, and inside it each property is read once.
## Outside a snapshot it is closed and reads go straight to [method _net_read_property],
## so a caller writing state at any other time sees the live value.
var _snapshot_reads: Dictionary = {}
var _snapshot_reads_open: bool = false

## Within one snapshot: what each distinct set of properties encodes to, by the bit of a
## byte it starts at (always 0 for a set with nothing byte-aligned in it) and then by the
## set, as a bitmask of declaration indices. See [method write_state].
var _encoded: Dictionary = {}

## Declaration -> its index in [member net_vars], built once [method _bind] has the list.
var _index_of: Dictionary = {}

## Bit i set when declaration i may byte-align ([method DotNetVar.may_align]); laid against
## a [method _signature] in [method write_state].
var _align_mask: int = 0


func begin_snapshot_reads() -> void:
	_snapshot_reads.clear()
	_encoded.clear()
	_snapshot_reads_open = true


func end_snapshot_reads() -> void:
	_snapshot_reads.clear()
	_encoded.clear()
	_snapshot_reads_open = false


func _read_for_send(property: StringName) -> Variant:
	if not _snapshot_reads_open:
		return _net_read_property(property)
	if _snapshot_reads.has(property):
		return _snapshot_reads[property]
	var value: Variant = _net_read_property(property)
	_snapshot_reads[property] = value
	return value


## Writes a property. Override to validate or to trigger side effects.
func _net_write_property(property: StringName, value: Variant) -> void:
	set(property, value)


# --- Declaration -----------------------------------------------------------

## How many properties one behaviour may replicate: the count of changed ones and each one's
## index both travel in 6 bits ([method _encode]), and [DotNetWriter] masks silently, so a 64th
## would be sent as a count of 0 and the 65th as index 0. Private: the width is the wire's.
const _MAX_NET_VARS := 63


## Declares a replicated property. Returns the [DotNetVar] for chaining.
##
## Past [constant _MAX_NET_VARS] the declaration is refused with an error and returned
## unregistered (it chains, and replicates nothing), rather than aliasing another property.
func replicate(property: StringName, type: DotNetVar.Type) -> DotNetVar:
	var declaration := DotNetVar.make(property, type)
	declaration.bind_config(_config)
	if net_vars.size() >= _MAX_NET_VARS:
		push_error("%s: replicate(%s) refused, a behaviour replicates at most %d properties (6-bit index)." % [name, property, _MAX_NET_VARS])
		return declaration
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

	_index_of.clear()
	_align_mask = 0
	for i in range(net_vars.size()):
		_index_of[net_vars[i]] = i
		if i < 62 and net_vars[i].may_align():
			_align_mask |= 1 << i

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
##
## [param until_acked] keeps a property dirty until the peer has [i]confirmed[/i] its
## current value, not merely been sent it. [DotNetManager] sets it for the entity a peer
## owns and predicts, and only that one, because that peer reads a property's absence as
## the server's word that it is unchanged and rewinds its prediction to the value it last
## received — see [method authoritative_values]. With the ordinary rule a send that is
## lost leaves that value stale until the peer's acknowledgement of a LATER snapshot
## reaches the server, a round trip at best, and every snapshot in between rewinds the
## player to where they were before the lost one: a rubber band on exactly the moment a
## player stops, which is when a stale position is most visible. For a property that
## changes every snapshot it costs nothing, since it is sent anyway; for one that changes
## once it is a round trip's worth of re-sends of one entity, per peer.
func collect_dirty(
	peer_id: int,
	force: bool = false,
	until_acked: bool = false
) -> Array[DotNetVar]:
	var out: Array[DotNetVar] = []
	var view := _view_for(peer_id)
	var owner := identity.owner_peer_id
	# Only asked for when something here is rate-limited: a clock read per behaviour per
	# peer per snapshot is a thousand of them a tick on a full server, for nothing.
	var now := -1
	var believed := view.believed

	# [b]Written out rather than calling `visible_to`, `_read_for_send` and `_is_dirty` per
	# property[/b]: this loop runs for every property of every relevant entity for every peer,
	# about thirteen thousand times a snapshot with thirty-two players, and a GDScript call
	# costs more than the comparison it wraps. The three are still the definitions; this is
	# them inlined, in the same order, and `netcode_demo`'s dirty-tracking sections hold it.
	for declaration in net_vars:
		match declaration.audience:
			DotNetVar.Audience.OWNER:
				if peer_id != owner:
					continue
			DotNetVar.Audience.OBSERVERS:
				if peer_id == owner:
					continue

		var property := declaration.property

		if not force and declaration.max_rate > 0.0:
			if now < 0:
				now = Time.get_ticks_msec()
			var interval := 1000.0 / declaration.max_rate
			var last := float(view.last_sent_ms.get(property, -100000))
			if float(now) - last < interval:
				continue

		var current: Variant
		if _snapshot_reads_open and _snapshot_reads.has(property):
			current = _snapshot_reads[property]
		else:
			current = _read_for_send(property)

		if force:
			out.append(declaration)
			continue

		# `differs` inlined for the common declaration, with no epsilon: there it is
		# exactly "a different type, or not equal" (see [method DotNetVar.differs]).
		var dirty: bool
		if not believed.has(property):
			dirty = true
		elif declaration.epsilon <= 0.0:
			var old: Variant = believed[property]
			dirty = typeof(old) != typeof(current) or old != current
		else:
			dirty = declaration.differs(believed[property], current)

		# "Spawn only" means "do not pay for it every snapshot", not "never update": sent
		# when it changes, and never kept owed until acknowledged as the predicted entity's
		# properties are.
		if declaration.on_spawn_only and not dirty:
			continue

		# A property once lost is owed until confirmed, like the predicted entity's.
		var owed := until_acked
		if not owed and view.relost.has(property):
			if _is_unconfirmed(view, declaration, current):
				owed = true
			else:
				view.relost.erase(property)

		if not dirty and not (owed and _is_unconfirmed(view, declaration, current)):
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


## Whether the peer has yet to confirm [param current]. Against [member PeerView.acked]
## rather than [member PeerView.believed]; see [method collect_dirty]'s [param until_acked].
func _is_unconfirmed(
	view: PeerView,
	declaration: DotNetVar,
	current: Variant
) -> bool:
	if not view.acked.has(declaration.property):
		return true
	return declaration.differs(view.acked[declaration.property], current)


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

	# [b]Encoded once per snapshot for each distinct set of properties, not once per peer.[/b]
	# Inside a snapshot every property is read once (see [member _snapshot_reads]), so the
	# same set of properties is the same bits for every peer it goes to -- and for a moving
	# player that set is the same for every peer but its owner. Encoding it again per peer
	# was the quadratic part of a full server's snapshots (game-g2gfast tools/load_probe,
	# 32 players). The per-peer half -- what that peer is believed to hold, when it was last
	# sent, what is unconfirmed -- is still per peer, below; the values recorded are one
	# dictionary shared by every peer's pending entry, which nothing writes to after this.
	var pad := writer.bit_length() & 7
	var found := _encoded_for(declarations, pad)
	var encoded: Array = found[0]

	if bool(found[1]):
		writer.write_bit_run(encoded[0], pad, int(encoded[1]))
	else:
		writer.write_shifted_run(encoded[0], int(encoded[1]))
	var recorded: Dictionary = encoded[2]

	if recorded.is_empty():
		return

	# One merge rather than a loop of assignments, and a send time only for what is
	# rate-limited, since nothing else reads one ([member DotNetVar.max_rate]): at 32
	# players this loop ran for every property of every entity for every peer.
	view.believed.merge(recorded, true)
	var rated: Array = encoded[3]
	if not rated.is_empty():
		var now := Time.get_ticks_msec()
		for property: StringName in rated:
			view.last_sent_ms[property] = now

	if tick <= 0:
		# Untracked: assume delivered, which is the only assumption available when
		# the caller has not said which snapshot this belongs to.
		view.acked.merge(recorded, true)
		return

	view.pending.append({"tick": tick, "values": recorded})


## Bits [method write_state] would add for [param declarations] to a writer standing
## [param pad] bits into a byte (its [code]bit_length() & 7[/code]).
##
## Exact, not an estimate, and the encoding it measures is the one [method write_state] then
## copies: inside a snapshot both read the same cache, so asking first costs a lookup. What
## [DotNetManager] decides where a snapshot is cut into parts with
## ([member DotNetConfig.mtu]); [method estimated_bits] is a full update's guess and can be
## several times the real figure, or short of it for a string.
func state_bits(declarations: Array[DotNetVar], pad: int) -> int:
	var found := _encoded_for(declarations, pad & 7)
	var encoded: Array = found[0]
	if bool(found[1]):
		return int(encoded[1]) - (pad & 7)
	return int(encoded[1])


## The encoding of [param declarations] for a writer [param pad] bits into a byte, as
## [code][encoded, aligned][/code]: the [method _encode] result, and whether it was encoded at
## that bit (copied with [method DotNetWriter.write_bit_run]) or at bit 0 (shifted into place).
func _encoded_for(declarations: Array[DotNetVar], pad: int) -> Array:
	var encoded: Array = []
	# [b]One shared copy, shifted into place -- unless something in it is byte-aligned.[/b] A
	# string or bytes aligns before its bytes, so where its padding falls depends on the bit
	# of a byte the encoding starts at; such a set is encoded at the bit it will be laid in
	# at (one copy per bit, eight at most) and copied, never shifted. Encoding everything per
	# bit instead cost a fifth of the saving, because entities start at every bit in turn.
	var key := _signature(declarations) if _snapshot_reads_open else -1
	var aligned := false
	if key >= 0:
		# The set's bitmask against the byte-aligned declarations', rather than a call
		# per declaration per peer.
		aligned = (key & _align_mask) != 0
	else:
		for declaration in declarations:
			if declaration.may_align():
				aligned = true
				break
	var at := pad if aligned else 0

	if key >= 0:
		var at_pad: Dictionary = _encoded.get(at, {})
		if at_pad.has(key):
			encoded = at_pad[key]
		else:
			encoded = _encode(declarations, at)
			at_pad[key] = encoded
			_encoded[at] = at_pad

	if encoded.is_empty():
		encoded = _encode(declarations, at)

	return [encoded, aligned]


## The encoding of [param declarations], as [code][bytes, end bit, recorded, rate-limited
## properties][/code], begun
## [param pad] zero bits into its first byte.
##
## An index per property rather than a full bitmask: with a handful of properties the
## index is smaller, and it does not need the receiver to know the declaration order
## beyond the shared registration.
func _encode(declarations: Array[DotNetVar], pad: int = 0) -> Array:
	var scratch := DotNetWriter.new(64)
	var recorded := {}
	var rated: Array[StringName] = []

	if pad > 0:
		scratch.write_bits(0, pad)

	scratch.write_uint(declarations.size(), 6)

	for declaration in declarations:
		var index := int(_index_of.get(declaration, -1))
		if index < 0:
			index = net_vars.find(declaration)
		if index < 0:
			continue

		var value: Variant = _read_for_send(declaration.property)

		scratch.write_uint(index, 6)
		declaration.write(scratch, value)
		recorded[declaration.property] = value
		if declaration.max_rate > 0.0:
			rated.append(declaration.property)

	return [scratch.to_bytes(), scratch.bit_length(), recorded, rated]


## [param declarations] as a bitmask of their indices, or -1 when it cannot stand for them:
## out of declaration order (the bits would be the same for two different encodings) or
## an index past what an int holds.
func _signature(declarations: Array[DotNetVar]) -> int:
	var key := 0
	var last := -1

	for declaration in declarations:
		var index := int(_index_of.get(declaration, -1))
		if index <= last or index >= 62:
			return -1
		key |= 1 << index
		last = index

	# The empty set is a real set (a count of zero), kept apart from "no key".
	return key | (1 << 62)


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

	# The resolved entries are a prefix (pending is in tick order), so they come off the
	# front; see [method trim_pending] for why not a rebuilt list.
	var resolved := 0
	var count := view.pending.size()
	var dropped := false

	while resolved < count:
		var entry: Dictionary = view.pending[resolved]
		var entry_tick := int(entry["tick"])

		if entry_tick > acked_tick:
			break

		resolved += 1

		if entry_tick == acked_tick or not view.strict:
			view.acked.merge(entry["values"], true)
		else:
			# Sent before a snapshot the peer has already applied, and still
			# unconfirmed. Dropped without promotion, so it goes out again -- and stays
			# owed until confirmed (`relost`), because sent once more it can be lost
			# once more, and on a link that holds back every other snapshot the next
			# send is always the held one.
			dropped = true
			for property: StringName in entry["values"]:
				view.relost[property] = true

	if resolved == 0:
		return

	if resolved == count:
		view.pending.clear()
	else:
		for i in resolved:
			view.pending.pop_front()
	# [b]Only a DROP changes what the peer is believed to hold.[/b] `believed` is `acked`
	# with every pending entry laid over it in tick order, and the entries resolved here
	# are the oldest ones; promoting them moves their values from the front of that
	# overlay into `acked`, which is the same dictionary afterwards. Rebuilding anyway
	# was a copy of every property per entity per peer per acknowledgement -- a third
	# of a 32-player server's snapshot cost, measured (`game-g2gfast tools/load_probe`).
	if dropped:
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

	# [b]The oldest entry first, and nearly always that is the whole answer.[/b] Pending is
	# in tick order, so if its oldest entry is inside the window every entry is. Walking the
	# list into a new one regardless was an allocation and a pass over every unconfirmed send
	# per entity per peer per snapshot -- 3.3 ms of a 32-player server's tick, for a call
	# that trims nothing on all but the rare snapshot a peer stops acknowledging.
	if int(view.pending[0]["tick"]) >= oldest_tick:
		return

	# The aged-out entries are a prefix (pending is in tick order), so they come off the
	# front and nothing else is touched. Walking the whole list into a new one was a pass
	# over every unconfirmed send and a fresh array per entity per peer per snapshot for a
	# host whose acknowledgements are not arriving, where one entry ages out every
	# snapshot: 2.9 ms of a 32-player tick (`game-g2gfast tools/load_probe`, no acks).
	var aged := 0
	var count := view.pending.size()

	while aged < count:
		var entry: Dictionary = view.pending[aged]
		if int(entry["tick"]) >= oldest_tick:
			break

		if not view.strict:
			view.acked.merge(entry["values"], true)
		else:
			for property: StringName in entry["values"]:
				view.relost[property] = true

		aged += 1

	if aged == count:
		view.pending.clear()
	else:
		for i in aged:
			view.pending.pop_front()

	# Promoted (not strict) leaves `believed` as it was; see [method sync_peer_acks].
	if view.strict:
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
##
## [param rewind] is for a predicted entity, and it is what makes reconciliation see the
## server's answer rather than the client's own. See [method authoritative_values].
func read_state(reader: DotNetReader, tick: int, rewind: bool = false) -> DotResult:
	var count := reader.read_uint(6)

	if not reader.ok():
		return DotResult.fail(DotError.CODE_PARSE, "Truncated state header.")

	_read_now.clear()

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
		_read_now[declaration.property] = true

		if declaration.change_handler.is_valid():
			declaration.change_handler.call(previous, value)

	_finish_read(tick, rewind)
	return DotResult.success(count)


## What [method read_state] does for an entity a snapshot listed as unchanged: exactly a read
## of zero properties. The snapshot names the entity without a body (see
## [code]docs/wire.md#unchanged-entities[/code]), and every consumer downstream -- the rewind,
## `_net_state_applied`, the predictor, the interpolator -- has to see what it saw when the
## same entity came with an empty body, or a game's per-snapshot bookkeeping (and the
## relevance it infers from it) changes meaning with the wire.
func apply_unchanged(tick: int, rewind: bool = false) -> void:
	_read_now.clear()
	_finish_read(tick, rewind)


func _finish_read(tick: int, rewind: bool) -> void:
	if rewind:
		# Everything the snapshot left out goes back to what the server last said, BEFORE
		# `_net_state_applied` — because that hook is where every game in the family
		# rewinds its simulation, by copying these properties into it. On the owning
		# client these properties do not hold the server's state between snapshots: the
		# behaviour's own `_net_simulate` copies each predicted tick into them. So a
		# snapshot that carried the entity with nothing changed handed the game its own
		# prediction as the server's answer, and the replay then re-ran the lead on top of
		# it — a client the server was holding still walked away at twice its speed.
		for property: StringName in authoritative_values():
			if not _read_now.has(property):
				_net_write_property(property, _baseline[property])

	_net_state_applied(tick)


## The server's whole state for this behaviour as of the snapshot just read, on a receiving
## peer: what that snapshot carried, and for everything it did not, what the server last
## sent.
##
## [b]Why "not sent" can be read as "unchanged".[/b] A property is left out of a snapshot
## when it has not changed against what the peer is believed to have, and for the entity a
## peer owns and predicts, the server also re-sends anything the peer has not yet
## [i]confirmed[/i] — see [method collect_dirty]'s [param until_acked] — so a lost packet
## cannot leave a stale value here that then reads as the server's word. The one exception
## is a property with a [member DotNetVar.max_rate]: it is left out because its rate
## limit was hit, not because it stood still, so its last received value is only a guess
## and is left out of this answer rather than rewound to.
##
## [b]Not [method snapshot_values][/b], which reads the properties themselves — and on a
## predicted entity those hold the client's own prediction, not anything the server said.
## Treating that as authoritative is the bug this exists to fix.
func authoritative_values() -> Dictionary:
	var out := {}

	for declaration in net_vars:
		var property := declaration.property

		if not _baseline.has(property):
			# Never received: invisible to this peer, or not sent yet. Nothing to rewind to.
			continue

		if declaration.max_rate > 0.0 and not _read_now.has(property):
			continue

		out[property] = _baseline[property]

	return out


## Every property's value as the server last sent it, on a receiving peer, whether or not
## the snapshot just read carried it. Unlike [method authoritative_values] it keeps a
## rate-limited property's last value: for drawing, the last thing the server said is the
## best answer there is, where for a rewind it is only a guess.
##
## What the manager hands the interpolator for a remote entity. The properties themselves
## are the wrong source there for the same reason they are on a predicted entity: between
## snapshots they hold whatever the client last wrote into them — the interpolator's blend.
func received_values() -> Dictionary:
	var out := {}

	for declaration in net_vars:
		if _baseline.has(declaration.property):
			out[declaration.property] = _baseline[declaration.property]

	return out


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
		_read_now.clear()
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
	# Asked once per entity per peer per snapshot, and its answer depends only on
	# whether the peer is the owner (see [method DotNetVar.visible_to]) -- so two
	# numbers, worked out once and again only if the declarations change.
	var is_owner := peer_id == identity.owner_peer_id
	if _estimate_for != net_vars.size():
		_estimate_owner = -1
		_estimate_other = -1
		_estimate_for = net_vars.size()
	var cached := _estimate_owner if is_owner else _estimate_other
	if cached >= 0:
		return cached
	var total := 6
	for declaration in net_vars:
		if declaration.visible_to(peer_id, identity.owner_peer_id):
			total += 6 + declaration.estimated_bits()
	if is_owner:
		_estimate_owner = total
	else:
		_estimate_other = total
	return total


var _estimate_owner: int = -1
var _estimate_other: int = -1
var _estimate_for: int = -1


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
