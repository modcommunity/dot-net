class_name DotNetBudget
extends RefCounted

## Per-client bandwidth budget with a priority accumulator.
##
## [b]The problem.[/b] Interest management decides [i]what[/i] a client could
## receive. On a busy tick that is still more than its connection can carry. Something
## must be dropped, and the naive answers are both bad: dropping whatever comes last
## means the same entities are always starved, and sending everything means the
## connection backs up until it collapses.
##
## [b]The accumulator.[/b] Every entity carries a score that grows each tick it is
## [i]not[/i] sent, at a rate set by its priority and relevance. Sending resets it.
## So an important entity is sent often, an unimportant one is sent eventually, and
## nothing is starved forever — which is what makes a distant object update once a
## second instead of never.
##
## This is the same idea as any engine's net priority, and it exists for the same
## reason:
## a fixed priority order starves the tail, and round-robin ignores importance.

const CHANNEL := "net.budget"

## Per-peer state: accumulators and spending.
class PeerBudget extends RefCounted:
	var peer_id: int

	## net_id -> accumulated priority
	var accumulators: Dictionary = {}

	## net_id -> ticks since this entity was last sent to this peer.
	var starved_ticks: Dictionary = {}

	## Bytes sent in the current second.
	var bytes_this_second: int = 0
	var packets_this_second: int = 0
	var window_started_ms: int = 0

	## Rolling averages, for reporting.
	var bytes_per_sec: float = 0.0
	var packets_per_sec: float = 0.0

	## Entities skipped this tick because the budget ran out.
	var starved_this_tick: int = 0
	var total_starved: int = 0

	func _init(p_peer_id: int) -> void:
		peer_id = p_peer_id
		window_started_ms = Time.get_ticks_msec()


var config: DotNetConfig

## peer_id -> PeerBudget
var _peers: Dictionary = {}


func _init(p_config: DotNetConfig) -> void:
	config = p_config


func for_peer(peer_id: int) -> PeerBudget:
	if not _peers.has(peer_id):
		_peers[peer_id] = PeerBudget.new(peer_id)
	return _peers[peer_id]


func forget_peer(peer_id: int) -> void:
	_peers.erase(peer_id)


# --- Accumulation ----------------------------------------------------------

## Grows every candidate's accumulator, then returns them in send order.
##
## [param scores] maps net_id to this tick's relevance, from the interest strategy.
## Entities absent from it are not candidates and their accumulators are left alone —
## an entity that leaves interest and comes back should not have banked priority the
## whole time it was invisible.
func accumulate(
	peer_id: int,
	candidates: Array[DotNetIdentity],
	scores: Dictionary
) -> Array[DotNetIdentity]:
	var budget := for_peer(peer_id)

	for identity in candidates:
		var score := float(scores.get(identity.net_id, identity.priority))
		var current := float(budget.accumulators.get(identity.net_id, 0.0))

		var waited := int(budget.starved_ticks.get(identity.net_id, 0)) + 1
		budget.starved_ticks[identity.net_id] = waited

		budget.accumulators[identity.net_id] = current \
			+ maxf(0.0, score) + _starvation_boost(waited)

	var ordered := candidates.duplicate()
	ordered.sort_custom(func(a: DotNetIdentity, b: DotNetIdentity) -> bool:
		return float(budget.accumulators.get(a.net_id, 0.0)) \
			> float(budget.accumulators.get(b.net_id, 0.0))
	)

	return ordered


## Extra priority for an entity that has waited too long.
##
## [b]The accumulator alone does not bound starvation tightly enough.[/b] It
## guarantees everything is sent *eventually* — an entity gaining 0.1 a tick against
## one gaining 10 does win, after a hundred ticks. At 20 Hz that is five seconds of
## an object never updating, which players see as it being frozen.
##
## So once an entity has waited past the threshold, its priority grows superlinearly
## with the wait. That turns "eventually" into a bound: nothing goes more than
## roughly [member starvation_ticks] snapshots without being sent, whatever its
## nominal priority.
func _starvation_boost(waited_ticks: int) -> float:
	if waited_ticks <= starvation_ticks:
		return 0.0

	var over := float(waited_ticks - starvation_ticks)
	return over * over * starvation_weight


## Snapshots an entity may go unsent before its priority starts climbing.
var starvation_ticks: int = 10

## How hard the starvation boost pushes. Higher bounds the wait tighter and gives
## nominal priority less say.
var starvation_weight: float = 1.0


## Records that an entity was sent, resetting its accumulator.
func note_sent(peer_id: int, net_id: int, bytes: int) -> void:
	var budget := for_peer(peer_id)
	budget.accumulators[net_id] = 0.0
	budget.starved_ticks[net_id] = 0
	budget.bytes_this_second += bytes


## Records an entity that could not be sent this tick.
func note_starved(peer_id: int) -> void:
	var budget := for_peer(peer_id)
	budget.starved_this_tick += 1
	budget.total_starved += 1


# --- Spending --------------------------------------------------------------

## Whether [param bytes] more may be sent to this peer this second.
func can_spend(peer_id: int, bytes: int) -> bool:
	if config.per_client_budget <= 0:
		return true

	var budget := for_peer(peer_id)
	_roll_window(budget)

	return budget.bytes_this_second + bytes <= config.per_client_budget


## Bytes still available to this peer this second.
func remaining(peer_id: int) -> int:
	if config.per_client_budget <= 0:
		# A caller comparing against this needs a number, not a special case. One
		# megabyte is effectively unlimited for a single tick.
		return 1 << 20

	var budget := for_peer(peer_id)
	_roll_window(budget)

	return maxi(0, config.per_client_budget - budget.bytes_this_second)


## Whether another packet may be sent this second.
func can_send_packet(peer_id: int) -> bool:
	if config.per_client_packet_rate <= 0:
		return true

	var budget := for_peer(peer_id)
	_roll_window(budget)

	return budget.packets_this_second < config.per_client_packet_rate


func note_packet(peer_id: int, bytes: int) -> void:
	var budget := for_peer(peer_id)
	_roll_window(budget)

	budget.packets_this_second += 1
	budget.bytes_this_second += bytes


## Rolls the one-second window when it expires.
##
## A hard window rather than a token bucket: bandwidth here is a fairness mechanism
## between entities, not a shaping mechanism against a link, and a window is easier to
## read in a report than a bucket level.
func _roll_window(budget: PeerBudget) -> void:
	var now := Time.get_ticks_msec()
	var elapsed := now - budget.window_started_ms

	if elapsed < 1000:
		return

	var seconds := float(elapsed) / 1000.0
	budget.bytes_per_sec = float(budget.bytes_this_second) / seconds
	budget.packets_per_sec = float(budget.packets_this_second) / seconds

	budget.bytes_this_second = 0
	budget.packets_this_second = 0
	budget.window_started_ms = now


## Clears the per-tick starvation counter. Call at the start of each snapshot.
func begin_tick(peer_id: int) -> void:
	for_peer(peer_id).starved_this_tick = 0


# --- Reporting -------------------------------------------------------------

func peer_ids() -> PackedInt64Array:
	var out := PackedInt64Array()
	for peer_id in _peers:
		out.append(peer_id)
	out.sort()
	return out


func describe_peer(peer_id: int) -> Dictionary:
	if not _peers.has(peer_id):
		return {}

	var budget: PeerBudget = _peers[peer_id]
	_roll_window(budget)

	return {
		"peer": peer_id,
		"bytes_per_sec": int(budget.bytes_per_sec),
		"packets_per_sec": int(budget.packets_per_sec),
		"budget": config.per_client_budget,
		"utilisation": "%.0f%%" % (
			budget.bytes_per_sec / maxf(1.0, float(config.per_client_budget)) * 100.0
		),
		"tracked": budget.accumulators.size(),
		"starved": budget.total_starved,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("%-8s %-12s %-10s %-8s %s" % [
		"peer", "bytes/s", "packets/s", "used", "starved"
	])

	for peer_id in peer_ids():
		var d := describe_peer(peer_id)
		out.append("%-8d %-12s %-10d %-8s %d" % [
			peer_id,
			DotPaths.format_bytes(int(d["bytes_per_sec"])),
			int(d["packets_per_sec"]),
			str(d["utilisation"]),
			int(d["starved"]),
		])

	return out


func clear() -> void:
	_peers.clear()
