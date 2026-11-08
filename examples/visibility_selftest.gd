extends Node

## [DotNetVisibility] and [DotNetInterestDistance] with it: the PVS row codec, hand-made rooms, a
## one-plane BSP baked, the conservative answers (outside the bounds, inside solid, no data), the
## tree and what the native core is handed, the per-snapshot cluster cache, the pins (owner, always-relevant, always_tags) and the audible radius, the switch, the
## fast and the generic interest paths agreeing, and a save/load round trip. The native core's
## agreement is checked by hash in [code]tools/visibility_bench.tscn[/code] (docs/testing.md).
## Run: [code]godot --headless --path . res://examples/visibility_selftest.tscn[/code]

const SECTIONS := 7
const CHECKS := 43

var _passed := 0
var _failed := 0
var _sections := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	print("dot-net visibility self-test")
	_rows()
	_rooms()
	_bsp()
	_tree()
	_interest()
	_paths_agree()
	_saved()
	print("%d sections, %d passed, %d failed" % [_sections, _passed, _failed])
	var bad := _sections != SECTIONS or _passed + _failed != CHECKS or _failed > 0
	if _sections != SECTIONS or _passed + _failed != CHECKS:
		print("ERROR: %d sections and %d checks ran, %d and %d expected" % [_sections, _passed + _failed, SECTIONS, CHECKS])
	get_tree().quit(1 if bad else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		print("   ok   ", what)
	else:
		_failed += 1
		print("  FAIL  ", what)


func _rows() -> void:
	_sections += 1
	print("-- PVS rows (Quake run-length: a zero byte, then how many zero bytes)")
	var pvs := PackedByteArray([0x05, 0x00, 0x02, 0x80, 0x00, 0x04])
	_check(DotNetVisibility.decode_row(pvs, 0, 4) == PackedByteArray([0x05, 0, 0, 0x80]), "a run of zeros expands")
	_check(DotNetVisibility.decode_row(pvs, 4, 4) == PackedByteArray([0, 0, 0, 0]), "a row of only zeros")
	_check(DotNetVisibility.decode_row(pvs, -1, 3) == PackedByteArray([0xFF, 0xFF, 0xFF]), "no row: sees everything")
	_check(DotNetVisibility.decode_row(pvs, 99, 2) == PackedByteArray([0xFF, 0xFF]), "a row past the end: sees everything")


## Four rooms in a row along x, each seeing its neighbours only.
func _corridor() -> DotNetVisibility:
	return DotNetVisibility.from_cells(
		Vector3.ZERO, 4.0, Vector3i(4, 1, 1), PackedInt32Array([0, 1, 2, 3]), [[1], [2], [3], []]
	)


func _rooms() -> void:
	_sections += 1
	print("-- hand-made rooms")
	var vis := _corridor()
	_check(vis.is_ready(), "built")
	_check(vis.visible(Vector3(2, 2, 2), Vector3(6, 2, 2)), "a neighbour is seen")
	_check(vis.visible(Vector3(6, 2, 2), Vector3(2, 2, 2)), "seeing is mutual (only one way was given)")
	_check(not vis.visible(Vector3(2, 2, 2), Vector3(10, 2, 2)), "two rooms away is not")
	_check(not vis.visible(Vector3(14, 2, 2), Vector3(2, 2, 2)), "nor the far end back")
	_check(vis.visible(Vector3(2, 2, 2), Vector3(-5, 2, 2)) and vis.visible(Vector3(40, 2, 2), Vector3(2, 2, 2)),
		"outside the bounds answers visible")
	var solid := DotNetVisibility.from_cells(
		Vector3.ZERO, 4.0, Vector3i(3, 1, 1), PackedInt32Array([0, -1, 1]), [[], []]
	)
	_check(not solid.visible(Vector3(2, 2, 2), Vector3(10, 2, 2)), "two rooms that do not see each other")
	_check(solid.visible(Vector3(6, 2, 2), Vector3(10, 2, 2)) and solid.visible(Vector3(2, 2, 2), Vector3(6, 2, 2)),
		"a cell inside solid answers visible both ways")
	_check(DotNetVisibility.new().visible(Vector3.ZERO, Vector3(99, 0, 0)), "no data answers visible")


func _bsp() -> void:
	_sections += 1
	print("-- a one-plane BSP baked")
	# One wall at x = 8: front (x >= 8) is leaf 0, cluster 1; back is leaf 1, cluster 0; neither sees the other.
	var vis := DotNetVisibility.bake_bsp(
		PackedFloat32Array([1, 0, 0, 8]), PackedInt32Array([0, -1, -2]), PackedInt32Array([1, 0]), 2,
		PackedInt32Array([0, 1]), PackedByteArray([0x01, 0x02]), 0, AABB(Vector3.ZERO, Vector3(16, 4, 4))
	)
	_check(vis.cluster_of(Vector3(6, 2, 2)) == 0 and vis.cluster_of(Vector3(14, 2, 2)) == 1, "a walk down the tree finds each side's cluster")
	_check(not vis.visible(Vector3(2, 2, 2), Vector3(14, 2, 2)), "across the wall: culled")
	_check(not vis.visible(Vector3(14, 2, 2), Vector3(6, 2, 2)), "and back, right up to the wall")
	_check(vis.visible(Vector3(2, 2, 2), Vector3(6, 2, 2)), "a cluster sees itself (the bake sets the bit)")
	_check(vis.cluster_of(Vector3(8, 2, 2)) == 1, "a point on the plane is in front")
	_check(vis.visible(Vector3(2, 2, 2), Vector3(20, 2, 2)) and vis.cluster_of(Vector3(20, 2, 2)) == -1,
		"outside the bounds: no cluster, visible")


func _tree() -> void:
	_sections += 1
	print("-- the tree of hand-made rooms")
	var vis := DotNetVisibility.from_cells(
		Vector3.ZERO, 2.0, Vector3i(4, 2, 1), PackedInt32Array([0, 0, 1, 1, 0, 0, 1, 1]), [[], []]
	)
	_check(vis.nodes.size() / 3 == 7, "eight cells, seven splits")
	_check(vis.cluster_of(Vector3(1, 1, 1)) == 0 and vis.cluster_of(Vector3(5, 3, 1)) == 1, "cells answer their clusters")
	_check(vis.describe()["clusters"] == 2 and vis.describe()["nodes"] == 7, "describe() counts them")
	var other := _corridor()
	_check(other.serial != vis.serial, "every set has its own serial")
	var nd := vis.native_dict()
	_check(nd["serial"] == vis.serial and nd["rows"] == vis.rows and nd["nodes"] == vis.nodes and nd["bounds"] == vis.bounds,
		"native_dict carries the tree")
	var broken := vis.duplicate() as DotNetVisibility
	broken.head = 99
	_check(not broken.is_ready() and broken.visible(Vector3(1, 1, 1), Vector3(5, 3, 1)), "a broken tree is not used: visible")


## An identity at [param at] on a node in the tree.
func _body(id: int, at: Vector3, owner_peer: int = 0) -> DotNetIdentity:
	var body := Node3D.new()
	add_child(body)
	body.global_position = at
	var identity := DotNetIdentity.new()
	body.add_child(identity)
	identity.entity = body
	identity.net_id = id
	identity.owner_peer_id = owner_peer
	# Linger is the wall clock's: off, so each answer is this call's alone.
	identity.interest_linger_sec = 0.0
	return identity


func _ids(list: Array) -> Array:
	var out := []
	for identity: DotNetIdentity in list:
		out.append(identity.net_id)
	out.sort()
	return out


func _interest() -> void:
	_sections += 1
	print("-- DotNetInterestDistance with visibility")
	var observer := _body(1, Vector3(2, 2, 2), 7)
	var neighbour := _body(2, Vector3(6, 2, 2))
	var hidden := _body(3, Vector3(10, 2, 2))
	var pinned := _body(4, Vector3(14, 2, 2))
	pinned.always_relevant = true
	var owned := _body(5, Vector3(14, 2, 2), 7)
	var tagged := _body(6, Vector3(10, 2, 2))
	tagged.interest_tags = PackedStringArray(["objective"])
	var all: Array[DotNetIdentity] = [observer, neighbour, hidden, pinned, owned, tagged]
	var context := {"tick": 1, "now_ms": 0}
	var interest := DotNetInterestDistance.new()
	interest.evaluation_interval_sec = 0.0
	interest.visibility_audible_radius = 0.0
	_check(_ids(interest.relevant_for(observer, all, 7, context)) == [1, 2, 3, 4, 5, 6], "no visibility: all in range")
	interest.visibility = _corridor()
	_check(_ids(interest.relevant_for(observer, all, 7, context)) == [1, 2, 4, 5], "hidden dropped; owned and always-relevant kept")
	interest.always_tags = PackedStringArray(["objective"])
	_check(_ids(interest.relevant_for(observer, all, 7, context)) == [1, 2, 4, 5, 6], "an always_tags entity is kept")
	interest.always_tags = PackedStringArray()
	interest._prepare(all, context)
	_check(interest._clusters.size() == all.size() and _ids(interest.relevant_for(observer, all, 7, context)) == [1, 2, 4, 5],
		"prepared: each entity's cluster looked up once, the same answer")
	interest.index_snapshot([])
	_check(interest._clusters.is_empty(), "and forgotten when the snapshot ends")
	interest.visibility_audible_radius = 9.0
	_check(_ids(interest.relevant_for(observer, all, 7, context)) == [1, 2, 3, 4, 5, 6], "within the audible radius (8 m away, 9 m radius) both are kept")
	interest.visibility_audible_radius = 0.0
	interest.visibility_enabled = false
	_check(_ids(interest.relevant_for(observer, all, 7, context)) == [1, 2, 3, 4, 5, 6], "switched off: distance only")
	interest.visibility_enabled = true
	interest.radius = 5.0
	_check(_ids(interest.relevant_for(observer, all, 7, context)) == [1, 2, 4, 5], "distance still cuts first")
	interest.radius = 200.0
	_check(interest.describe()["visibility"] is Dictionary, "describe() shows the set")
	_check(interest.native_config(DotNetConfig.new())["vis"].has("rows"), "the native config carries it")
	interest.visibility_enabled = false
	_check(interest.native_config(DotNetConfig.new())["vis"].is_empty(), "and not when switched off")
	var cached := DotNetInterestDistance.new()
	cached.evaluation_interval_sec = 10.0
	cached.visibility_audible_radius = 0.0
	var _first := cached.relevant_for(observer, all, 7, context)
	cached.visibility = _corridor()
	_check(_ids(cached.relevant_for(observer, all, 7, context)) == [1, 2, 4, 5], "assigning a set invalidates the cache")
	for identity in all:
		identity.entity.queue_free()


func _paths_agree() -> void:
	_sections += 1
	print("-- the fast loop and the generic path agree")
	var vis := DotNetVisibility.from_cells(
		Vector3.ZERO, 4.0, Vector3i(8, 2, 8), _random_cells(8 * 2 * 8, 12), _random_sees(12)
	)
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026
	var all: Array[DotNetIdentity] = []
	for i in 120:
		all.append(_body(i + 1, Vector3(rng.randf_range(-4, 36), rng.randf_range(0, 8), rng.randf_range(-4, 36)), i % 7))
	var fast := DotNetInterestDistance.new()
	var slow := DotNetInterestDistance.new()
	slow.use_squared = false
	for s in [fast, slow]:
		s.evaluation_interval_sec = 0.0
		s.radius = 30.0
		s.visibility = vis
		s.visibility_audible_radius = 3.0
	var context := {"tick": 1, "now_ms": 0}
	var same := 0
	var culled := 0
	for o in 20:
		var observer := all[o]
		var a := _ids(fast.relevant_for(observer, all, observer.owner_peer_id, context))
		var b := _ids(slow.relevant_for(observer, all, observer.owner_peer_id, context))
		if a == b:
			same += 1
		var plain := DotNetInterestDistance.new()
		plain.evaluation_interval_sec = 0.0
		plain.radius = 30.0
		culled += plain.relevant_for(observer, all, observer.owner_peer_id, context).size() - a.size()
	_check(same == 20, "20 observers, 120 entities: the same sets (%d agree)" % same)
	_check(culled > 0, "and the set culls something (%d)" % culled)
	for identity in all:
		identity.entity.queue_free()


func _random_cells(count: int, clusters: int) -> PackedInt32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var out := PackedInt32Array()
	for i in count:
		var _a := out.append(-1 if rng.randf() < 0.1 else rng.randi_range(0, clusters - 1))
	return out


func _random_sees(clusters: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var out := []
	for c in clusters:
		var row := []
		for o in clusters:
			if rng.randf() < 0.25:
				row.append(o)
		out.append(row)
	return out


func _saved() -> void:
	_sections += 1
	print("-- saved and loaded")
	var vis := _corridor()
	var path := "user://visibility_selftest.res"
	_check(ResourceSaver.save(vis, path) == OK, "ResourceSaver writes it")
	var back := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as DotNetVisibility
	_check(back != null and back.is_ready(), "and it loads ready")
	_check(back != null and not back.visible(Vector3(2, 2, 2), Vector3(10, 2, 2)) and back.visible(Vector3(2, 2, 2), Vector3(6, 2, 2)),
		"answering as before")
	_check(back != null and back.serial != vis.serial, "with a serial of its own")
	var _r := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
