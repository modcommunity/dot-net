class_name DotNetStats
extends RefCounted

## Counters for what the network is actually doing.
##
## [b]Netcode fails quietly.[/b] A game with a broken prediction model, a starving
## bandwidth budget or a client whose clock never synced still runs — it just feels
## bad, in ways players describe as "laggy" regardless of cause. These counters are
## what turn that into a diagnosis: a high correction rate is a determinism problem, a
## high starvation count is a bandwidth problem, a high late-input count is a clock
## problem, and they need entirely different fixes.
##
## Cheap enough to leave on in a shipping build. A game that only measures this in
## development finds out about the problem from its players.

## Rolling window for rates, in seconds.
const WINDOW_SEC := 1.0

## Samples kept for percentile estimates.
const SAMPLE_CAPACITY := 128

var bytes_sent: int = 0
var bytes_received: int = 0
var packets_sent: int = 0
var packets_received: int = 0
var messages_sent: int = 0
var messages_received: int = 0

## Packets that failed to decode. Non-zero means a schema mismatch or corruption.
var decode_failures: int = 0

## Messages refused for arriving from the wrong side.
var direction_violations: int = 0

## Messages dropped by a rate limit.
var rate_limited: int = 0

## Snapshots that arrived out of order.
var out_of_order: int = 0

## Snapshots that never arrived, inferred from gaps in tick numbers.
var snapshots_lost: int = 0

## Snapshots that did arrive. The denominator [method loss_rate] needs.
##
## Separate from [member packets_received] because they do not count the same
## thing: a packet carries inputs, commands and acks as well as snapshots, and on
## a server it carries no snapshots at all. Dividing losses by packets therefore
## gave a loss rate that fell as unrelated traffic rose.
var snapshots_received: int = 0

var _last_snapshot_tick: int = -1

## Rolling rates.
var bytes_sent_per_sec: float = 0.0
var bytes_received_per_sec: float = 0.0
var packets_sent_per_sec: float = 0.0

var _window_started_ms: int = 0
var _window_bytes_sent: int = 0
var _window_bytes_received: int = 0
var _window_packets_sent: int = 0

## Round-trip samples, for percentiles.
var _rtt_samples: Array[float] = []


func _init() -> void:
	_window_started_ms = Time.get_ticks_msec()


# --- Recording -------------------------------------------------------------

func note_sent(bytes: int, message_count: int = 1) -> void:
	bytes_sent += bytes
	packets_sent += 1
	messages_sent += message_count

	_window_bytes_sent += bytes
	_window_packets_sent += 1

	_maybe_roll()


func note_received(bytes: int, message_count: int = 1) -> void:
	bytes_received += bytes
	packets_received += 1
	messages_received += message_count

	_window_bytes_received += bytes

	_maybe_roll()


func note_decode_failure() -> void:
	decode_failures += 1


func note_direction_violation() -> void:
	direction_violations += 1


func note_rate_limited() -> void:
	rate_limited += 1


func note_rtt(rtt_ms: float) -> void:
	if rtt_ms <= 0.0:
		return

	_rtt_samples.append(rtt_ms)
	if _rtt_samples.size() > SAMPLE_CAPACITY:
		_rtt_samples.pop_front()


## Tracks snapshot ordering and infers loss from tick gaps.
##
## Inferred rather than measured: an unreliable channel gives no delivery report, so
## a gap between consecutive received ticks is the only evidence a packet went
## missing. It undercounts a burst that loses the newest packets, which is acceptable
## for a diagnostic.
func note_snapshot(tick: int) -> void:
	snapshots_received += 1

	if _last_snapshot_tick < 0:
		_last_snapshot_tick = tick
		return

	if tick <= _last_snapshot_tick:
		out_of_order += 1

		# A tick *older* than the newest was already counted as lost when the
		# gap it left was measured, and it has now turned up — reordered, not
		# dropped. Without this, any path that reorders reports steady loss on a
		# connection that is losing nothing, which is a diagnosis pointing at the
		# wrong subsystem. A repeat of the newest tick is a duplicate, not a
		# recovery, so it does not qualify.
		if tick < _last_snapshot_tick and snapshots_lost > 0:
			snapshots_lost -= 1

		return

	var gap := tick - _last_snapshot_tick
	if gap > 1:
		snapshots_lost += gap - 1

	_last_snapshot_tick = tick


## Closes the rolling window if it is due, whether or not traffic arrived.
##
## [DotNetManager] calls this every physics frame. The rates used to be rolled
## only from [method note_sent] and [method note_received], so a connection that
## went silent kept reporting the rate it had when it stopped — the one moment a
## rate is worth reading, and the one moment it was stale. A stalled peer showed
## a healthy 40 KiB/s indefinitely.
func roll() -> void:
	_maybe_roll()


func _maybe_roll() -> void:
	var now := Time.get_ticks_msec()
	var elapsed := now - _window_started_ms

	if elapsed < int(WINDOW_SEC * 1000.0):
		return

	var seconds := float(elapsed) / 1000.0

	bytes_sent_per_sec = float(_window_bytes_sent) / seconds
	bytes_received_per_sec = float(_window_bytes_received) / seconds
	packets_sent_per_sec = float(_window_packets_sent) / seconds

	_window_bytes_sent = 0
	_window_bytes_received = 0
	_window_packets_sent = 0
	_window_started_ms = now


# --- Derived ---------------------------------------------------------------

## Round-trip time at a percentile, in milliseconds.
##
## The 95th matters more than the mean. A connection whose mean is 40 ms and whose
## 95th is 300 ms feels far worse than one at a steady 80 ms, and the mean alone
## cannot tell them apart.
func rtt_percentile(percentile: float = 0.5) -> float:
	if _rtt_samples.is_empty():
		return 0.0

	var sorted := _rtt_samples.duplicate()
	sorted.sort()

	var index := clampi(
		int(float(sorted.size() - 1) * clampf(percentile, 0.0, 1.0)),
		0,
		sorted.size() - 1
	)

	return sorted[index]


## Estimated snapshot loss, 0..1.
##
## Losses over losses-plus-arrivals, both counted in snapshots. It used to divide
## by [member packets_received], which counts every packet of any kind — so a
## client sending plenty and receiving little reported a loss rate diluted by
## traffic that had nothing to do with snapshots, and a server reported 0.0
## because it receives no snapshots at all.
func loss_rate() -> float:
	var expected := snapshots_lost + snapshots_received
	if expected <= 0:
		return 0.0
	return float(snapshots_lost) / float(expected)


## Average bytes per packet sent. The number that says whether batching is working.
##
## Well below the MTU means many small packets and wasted header overhead; at the MTU
## means packets are full and something is probably being dropped by the budget.
func average_packet_bytes() -> float:
	if packets_sent == 0:
		return 0.0
	return float(bytes_sent) / float(packets_sent)


func reset() -> void:
	bytes_sent = 0
	bytes_received = 0
	packets_sent = 0
	packets_received = 0
	messages_sent = 0
	messages_received = 0
	decode_failures = 0
	direction_violations = 0
	rate_limited = 0
	out_of_order = 0
	snapshots_lost = 0
	snapshots_received = 0
	_last_snapshot_tick = -1
	_rtt_samples.clear()
	_window_bytes_sent = 0
	_window_bytes_received = 0
	_window_packets_sent = 0
	_window_started_ms = Time.get_ticks_msec()


func describe() -> Dictionary:
	return {
		"sent": DotPaths.format_bytes(bytes_sent),
		"received": DotPaths.format_bytes(bytes_received),
		"send_rate": "%s/s" % DotPaths.format_bytes(int(bytes_sent_per_sec)),
		"recv_rate": "%s/s" % DotPaths.format_bytes(int(bytes_received_per_sec)),
		"packets_sent": packets_sent,
		"packets_per_sec": int(packets_sent_per_sec),
		"avg_packet": "%.0f B" % average_packet_bytes(),
		"messages_sent": messages_sent,
		"rtt_p50": int(rtt_percentile(0.5)),
		"rtt_p95": int(rtt_percentile(0.95)),
		"loss": "%.1f%%" % (loss_rate() * 100.0),
		"lost_snapshots": snapshots_lost,
		"snapshots_received": snapshots_received,
		"out_of_order": out_of_order,
		"decode_failures": decode_failures,
		"direction_violations": direction_violations,
		"rate_limited": rate_limited,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var d := describe()
	var keys := d.keys()
	keys.sort()

	for key in keys:
		out.append("%-22s %s" % [str(key), str(d[key])])

	# Called out because they are the ones that are always a bug rather than a
	# condition — a healthy connection has zero of both, at any latency.
	if decode_failures > 0:
		out.append("")
		out.append("decode failures are non-zero: the peers' message schemas differ")
	if direction_violations > 0:
		out.append("direction violations are non-zero: a peer sent a message it may not send")

	return out
