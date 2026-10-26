extends Node

## A server and two clients with a seeded link that loses, duplicates, delays and reorders (datagram)
## or only delays (stream). Over many seeds, state converges once it heals and nothing older applies.
## Run: [code]godot --headless --path . res://examples/loss_demo.tscn[/code]

const SEEDS := [11, 2026, 90210]
const TICK_RATE := 60
const SNAPSHOT_RATE := 20
const ENTITIES := 6
const CHAOS_TICKS := 360
const HEAL_TICKS := 90
## How soon after the link heals every client must agree with the server, in ticks. Two
## snapshot periods to deliver, one more for the acknowledgement to retire what was owed.
const CONVERGE_WITHIN := 30

## Every check this suite makes. Raise it with every check added.
const CHECKS := 39

var _seeds: Array = SEEDS
var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_completed := 0


class Mover extends DotNetBehaviour:
	var position: Vector3 = Vector3.ZERO
	var health: int = 100
	var grounded: bool = true
	var tag: String = ""

	func _register_net_vars() -> void:
		replicate(&"position", DotNetVar.Type.VECTOR3_POSITION)
		replicate(&"health", DotNetVar.Type.UINT).bits(8)
		replicate(&"grounded", DotNetVar.Type.BOOL)
		replicate(&"tag", DotNetVar.Type.STRING)


## One direction of the link. Datagram mode loses, repeats and reorders; stream mode only
## delays, and keeps order (a later packet is never due before an earlier one).
class Link:
	var rng := RandomNumberGenerator.new()
	var stream := false
	var loss := 0.0
	var duplicate := 0.0
	var base := 0
	var jitter := 0
	var blackout := false
	var queue: Array = []
	var last_due := 0
	var sent := 0
	var dropped := 0
	var duplicated := 0

	func push(tick: int, payload: PackedByteArray) -> void:
		sent += 1
		if blackout or rng.randf() < loss:
			dropped += 1
			return
		_enqueue(tick, payload)
		if rng.randf() < duplicate:
			duplicated += 1
			_enqueue(tick, payload)

	func _enqueue(tick: int, payload: PackedByteArray) -> void:
		var due := tick + base + (rng.randi_range(0, jitter) if jitter > 0 else 0)
		if stream:
			due = maxi(due, last_due)
			last_due = due
		queue.append([due, payload])

	## Payloads due by [param tick], earliest first (stable, so a stream keeps its order).
	func due(tick: int) -> Array:
		var out: Array = []
		var rest: Array = []
		for item in queue:
			if int(item[0]) <= tick:
				out.append(item)
			else:
				rest.append(item)
		queue = rest
		out.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
		return out


## Everything one run measured.
class Rig:
	var host: DotNetManager
	var clients: Array[DotNetManager] = []
	var peers: Array[int] = []
	var down: Dictionary = {}
	var up: Dictionary = {}
	var server_side: Array[Mover] = []
	var client_side: Array = []
	var tick := 0
	## Highest position.x each client has seen of each entity, and whether it ever fell.
	var best: Dictionary = {}
	var regressions := 0
	var rng := RandomNumberGenerator.new()
	## Distinct snapshot ticks that reached each client.
	var delivered: Dictionary = {}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	await _run()


func _run() -> void:
	print("dot-net loss")
	var errors := EngineErrors.new()
	OS.add_logger(errors)

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			_seeds = [int(arg.substr(7))]
	_datagram_sections()
	_stream_section()
	_blackout_section()
	_parts_section()
	_stale_section()
	_stats_section()

	OS.remove_logger(errors)
	_check("no engine errors (%d)" % errors.count(), errors.count() == 0)
	_check("every section ran (%d/%d)" % [_sections_completed, _sections_entered],
		_sections_completed == _sections_entered)
	_check("every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS],
		_passed + _failed + 1 == CHECKS)
	print("")
	print("%d checks, %d failed" % [_passed + _failed, _failed])
	await get_tree().process_frame
	get_tree().quit(1 if _failed > 0 else 0)


class EngineErrors extends Logger:
	var _lock := Mutex.new()
	var _seen := 0

	func _log_error(
		_function: String, _file: String, _line: int, _code: String, _rationale: String,
		_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]
	) -> void:
		_lock.lock()
		_seen += 1
		_lock.unlock()

	func count() -> int:
		return _seen


func _build_mover(_context: Dictionary) -> Node:
	return _make_entity().get_parent()


func _make_entity() -> DotNetIdentity:
	var body := Node3D.new()
	body.name = "Entity"
	var identity := DotNetIdentity.new()
	identity.name = "NetIdentity"
	identity.prefab_id = &"mover"
	identity.authority = DotNetIdentity.Authority.SHARED
	body.add_child(identity)
	var mover := Mover.new()
	mover.name = "Mover"
	body.add_child(mover)
	identity.entity = body
	identity.behaviours = [mover]
	mover.identity = identity
	mover._bind(DotNetConfig.new())
	return identity


func _manager(label: String, server: bool, peer: int, mtu: int) -> DotNetManager:
	var m := DotNetManager.new()
	m.name = label
	m.is_server = server
	m.service_scope = StringName(label.to_lower())
	m.local_peer_id = peer
	m.auto_tick = false
	m.config_file = ""
	m.config = DotNetConfig.new()
	m.config.tick_rate = TICK_RATE
	m.config.snapshot_rate = SNAPSHOT_RATE
	m.config.mtu = mtu
	m.config.per_client_budget = 1000000
	add_child(m)
	return m


func _rig(seed_value: int, stream: bool, loss: float, duplicate: float, base: int, jitter: int,
		mtu: int = 1200, entities: int = ENTITIES) -> Rig:
	var rig := Rig.new()
	rig.rng.seed = seed_value
	rig.host = _manager("LossServer%d" % seed_value, true, 1, mtu)
	rig.peers = [2, 3]
	for peer in rig.peers:
		var client := _manager("LossClient%d_%d" % [seed_value, peer], false, peer, mtu)
		rig.clients.append(client)
		for table in [rig.down, rig.up]:
			var link := Link.new()
			link.rng.seed = seed_value * 31 + peer + (7 if table == rig.up else 0)
			link.stream = stream
			link.loss = loss
			link.duplicate = duplicate
			link.base = base
			link.jitter = jitter
			table[peer] = link
	var _a := rig.host.setup()
	for client in rig.clients:
		var _b := client.setup()
	rig.host.send_fn = func(peer_id: int, payload: PackedByteArray, d: int) -> void:
		var index := rig.peers.find(peer_id)
		if index < 0:
			return
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var _r := rig.clients[index].receive(payload, 1)
			return
		(rig.down[peer_id] as Link).push(rig.tick, payload)
	rig.host.start()
	for client in rig.clients:
		client.start()
	for peer in rig.peers:
		rig.host.add_peer(peer)
	rig.host.spawner.register_factory(&"mover", _build_mover)
	for client in rig.clients:
		client.spawner.register_factory(&"mover", _build_mover)
	for i in entities:
		var spawned := rig.host.spawner.spawn(&"mover", 0, Transform3D.IDENTITY, 0)
		var identity: DotNetIdentity = spawned.value
		rig.server_side.append(identity.behaviours[0] as Mover)
		var row: Array = []
		for client in rig.clients:
			var _m := client.spawner.spawn_remote(&"mover", identity.net_id, 0, Transform3D.IDENTITY, 0)
			row.append(client.registry.get_identity(identity.net_id).behaviours[0])
		rig.client_side.append(row)
	return rig


func _free_rig(rig: Rig) -> void:
	rig.host.stop()
	for client in rig.clients:
		client.stop()
	for node in [rig.host] + rig.clients:
		remove_child(node)
		node.free()


## One server tick: the entities move (and, while [param churn], change now and then), the
## server sends, the link delivers what is due to each client, and acks come back.
func _step(rig: Rig, churn: bool) -> void:
	rig.tick += 1
	for i in rig.server_side.size():
		var mover := rig.server_side[i]
		if churn:
			mover.position += Vector3(0.05 * float(i + 1), 0.0, 0.0)
		if churn and rig.tick % (13 + i) == 0:
			mover.health = rig.rng.randi_range(0, 255)
		if churn and rig.tick % (29 + i) == 0:
			mover.grounded = not mover.grounded
		if churn and rig.tick % (41 + i) == 0:
			mover.tag = "t%d" % rig.tick
	rig.host.server_tick(rig.tick)
	for index in rig.clients.size():
		var peer: int = rig.peers[index]
		var client := rig.clients[index]
		for item in (rig.down[peer] as Link).due(rig.tick):
			var arrived: PackedByteArray = item[1]
			if not rig.delivered.has(peer):
				rig.delivered[peer] = {}
			rig.delivered[peer][arrived.decode_u32(0)] = true
			var _r := client.receive_snapshot(item[1])
			(rig.up[peer] as Link).push(rig.tick, client.encode_ack())
		for item in (rig.up[peer] as Link).due(rig.tick):
			var _a := rig.host.receive_ack_payload(peer, item[1])
		for i in rig.server_side.size():
			var seen := float(((rig.client_side[i][index] as Mover).received_values()
				.get(&"position", Vector3.ZERO) as Vector3).x)
			var key := Vector2i(i, index)
			if seen < float(rig.best.get(key, -1.0)) - 0.001:
				rig.regressions += 1
			rig.best[key] = maxf(seen, float(rig.best.get(key, -1.0)))


## Number of clients' entities that differ from the server's.
func _mismatches(rig: Rig) -> int:
	var bad := 0
	for i in rig.server_side.size():
		var s := rig.server_side[i]
		for index in rig.clients.size():
			var values: Dictionary = (rig.client_side[i][index] as Mover).received_values()
			var pos: Vector3 = values.get(&"position", Vector3.ZERO)
			if absf(pos.x - s.position.x) > 0.05 \
					or int(values.get(&"health", 100)) != s.health \
					or bool(values.get(&"grounded", true)) != s.grounded \
					or str(values.get(&"tag", "")) != s.tag:
				bad += 1
	return bad


## Heals the link and returns the ticks until every client agrees, or -1.
func _heal(rig: Rig) -> int:
	for table in [rig.down, rig.up]:
		for peer in rig.peers:
			var link: Link = table[peer]
			link.loss = 0.0
			link.duplicate = 0.0
			link.jitter = 0
			link.blackout = false
	for n in HEAL_TICKS:
		_step(rig, false)
		if n >= 1 and _mismatches(rig) == 0:
			return n + 1
	_report_mismatch(rig)
	return -1


func _report_mismatch(rig: Rig) -> void:
	for i in rig.server_side.size():
		var s := rig.server_side[i]
		for index in rig.clients.size():
			var v: Dictionary = (rig.client_side[i][index] as Mover).received_values()
			var pos: Vector3 = v.get(&"position", Vector3.ZERO)
			if absf(pos.x - s.position.x) > 0.05 or int(v.get(&"health", 100)) != s.health \
					or bool(v.get(&"grounded", true)) != s.grounded or str(v.get(&"tag", "")) != s.tag:
				print("    entity %d client %d: server x=%.3f h=%d g=%s tag=%s | client %s"
					% [i, index, s.position.x, s.health, s.grounded, s.tag, v])


func _datagram_sections() -> void:
	_sections_entered += 1
	print("")
	print("[datagrams: loss, duplicates, jitter]")
	for seed_value in _seeds:
		var rig := _rig(seed_value, false, 0.25, 0.15, 2, 9)
		for _t in CHAOS_TICKS:
			_step(rig, true)
		var link: Link = rig.down[2]
		var up_link: Link = rig.up[2]
		var behind := _mismatches(rig)
		var took := _heal(rig)
		var label := "seed %d" % seed_value
		_check("%s: the link did lose, repeat and send (%d dropped, %d repeated of %d)"
			% [label, link.dropped, link.duplicated, link.sent],
			link.dropped > 10 and link.duplicated > 5 and up_link.dropped > 10)
		_check("%s: it had really diverged under chaos (%d entities off)" % [label, behind], behind > 0)
		_check("%s: every client agrees with the server %d ticks after the link heals" % [label, took],
			took > 0 and took <= CONVERGE_WITHIN)
		_check("%s: nothing older than what was applied was applied (%d regressions)"
			% [label, rig.regressions], rig.regressions == 0)
		var failures := 0
		for client in rig.clients:
			failures += client.stats.decode_failures
		_check("%s: reordered and repeated snapshots decode cleanly (%d)" % [label, failures],
			failures == 0)
		_free_rig(rig)
	_sections_completed += 1


func _stream_section() -> void:
	_sections_entered += 1
	print("")
	print("[a stream: late, never lost or reordered]")
	var rig := _rig(77, true, 0.0, 0.0, 3, 6)
	for _t in CHAOS_TICKS:
		_step(rig, true)
	var client := rig.clients[0]
	var took := _heal(rig)
	_check("converged %d ticks after the churn stops" % took, took > 0 and took <= CONVERGE_WITHIN)
	_check("no snapshot reported lost (%d)" % client.stats.snapshots_lost,
		client.stats.snapshots_lost == 0)
	_check("none out of order (%d)" % client.stats.out_of_order, client.stats.out_of_order == 0)
	_check("nothing went backwards (%d)" % rig.regressions, rig.regressions == 0)
	_free_rig(rig)
	_sections_completed += 1


## Every snapshot and ack lost for a stretch while properties change that never change again
## afterwards: what the baseline believes the client has is wrong, and has to be put right.
func _blackout_section() -> void:
	_sections_entered += 1
	print("")
	print("[a blackout: the baseline the client never got]")
	var rig := _rig(5, false, 0.0, 0.0, 1, 0)
	for _t in 60:
		_step(rig, true)
	for table in [rig.down, rig.up]:
		for peer in rig.peers:
			(table[peer] as Link).blackout = true
	for _t in 120:
		_step(rig, true)
	var stale := _mismatches(rig)
	var dropped: int = (rig.down[2] as Link).dropped
	_check("the clients fell behind in the dark (%d off, %d snapshots dropped)" % [stale, dropped],
		stale > 0 and dropped > 20)
	var took := _heal(rig)
	_check("all state, one-time changes included, is back %d ticks after" % took,
		took > 0 and took <= CONVERGE_WITHIN)
	_check("the server owes nobody anything it was acked for: a quiet tick sends no body",
		_quiet_tick_is_small(rig))
	_free_rig(rig)
	_sections_completed += 1


## Once converged and acked, a tick with nothing changed must not re-send state: a recovery
## that never retires its debt would keep the baseline stuck at "owed" for ever.
func _quiet_tick_is_small(rig: Rig) -> bool:
	var before := rig.host.stats.bytes_sent
	for _t in 12:
		_step(rig, false)
	var per_snapshot := float(rig.host.stats.bytes_sent - before) / (4.0 * 2.0)
	var full := float(ENTITIES) * 14.0
	return per_snapshot < full


## A small MTU splits the snapshot in parts; under loss a lost part must cost only its own
## entities and the rest must still converge.
func _parts_section() -> void:
	_sections_entered += 1
	print("")
	print("[parts under loss]")
	var rig := _rig(303, false, 0.2, 0.1, 2, 7, 256, 60)
	for _t in CHAOS_TICKS:
		_step(rig, true)
	var sent_per_snapshot := float(rig.host.stats.packets_sent) / maxf(1.0, float(rig.tick) / 3.0 * 2.0)
	var took := _heal(rig)
	_check("snapshots really went out in parts (%.2f packets per client snapshot)" % sent_per_snapshot,
		sent_per_snapshot > 1.05)
	_check("converged %d ticks after the link heals" % took, took > 0 and took <= CONVERGE_WITHIN)
	_check("nothing went backwards (%d)" % rig.regressions, rig.regressions == 0)
	_check("and no decode failures (%d)" % rig.clients[0].stats.decode_failures,
		rig.clients[0].stats.decode_failures == 0)
	_free_rig(rig)
	_sections_completed += 1


## An old snapshot delivered after newer ones, with values that would be visible if applied.
func _stale_section() -> void:
	_sections_entered += 1
	print("")
	print("[a stale snapshot, delivered late]")
	var rig := _rig(9, false, 0.0, 0.0, 0, 0)
	var client := rig.clients[0]
	var held: Array[PackedByteArray] = []
	rig.server_side[0].health = 11
	rig.server_side[0].tag = "old"
	var first_send := rig.host.send_fn
	rig.host.send_fn = func(peer_id: int, payload: PackedByteArray, d: int) -> void:
		if held.is_empty() and peer_id == 2 and d == DotNetMessage.Delivery.UNRELIABLE:
			held.append(payload)
			return
		first_send.call(peer_id, payload, d)
	for _t in 30:
		_step(rig, false)
	var mover := rig.server_side[0]
	var old: PackedByteArray = held[0] if not held.is_empty() else PackedByteArray()
	_check("the first snapshot was held back", not old.is_empty())
	mover.health = 222
	mover.tag = "new"
	for _t in 12:
		_step(rig, false)
	var applied := (rig.client_side[0][0] as Mover).received_values()
	_check("newer state applied (health %s, tag %s)" % [applied.get(&"health"), applied.get(&"tag")],
		int(applied.get(&"health", 0)) == 222 and str(applied.get(&"tag", "")) == "new")
	var lost_before: int = client.stats.snapshots_lost
	var order_before: int = client.stats.out_of_order
	var _r1 := client.receive_snapshot(old)
	var _r2 := client.receive_snapshot(old)
	var after := (rig.client_side[0][0] as Mover).received_values()
	_check("the stale one, twice, changes nothing (health %s, tag %s)" % [after.get(&"health"), after.get(&"tag")],
		int(after.get(&"health", 0)) == 222 and str(after.get(&"tag", "")) == "new")
	_check("counted out of order once, the repeat not again (%d more)" % (client.stats.out_of_order - order_before),
		client.stats.out_of_order - order_before == 1)
	_check("and not as loss (%d -> %d)" % [lost_before, client.stats.snapshots_lost],
		client.stats.snapshots_lost <= lost_before)
	_free_rig(rig)
	_sections_completed += 1


func _stats_section() -> void:
	_sections_entered += 1
	print("")
	print("[counters report what the link did]")
	var rig := _rig(4242, false, 0.2, 0.2, 2, 8)
	for _t in CHAOS_TICKS:
		_step(rig, true)
	var link: Link = rig.down[2]
	var stats: DotNetStats = rig.clients[0].stats
	var rate := stats.loss_rate()
	var injected := float(link.dropped) / float(link.sent)
	_check("loss inferred %.1f%% against %.1f%% injected" % [rate * 100.0, injected * 100.0],
		absf(rate - injected) < 0.1)
	_check("repeats and reordering counted (%d)" % stats.out_of_order, stats.out_of_order > 0)
	_check("every distinct tick that arrived is counted once, repeats not: %d of %d"
		% [stats.snapshots_received, rig.delivered[2].size()],
		stats.snapshots_received == rig.delivered[2].size())
	var lines := "\n".join(Array(rig.clients[0].describe_lines()))
	_check("describe_lines names the lost and out-of-order counts",
		lines.contains("lost_snapshots") and lines.contains("out_of_order"))
	_check("and the dictionary agrees with the counters",
		int(stats.describe()["lost_snapshots"]) == stats.snapshots_lost
		and int(stats.describe()["out_of_order"]) == stats.out_of_order)
	_free_rig(rig)
	_sections_completed += 1


func _check(what: String, passed: bool) -> void:
	if passed:
		_passed += 1
		print("  %-60s ok" % what)
	else:
		_failed += 1
		print("  %-60s FAILED" % what)
