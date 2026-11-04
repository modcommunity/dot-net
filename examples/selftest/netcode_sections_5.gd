extends "netcode_sections_4.gd"

## Sections of netcode_demo.gd, moved unchanged; part 5 of 9.


## A snapshot bigger than [member DotNetConfig.mtu] goes out in parts, each applying alone:
## ENet fragments an unreliable packet over its MTU and losing any fragment loses the packet.
## Every check below is armed (the setting was once declared and read by nothing).
func _test_snapshot_parts() -> void:
	print("")
	print("[snapshot parts]")

	const ENTITIES := 40
	const MTU := 256
	var host := _parts_manager("PartsServer", true, MTU)
	var watcher := _parts_manager("PartsClient", false, MTU)

	var sent: Array[PackedByteArray] = []
	host.send_fn = func(peer_id: int, payload: PackedByteArray, d: int) -> void:
		if peer_id != 2:
			return
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var _schema := watcher.receive(payload, 1)
			return
		sent.append(payload)

	host.start()
	watcher.start()
	host.add_peer(2)
	host.spawner.register_factory(&"player", _build_player)
	watcher.spawner.register_factory(&"player", _build_player)

	var on_server: Array[Movement] = []
	var on_client: Array[Movement] = []
	for i in ENTITIES:
		var spawned := host.spawner.spawn(&"player", 3, Transform3D.IDENTITY, 0)
		var server_entity: DotNetIdentity = spawned.value
		var _mirror := watcher.spawner.spawn_remote(&"player", server_entity.net_id, 3, Transform3D.IDENTITY, 0)
		on_server.append(server_entity.behaviours[0] as Movement)
		on_client.append(watcher.registry.get_identity(server_entity.net_id).behaviours[0] as Movement)

	var deliver := func(payload: PackedByteArray) -> void:
		var _r := watcher.receive_snapshot(payload)
		var _a := host.receive_ack_payload(2, watcher.encode_ack())

	var at := func(m: Movement) -> float:
		return float((m.received_values().get(&"position", Vector3.ZERO) as Vector3).x)
	var s := {"host": host, "watcher": watcher, "sent": sent, "on_server": on_server,
		"on_client": on_client, "deliver": deliver, "at": at}
	_parts_check_first_tick(s, ENTITIES, MTU)
	var second := _parts_check_lost_part(s, ENTITIES)
	_parts_check_late_and_resent(s, second, ENTITIES)
	_parts_check_older_after_newer(s, ENTITIES)
	_parts_check_under_mtu(s, ENTITIES)
	_parts_check_max_parts(s, MTU)

	host.stop()
	watcher.stop()
	remove_child(host)
	remove_child(watcher)
	host.free()
	watcher.free()


func _parts_check_first_tick(s: Dictionary, ENTITIES: int, MTU: int) -> void:
	var host: DotNetManager = s.host
	var watcher: DotNetManager = s.watcher
	var sent: Array[PackedByteArray] = s.sent
	var on_server: Array[Movement] = s.on_server
	var on_client: Array[Movement] = s.on_client
	var deliver: Callable = s.deliver
	var at: Callable = s.at
	for i in ENTITIES:
		on_server[i].position = Vector3(1.0 + i, 0, 0)
	host.server_tick(3)
	var first := sent.duplicate()
	sent.clear()

	var largest := 0
	var total_bytes := 0
	var total_entities := 0
	for payload in first:
		largest = maxi(largest, payload.size())
		total_bytes += payload.size()
		total_entities += _part_count(payload)
	_check("a snapshot over the MTU is sent in parts (%d)" % first.size(), first.size() > 1)
	_check("every part is within the MTU (largest %d of %d)" % [largest, MTU], largest <= MTU)
	_check("each entity is in one part (%d of %d)" % [total_entities, ENTITIES], total_entities == ENTITIES)
	_check("parts are full, not one entity each (%d B in %d)" % [total_bytes, first.size()],
		first.size() * MTU < total_bytes + MTU * 2)

	for payload in first:
		deliver.call(payload)
	var arrived := 0
	for i in ENTITIES:
		if absf(at.call(on_client[i]) - (1.0 + i)) < 0.02:
			arrived += 1
	_check("every part applies: all %d entities arrive (%d)" % [ENTITIES, arrived], arrived == ENTITIES)
	_check("the whole tick is acknowledged once every part is in (%d)" % watcher.ack_tick(),
		watcher.ack_tick() == 3)
	_check("a second part is not a repeated or late snapshot to the stats (%d)" % watcher.stats.out_of_order,
		watcher.stats.out_of_order == 0 and watcher.stats.snapshots_lost == 0)
	_check("and the decode is clean (%d)" % watcher.stats.decode_failures,
		watcher.stats.decode_failures == 0)


func _parts_check_lost_part(s: Dictionary, ENTITIES: int) -> Array[PackedByteArray]:
	var host: DotNetManager = s.host
	var watcher: DotNetManager = s.watcher
	var sent: Array[PackedByteArray] = s.sent
	var on_server: Array[Movement] = s.on_server
	var on_client: Array[Movement] = s.on_client
	var deliver: Callable = s.deliver
	var at: Callable = s.at
	for i in ENTITIES:
		on_server[i].position = Vector3(100.0 + i, 0, 0)
	host.server_tick(6)
	var second := sent.duplicate()
	sent.clear()
	var lost_count := _part_count(second[1]) if second.size() > 1 else -1
	for index in second.size():
		if index != 1:
			deliver.call(second[index])
	var moved := 0
	var stayed := 0
	for i in ENTITIES:
		var x: float = at.call(on_client[i])
		if absf(x - (100.0 + i)) < 0.02:
			moved += 1
		elif absf(x - (1.0 + i)) < 0.02:
			stayed += 1
	_check("with part 1 lost, the other parts' entities still arrive (%d moved)" % moved,
		moved == ENTITIES - lost_count)
	_check("only the lost part's entities are stale (%d of %d)" % [stayed, lost_count],
		lost_count > 0 and stayed == lost_count)
	_check("a tick with a part missing is not acknowledged (%d)" % watcher.ack_tick(),
		watcher.ack_tick() == 3)
	return second


func _parts_check_late_and_resent(s: Dictionary, second: Array[PackedByteArray], ENTITIES: int) -> void:
	var host: DotNetManager = s.host
	var watcher: DotNetManager = s.watcher
	var sent: Array[PackedByteArray] = s.sent
	var on_server: Array[Movement] = s.on_server
	var on_client: Array[Movement] = s.on_client
	var deliver: Callable = s.deliver
	var at: Callable = s.at
	# A late copy of the lost part, after a newer tick: superseded, not applied.
	on_server[0].position = Vector3(200.0, 0, 0)
	host.server_tick(9)
	for payload in sent:
		deliver.call(payload)
	sent.clear()
	_check("the next, complete tick is acknowledged (%d)" % watcher.ack_tick(), watcher.ack_tick() == 9)
	var current := func() -> int:
		var n := 0
		for i in range(1, ENTITIES):
			if absf(at.call(on_client[i]) - (100.0 + i)) < 0.02:
				n += 1
		return n
	var before_late: int = current.call()
	deliver.call(second[1])
	var after_late: int = current.call()
	_check("a late part of an older tick is superseded (%d, was %d)" % [after_late, before_late],
		after_late == before_late and before_late < ENTITIES - 1)

	# The acknowledgement of 9 resolves 6 as lost, so what part 1 carried goes again.
	host.server_tick(12)
	for payload in sent:
		deliver.call(payload)
	sent.clear()
	var caught_up := 0
	for i in range(1, ENTITIES):
		if absf(at.call(on_client[i]) - (100.0 + i)) < 0.02:
			caught_up += 1
	_check("the lost part's entities are re-sent and arrive (%d of %d)" % [caught_up, ENTITIES - 1],
		caught_up == ENTITIES - 1)


func _parts_check_older_after_newer(s: Dictionary, ENTITIES: int) -> void:
	var host: DotNetManager = s.host
	var sent: Array[PackedByteArray] = s.sent
	var on_server: Array[Movement] = s.on_server
	var on_client: Array[Movement] = s.on_client
	var deliver: Callable = s.deliver
	var at: Callable = s.at
	# A part of an older tick that turns up after a part of a newer, still incomplete one
	# is superseded too: entities are not in the same part every tick (the order is the
	# priority accumulator's), so it can carry an entity the newer part already moved.
	for i in ENTITIES:
		on_server[i].position = Vector3(400.0 + i, 0, 0)
	host.server_tick(13)
	var older := sent.duplicate()
	sent.clear()
	for i in ENTITIES:
		on_server[i].position = Vector3(500.0 + i, 0, 0)
	host.server_tick(14)
	var newer := sent.duplicate()
	sent.clear()
	deliver.call(newer[0])
	deliver.call(older[older.size() - 1])
	var went_back := 0
	for i in ENTITIES:
		if absf(at.call(on_client[i]) - (400.0 + i)) < 0.02:
			went_back += 1
	_check("an older part after a newer incomplete tick is not applied (%d)" % went_back,
		older.size() > 1 and newer.size() > 1 and went_back == 0)
	for index in range(1, newer.size()):
		deliver.call(newer[index])


func _parts_check_under_mtu(s: Dictionary, ENTITIES: int) -> void:
	var host: DotNetManager = s.host
	var watcher: DotNetManager = s.watcher
	var sent: Array[PackedByteArray] = s.sent
	var on_server: Array[Movement] = s.on_server
	var at: Callable = s.at
	host.config.mtu = 8192
	for i in ENTITIES:
		on_server[i].position = Vector3(300.0 + i, 0, 0)
	host.server_tick(15)
	_check("under the MTU a snapshot is one packet (%d)" % sent.size(), sent.size() == 1)
	if sent.size() == 1:
		var whole := sent[0]
		var reader := DotNetReader.new(whole)
		var _tick := reader.read_uint(32)
		var count := reader.read_uint(12)
		# Walk the entities with the client's own declarations, then look at what is left.
		var _applied := watcher.receive_snapshot(whole)
		_check("and it carries no part trailer (%d entities, %d B)" % [count, whole.size()],
			count == ENTITIES and whole.size() * 8 - _bits_before_trailer(whole, watcher) < 8)
	sent.clear()


func _parts_check_max_parts(s: Dictionary, MTU: int) -> void:
	var host: DotNetManager = s.host
	var watcher: DotNetManager = s.watcher
	var sent: Array[PackedByteArray] = s.sent
	var deliver: Callable = s.deliver
	var at: Callable = s.at
	host.config.mtu = MTU
	host.config.max_entities_per_snapshot = 0
	for i in 200:
		var spawned := host.spawner.spawn(&"player", 3, Transform3D.IDENTITY, 0)
		var extra: DotNetIdentity = spawned.value
		var _mirror := watcher.spawner.spawn_remote(&"player", extra.net_id, 3, Transform3D.IDENTITY, 0)
	host.server_tick(18)
	var widest := 0
	for payload in sent:
		widest = maxi(widest, payload.size())
	_check("a snapshot is cut into at most %d parts (%d)" % [DotNetManager.MAX_SNAPSHOT_PARTS, sent.size()],
		sent.size() == DotNetManager.MAX_SNAPSHOT_PARTS and widest <= MTU)
	var failures_before := watcher.stats.decode_failures
	for payload in sent:
		deliver.call(payload)
	_check("and every one of them decodes", watcher.stats.decode_failures == failures_before)
	sent.clear()




## A thousand-entity world under the default entity cap reaches a client whole, within the parts limit.
func _test_snapshot_thousand() -> void:
	print("")
	print("[snapshot of a thousand entities]")

	const ENTITIES := 1000
	const OVERFLOW := 3000
	const MTU := 1200

	_check("the default per-snapshot cap covers a thousand entities (%d)" % DotNetConfig.new().entity_cap(),
		DotNetConfig.new().entity_cap() >= ENTITIES)

	var host := _parts_manager("ThousandServer", true, MTU)
	var watcher := _parts_manager("ThousandClient", false, MTU)
	var sent: Array[PackedByteArray] = []
	host.send_fn = func(peer_id: int, payload: PackedByteArray, d: int) -> void:
		if peer_id != 2:
			return
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var _schema := watcher.receive(payload, 1)
			return
		sent.append(payload)
	host.start()
	watcher.start()
	host.add_peer(2)
	host.spawner.register_factory(&"player", _build_player)
	watcher.spawner.register_factory(&"player", _build_player)

	var on_server: Array[Movement] = []
	var on_client: Array[Movement] = []
	_spawn_mirrored(host, watcher, ENTITIES, on_server, on_client)
	var largest := 0
	var first_parts := 0
	var arrived := 0
	var ticks := 0
	var tick := 3
	var run := _thousand_ticks(host, watcher, sent, on_client, ENTITIES, tick)
	largest = run["largest"]
	first_parts = run["first_parts"]
	arrived = run["arrived"]
	ticks = run["ticks"]
	tick = run["tick"]
	_check("a first snapshot of %d entities is %d parts, each within the MTU (largest %d)" % [ENTITIES, first_parts, largest],
		first_parts > 1 and first_parts <= DotNetManager.MAX_SNAPSHOT_PARTS and largest <= MTU)
	_check("what the sixteen parts could not hold follows within %d ticks: %d of %d arrived" % [ticks, arrived, ENTITIES],
		arrived == ENTITIES and ticks <= 3)
	_check("and the decode is clean (%d)" % watcher.stats.decode_failures, watcher.stats.decode_failures == 0)

	# More than sixteen parts hold: the rest waits for a later tick, nothing overflows or fails to decode.
	for i in range(ENTITIES, OVERFLOW):
		var spawned := host.spawner.spawn(&"player", 3, Transform3D.IDENTITY, 0)
		var server_entity: DotNetIdentity = spawned.value
		var _mirror := watcher.spawner.spawn_remote(&"player", server_entity.net_id, 3, Transform3D.IDENTITY, 0)
	host.server_tick(tick)
	var failures_before := watcher.stats.decode_failures
	for payload in sent:
		var _r := watcher.receive_snapshot(payload)
	_check("a world too big for sixteen parts is cut at %d, still within the MTU, and decodes (%d)" % [sent.size(), watcher.stats.decode_failures],
		sent.size() <= DotNetManager.MAX_SNAPSHOT_PARTS and watcher.stats.decode_failures == failures_before)
	_check("and the overflow was logged once", host._warned_parts or sent.size() < DotNetManager.MAX_SNAPSHOT_PARTS)

	host.stop()
	watcher.stop()
	remove_child(host)
	remove_child(watcher)
	host.free()
	watcher.free()
	_thousand_native_matches(ENTITIES, MTU)


## The same thousand-entity world built by the native core and by GDScript: every part byte for byte.
func _thousand_native_matches(count: int, mtu: int) -> void:
	if not DotNetNative.load_library().ok:
		print("  native library not loaded; thousand-entity native comparison skipped")
		return
	var runs: Array = []
	for native in [false, true]:
		var host := _parts_manager("ThousandNativeServer%s" % native, true, mtu, native)
		var watcher := _parts_manager("ThousandNativeClient%s" % native, false, mtu)
		var sent: Array[PackedByteArray] = []
		host.send_fn = func(peer_id: int, payload: PackedByteArray, d: int) -> void:
			if peer_id == 2 and d == DotNetMessage.Delivery.UNRELIABLE:
				sent.append(payload)
			elif peer_id == 2:
				var _schema := watcher.receive(payload, 1)
		host.start()
		watcher.start()
		host.add_peer(2)
		host.spawner.register_factory(&"player", _build_player)
		watcher.spawner.register_factory(&"player", _build_player)
		var on_server: Array[Movement] = []
		var on_client: Array[Movement] = []
		_spawn_mirrored(host, watcher, count, on_server, on_client)
		var all: Array = []
		var tick := 3
		for _round in 3:
			host.server_tick(tick)
			tick += 1
			for payload in sent:
				all.append(payload)
				var _r := watcher.receive_snapshot(payload)
				var _a := host.receive_ack_payload(2, watcher.encode_ack())
			sent.clear()
		runs.append({"payloads": all, "native_used": host._native != null})
		host.stop()
		watcher.stop()
		remove_child(host)
		remove_child(watcher)
		host.free()
		watcher.free()
	_check("native: the thousand-entity world is built natively at MTU %d" % mtu, bool(runs[1]["native_used"]))
	_check("native: %d parts of a thousand entities equal GDScript's byte for byte %s" % [
			(runs[0]["payloads"] as Array).size(), _first_difference(runs[0]["payloads"], runs[1]["payloads"])],
		(runs[0]["payloads"] as Array).size() > 3
			and _first_difference(runs[0]["payloads"], runs[1]["payloads"]) == "")


## Spawns [param count] players on [param host], mirrored on [param watcher], each at x = 1 + index.
func _spawn_mirrored(host: DotNetManager, watcher: DotNetManager, count: int,
		on_server: Array[Movement], on_client: Array[Movement]) -> void:
	for i in count:
		var spawned := host.spawner.spawn(&"player", 3, Transform3D.IDENTITY, 0)
		var server_entity: DotNetIdentity = spawned.value
		var _mirror := watcher.spawner.spawn_remote(&"player", server_entity.net_id, 3, Transform3D.IDENTITY, 0)
		on_server.append(server_entity.behaviours[0] as Movement)
		on_client.append(watcher.registry.get_identity(server_entity.net_id).behaviours[0] as Movement)
		on_server[i].position = Vector3(1.0 + i, 0, 0)


## Ticks [param host] until every entity reached [param watcher] (at most 4 ticks); returns the counts.
func _thousand_ticks(host: DotNetManager, watcher: DotNetManager, sent: Array[PackedByteArray],
		on_client: Array[Movement], count: int, tick: int) -> Dictionary:
	var largest := 0
	var first_parts := 0
	var arrived := 0
	var ticks := 0
	while arrived < count and ticks < 4:
		host.server_tick(tick)
		tick += 1
		ticks += 1
		if ticks == 1:
			first_parts = sent.size()
		for payload in sent:
			largest = maxi(largest, payload.size())
			var _r := watcher.receive_snapshot(payload)
			var _a := host.receive_ack_payload(2, watcher.encode_ack())
		sent.clear()
		arrived = 0
		for i in count:
			if absf(float((on_client[i].received_values().get(&"position", Vector3.ZERO) as Vector3).x) - (1.0 + i)) < 0.02:
				arrived += 1
	return {"largest": largest, "first_parts": first_parts, "arrived": arrived, "ticks": ticks, "tick": tick}


## The extra scenarios of [method _test_snapshot_threads] against the base run [param off].
func _check_thread_variants(off: Dictionary, extra: Dictionary) -> void:
	_check("thin: far entities thinned change what is sent %s" % _first_difference(off["payloads"], (extra["thin"] as Array)[0]["payloads"]),
		_first_difference(off["payloads"], (extra["thin"] as Array)[0]["payloads"]) != "")
	for variant: String in extra:
		var runs: Array = extra[variant]
		var serial: Dictionary = runs[0]
		if variant == "thin":
			for k in [1, 2]:
				_check("thin: pooled runs send the same payloads and state as the inline path",
					_first_difference(serial["payloads"], runs[k]["payloads"]) == ""
						and _first_difference(serial["states"], runs[k]["states"]) == "")
			continue
		_check("%s: the scenario sent snapshots under a held cache, linger and stagger (%d payloads, %d cached peers)"
				% [variant, (serial["payloads"] as Array).size(), serial["cache_hits"]],
			(serial["payloads"] as Array).size() > 100 and int(serial["cache_hits"]) > 0)
		for k in [1, 2]:
			var other: Dictionary = runs[k]
			_check("%s: %s workers send the same payloads and state as the inline path (payloads: %s; state: %s; pooled %d)"
					% [variant, "three" if k == 1 else "two (verify on)", _first_difference(serial["payloads"], other["payloads"]),
						_first_difference(serial["states"], other["states"]), other["pooled"]],
				_first_difference(serial["payloads"], other["payloads"]) == ""
					and _first_difference(serial["states"], other["states"]) == ""
					and (not DotParallel.available() or int(other["pooled"]) > 0))


## Send views exist only for what a peer is sent, not one per behaviour of every entity for
## every peer. Two peers, entities far from both, inline and on workers.
func _test_view_count() -> void:
	var counts := {}
	for workers in [0, 2]:
		var host := _parts_manager("ViewCount%d" % workers, true, 1200)
		host.config.snapshot_workers = workers
		var probe := FrozenProbe.new()
		probe.radius = 5.0
		probe.evaluation_interval_sec = 0.0
		host.interest = probe
		host.send_fn = func(_peer_id: int, _payload: PackedByteArray, _d: int) -> void:
			pass
		host.start()
		host.spawner.register_factory(&"counted", _build_counted)
		var modern := host.messages.schema_payload()
		for peer in [2, 3]:
			host.add_peer(peer)
			var _adopted := host.receive(modern, peer)
		var all: Array = []
		for i in 20:
			var owner_peer := 2 if i == 0 else (3 if i == 6 else 0)
			var x := 0.0 if i < 6 else (100.0 if i < 12 else 1000.0)
			var identity: DotNetIdentity = host.spawner.spawn(&"counted", owner_peer, Transform3D(Basis.IDENTITY, Vector3(x, 0, 0)), 0).value
			all.append(identity)
		var behaviours := 0
		for tick in range(1, 5):
			host.server_tick(tick)
		var views := 0
		var far_views := 0
		for i in all.size():
			var identity: DotNetIdentity = all[i]
			behaviours += identity.behaviours.size()
			for behaviour in identity.behaviours:
				views += behaviour._views.size()
				if i >= 12:
					far_views += behaviour._views.size()
		counts[workers] = [views, far_views, behaviours]
		for identity: DotNetIdentity in host.registry.all():
			var body := identity.get_parent()
			if body != null and body.is_inside_tree():
				body.get_parent().remove_child(body)
		remove_child(host)
		host.free()
	_check("views: pooled and inline make the same (%s vs %s)" % [counts[2], counts[0]],
		counts[2][0] == counts[0][0] and counts[2][1] == counts[0][1])
	_check("views: only the %d relevant (peer, behaviour) pairs, not %d (%d made, %d for unseen entities)"
			% [12, 2 * counts[2][2], counts[2][0], counts[2][1]],
		counts[2][0] == 12 and counts[2][1] == 0)


## A peer's first entity registered inside a tick, with workers on: the snapshot locates the
## observer but it was not in the frozen list, so interest must be asked about a frozen one.
## Fails (unfrozen asks) if the job takes the observer as it finds it.
func _test_first_entity_mid_tick() -> void:
	var host := _parts_manager("MidTick", true, 1200)
	host.config.snapshot_workers = 2
	var probe := FrozenProbe.new()
	probe.radius = 50.0
	probe.evaluation_interval_sec = 0.0
	host.interest = probe
	var sent := {}
	host.send_fn = func(peer_id: int, _payload: PackedByteArray, _d: int) -> void:
		sent[peer_id] = int(sent.get(peer_id, 0)) + 1
	host.start()
	host.spawner.register_factory(&"counted", _build_counted)
	var modern := host.messages.schema_payload()
	for peer in [2, 3]:
		host.add_peer(peer)
		var _adopted := host.receive(modern, peer)
	var keep: Array = []
	for peer in [2, 3, 0, 0]:
		var identity: DotNetIdentity = host.spawner.spawn(&"counted", peer, Transform3D.IDENTITY, 0).value
		keep.append(identity)

	# The spawner is the one that spawns peer 3's... a third peer, joined with no entity.
	host.add_peer(4)
	var _adopted4 := host.receive(modern, 4)
	var spawner_identity := _make_entity(&"counted", 0)
	var driver := SpawnsFirst.new()
	driver.name = "Driver"
	spawner_identity.get_parent().add_child(driver)
	spawner_identity.behaviours = [driver]
	driver.identity = spawner_identity
	driver._bind(DotNetConfig.new())
	driver.host = host
	driver.peer = 4
	driver.at_tick = 3
	var registered := host.registry.register(spawner_identity, 0, 0, host.config)
	_check("mid-tick: the driver entity registered", registered.ok)
	keep.append(spawner_identity)

	for tick in range(1, 7):
		host.server_tick(tick)
	var pooled_runs: int = host._snapshot_pooled
	_check("mid-tick: peer 4's entity exists, spawned during tick 3", driver.spawned
		and not host.registry.owned_by(4).is_empty())
	_check("mid-tick: the snapshots were built on workers (%d)" % pooled_runs,
		not DotParallel.available() or pooled_runs > 0)
	_check("mid-tick: interest asked about the late observer (%d asks)" % probe.asks_with_observer,
		probe.asks_with_observer > 0)
	_check("mid-tick: never asked about an observer that was not frozen (%d asks)" % probe.unfrozen_asks,
		not DotParallel.available() or probe.unfrozen_asks == 0)
	_check("mid-tick: every freeze was undone",
		not host.registry.owned_by(4)[0].is_position_frozen())

	for identity: DotNetIdentity in host.registry.all():
		var body := identity.get_parent()
		if body != null and body.is_inside_tree():
			body.get_parent().remove_child(body)
	remove_child(host)
	host.free()


## A [method DotNetBehaviour.peer_view_snapshot] in the fields the native core keeps, keys sorted:
## the GDScript-only memo fields dropped, and a view holding nothing else read as none.
func _normal_view(view: Dictionary) -> Dictionary:
	if view.is_empty():
		return {}
	var pending: Array = []
	for entry: Array in view["pending"]:
		pending.append([entry[0], _sorted_dict(entry[1])])
	var out := {
		"acked": _sorted_dict(view["acked"]), "believed": _sorted_dict(view["believed"]),
		"pending": pending, "last_sent_ms": _sorted_dict(view["last_sent_ms"]),
		"last_ack": view["last_ack"], "relost": _sorted_dict(view["relost"]), "strict": view["strict"],
	}
	var empty := pending.is_empty() and int(view["last_ack"]) == 0 and not bool(view["strict"])
	for k in ["acked", "believed", "last_sent_ms", "relost"]:
		empty = empty and (out[k] as Dictionary).is_empty()
	return {} if empty else out


## One run of [method _test_snapshot_threads]'s game; everything it sent and kept, as bytes.
func _threads_scenario(
	label: String, workers: int, skew: bool, variant: String = "", native: bool = false,
	native_interest: bool = false
) -> Dictionary:
	const PEERS := 10
	const ENTITIES := 40
	const TICKS := 40

	var host := _parts_manager(label, true, 320)
	host.config.snapshot_workers = workers
	host.config.native = native and variant != "toggle"
	host.config.native_interest = native_interest
	# 1500 B per window of ten ticks (the window is scripted below): well under what the
	# entities in view want, so the accumulator decides who waits.
	host.config.per_client_budget = 1500
	var distance := DotNetInterestDistance.new()
	distance.radius = 14.0
	distance.evaluation_interval_sec = 0.0
	host.interest = distance
	host._test_skew_pooled = skew
	if variant == "thin":
		distance.far_every = 3
		distance.far_distance = 6.0
		distance.far_tiers = 2
		host.config.peer_send_budget = 4
	var rich := variant == "cache" or variant == "grid" or variant == "coded"
	if rich:
		# A cached answer is kept for good and expired by hand below (a wall-clock interval
		# would expire at a different tick in each run); a leaver lingers for good.
		var strategy: DotNetInterest = distance
		if variant == "grid":
			var grid := DotNetInterestGrid.new()
			grid.cell_size = 8.0
			grid.radius = 14.0
			strategy = grid
			host.interest = grid
		strategy.evaluation_interval_sec = 1.0e6
		# Staggered: three phases, a peer a tick each third.
		host.config.snapshot_rate = 20
		host.config.stagger_snapshots = true

	var payloads: Array = []
	var peers_fed := {}
	host.send_fn = func(peer_id: int, payload: PackedByteArray, d: int) -> void:
		if d == DotNetMessage.Delivery.UNRELIABLE:
			payloads.append([peer_id, payload])
			peers_fed[peer_id] = true
	host.start()
	var factory := (func(c: Dictionary) -> Node: return _build_rich(c, true)) if variant == "coded" \
		else (_build_rich if rich else _build_counted)
	host.spawner.register_factory(&"counted", factory)

	var modern := host.messages.schema_payload()
	host.messages.features = 0
	var legacy := host.messages.schema_payload()
	host.messages.features = DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS | DotNetMessageRegistry.FEATURE_INPUT_LEAD
	for i in PEERS:
		var peer := 2 + i
		host.add_peer(peer)
		var _adopted := host.receive(modern if i % 2 == 0 else legacy, peer)

	var behaviours: Array[Counted] = []
	for i in PEERS + ENTITIES:
		# The first ten are the peers' own (the observers interest measures from).
		var owner := 2 + i if i < PEERS else 0
		var spawned: DotNetIdentity = host.spawner.spawn(&"counted", owner, Transform3D.IDENTITY, 0).value
		spawned.interest_linger_sec = 1.0e6 if rich else 0.0
		# Two always-relevant entities: the pinned path under a cache hit.
		spawned.always_relevant = rich and i >= PEERS and i < PEERS + 2
		behaviours.append(spawned.behaviours[0] as Counted)

	var states: Array = []
	var normal_states: Array = []
	var starved := 0
	var split := 0
	for tick in range(1, TICKS + 1):
		for i in behaviours.size():
			var c := behaviours[i]
			# A pure function of (entity, tick): a slow circle per entity, the peers' own
			# drifting through the crowd so the set in view changes.
			var phase := float(i) * 0.7 + float(tick) * (0.05 if i >= PEERS else 0.12)
			var r := 4.0 + float(i % 7) * 3.0
			var p := Vector3(cos(phase) * r, 0.0, sin(phase) * r)
			c.position = p
			(c.identity.get_parent() as Node3D).position = p
			if tick % 3 != i % 3:
				c.velocity = Vector3(float((i + tick) % 5), 0.0, 0.0)
			if (tick + i) % 7 == 0:
				c.health = 100 - ((tick * 3 + i) % 60)
			c.grounded = (tick + i) % 4 != 0
			if c is Rich:
				var r2 := c as Rich
				r2.title = "unit-%d" % ((tick + i) % 6)
				r2.blob = PackedByteArray([i % 256, tick % 256, (i * tick) % 256]).slice(0, 1 + (tick + i) % 3)
				r2.rated = tick * 7 + i
			if c is Coded:
				var c2 := c as Coded
				c2.code = ["a", "bc", "def"].slice(0, (tick + i) % 4)
				c2.turn = float(tick * 37 + i * 11) - 400.0
				c2.facing = Quaternion(Vector3(0.3, 1.0, float(i % 3) - 1.0).normalized(), float(tick) * 0.21 + float(i))
				c2.aim = Vector3(cos(float(tick) * 0.1 + i), 0.2, sin(float(tick) * 0.1)) * 3.0
				c2.label = (tick / 4 + i) % 5

		# The budget's window is a wall-clock second, which one run can cross at a different
		# tick from another; hold it open and roll it every ten ticks instead.
		for i in PEERS:
			var w := host.budget.for_peer(2 + i)
			w.window_started_ms = Time.get_ticks_msec()
			if tick % 10 == 1:
				w.bytes_this_second = 0
		if rich and tick % 8 == 0:
			for cached: Dictionary in host.interest._cache.values():
				cached["at_ms"] = 0
			if host._native != null:
				host._native.call(&"expire_interest")
		# Native on at 10 and off at 24 must resend as a run that forgot every view then.
		if variant == "toggle" and (tick == 10 or tick == 24):
			if native:
				host.config.native = tick == 10
			else:
				for c in behaviours:
					c._views.clear()
		var before := payloads.size()
		host.server_tick(tick)
		var per_peer := {}
		for k in range(before, payloads.size()):
			var peer: int = payloads[k][0]
			per_peer[peer] = int(per_peer.get(peer, 0)) + 1
		for peer: int in per_peer:
			if int(per_peer[peer]) > 1:
				split += 1

		# Lossy acks: each peer loses a different third, and the last never acks at all.
		for i in PEERS - 1:
			if (tick + i) % 3 != 0:
				var _acked := host.receive_ack(2 + i, tick)

		var state := []
		var normal := []
		for i in PEERS:
			var b := host.budget.for_peer(2 + i)
			starved += b.starved_this_tick
			state.append([b.accumulators, b.starved_ticks, b.bytes_this_second])
			normal.append([_sorted_dict(b.accumulators), _sorted_dict(b.starved_ticks), b.bytes_this_second])
		for c in behaviours:
			for i in PEERS:
				var view_state := c.peer_view_snapshot(2 + i)
				# The wall-clock times of a rate-limited send differ between runs; which
				# properties have one does not.
				if view_state.has("last_sent_ms"):
					for key in view_state["last_sent_ms"]:
						view_state["last_sent_ms"][key] = true
				state.append(view_state)
				normal.append(_normal_view(view_state))
		states.append(var_to_bytes(state))
		normal_states.append(var_to_bytes(normal))

	var out := {
		"payloads": payloads, "states": states, "peers_fed": peers_fed.size(),
		"starved": starved, "split": split, "pooled": host._snapshot_pooled, "note": host._snapshot_threads_note,
		"snapshots": TICKS, "cache_hits": 0, "normal_states": normal_states,
		"native_note": host._native_note,
		"interest_native": host._native != null and bool(host._native.call(&"describe").get("interest", false)),
	}
	if rich:
		# Hits that happened: a cache entry older than the first tick's can only be a hit.
		out["cache_hits"] = host.interest._cache.size()
	for c in behaviours:
		var body := c.identity.get_parent()
		if body.is_inside_tree():
			body.get_parent().remove_child(body)
		body.free()
	remove_child(host)
	host.free()
	return out
