extends Node

## DotNetInterestDistance over a frozen world with and without the packed per-snapshot copies
## ([member DotNetInterest.use_packed]): the same relevant set in the same order over seeded worlds (owners,
## always-relevant, tagged entities), then the cost of index_snapshot plus one relevance per observer.
## Exit 1 on any difference or when the packed path is not the one measured; the timings are printed, not asserted
## (budgets belong to the perf system). Run: [code]godot --headless --path . res://tools/interest_packed_bench.tscn[/code]

const ENTITIES := 2000
const OBSERVERS := 32


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	var bad := 0
	for seed_i in 4:
		bad += _compare(seed_i)
	_bench()
	print("RESULT: ", "PASS" if bad == 0 else "FAIL (%d differing)" % bad)
	get_tree().quit(1 if bad > 0 else 0)


func _world(seed_i: int, n: int) -> Array[DotNetIdentity]:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2000 + seed_i
	var all: Array[DotNetIdentity] = []
	for i in n:
		var id := DotNetIdentity.new()
		id.net_id = i + 1
		id.owner_peer_id = i % 40
		id._frozen_position = Vector3(rng.randf_range(-900, 900), rng.randf_range(-40, 80), rng.randf_range(-900, 900))
		id._position_frozen = true
		id.always_relevant = i % 97 == 0
		if i % 11 == 0:
			id.interest_tags = PackedStringArray(["prop"])
		all.append(id)
	return all


func _strategy() -> DotNetInterestDistance:
	var d := DotNetInterestDistance.new()
	d.radius = 150.0
	d.radius_by_tag = {"prop": 60.0}
	d.evaluation_interval_sec = 0.0
	return d


func _ids(arr: Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for id: DotNetIdentity in arr:
		out.append(id.net_id)
	return out


func _compare(seed_i: int) -> int:
	var all := _world(seed_i, ENTITIES)
	var bad := 0
	var sets: Array = []
	for packed in [false, true]:
		DotNetInterest.use_packed = packed
		var d := _strategy()
		d.index_snapshot(all)
		if d._packed_ok != packed:
			print("FAIL: packed path is %s, wanted %s" % [d._packed_ok, packed])
			bad += 1
		var per: Array = []
		for o in OBSERVERS:
			var out: Array = []
			d._evaluate_into(out, all[o * 13], all, {})
			per.append(_ids(out))
		sets.append(per)
	DotNetInterest.use_packed = true
	for o in OBSERVERS:
		if sets[0][o] != sets[1][o]:
			bad += 1
	print("seed %d: %d observers, %d differing" % [seed_i, OBSERVERS, bad])
	for id in all:
		id.free()
	return bad


func _bench() -> void:
	var all := _world(9, ENTITIES)
	for packed in [false, true]:
		DotNetInterest.use_packed = packed
		var d := _strategy()
		var best := INF
		for rep in 9:
			var t0 := Time.get_ticks_usec()
			d.index_snapshot(all)
			for o in OBSERVERS:
				var out: Array = []
				d._evaluate_into(out, all[o * 13], all, {})
			best = minf(best, float(Time.get_ticks_usec() - t0))
		print("BENCH %s: %d entities, %d observers, index+queries %.0f us" % ["packed" if packed else "objects", ENTITIES, OBSERVERS, best])
	DotNetInterest.use_packed = true
