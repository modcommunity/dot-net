extends Node

## Hammers the native core's job pool: many begin_snapshot / submit_peer / finish_snapshot rounds
## with tiny jobs and several workers, so a worker that has just finished its last job races the
## main thread's reset for the next round. Before that reset was taken under the pool's lock it
## could hand a worker a freed Job (a garbage Peer: SIGFPE in the interest pass, or a finish that
## returned early with too few results).
## Run: [code]res://tools/native_jobs_stress.tscn -- --rounds=300000 --workers=32 --peers=2[/code]
## (more workers than cores, so a worker is preempted inside that window: the old build crashed
## so on the PH build VM, the fixed one runs clean);
## [code]--cfg=/abs/x.cfg[/code] loads another build of the library. Prints [code]STRESS {json}[/code],
## exits 1 on any round with the wrong number of results.


func _ready() -> void:
	var rounds := 100000
	var workers := 4
	var peers := 6
	var cfg := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--rounds="):
			rounds = int(arg.get_slice("=", 1))
		elif arg.begins_with("--workers="):
			workers = int(arg.get_slice("=", 1))
		elif arg.begins_with("--peers="):
			peers = int(arg.get_slice("=", 1))
		elif arg.begins_with("--cfg="):
			cfg = arg.get_slice("=", 1)
	var res := DotNetNative.load_library(cfg)
	if not res.ok:
		printerr("STRESS no native library: %s" % str(res))
		get_tree().quit(2)
		return
	var core: Object = ClassDB.instantiate(DotNetNative.CORE_CLASS)
	var empty: Array = []
	var bad := 0
	var started := Time.get_ticks_msec()
	for r in rounds:
		core.call(&"set_interest", {})
		core.call(&"begin_snapshot", empty, PackedInt64Array([r + 1, r * 8, 1200, 0, workers, 1]))
		for p in peers:
			core.call(&"submit_peer", empty, PackedInt64Array([p + 2, 0, 0, 0, 1200, 0, 0, 0]), {}, {})
		var out: Array = core.call(&"finish_snapshot")
		if out.size() != peers:
			bad += 1
			if bad <= 5:
				printerr("STRESS round %d: %d results for %d peers" % [r, out.size(), peers])
	var summary := {
		"rounds": rounds, "workers": workers, "peers": peers, "bad": bad,
		"ms": Time.get_ticks_msec() - started, "from": DotNetNative.describe()["from"],
	}
	print("STRESS %s" % JSON.stringify(summary))
	get_tree().quit(1 if bad > 0 else 0)
