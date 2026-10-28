@tool
extends Node

## The per-peer view and encode-cache records of [DotNetBehaviour], in a base file of their own.
## Nothing here is used on its own.

const CHANNEL := "net.behaviour"

## The identity this belongs to. Set when the identity collects behaviours.
var identity: DotNetIdentity = null

## Declared properties, in registration order.
var net_vars: Array[DotNetVar] = []

## property -> last value received, on a receiving peer. The receive side only; the send side is
## [member _views], one entry per peer (see [PeerView]).
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


## What one peer is believed to have, and what it has confirmed. Per peer because one shared dirty
## dictionary let the first peer served mark everything clean for all. [member acked] is confirmed,
## [member pending] is sent since (oldest first), [member believed] is acked with pending laid over; a lost snapshot leaves pending and its properties go dirty again.
class PeerView extends RefCounted:
	## property -> value the peer has confirmed.
	var acked: Dictionary = {}

	## property -> value we believe the peer has or is about to have.
	var believed: Dictionary = {}

	## [code]{"tick": int, "values": Dictionary}[/code], ascending by tick. An [Array] because it is only
	## appended at the newest tick and consumed from the oldest, so insertion order is tick order.
	var pending: Array[Dictionary] = []

	## property -> last send time in ms, for [member DotNetVar.max_rate].
	var last_sent_ms: Dictionary = {}

	## Newest tick this peer has acknowledged.
	var last_ack: int = 0

	## property -> true for a property whose send this peer never confirmed and which was
	## dropped as lost: owed until the peer confirms it, not merely until it is sent again.
	## See [method collect_dirty].
	var relost: Dictionary = {}

	## Whether acknowledgements are arriving for this peer. Until one does, an unconfirmed snapshot is
	## assumed delivered once it ages out of the window (no loss recovery), as for a host that has not
	## wired [method DotNetManager.receive_ack].
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


## Within one snapshot, what [method write_state] and [method collect_dirty] remember between peers:
## each distinct set encoded, the last set signed, the dirty sets shared by peers in step. A worker
## task has one per behaviour, since two threads filling one would race; a memo of pure reads.
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



## Declare replicated properties here, with [method replicate].
func _register_net_vars() -> void:
	pass


## Called once this entity has a network id, on every peer: the place for setup that needs
## [member DotNetIdentity.is_owner] or authority, neither known in [method Node._ready].
func _net_ready() -> void:
	pass


## Called before the entity is removed from the network.
func _net_removed() -> void:
	pass


## Fixed-tick simulation. Runs only where this entity can be simulated ([method DotNetIdentity.can_simulate]).
## On a predicted entity it runs on the owning client and the server with the same inputs, so it must
## be deterministic: no wall clock, unseeded random, or other players' unpredicted state.
func _net_simulate(_tick: int, _delta: float) -> void:
	pass


## Whether simulating this behaviour on its owning client would change anything now, asked on a
## predicted entity after a reconcile rewound it. False when every behaviour says so (a dead player
## simulates nothing) and the rewind is kept without replaying the lead. Default true.
func _net_predicts() -> bool:
	return true


## Called on a receiving peer after a batch of properties is applied.
##
## For work that should happen once per update rather than once per property.
func _net_state_applied(_tick: int) -> void:
	pass


## Reads a property. Override to compute rather than store. Called every frame on a remote entity after
## [DotNetInterpolator] wrote the smoothed values, unlike [method _net_state_applied] (snapshot rate).
## It does not record the tick: it is a render tick, and recording it would make reconciliation rewind to one never sent.
func _net_interpolated(_tick: int) -> void:
	pass


func _net_read_property(property: StringName) -> Variant:
	return get(property)
