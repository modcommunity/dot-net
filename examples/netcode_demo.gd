extends "selftest/netcode_sections_8.gd"

## Runs a server and a client in one process over a loopback that can delay, reorder and drop packets, and checks the netcode works.
##
## Offline and deterministic; exits non-zero on any failure, so it works as a smoke test in CI.


## Every check this suite makes, the last one included. The section counter cannot see a check that never ran inside a section that had announced itself, so the total is compared with this. Raise it with every check added.
const CHECKS := 538


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_rng.seed = 12345
	await _run()


func _run() -> void:
	_test_config_sizing()
	_test_count_limits()
	print("dot-net self-test")
	print("")

	_test_wire()
	_test_bit_runs()
	_test_quantisation()
	_test_messages()
	_test_mismatched_schemas()
	_test_packets()
	_test_clock()
	await _test_replication()
	_test_interest()
	_test_budget()
	await _test_interpolation()
	_test_render_delay()
	_test_lag_compensation()
	_test_prediction()
	_test_starved_input()
	_test_correction_offsets()
	_test_buffer_growth()
	_test_drawing_through_slips()
	_test_spawning()
	_test_freed_entity()
	_test_unregistered_mid_tick()
	_test_acked_baselines()
	_test_shared_dirty_sets()
	_test_standing_still()
	_test_remote_bumps()
	_test_reconcile_once_per_frame()
	_test_skip_matching_replays(false)
	_test_skip_matching_replays(true)
	_test_staggered_snapshots()
	_test_reordered_and_repeated()
	_test_snapshot_parts()
	_test_unchanged_entities()
	_test_snapshot_threads()
	_test_native()
	_test_input_batches()
	_test_input_lead()
	_test_dropped_time()
	_test_join_hitch()
	_test_cover_stalls()
	await _test_dropped_time_live()
	await _test_integration()
	_test_late_mirror_observer_vars()
	_test_latency_baseline()

	print("")
	_check(
		"every suspending section ran to completion (%d/%d)"
			% [_sections_completed, _sections_entered],
		_sections_completed == _sections_entered
	)

	_check(
		"every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS],
		_passed + _failed + 1 == CHECKS
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	if DotPlatform.is_headless():
		await get_tree().process_frame
		get_tree().quit(1 if _failed > 0 else 0)
