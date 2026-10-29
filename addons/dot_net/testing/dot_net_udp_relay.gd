extends RefCounted

## A lossy UDP relay: real datagrams, between a real client and a real server, dropped, delayed,
## reordered and duplicated on a seed.

const CHANNEL := "net.relay"

## How one direction treats the datagrams it carries.
class Impairment extends RefCounted:
	## Chance a datagram is dropped, 0..1.
	var loss: float = 0.0

	## Chance a datagram that survives is delivered twice. The copy gets its own delay, so
	## it can arrive before the original as easily as after it.
	var duplicate: float = 0.0

	## Mean one-way delay added to every datagram, milliseconds.
	var delay_ms: float = 0.0

	## Each datagram's delay is drawn uniformly from [code]delay_ms +- jitter_ms[/code].
	## A spread wider than the gap between two datagrams reorders them, exactly as it
	## does on a real path, so there is no separate reorder switch for the common case.
	var jitter_ms: float = 0.0

	## Chance a datagram is held back a further [member reorder_ms] on top of its delay:
	## reordering on a path whose jitter alone would not cause it.
	var reorder: float = 0.0
	var reorder_ms: float = 0.0

	## Datagrams that reached the relay in this direction.
	var received: int = 0
	## Of those, dropped.
	var dropped: int = 0
	## Extra copies sent.
	var duplicated: int = 0
	## Datagrams put on the wire towards the far end, copies included.
	var delivered: int = 0
	## Delivered behind a datagram that reached the relay after it.
	var reordered: int = 0
	## The longest and shortest delay actually applied, milliseconds.
	var max_delay_ms: float = 0.0
	var min_delay_ms: float = INF

	var _rng := RandomNumberGenerator.new()
	var _next_seq: int = 0
	var _newest_delivered_seq: int = -1

	func configure(p_loss: float, p_delay_ms: float, p_jitter_ms: float, p_duplicate: float = 0.0) -> Impairment:
		loss = p_loss
		delay_ms = p_delay_ms
		jitter_ms = p_jitter_ms
		duplicate = p_duplicate
		return self

	func loss_ratio() -> float:
		return float(dropped) / float(received) if received > 0 else 0.0

	func reset_counts() -> void:
		received = 0
		dropped = 0
		duplicated = 0
		delivered = 0
		reordered = 0
		max_delay_ms = 0.0
		min_delay_ms = INF

	func describe() -> Dictionary:
		return {
			"loss": loss, "delay_ms": delay_ms, "jitter_ms": jitter_ms,
			"duplicate": duplicate, "reorder": reorder,
			"received": received, "dropped": dropped, "duplicated": duplicated,
			"delivered": delivered, "reordered": reordered,
			"measured_loss": "%.3f" % loss_ratio(),
			"delay_range_ms": [
				snappedf(min_delay_ms if min_delay_ms != INF else 0.0, 0.1),
				snappedf(max_delay_ms, 0.1),
			],
		}

	## What happens to one datagram: a list of delays in microseconds, one per copy to
	## deliver. Empty is dropped.
	func _fate() -> Array[int]:
		received += 1
		var out: Array[int] = []

		if _rng.randf() < loss:
			dropped += 1
			return out

		out.append(_delay_usec())

		if duplicate > 0.0 and _rng.randf() < duplicate:
			duplicated += 1
			out.append(_delay_usec())

		return out

	func _delay_usec() -> int:
		var ms := delay_ms

		if jitter_ms > 0.0:
			ms += _rng.randf_range(-jitter_ms, jitter_ms)

		if reorder > 0.0 and _rng.randf() < reorder:
			ms += reorder_ms

		ms = maxf(0.0, ms)
		max_delay_ms = maxf(max_delay_ms, ms)
		min_delay_ms = minf(min_delay_ms, ms)
		return int(ms * 1000.0)


## Client to server.
var up := Impairment.new()

## Server to client.
var down := Impairment.new()

## Seeds both directions. Set before [method start]; the two directions take
## [code]seed[/code] and [code]seed + 1[/code], so loss on the way up does not mirror
## loss on the way down.
var seed: int = 1

## Run the relay on its own thread (the default). False: the harness calls [method poll].
var threaded: bool = true

## How long the thread sleeps between polls, microseconds. A quarter of a millisecond keeps
## a delay accurate to well under a tick at any tick rate in the family.
var poll_interval_usec: int = 250

## A client the relay has seen: the socket it answers on, and the one it forwards from.
class Flow extends RefCounted:
	var client: PacketPeerUDP = null
	var upstream: PacketPeerUDP = null
	var label: String = ""

var _listener: UDPServer = null
var _target_host: String = ""
var _target_port: int = 0
var _flows: Array[Flow] = []

## Pending deliveries, kept sorted by due time: [due_usec, seq, Flow, to_server, bytes, order].
var _queue: Array = []
var _order: int = 0

var _thread: Thread = null
var _mutex := Mutex.new()
var _running: bool = false
var _port: int = 0


## Listens on [param listen_port] (0 picks one; see [method port]) and forwards every
## client it hears to [param target_host]:[param target_port].
func start(listen_port: int, target_host: String, target_port: int, bind_address: String = "127.0.0.1") -> DotResult:
	if _listener != null:
		return DotResult.fail(DotError.CODE_STATE, "The relay is already running.")

	up._rng.seed = seed
	down._rng.seed = seed + 1

	_listener = UDPServer.new()
	# Every datagram from a new address is a new client, and a test with a few of them
	# must never meet the default backlog.
	_listener.max_pending_connections = 64
	var err := _listener.listen(listen_port, bind_address)

	if err != OK:
		_listener = null
		return DotResult.failure(
			DotError.from_engine(err, "relay listening on UDP %d" % listen_port)
		)

	_port = _listener.get_local_port()
	_target_host = target_host
	_target_port = target_port
	_running = true

	if threaded:
		_thread = Thread.new()
		_thread.start(_loop)

	DotLog.info(CHANNEL, "relay listening", {
		"port": _port, "target": "%s:%d" % [target_host, target_port],
		"up": up.describe(), "down": down.describe(),
	})
	return DotResult.success(_port)


## The UDP port clients should connect to.
func port() -> int:
	return _port


func is_running() -> bool:
	return _running


## Stops the thread and closes every socket. Anything still queued is discarded, which is
## what a path that went away does to it.
func stop() -> void:
	if not _running:
		return

	_mutex.lock()
	_running = false
	_mutex.unlock()

	if _thread != null:
		_thread.wait_to_finish()
		_thread = null

	for flow in _flows:
		flow.client.close()
		flow.upstream.close()

	_flows.clear()
	_queue.clear()

	if _listener != null:
		_listener.stop()
		_listener = null


## Changes one direction's impairment while running. Counters are kept.
func set_impairment(to_server: bool, loss: float, delay_ms: float, jitter_ms: float, duplicate: float = 0.0) -> void:
	_mutex.lock()
	(up if to_server else down).configure(loss, delay_ms, jitter_ms, duplicate)
	_mutex.unlock()


## Zeroes both directions' counters, for a measuring window.
func reset_counts() -> void:
	_mutex.lock()
	up.reset_counts()
	down.reset_counts()
	_mutex.unlock()


## How many clients the relay has carried.
func flow_count() -> int:
	_mutex.lock()
	var n := _flows.size()
	_mutex.unlock()
	return n


func _loop() -> void:
	while true:
		_mutex.lock()
		var running := _running
		_mutex.unlock()

		if not running:
			return

		poll()
		OS.delay_usec(poll_interval_usec)


## One pass: take what has arrived from either side, and deliver what is due.
func poll() -> void:
	_mutex.lock()

	if _listener == null:
		_mutex.unlock()
		return

	var now := Time.get_ticks_usec()

	_listener.poll()

	while _listener.is_connection_available():
		var flow := Flow.new()
		flow.client = _listener.take_connection()
		flow.upstream = PacketPeerUDP.new()
		flow.label = "%s:%d" % [flow.client.get_packet_ip(), flow.client.get_packet_port()]

		var err := flow.upstream.connect_to_host(_target_host, _target_port)

		if err != OK:
			DotLog.warn(CHANNEL, "could not open the upstream socket", {"error": error_string(err)})
			flow.client.close()
			continue

		_flows.append(flow)

	for flow in _flows:
		while flow.client.get_available_packet_count() > 0:
			_schedule(flow, true, flow.client.get_packet(), now)

		while flow.upstream.get_available_packet_count() > 0:
			_schedule(flow, false, flow.upstream.get_packet(), now)

	while not _queue.is_empty() and int(_queue[0][0]) <= now:
		var item: Array = _queue.pop_front()
		var to_server: bool = item[3]
		var flow: Flow = item[2]
		var bytes: PackedByteArray = item[4]
		var direction := up if to_server else down
		var seq := int(item[1])

		if seq < direction._newest_delivered_seq:
			direction.reordered += 1
		direction._newest_delivered_seq = maxi(direction._newest_delivered_seq, seq)
		direction.delivered += 1

		if to_server:
			flow.upstream.put_packet(bytes)
		else:
			flow.client.put_packet(bytes)

	_mutex.unlock()


func _schedule(flow: Flow, to_server: bool, bytes: PackedByteArray, now: int) -> void:
	var direction := up if to_server else down
	var seq := direction._next_seq
	direction._next_seq += 1

	for delay in direction._fate():
		_order += 1
		var item := [now + delay, seq, flow, to_server, bytes, _order]
		var at := _queue.bsearch_custom(item, _due_before)
		_queue.insert(at, item)


## Due time first; two datagrams due in the same microsecond keep the order they arrived in.
static func _due_before(a: Array, b: Array) -> bool:
	if int(a[0]) != int(b[0]):
		return int(a[0]) < int(b[0])
	return int(a[5]) < int(b[5])


func describe() -> Dictionary:
	_mutex.lock()
	var out := {
		"port": _port,
		"target": "%s:%d" % [_target_host, _target_port],
		"running": _running,
		"flows": _flows.size(),
		"queued": _queue.size(),
		"seed": seed,
		"up": up.describe(),
		"down": down.describe(),
	}
	_mutex.unlock()
	return out
