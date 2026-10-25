extends Node

## Snapshot cost on a scripted server: N peers, each owning a predicted player, and a crowd of
## server-owned NPCs, moving every tick, acked two snapshots late. No game, no physics: the
## manager's snapshot half alone, in seconds rather than a game probe's minutes.
##
## [codeblock]
## godot --headless --path . res://tools/snapshot_bench.tscn -- --peers=100 --npcs=213
##     [--ticks=60] [--warm=20] [--relevance=off] [--radius=60] [--workers=N] [--cap=192]
##     [--far-every=N --far=M] [--hash]
## [/codeblock]
##
## [code]--hash[/code] prints one digest of every payload sent, in order: two builds of dot-net
## that print the same digest sent the same bytes. Prints one [code]BENCH {json}[/code] line.

class Player extends DotNetBehaviour:
	var position := Vector3.ZERO
	var velocity := Vector3.ZERO
	var yaw := 0.0
	var pitch := 0.0
	var health := 100.0
	var stance := 0
	var weapon := 0
	var ammo := 30
	var points := 0
	var flags := 0
	var grounded := true

	func _register_net_vars() -> void:
		replicate(&"position", DotNetVar.Type.VECTOR3_POSITION).interpolated()
		replicate(&"velocity", DotNetVar.Type.VECTOR3_VELOCITY)
		replicate(&"yaw", DotNetVar.Type.ANGLE).bits(12)
		replicate(&"pitch", DotNetVar.Type.ANGLE).bits(10)
		replicate(&"health", DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 2000.0).bits(14)
		replicate(&"stance", DotNetVar.Type.UINT).bits(3)
		replicate(&"weapon", DotNetVar.Type.UINT).bits(5)
		replicate(&"ammo", DotNetVar.Type.UINT).bits(9).to_owner_only()
		replicate(&"points", DotNetVar.Type.UINT).bits(16)
		replicate(&"flags", DotNetVar.Type.UINT).bits(8)
		replicate(&"grounded", DotNetVar.Type.BOOL)


class Npc extends DotNetBehaviour:
	var net_x := 0.0
	var net_y := 0.0
	var net_z := 0.0
	var net_yaw := 0
	var net_health := 100
	var net_state := 0
	var net_limbs := 0
	var net_anim := 0
	var net_flags := 0

	func _register_net_vars() -> void:
		replicate(&"net_x", DotNetVar.Type.FLOAT_RANGE).range_of(-2048.0, 2048.0).bits(20).interpolated()
		replicate(&"net_y", DotNetVar.Type.FLOAT_RANGE).range_of(-512.0, 512.0).bits(16).interpolated()
		replicate(&"net_z", DotNetVar.Type.FLOAT_RANGE).range_of(-2048.0, 2048.0).bits(20).interpolated()
		replicate(&"net_yaw", DotNetVar.Type.UINT).bits(8)
		replicate(&"net_health", DotNetVar.Type.UINT).bits(10)
		replicate(&"net_state", DotNetVar.Type.UINT).bits(3)
		replicate(&"net_limbs", DotNetVar.Type.UINT).bits(6)
		replicate(&"net_anim", DotNetVar.Type.UINT).bits(5)
		replicate(&"net_flags", DotNetVar.Type.UINT).bits(5)


const ACK_LAG := 2

var _peers := 100
var _npcs := 213
var _ticks := 60
var _warm := 20
var _relevance := true
var _radius := 60.0
var _workers := 0
var _cap := 192
var _far_every := 1
var _far := 0.0
var _hash := false


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	for arg in OS.get_cmdline_user_args():
		var value := arg.get_slice("=", 1)
		match arg.get_slice("=", 0):
			"--peers": _peers = value.to_int()
			"--npcs": _npcs = value.to_int()
			"--ticks": _ticks = value.to_int()
			"--warm": _warm = value.to_int()
			"--relevance": _relevance = value != "off"
			"--radius": _radius = value.to_float()
			"--workers": _workers = value.to_int()
			"--cap": _cap = value.to_int()
			"--far-every": _far_every = value.to_int()
			"--far": _far = value.to_float()
			"--hash": _hash = true
	_run.call_deferred()


func _run() -> void:
	var host := DotNetManager.new()
	host.name = "Bench"
	host.is_server = true
	host.local_peer_id = 1
	host.service_scope = &"snapshot_bench"
	host.auto_tick = false
	host.config_file = ""
	var config := DotNetConfig.new()
	config.tick_rate = 64
	config.snapshot_rate = 64
	config.per_client_budget = 0
	config.max_entities_per_snapshot = _cap
	config.snapshot_workers = _workers
	host.config = config
	add_child(host)
	var _s := host.setup()
	if _relevance:
		var distance := DotNetInterestDistance.new()
		distance.radius = _radius
		host.interest = distance
	else:
		host.interest = DotNetInterestAll.new()
	host.interest.evaluation_interval_sec = 0.0
	host.interest.far_every = _far_every
	host.interest.far_distance = _far

	var digest := HashingContext.new()
	var _d := digest.start(HashingContext.HASH_MD5)
	var sent := [0, 0]
	var acks_due: Array = []
	host.send_fn = func(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
		if delivery != DotNetMessage.Delivery.UNRELIABLE:
			return
		sent[0] += 1
		sent[1] += payload.size()
		if _hash:
			var _u := digest.update(PackedByteArray([peer_id & 0xFF, peer_id >> 8]))
			var _v := digest.update(payload)
	var _started := host.start()
	host.spawner.register_factory(&"player", func(_c: Dictionary) -> Node: return _body(Player.new()))
	host.spawner.register_factory(&"npc", func(_c: Dictionary) -> Node: return _body(Npc.new()))
	var schema := host.messages.schema_payload()

	var players: Array[Player] = []
	var npcs: Array[Npc] = []
	for i in _peers:
		var peer := i + 2
		host.add_peer(peer)
		var _r := host.receive(schema, peer)
		var made: DotNetIdentity = host.spawner.spawn(&"player", peer, Transform3D.IDENTITY, 0).value
		players.append(made.behaviours[0] as Player)
	for i in _npcs:
		var made: DotNetIdentity = host.spawner.spawn(&"npc", 0, Transform3D.IDENTITY, 0).value
		npcs.append(made.behaviours[0] as Npc)

	var times: Array[float] = []
	for tick in range(1, _warm + _ticks + 1):
		_move(players, npcs, tick)
		var at := Time.get_ticks_usec()
		host.server_tick(tick)
		if tick > _warm:
			times.append(float(Time.get_ticks_usec() - at) / 1000.0)
		acks_due.append(tick)
		if acks_due.size() > ACK_LAG:
			var acked: int = acks_due.pop_front()
			for i in _peers:
				var _a := host.receive_ack(i + 2, acked)

	times.sort()
	var total := 0.0
	for t in times:
		total += t
	var row := {
		"peers": _peers, "npcs": _npcs, "relevance": _relevance, "workers": _workers,
		"far_every": _far_every, "mean_ms": snappedf(total / times.size(), 0.01),
		"p50_ms": snappedf(times[times.size() / 2], 0.01),
		"min_ms": snappedf(times[0], 0.01),
		"bytes_per_peer": int(float(sent[1]) / float(maxi(sent[0], 1))),
		"pairs_us": snappedf(1000.0 * total / times.size() / float(_peers * (_peers + _npcs)), 0.01),
	}
	if _hash:
		row["hash"] = digest.finish().hex_encode()
	print("BENCH %s" % JSON.stringify(row))
	get_tree().quit(0)


func _body(behaviour: DotNetBehaviour) -> Node:
	var body := Node3D.new()
	var identity := DotNetIdentity.new()
	identity.name = "NetIdentity"
	identity.prefab_id = &"player" if behaviour is Player else &"npc"
	identity.authority = DotNetIdentity.Authority.SHARED if behaviour is Player else DotNetIdentity.Authority.SERVER
	if _hash:
		# Linger is timed by the wall clock, so a faster build would keep entities longer.
		identity.interest_linger_sec = 0.0
	body.add_child(identity)
	behaviour.name = "State"
	body.add_child(behaviour)
	identity.entity = body
	identity.behaviours = [behaviour]
	behaviour.identity = identity
	return body


## A pure function of (entity, tick): players and most NPCs move every tick, a fifth of the NPCs
## stand still, health and the small fields change now and then.
func _move(players: Array[Player], npcs: Array[Npc], tick: int) -> void:
	for i in players.size():
		var p := players[i]
		var a := float(i) * 0.37 + float(tick) * 0.02
		var r := 20.0 + float(i % 9) * 12.0
		p.position = Vector3(cos(a) * r, 0.0, sin(a) * r)
		p.velocity = Vector3(-sin(a), 0.0, cos(a)) * 4.0
		p.yaw = fposmod(a * 57.0, 360.0)
		p.pitch = float((tick + i) % 30)
		(p.identity.get_parent() as Node3D).position = p.position
		if (tick + i) % 23 == 0:
			p.health = 100.0 - float((tick * 7 + i) % 90)
			p.ammo = (tick + i) % 30
		if (tick + i) % 41 == 0:
			p.points += 10
	for i in npcs.size():
		var n := npcs[i]
		var node := n.identity.get_parent() as Node3D
		if i % 5 != 0:
			var a := float(i) * 0.61 + float(tick) * 0.01
			var r := 10.0 + float(i % 13) * 9.0
			n.net_x = cos(a) * r
			n.net_z = sin(a) * r
			n.net_yaw = int(a * 40.0) & 255
			node.position = Vector3(n.net_x, 0.0, n.net_z)
		elif tick == 1:
			n.net_x = float(i % 50) * 3.0 - 75.0
			n.net_z = float(i % 7) * 11.0 - 30.0
			node.position = Vector3(n.net_x, 0.0, n.net_z)
		if (tick + i) % 17 == 0:
			n.net_anim = (tick + i) % 20
			n.net_health = 100 - (tick + i) % 100
