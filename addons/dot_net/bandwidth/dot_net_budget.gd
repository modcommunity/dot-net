class_name DotNetBudget
extends RefCounted

## Per-client bandwidth budget with a priority accumulator. [b]The problem.[/b] Interest management
## decides [i]what[/i] a client could receive.

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

	## Whether the tick that just ended starved anything, so the log can report the
	## edges rather than the condition. See [method DotNetBudget.begin_tick].
	var was_starving: bool = false

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


## Grows every candidate's accumulator, then returns them in send order. [param scores] maps net_id to
## this tick's relevance, from the interest strategy.
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

	return _by_accumulator(candidates, budget.accumulators)


## [method accumulate] for a worker thread: the same writes, into [param budget] (the peer's
## record from [method for_peer], made on the manager's thread, and written by no other
## thread), and the order as an untyped list (see [method DotNetInterest.relevance]).
func accumulate_record(
	budget: PeerBudget,
	candidates: Array,
	scores: Dictionary
) -> Array:
	var count := candidates.size()
	var values := PackedFloat64Array()
	values.resize(count)
	var accumulators := budget.accumulators
	var waits := budget.starved_ticks
	var threshold := starvation_ticks
	var weight := starvation_weight
	var i := 0
	for identity: DotNetIdentity in candidates:
		var id := identity.net_id
		var waited: int = int(waits.get(id, 0)) + 1
		waits[id] = waited
		var total: float = float(accumulators.get(id, 0.0)) + maxf(0.0, float(scores.get(id, identity.priority)))
		if waited > threshold:
			var over := float(waited - threshold)
			total += over * over * weight
		accumulators[id] = total
		values[i] = maxf(0.0, total)
		i += 1

	var ordered: Array = []
	_order_values_into(candidates, values, ordered)
	return ordered


## [param candidates], highest accumulator first.
static func _by_accumulator(
	candidates: Array[DotNetIdentity], accumulators: Dictionary
) -> Array[DotNetIdentity]:
	var ordered: Array[DotNetIdentity] = []
	_order_into(candidates, accumulators, ordered)
	return ordered


## [method _by_accumulator] into [param ordered], typed or not: untyped from
## [method accumulate_record] on a worker thread (see [method DotNetInterest.relevance]).
static func _order_into(
	candidates: Array, accumulators: Dictionary, ordered: Array
) -> void:
	var count := candidates.size()
	if count == 0:
		return
	var values := PackedFloat64Array()
	values.resize(count)
	for i in count:
		values[i] = maxf(0.0, float(accumulators.get(candidates[i].net_id, 0.0)))
	_order_values_into(candidates, values, ordered)


## The sort of [method _order_into], for a caller that already has the values.
static func _order_values_into(candidates: Array, values: PackedFloat64Array, ordered: Array) -> void:
	var count := candidates.size()
	if count == 0:
		return
	var index_bits := 1
	while (1 << index_bits) < count:
		index_bits += 1
	var low := (1 << index_bits) - 1
	var keys := values.to_byte_array().to_int64_array()
	for i in count:
		# Descending by value, then ascending by index: the value's bits inverted (still
		# non-negative, since the sign bit is clear) and the index as it is.
		keys[i] = ((0x7FFFFFFFFFFFFFFF - keys[i]) & ~low) | i
	keys.sort()
	ordered.resize(count)
	for i in count:
		ordered[i] = candidates[keys[i] & low]


## Extra priority for an entity that has waited too long. [b]The accumulator alone does not bound
## starvation tightly enough.[/b] It guarantees everything is sent *eventually* — an entity gaining 0.1
## a tick against one gaining 10 does win, after a hundred ticks.
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


## Rolls the one-second window when it expires. A hard window rather than a token bucket: bandwidth
## here is a fairness mechanism between entities, not a shaping mechanism against a link, and a window
## is easier to read in a report than a bucket level.
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
	var budget := for_peer(peer_id)
	var starving := budget.starved_this_tick > 0

	if starving != budget.was_starving:
		if starving:
			DotLog.debug(CHANNEL, "a peer's budget ran out", {
				"peer": peer_id,
				"starved": budget.starved_this_tick,
				"bytes_this_second": budget.bytes_this_second,
				"budget": config.per_client_budget,
			})
		else:
			DotLog.debug(CHANNEL, "a peer's budget is keeping up again", {
				"peer": peer_id, "total_starved": budget.total_starved
			})

		budget.was_starving = starving

	budget.starved_this_tick = 0


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
