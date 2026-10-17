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
const LEVEL := 10
const OLDEST := 1
