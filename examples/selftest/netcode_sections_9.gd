extends "netcode_sections_8.gd"

## Sections of netcode_demo.gd, moved unchanged; part 9 of 9.


## [b]An entity with nothing to say is listed, not written.[/b] A client announcing
## [constant DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS] gets runs of ids in the part's tail,
## applied exactly as an empty body. Armed with each fix reverted in turn (send, receive, early return).
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
