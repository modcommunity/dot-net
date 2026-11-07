extends "netcode_sections_9.gd"

## Sections of netcode_demo.gd; part 10: distance rings (radius, far_every, far_tiers, far_coherent).


## A server and one client over a lossless pipe, with an observer the client owns at the origin.
class RingRig extends RefCounted:
	var host: DotNetManager
	var client: DotNetManager
	var subjects: Array = []
	var mirrors: Array = []
	var bytes := 0
	var pending: Array[PackedByteArray] = []
	var tick := 0

	## One server tick and its delivery. [param drift] is added to every subject's replicated y so that
	## each snapshot has something to send.
	func step() -> void:
		tick += 1
		for s in subjects:
			s.position.y = float(tick) * 0.01
		host.server_tick(tick)
		for payload in pending:
			bytes += payload.size()
			var _r := client.receive_snapshot(payload)
			var _a := host.receive_ack_payload(2, client.encode_ack())
		pending.clear()


func _ring_rig(distances: Array, far_every: int, tiers: int, radius: float, label: String = "Ring") -> RingRig:
	var rig := RingRig.new()
	rig.host = _parts_manager(label + "Server", true, 1200)
	rig.client = _parts_manager(label + "Client", false, 1200)
	var distance := DotNetInterestDistance.new()
	distance.radius = radius
	distance.far_every = far_every
	distance.far_distance = 40.0
	distance.far_tiers = tiers
	distance.far_coherent = true
	distance.evaluation_interval_sec = 0.0
	rig.host.interest = distance
	rig.host.send_fn = func(_peer: int, payload: PackedByteArray, d: int) -> void:
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var _schema := rig.client.receive(payload, 1)
			return
		rig.pending.append(payload)
	rig.client.send_fn = func(_peer: int, payload: PackedByteArray, d: int) -> void:
		if d != DotNetMessage.Delivery.UNRELIABLE:
			var _adopted := rig.host.receive(payload, 2)
	rig.host.start()
	rig.client.start()
	rig.host.add_peer(2)
	for m in [rig.host, rig.client]:
		(m as DotNetManager).spawner.register_factory(&"counted", _build_counted)
	# The observer: owned by peer 2, at the origin, never thinned.
	var observer: DotNetIdentity = rig.host.spawner.spawn(&"counted", 2, Transform3D.IDENTITY, 0).value
	var _o := rig.client.spawner.spawn_remote(&"counted", observer.net_id, 2, Transform3D.IDENTITY, 0)
	for d in distances:
		var spawned: DotNetIdentity = rig.host.spawner.spawn(&"counted", 9, Transform3D.IDENTITY, 0).value
		spawned.interest_linger_sec = 0.0
		(spawned.entity as Node3D).global_position = Vector3(float(d), 0, 0)
		var behaviour: Counted = spawned.behaviours[0]
		behaviour.position = Vector3(float(d), 0, 0)
		var _m := rig.client.spawner.spawn_remote(&"counted", spawned.net_id, 9, Transform3D.IDENTITY, 0)
		rig.subjects.append(behaviour)
		rig.mirrors.append(rig.client.registry.get_identity(spawned.net_id).behaviours[0])
	return rig


func _ring_free(rig: RingRig) -> void:
	rig.host.stop()
	rig.client.stop()
	for m in [rig.host, rig.client]:
		remove_child(m)
		(m as DotNetManager).free()


func _test_distance_rings() -> void:
	print("")
	print("[distance rings]")
	# 10 m: inside far_distance (40). 60: first ring. 100: second. 150: past the radius (120).
	var rig := _ring_rig([10, 60, 100, 150], 2, 2, 120.0)
	for _i in 4:
		rig.step()
	for m in rig.mirrors:
		m.applied = 0
	for _i in 16:
		rig.step()
	var got: Array = []
	for m in rig.mirrors:
		got.append(m.applied)
	_check("near sends every snapshot, mid every 2nd, far every 4th, past the radius none (%s)" % [got],
		got == [16, 8, 4, 0])

	# The same room with the rings off: more bytes, and the far one is heard.
	var plain := _ring_rig([10, 60, 100, 150], 1, 1, 1000.0, "Plain")
	for _i in 20:
		plain.step()
	_check("rings cost fewer bytes than none (%d B against %d B)" % [rig.bytes, plain.bytes],
		rig.bytes < plain.bytes)
	_check("with no rings every entity is heard (%d)" % plain.mirrors[3].applied, plain.mirrors[3].applied > 0)
	_ring_free(plain)

	# Leaving: the client keeps the last pose, it is not thrown to the origin.
	var c: Counted = rig.subjects[2]
	var mirror: Counted = rig.mirrors[2]
	var last_heard: Vector3 = mirror.received_values().get(&"position", Vector3.ZERO)
	_check("the far one was heard at its place, not at the origin (%s)" % last_heard, absf(last_heard.x - 100.0) < 0.05)
	(c.identity.entity as Node3D).global_position = Vector3(150, 0, 0)
	c.position.x = 150.0
	var applied_before: int = mirror.applied
	for _i in 8:
		rig.step()
	var held: Vector3 = mirror.received_values().get(&"position", Vector3.ZERO)
	var silent: int = mirror.applied - applied_before
	_check("leaving the radius stops the snapshots and holds the last pose (%d new, x %.1f)" % [silent, held.x],
		silent == 0 and absf(held.x - 100.0) < 0.05)

	# Coming back: the first snapshot after the entity returns carries its current state.
	(c.identity.entity as Node3D).global_position = Vector3(100, 0, 0)
	c.position.x = 100.0
	var before_return: int = mirror.applied
	for _i in 8:
		rig.step()
	var back: Vector3 = mirror.received_values().get(&"position", Vector3.ZERO)
	_check("it is heard again within one ring turn of returning (%d snapshots)" % [mirror.applied - before_return],
		mirror.applied - before_return >= 1 and absf(back.x - 100.0) < 0.05)
	_check("and what it says is the current state, y %.2f of %.2f" % [back.y, c.position.y],
		absf(back.y - c.position.y) <= 0.01 * 4.0 + 0.02)
	_ring_free(rig)

	_test_ring_reentry_drawn()


## What is drawn when an entity returns from beyond the radius: no jump larger than the distance it
## actually covered, and it ends up at the server's place.
func _test_ring_reentry_drawn() -> void:
	var rig := _ring_rig([100], 2, 2, 120.0, "Back")
	var subject: Counted = rig.subjects[0]
	var identity := subject.identity
	for _i in 12:
		rig.step()
	# Out for 3 s (180 ticks at 60), well past the interpolation buffer, then back where it was not.
	(identity.entity as Node3D).global_position = Vector3(300, 0, 0)
	subject.position.x = 300.0
	for _i in 180:
		rig.step()
	(identity.entity as Node3D).global_position = Vector3(70, 0, 0)
	subject.position.x = 70.0
	var drawn: Array[float] = []
	for _i in 40:
		rig.step()
		var sampled: Dictionary = rig.client.interpolator.sample(identity.net_id, float(rig.tick))
		var pos: Variant = sampled.get(&"position")
		if pos is Vector3:
			drawn.append((pos as Vector3).x)
	var worst_step := 0.0
	for i in range(1, drawn.size()):
		worst_step = maxf(worst_step, absf(drawn[i] - drawn[i - 1]))
	_check("after 3 s away it is drawn at the server's place within 40 ticks (x %.1f)" % drawn[drawn.size() - 1],
		absf(drawn[drawn.size() - 1] - 70.0) < 1.0)
	_check("and never drawn outside the two places it moved between (min %.1f max %.1f)" % [drawn.min(), drawn.max()],
		drawn.min() >= 69.0 and drawn.max() <= 101.0)
	_check("and no drawn step is larger than the 30 m it really covered while unheard (worst %.1f m)" % worst_step,
		worst_step <= 30.5)
	_ring_free(rig)
