extends "netcode_sections_8.gd"

## Sections of netcode_demo.gd, moved unchanged; part 9 of 9.


## Three managers over a lossless pipe and the entities they share, for [method _test_unchanged_entities].
class QuietRig extends RefCounted:
	var host: DotNetManager
	var fresh: DotNetManager
	var legacy: DotNetManager
	var exclude: ExcludeInterest
	var sent := {2: [], 3: []}
	var on_server: Array = []
	var on_fresh: Array = []
	var on_legacy: Array = []

	func deliver(tick: int) -> void:
		host.server_tick(tick)
		for payload: PackedByteArray in sent[2]:
			var _r := fresh.receive_snapshot(payload)
		for payload: PackedByteArray in sent[3]:
			var _r := legacy.receive_snapshot(payload)
		var _a := host.receive_ack_payload(2, fresh.encode_ack())
		var _b := host.receive_ack_payload(3, legacy.encode_ack())

	func sizes(peer: int) -> int:
		var n := 0
		for payload: PackedByteArray in sent[peer]:
			n += payload.size()
		return n

	func all_at(list: Array, tick: int) -> int:
		var n := 0
		for c in list:
			if c.last_applied == tick:
				n += 1
		return n

	func clear_sent() -> void:
		sent[2].clear()
		sent[3].clear()


func _unchanged_rig(entities: int) -> QuietRig:
	var rig := QuietRig.new()
	rig.host = _parts_manager("QuietServer", true, 1200)
	rig.fresh = _parts_manager("QuietClient", false, 1200)
	rig.legacy = _parts_manager("QuietLegacy", false, 1200)
	var host := rig.host
	var fresh := rig.fresh
	var legacy := rig.legacy
	legacy.local_peer_id = 3
	# A client from before the lists: it announces no features, as its table had none.
	legacy.messages.features = 0
	rig.exclude = ExcludeInterest.new()
	host.interest = rig.exclude
	var sent := rig.sent
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
	for i in entities:
		# Owned by nobody here, so both clients interpolate them.
		var spawned: DotNetIdentity = host.spawner.spawn(&"counted", 9, Transform3D.IDENTITY, 0).value
		# Out of view means out at once, not after the boundary's grace period.
		spawned.interest_linger_sec = 0.0
		var _f := fresh.spawner.spawn_remote(&"counted", spawned.net_id, 9, Transform3D.IDENTITY, 0)
		var _l := legacy.spawner.spawn_remote(&"counted", spawned.net_id, 9, Transform3D.IDENTITY, 0)
		rig.on_server.append(spawned.behaviours[0])
		rig.on_fresh.append(fresh.registry.get_identity(spawned.net_id).behaviours[0])
		rig.on_legacy.append(legacy.registry.get_identity(spawned.net_id).behaviours[0])
	return rig


## [b]An entity with nothing to say is listed, not written.[/b] A client announcing
## [constant DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS] gets runs of ids in the part's tail,
## applied exactly as an empty body. Armed with each fix reverted in turn (send, receive, early return).
func _test_unchanged_entities() -> void:
	print("")
	print("[unchanged entities]")
	var rig := _unchanged_rig(30)
	_unchanged_savings(rig)
	_unchanged_relevance(rig)
	_unchanged_codec(rig)
	rig.host.stop()
	rig.fresh.stop()
	rig.legacy.stop()
	for m in [rig.host, rig.fresh, rig.legacy]:
		remove_child(m)
		(m as DotNetManager).free()


func _unchanged_savings(rig: QuietRig) -> void:
	var on_server := rig.on_server
	var on_fresh := rig.on_fresh
	var on_legacy := rig.on_legacy
	var fresh := rig.fresh
	var legacy := rig.legacy
	var sent := rig.sent
	const ENTITIES := 30
	# Everything once, then only entity 0 moves.
	for i in ENTITIES:
		on_server[i].position = Vector3(1.0 + i, 0, 0)
	rig.deliver(3)
	sent[2].clear()
	sent[3].clear()
	on_server[0].position = Vector3(50, 0, 0)
	rig.deliver(6)

	var compact_bytes: int = rig.sizes(2)
	var legacy_bytes: int = rig.sizes(3)
	# 29 entities of 36 bits is 130 bytes of headers; the list of them is a few bits.
	_check("29 unchanged entities cost a few bits, not 130 B (%d B, old format %d B)"
			% [compact_bytes, legacy_bytes],
		compact_bytes + 120 <= legacy_bytes)
	_check("and only the moving entity is written (%d)" % _part_count(sent[2][0]),
		sent[2].size() == 1 and _part_count(sent[2][0]) == 1)
	_check("every entity's per-snapshot hook fired at the new tick (%d of %d)"
			% [rig.all_at(on_fresh, 6), ENTITIES],
		rig.all_at(on_fresh, 6) == ENTITIES)
	_check("as it does on the old format (%d of %d)" % [rig.all_at(on_legacy, 6), ENTITIES],
		rig.all_at(on_legacy, 6) == ENTITIES)
	var tracked := 0
	for i in ENTITIES:
		var track: Variant = fresh.interpolator._tracks.get(on_fresh[i].identity.net_id)
		if track != null and int(track.newest_tick()) == 6:
			tracked += 1
	_check("the interpolator holds a sample at that tick for each (%d)" % tracked, tracked == ENTITIES)
	_check("and both acknowledge it (%d, %d)" % [fresh.ack_tick(), legacy.ack_tick()],
		fresh.ack_tick() == 6 and legacy.ack_tick() == 6)


func _unchanged_relevance(rig: QuietRig) -> void:
	var on_server := rig.on_server
	var on_fresh := rig.on_fresh
	var on_legacy := rig.on_legacy
	var fresh := rig.fresh
	var legacy := rig.legacy
	var host := rig.host
	var sent := rig.sent
	const ENTITIES := 30
	# Out of view: neither written nor listed, so it hears nothing, on either format.
	rig.exclude.excluded[on_server[5].identity.net_id] = true
	sent[2].clear()
	sent[3].clear()
	rig.deliver(9)
	_check("an entity that left relevance is not listed (last %d, others %d of %d)"
			% [on_fresh[5].last_applied, rig.all_at(on_fresh, 9), ENTITIES - 1],
		on_fresh[5].last_applied == 6 and rig.all_at(on_fresh, 9) == ENTITIES - 1
			and on_legacy[5].last_applied == 6)

	# Nothing relevant at all: a snapshot still goes, for the clock and the acknowledgement.
	for c in on_server:
		rig.exclude.excluded[c.identity.net_id] = true
	sent[2].clear()
	sent[3].clear()
	rig.deliver(12)
	_check("with nothing relevant a header-only snapshot is still sent (%d B, %d B)"
			% [rig.sizes(2), rig.sizes(3)],
		sent[2].size() == 1 and sent[3].size() == 1 and _part_count(sent[2][0]) == 0
			and (sent[2][0] as PackedByteArray).size() == 6 and (sent[3][0] as PackedByteArray).size() == 6)
	_check("and it feeds the clock and is acknowledged (%d, %d)" % [fresh.ack_tick(), legacy.ack_tick()],
		fresh.ack_tick() == 12 and legacy.ack_tick() == 12 and fresh.clock.received_tick() >= 12)
	rig.exclude.excluded.clear()

	# Over the MTU with a list: every part applies and the tick is acknowledged.
	host.config.mtu = 96
	for i in range(0, ENTITIES, 3):
		on_server[i].position = Vector3(500.0 + i, 0, 0)
	sent[2].clear()
	sent[3].clear()
	var failures := fresh.stats.decode_failures
	rig.deliver(15)
	_check("split with a list: %d parts, all applied, tick acknowledged (%d)" % [sent[2].size(), fresh.ack_tick()],
		sent[2].size() > 1 and fresh.ack_tick() == 15 and rig.all_at(on_fresh, 15) == ENTITIES
			and fresh.stats.decode_failures == failures)
	host.config.mtu = 1200

	# An old client handed a tail by mistake refuses it as a bad part trailer, not a misread.
	var mark := DotNetManager.UNCHANGED_TAIL_MARK
	_check("the tail's mark reads to an old client as an impossible trailer",
		(mark & 0xF) >= (mark >> 4) + 1)


func _unchanged_codec(rig: QuietRig) -> void:
	var on_fresh := rig.on_fresh
	var fresh := rig.fresh
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
	var before: Variant = on_fresh[0].applied
	var refused := fresh.receive_snapshot(bad.to_bytes())
	_check("a truncated list is refused and applies nothing",
		not refused.ok and on_fresh[0].applied == before)
