extends "netcode_sections_4.gd"

## Sections of netcode_demo.gd, moved unchanged; part 5 of 7.


## A snapshot bigger than [member DotNetConfig.mtu] goes out in parts, each applying alone.
##
## Godot's ENet peer fragments an unreliable packet over its MTU, and losing any fragment
## loses the packet: a game whose snapshots ran past it (mg-buses-from-hell, at a round's
## spawn) lost about twice as many on a native client, and nothing here measured a size.
## Every check below is armed: [member DotNetConfig.mtu] was declared and read by nothing.
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

	# --- Over the MTU: parts, each under it, every entity in exactly one ---------

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

	# --- A lost part loses its own entities and nothing else -------------------

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

	# --- Under the MTU: one packet, byte for byte the format before parts --------

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

	# --- More than sixteen parts' worth: the rest waits, nothing is malformed ----

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

	host.stop()
	watcher.stop()
	remove_child(host)
	remove_child(watcher)
	host.free()
	watcher.free()


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


## Send views exist only for what a peer is sent: the pooled path used to make one for every
## behaviour of every entity for every peer. Two peers, entities far from both, inline and on
## workers.
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


## A peer's first entity registered inside a tick, with workers on: the observer is found by
## the snapshot but was not in the list that was frozen, so interest must be asked about a
## frozen one. Fails (unfrozen asks) if the job takes the observer as it finds it.
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


## [b]An entity with nothing to say is listed, not written.[/b] Every relevant entity used to
## go out every snapshot with its 24-bit id and a 6-bit count per behaviour even when nothing
## had changed: about 396 of mg-buses-from-hell's 429 steady bytes, 88 entities of headers.
## A client that announces [constant DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS] is sent
## those as runs of ids in the part's tail and applies each exactly as an empty body, so
## `_net_state_applied`, the interpolator and relevance all read as before. Armed, each fix
## reverted in turn: the send side off sends 149 B against 149 B and writes all 30; the
## receive side ignoring the list fires the hook for 1 of 30, splits fail to apply, and
## [method _test_standing_still]'s listed run walks 19.5 m off (#17's shape); the old early
## return sends 0 B to a peer with nothing relevant and its acknowledgement stays at 9.
func _test_unchanged_entities() -> void:
	print("")
	print("[unchanged entities]")

	const ENTITIES := 30

	var host := _parts_manager("QuietServer", true, 1200)
	var fresh := _parts_manager("QuietClient", false, 1200)
	var legacy := _parts_manager("QuietLegacy", false, 1200)
	legacy.local_peer_id = 3
	# A client from before the lists: it announces no features, as its table had none.
	legacy.messages.features = 0
	var exclude := ExcludeInterest.new()
	host.interest = exclude

	var sent := {2: [], 3: []}
	host.send_fn = func(peer_id: int, payload: PackedByteArray, d: int) -> void:
		var to: DotNetManager = fresh if peer_id == 2 else legacy
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var _schema := to.receive(payload, 1)
			return
		(sent[peer_id] as Array).append(payload)
	fresh.send_fn = func(_peer: int, payload: PackedByteArray, d: int) -> void:
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var _adopted := host.receive(payload, 2)
	legacy.send_fn = func(_peer: int, payload: PackedByteArray, d: int) -> void:
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var _adopted := host.receive(payload, 3)

	host.start()
	fresh.start()
	legacy.start()
	host.add_peer(2)
	host.add_peer(3)
	for m in [host, fresh, legacy]:
		(m as DotNetManager).spawner.register_factory(&"counted", _build_counted)

	_check("the new client says it reads unchanged lists, the old one does not",
		host.messages.peer_supports(2, DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS)
			and not host.messages.peer_supports(3, DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS))

	var on_server: Array[Counted] = []
	var on_fresh: Array[Counted] = []
	var on_legacy: Array[Counted] = []
	for i in ENTITIES:
		# Owned by nobody here, so both clients interpolate them.
		var spawned: DotNetIdentity = host.spawner.spawn(&"counted", 9, Transform3D.IDENTITY, 0).value
		# Out of view means out at once, not after the boundary's grace period.
		spawned.interest_linger_sec = 0.0
		var _f := fresh.spawner.spawn_remote(&"counted", spawned.net_id, 9, Transform3D.IDENTITY, 0)
		var _l := legacy.spawner.spawn_remote(&"counted", spawned.net_id, 9, Transform3D.IDENTITY, 0)
		on_server.append(spawned.behaviours[0] as Counted)
		on_fresh.append(fresh.registry.get_identity(spawned.net_id).behaviours[0] as Counted)
		on_legacy.append(legacy.registry.get_identity(spawned.net_id).behaviours[0] as Counted)

	var deliver := func(tick: int) -> void:
		host.server_tick(tick)
		for payload: PackedByteArray in sent[2]:
			var _r := fresh.receive_snapshot(payload)
		for payload: PackedByteArray in sent[3]:
			var _r := legacy.receive_snapshot(payload)
		var _a := host.receive_ack_payload(2, fresh.encode_ack())
		var _b := host.receive_ack_payload(3, legacy.encode_ack())

	var sizes := func(peer: int) -> int:
		var n := 0
		for payload: PackedByteArray in sent[peer]:
			n += payload.size()
		return n

	var all_at := func(list: Array[Counted], tick: int) -> int:
		var n := 0
		for c in list:
			if c.last_applied == tick:
				n += 1
		return n

	# Everything once, then only entity 0 moves.
	for i in ENTITIES:
		on_server[i].position = Vector3(1.0 + i, 0, 0)
	deliver.call(3)
	sent[2].clear()
	sent[3].clear()
	on_server[0].position = Vector3(50, 0, 0)
	deliver.call(6)

	var compact_bytes: int = sizes.call(2)
	var legacy_bytes: int = sizes.call(3)
	# 29 entities of 36 bits is 130 bytes of headers; the list of them is a few bits.
	_check("29 unchanged entities cost a few bits, not 130 B (%d B, old format %d B)"
			% [compact_bytes, legacy_bytes],
		compact_bytes + 120 <= legacy_bytes)
	_check("and only the moving entity is written (%d)" % _part_count(sent[2][0]),
		sent[2].size() == 1 and _part_count(sent[2][0]) == 1)
	_check("every entity's per-snapshot hook fired at the new tick (%d of %d)"
			% [all_at.call(on_fresh, 6), ENTITIES],
		all_at.call(on_fresh, 6) == ENTITIES)
	_check("as it does on the old format (%d of %d)" % [all_at.call(on_legacy, 6), ENTITIES],
		all_at.call(on_legacy, 6) == ENTITIES)
	var tracked := 0
	for i in ENTITIES:
		var track: Variant = fresh.interpolator._tracks.get(on_fresh[i].identity.net_id)
		if track != null and int(track.newest_tick()) == 6:
			tracked += 1
	_check("the interpolator holds a sample at that tick for each (%d)" % tracked, tracked == ENTITIES)
	_check("and both acknowledge it (%d, %d)" % [fresh.ack_tick(), legacy.ack_tick()],
		fresh.ack_tick() == 6 and legacy.ack_tick() == 6)

	# Out of view: neither written nor listed, so it hears nothing, on either format.
	exclude.excluded[on_server[5].identity.net_id] = true
	sent[2].clear()
	sent[3].clear()
	deliver.call(9)
	_check("an entity that left relevance is not listed (last %d, others %d of %d)"
			% [on_fresh[5].last_applied, all_at.call(on_fresh, 9), ENTITIES - 1],
		on_fresh[5].last_applied == 6 and all_at.call(on_fresh, 9) == ENTITIES - 1
			and on_legacy[5].last_applied == 6)

	# Nothing relevant at all: a snapshot still goes, for the clock and the acknowledgement.
	for c in on_server:
		exclude.excluded[c.identity.net_id] = true
	sent[2].clear()
	sent[3].clear()
	deliver.call(12)
	_check("with nothing relevant a header-only snapshot is still sent (%d B, %d B)"
			% [sizes.call(2), sizes.call(3)],
		sent[2].size() == 1 and sent[3].size() == 1 and _part_count(sent[2][0]) == 0
			and (sent[2][0] as PackedByteArray).size() == 6 and (sent[3][0] as PackedByteArray).size() == 6)
	_check("and it feeds the clock and is acknowledged (%d, %d)" % [fresh.ack_tick(), legacy.ack_tick()],
		fresh.ack_tick() == 12 and legacy.ack_tick() == 12 and fresh.clock.received_tick() >= 12)
	exclude.excluded.clear()

	# Over the MTU with a list: every part applies and the tick is acknowledged.
	host.config.mtu = 96
	for i in range(0, ENTITIES, 3):
		on_server[i].position = Vector3(500.0 + i, 0, 0)
	sent[2].clear()
	sent[3].clear()
	var failures := fresh.stats.decode_failures
	deliver.call(15)
	_check("split with a list: %d parts, all applied, tick acknowledged (%d)" % [sent[2].size(), fresh.ack_tick()],
		sent[2].size() > 1 and fresh.ack_tick() == 15 and all_at.call(on_fresh, 15) == ENTITIES
			and fresh.stats.decode_failures == failures)
	host.config.mtu = 1200

	# An old client handed a tail by mistake refuses it as a bad part trailer, not a misread.
	var mark := DotNetManager.UNCHANGED_TAIL_MARK
	_check("the tail's mark reads to an old client as an impossible trailer",
		(mark & 0xF) >= (mark >> 4) + 1)

	# The run codec, against sets a contiguous block, a scatter and a mix.
	var codec_ok := true
	var sets := [[1, 2, 3, 4, 5], [7, 100, 4000, 16000000], [3, 4, 9, 10, 11, 12, 40], [1]]
	for ids_set: Array in sets:
		var ids := PackedInt32Array(ids_set)
		var runs := DotNetManager._unchanged_runs(ids)
		var w := DotNetWriter.new()
		DotNetManager._write_unchanged_tail(w, runs)
		var r := w.to_reader()
		var got: Array = []
		var _m := r.read_uint(8)
		var count := DotNetManager._read_gamma(r)
		var cursor := 0
		for _k in count:
			var first := cursor + DotNetManager._read_gamma(r)
			var length := DotNetManager._read_gamma(r) + 1
			for id in range(first, first + length):
				got.append(id)
			cursor = first + length
		if got != ids_set or w.bit_length() + DotNetManager.SNAPSHOT_PART_TRAILER_BITS \
				!= DotNetManager._unchanged_tail_bits(runs):
			codec_ok = false
	_check("unchanged runs round-trip, and their size is known before writing", codec_ok)

	# A truncated list changes nothing and is a decode failure.
	var bad := DotNetWriter.new()
	bad.write_uint(20, 32)
	bad.write_uint(0, 12)
	bad.write_uint(DotNetManager.UNCHANGED_TAIL_MARK, 8)
	DotNetManager._write_gamma(bad, 1)
	DotNetManager._write_gamma(bad, on_fresh[0].identity.net_id)
	bad.write_bits(0, 12)
	var before := on_fresh[0].applied
	var refused := fresh.receive_snapshot(bad.to_bytes())
	_check("a truncated list is refused and applies nothing",
		not refused.ok and on_fresh[0].applied == before)

	host.stop()
	fresh.stop()
	legacy.stop()
	for m in [host, fresh, legacy]:
		remove_child(m)
		(m as DotNetManager).free()
