extends Node

## DotNetInterestGrid's script index against dot-sim's DotSimInterestGrid: same candidates in the same order over
## seeded worlds (flat and 3D binning, negative coordinates, always-relevant entities), then a microbench of
## _prepare plus one _candidates per observer. Without the native class it prints SKIPPED and exits 0
## (exit 1 under GS_NATIVE_REQUIRED=1).
## Run: [code]godot --headless --path . res://tools/interest_native_parity.tscn[/code]

const ENTITIES := 2000
const OBSERVERS := 32


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	if not ClassDB.class_exists(&"DotSimInterestGrid"):
		print("SKIPPED: DotSimInterestGrid is not loaded")
		get_tree().quit(1 if OS.get_environment("GS_NATIVE_REQUIRED") == "1" else 0)
		return
	var bad := 0
	for seed_i in 4:
		for flat in [true, false]:
			bad += _compare(seed_i, flat)
	_bench()
	print("RESULT: ", "PASS" if bad == 0 else "FAIL (%d differing)" % bad)
	get_tree().quit(1 if bad > 0 else 0)


func _world(seed_i: int, n: int) -> Array[DotNetIdentity]:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1000 + seed_i
	var all: Array[DotNetIdentity] = []
	for i in n:
		var id := DotNetIdentity.new()
		id.net_id = i + 1
		id._frozen_position = Vector3(rng.randf_range(-900, 900), rng.randf_range(-40, 80), rng.randf_range(-900, 900))
		id._position_frozen = true
		id.always_relevant = i % 97 == 0
		all.append(id)
	return all


func _grid(native: bool, flat: bool) -> DotNetInterestGrid:
	var g := DotNetInterestGrid.new()
	g.native = native
	g.ignore_vertical = flat
	g.cell_size = 64.0
	g.radius = 150.0
	return g


func _ids(arr: Variant) -> PackedInt32Array:
	var out := PackedInt32Array()
	if arr == null:
		return out
	for id: DotNetIdentity in arr:
		out.append(id.net_id)
	return out


func _compare(seed_i: int, flat: bool) -> int:
	var all := _world(seed_i, ENTITIES)
	var a := _grid(false, flat)
	var b := _grid(true, flat)
	a._prepare(all, {})
	b._prepare(all, {})
	var bad := 0
	if b._index == null:
		print("FAIL: native index not used")
		return 1
	for o in OBSERVERS:
		var obs: DotNetIdentity = all[o * 13]
		if _ids(a._candidates(obs, all, {})) != _ids(b._candidates(obs, all, {})):
			bad += 1
	print("seed %d flat=%s: %d observers, %d differing" % [seed_i, flat, OBSERVERS, bad])
	for id in all:
		id.free()
	return bad


func _bench() -> void:
	var all := _world(9, ENTITIES)
	for native in [false, true]:
		var g := _grid(native, true)
		var best := INF
		for rep in 5:
			var t0 := Time.get_ticks_usec()
			g._prepare(all, {})
			for o in OBSERVERS:
				g._candidates(all[o * 13], all, {})
			best = minf(best, float(Time.get_ticks_usec() - t0))
		print("BENCH %s: %d entities, %d observers, prepare+queries %.0f us" % ["native" if native else "script", ENTITIES, OBSERVERS, best])
