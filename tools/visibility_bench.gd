extends "res://tools/snapshot_bench.gd"

## [code]snapshot_bench[/code] on a real map: every player and NPC walks between standing positions
## sampled from the map, and [code]--vis=on[/code] gives the distance interest the map's
## [DotNetVisibility]. The map comes from [code]tools/bsp_vis_export.py[/code]:
## [code]res://tools/visibility_bench.tscn -- --map=/path/orange_x3_vis.json --vis=on --radius=200[/code].
## Extra knob: [code]--audible=8[/code]. Prints [code]VIS {json}[/code] (the bake and
## the share of position pairs it culls) before the bench's [code]BENCH {json}[/code].

var _map_path := ""
var _vis_on := false
var _audible := 8.0
var _points: Array[Vector3] = []
var _vis: DotNetVisibility = null
## Per point, a near one to walk to (the third nearest, so mostly not through a wall).
var _next: PackedInt32Array = PackedInt32Array()


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var value := arg.get_slice("=", 1)
		match arg.get_slice("=", 0):
			"--map": _map_path = value
			"--vis": _vis_on = value != "off"
			"--audible": _audible = value.to_float()
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(_map_path)) if _map_path != "" else null
	if not data is Dictionary:
		push_error("visibility_bench: --map=<json from tools/bsp_vis_export.py> is required")
		get_tree().quit(2)
		return
	var map: Dictionary = data
	for p: Array in map["points"]:
		_points.append(Vector3(p[0], p[1], p[2]))
	for i in _points.size():
		var order := range(_points.size())
		order.sort_custom(func(a: int, c: int) -> bool:
			return _points[i].distance_squared_to(_points[a]) < _points[i].distance_squared_to(_points[c]))
		var _n := _next.append(order[mini(3, order.size() - 1)])
	var b: Array = map["bounds"]
	var at := Time.get_ticks_usec()
	_vis = DotNetVisibility.bake_bsp(
		PackedFloat32Array(map["planes"]), PackedInt32Array(map["nodes"]),
		PackedInt32Array(map["leaf_cluster"]), int(map["clusters"]), PackedInt32Array(map["pvs_offsets"]),
		Marshalls.base64_to_raw(map["pvs"]), int(map["head"]),
		AABB(Vector3(b[0], b[1], b[2]), Vector3(b[3], b[4], b[5]))
	)
	var bake_ms := float(Time.get_ticks_usec() - at) / 1000.0
	# The share of sampled position pairs the set culls, as the interest asks it.
	var pairs := 0
	var culled := 0
	var raw_culled := 0
	for i in _points.size():
		for j in _points.size():
			if i == j:
				continue
			pairs += 1
			if not _vis.visible(_points[i], _points[j]):
				raw_culled += 1
				if _points[i].distance_to(_points[j]) > _audible:
					culled += 1
	var row := _vis.describe()
	row.merge({
		"map": map["map"], "bake_ms": snappedf(bake_ms, 0.1), "audible": _audible,
		"points": _points.size(), "culled_pairs": snappedf(float(culled) / pairs, 0.001),
		"culled_pairs_no_audible": snappedf(float(raw_culled) / pairs, 0.001), "vis": _vis_on,
	})
	print("VIS %s" % JSON.stringify(row))
	super._ready()


func _make_host() -> DotNetManager:
	var host := super._make_host()
	var distance := host.interest as DotNetInterestDistance
	if _vis_on and distance != null:
		distance.visibility = _vis
		distance.visibility_audible_radius = _audible
	return host


## Positions on the map: each entity walks between a sampled standing point and a near one at
## 5 m/s, a fifth of the NPCs stand on theirs. The same pure function of (entity, tick) as the base.
func _move(players: Array[Player], npcs: Array[Npc], tick: int) -> void:
	for i in players.size():
		var p := players[i]
		var at := _walk(i * 37, tick)
		p.velocity = (at - p.position) * 64.0 if tick > 1 else Vector3.ZERO
		p.position = at
		p.yaw = fposmod(float(tick + i) * 3.0, 360.0)
		p.pitch = float((tick + i) % 30)
		(p.identity.get_parent() as Node3D).position = at
		if (tick + i) % 23 == 0:
			p.health = 100.0 - float((tick * 7 + i) % 90)
			p.ammo = (tick + i) % 30
		if (tick + i) % 41 == 0:
			p.points += 10
	for i in npcs.size():
		var n := npcs[i]
		var node := n.identity.get_parent() as Node3D
		if i % 5 != 0 or tick == 1:
			var at := _walk(1000 + i * 53, tick if i % 5 != 0 else 0)
			n.net_x = at.x
			n.net_y = at.y
			n.net_z = at.z
			n.net_yaw = (tick + i) & 255
			node.position = at
		if (tick + i) % 17 == 0:
			n.net_anim = (tick + i) % 20
			n.net_health = 100 - (tick + i) % 100


func _walk(seed_index: int, tick: int) -> Vector3:
	var count := _points.size()
	var from := _points[seed_index % count]
	var to := _points[_next[seed_index % count]]
	var length := maxf(from.distance_to(to), 0.1)
	# 5 m/s at 64 Hz, there and back.
	var s := fposmod(float(tick + seed_index) * 5.0 / 64.0, 2.0 * length)
	return from.lerp(to, (s if s <= length else 2.0 * length - s) / length)
