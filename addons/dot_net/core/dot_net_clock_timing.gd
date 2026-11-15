extends "dot_net_clock_state.gd"

## The timing half of [DotNetClock]: tick reads, round-trip time, stalls and the lead and catch-up thresholds.


## The most a tick is lengthened to give lead back: [constant MAX_DRIFT_RATE], or [constant LEAD_RAISE_RATE] while the latest report says its command arrived more than [constant LEAD_EARLY_TICKS] past the slack early.
##
## The drift rate alone is too slow to give back a large lead; a command that arrived that early says the lead really is too large.
func _slowest() -> float:
	if _last_arrival_lead - lead_slack_ticks <= LEAD_EARLY_TICKS:
		return MAX_DRIFT_RATE
	return LEAD_RAISE_RATE


## How far behind its target the input timeline may fall before it jumps forward, in ticks.
##
## Within it a command still lands before its tick; past it every tick of smoothing is a command the server throws away. See [method sync_from_server].
func catch_up_threshold_ticks() -> int:
	return maxi(1, _target_lead() - one_way_ticks())


## [constant SNAP_THRESHOLD_SECONDS] in ticks, at this clock's rate.
##
## At least one tick, so an absurdly low rate still snaps on a different session.
func snap_threshold_ticks() -> int:
	return maxi(1, int(roundf(SNAP_THRESHOLD_SECONDS * float(tick_rate))))


## Ticks a packet spends in flight, one way. Half the measured round trip.
##
## Zero until an RTT sample arrives: right on loopback, dangerous elsewhere. See [method sync_from_server].
func one_way_ticks() -> int:
	return int(roundf((_rtt_ms * 0.5) / 1000.0 * float(tick_rate) * _pace))


## How far ahead of the estimated server tick the input timeline should run.
##
## The flight time is part of the lead, not just the margin ([method one_way_ticks]): a timeline only [member input_margin_ticks] ahead produces commands that land after their tick, are discarded as late, and read as a broken predictor.
func _target_lead() -> int:
	var margin := input_margin_ticks

	if adaptive_margin:
		# Cover the jitter as well as the mean. A connection whose latency varies by
		# 40 ms needs that much extra margin or a fifth of its commands arrive late.
		var jitter_ticks := int(ceilf(_jitter_ms / 1000.0 * float(tick_rate) * _pace))
		margin = maxi(margin, jitter_ticks + 1)

	return one_way_ticks() + margin


## Remembers a frame or a dropped stretch of [param seconds] ending at [param wall_usec], when it
## is long enough for a round trip measured across it to be wrong ([method _across_stall]).
func _note_stall(wall_usec: int, seconds: float) -> void:
	if seconds < RTT_STALL_SECONDS:
		return
	_stalls.append(Vector2(float(wall_usec) / 1000000.0, seconds))
	if _stalls.size() > RTT_STALL_MEMORY:
		_stalls.pop_front()


## Whether a round trip of [param rtt_ms] that ended now spans a stall that explains how far it
## is past the median: the time a ping waited for this process to read its answer is not the
## link's ([method _note_rtt] holds it near the median). Without a wall clock to compare (nothing handed to [method note_engine_frame]) never.
func _across_stall(rtt_ms: float) -> bool:
	# No untouched sample yet: nothing to hold near, and holding would pin every sample at 250 ms.
	if _last_wall_usec <= 0 or _stalls.is_empty() or _rtt_base <= 0.0:
		return false
	var excess := (rtt_ms - _rtt_base) / 1000.0
	if excess <= RTT_STALL_SECONDS:
		return false
	var now := float(_last_wall_usec) / 1000000.0
	var from := now - rtt_ms / 1000.0 - 1.0
	for stall in _stalls:
		if stall.x >= from and stall.y >= 0.5 * excess:
			return true
	return false


## Round trip samples held down because a stall explains them.
func rtt_rejected() -> int:
	return _rtt_rejected


func _note_rtt(rtt_ms: float) -> void:
	if rtt_ms <= 0.0:
		return

	var held_down := _across_stall(rtt_ms)
	if not held_down:
		_hold_since_usec = 0
	elif _hold_since_usec == 0:
		_hold_since_usec = _last_wall_usec
	elif float(_last_wall_usec - _hold_since_usec) / 1000000.0 > RTT_HOLD_SECONDS:
		held_down = false
	if held_down:
		# Held to a quarter second past the median rather than dropped: the frames a stall
		# leaves behind do delay a command, and the spread it adds to the margin covers them.
		_rtt_rejected += 1
		var held := _rtt_base + RTT_STALL_SECONDS * 1000.0
		DotLog.debug(CHANNEL, "round trip held; a stall explains it",
			{"rtt": snappedf(rtt_ms, 0.1), "held": snappedf(held, 0.1), "base": snappedf(_rtt_base, 0.1),
			"held_count": _rtt_rejected})
		rtt_ms = held

	_rtt_samples.append(rtt_ms)
	if _rtt_samples.size() > RTT_SAMPLE_COUNT:
		_rtt_samples.pop_front()
	var untouched := not held_down

	# Median rather than mean: one 2-second stall from a Wi-Fi retransmit would drag
	# a mean far enough to add a hundred ms of input latency for the next minute.
	var sorted := _rtt_samples.duplicate()
	sorted.sort()
	_rtt_ms = sorted[sorted.size() / 2]
	if untouched:
		_rtt_base = _rtt_ms

	# Jitter as mean absolute deviation from the median — cheaper than a standard
	# deviation and less sensitive to the same outliers.
	var total := 0.0
	for sample in _rtt_samples:
		total += absf(sample - _rtt_ms)
	_jitter_ms = total / float(_rtt_samples.size())


## The tick this client believes the server is simulating right now: the receive
## timeline plus the flight time.
func server_tick() -> int:
	return _received_tick + one_way_ticks() if not is_authority else tick


## The newest snapshot tick this client expects to hold now, as the quickest recent arrivals place it.
##
## What the render timeline is measured back from: the newest that has ARRIVED, not the one the server is building. See [member _received_tick].
func received_tick() -> int:
	return _received_tick if not is_authority else tick


## The tick inputs are being generated for. Ahead of the server.
func input_tick() -> int:
	return tick


## The tick to render, given an interpolation delay in ticks: that far behind the newest snapshot held ([method received_tick]), not behind the server's tick.
##
## Counting from the server's tick spends the flight time waiting for a snapshot in flight, so most frames extrapolate. Never ahead of the receive timeline.
func render_tick(delay_ticks: int) -> int:
	return mini(received_tick() - delay_ticks, received_tick())


func rtt_ms() -> float:
	return _rtt_ms


func jitter_ms() -> float:
	return _jitter_ms


func is_synced() -> bool:
	return is_authority or _synced


## Ticks of correction currently applied, for diagnostics.
func drift_percent() -> float:
	return (_drift_scale - 1.0) * 100.0


func seconds_to_ticks(seconds: float) -> int:
	return int(roundf(seconds * float(tick_rate)))


func ticks_to_seconds(ticks: int) -> float:
	return float(ticks) / float(tick_rate)
