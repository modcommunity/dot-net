@tool
extends Node

## The per-peer view and encode-cache records of [DotNetBehaviour], in a base file of their own.
## Nothing here is used on its own.

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

## The tick of the snapshot [member _baseline] was last read from, on a receiving peer; -1
## before the first. What [method extrapolated_value] measures the age of what it heard by.
var _read_tick: int = -1


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

	## The snapshot serial ([member DotNetBehaviour._read_serial]) whose reads [member believed]
	## matches, property for property, or -1 when it is not known to match any. What lets
	## [method DotNetBehaviour.collect_dirty] share one answer between peers.
	var synced_serial: int = -1

	## What [method DotNetBehaviour.collect_dirty] last returned for this peer, and in which
	## snapshot: [method DotNetBehaviour.write_state] given that same array in that same
	## snapshot leaves [member believed] equal to the snapshot's reads.
	var collected: Array[DotNetVar] = []
	var collected_serial: int = -1

	## Everything this view records, as plain values, for a test to compare two views by.
	## Nothing was ever collected, sent or acknowledged into it: what [method view_for] makes,
	## and what every reader treats exactly as no view at all.
	func is_fresh() -> bool:
		return pending.is_empty() and believed.is_empty() and acked.is_empty() \
			and last_sent_ms.is_empty() and relost.is_empty() and collected.is_empty() \
			and last_ack == 0 and not strict and synced_serial == -1 and collected_serial == -1

	func snapshot() -> Dictionary:
		var entries := []
		for entry in pending:
			entries.append([int(entry["tick"]), (entry["values"] as Dictionary).duplicate()])
		var names := []
		for declaration in collected:
			names.append(declaration.property)
		return {
			"acked": acked.duplicate(), "believed": believed.duplicate(), "pending": entries,
			"last_sent_ms": last_sent_ms.duplicate(), "last_ack": last_ack,
			"relost": relost.duplicate(), "strict": strict, "synced_serial": synced_serial,
			"collected": names, "collected_serial": collected_serial,
		}


## Within one snapshot, what [method write_state] and [method collect_dirty] remember between
## peers: each distinct set of properties encoded, the last set signed, and the dirty sets
## shared by peers in step. The manager's own thread keeps
## these in the behaviour's own members ([member _encoded] and the rest); a snapshot built on
## workers has one per behaviour per task when snapshots are built on workers,
## because these are filled in as peers ask and two threads filling one would race. A
## memo of answers that depend only on the snapshot's reads, so any number of them give the
## same bits.
class EncodeCache extends RefCounted:
	## The encoding of each distinct set of properties, by the bit of a byte it starts at
	## (always 0 for a set with nothing byte-aligned in it) and then by the set, as a bitmask
	## of declaration indices. See [method DotNetBehaviour.write_state].
	var encoded: Dictionary = {}

	## The last declarations array [method DotNetBehaviour._signature] was worked out for,
	## and its answer.
	var signed: Array = []
	var signed_key: int = -1

	## The last shared set found with nothing byte-aligned in it, and its encoding: what
	## [method DotNetBehaviour.write_state] reuses for the next peer given that same array.
	var fast_declarations: Array = []
	var fast_encoded: Array = []

	## [code]synced serial * 2 + is owner[/code] -> the dirty set every peer in step from that
	## serial is owed. See [method DotNetBehaviour.collect_dirty].
	var shared_dirty: Dictionary = {}

	func clear() -> void:
		encoded.clear()
		signed = []
		signed_key = -1
		fast_declarations = []
		fast_encoded = []
		shared_dirty.clear()


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


## Whether simulating this behaviour on its owning client would change anything now.
## Asked on a predicted entity after a reconcile has rewound it to the server's state.
##
## [b]A replay of a simulation that does nothing is the whole lead for nothing.[/b] A dead
## player simulates nothing, while the server moves its body anyway (a fall, a push, a
## spectator's view), so no snapshot can match the prediction and every one replayed the
## whole input lead to land where the rewind had already put it: game-arena's client,
## dead, replayed 10 ticks on every snapshot (2026-10-17). False when every behaviour of
## the entity says so, and the rewind is kept without a replay. Default true. Decide from
## the rewound state ([method _net_state_applied] has run), so the snapshot that
## respawns the player replays as usual.
func _net_predicts() -> bool:
	return true


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
