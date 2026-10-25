extends RefCounted

## dot-net's API level. The rule for bumping it is on [DotAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.

# 7: DotNetClock.adopt_tick_rate(rate), the engine's tick rate plus a step cap of a quarter second.
# 8: DotNetBehaviour.extrapolated_value(property, velocity_property, tick) and
#    DotNetConfig.remote_extrapolation_sec: a remote where it is at an input tick, to bump against.
# 9: DotNetManager.perf_counters(), running totals of snapshot, reconcile and predict time.
# 10: DotNetManager.predict_tick(tick, input), and DotNetPredictor.predict's optional input:
#     a host with its own client tick predicts through the predictor, which remembers the tick
#     and rounds the input to the wire first (DotNetInput.round_trip, config.predict_wire_input).
#     DotNetBehaviour._net_predicts(): false keeps a reconcile's rewind without a replay.
# 11: DotNetConfig.snapshot_workers (env DOT_NET_SNAPSHOT_WORKERS, --net-snapshot-workers):
#     per-peer snapshots built on worker threads through dot-core's DotParallel, off by default.
#     DotNetInterest.is_thread_safe(), relevance() / commit_relevance(), ranked() / note_cap();
#     DotNetBudget.accumulate_record(); DotNetBehaviour.EncodeCache, collect_for_view,
#     write_for_view, state_bits_cached, view_for, peer_view_snapshot;
#     DotNetIdentity.freeze_position.
# 12: DotNetInterest.scores_for(observer, entities, context), the optional scores argument of
#     prioritise / ranked, and index_snapshot(all): each entity scored and looked up once a snapshot.
# 13: DotNetConfig.native / native_path (env DOT_NET_NATIVE, --net-native): server snapshots
#     built by the optional native library, DotNetNative; the same bytes, off by default.
# 14: DotNetInterpolator.value_at(net_id, property, render_tick): a remote as drawn at a past render
#     tick, counting nothing; what lag-compensated solid-player collision predicts against.
# 15: DotNetInterpolator.bracket_at(render_tick) and value_between(...): the two snapshot ticks a
#     view tick was drawn between, so a server can rewind between the same two; and
#     DotNetVar.wire_value(value), a value as the receiver reads it.
const LEVEL := 15
const OLDEST := 1
