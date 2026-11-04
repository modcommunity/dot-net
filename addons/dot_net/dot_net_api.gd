extends RefCounted

## dot-net's API level. The rule for bumping it is on [DotAddonApi]. LEVEL rises by one for anything a
## game could call that did not exist before.

# 7: DotNetClock.adopt_tick_rate(rate), the engine's tick rate plus a step cap of a quarter second. 8:
# DotNetBehaviour.extrapolated_value(property, velocity_property, tick) and
# DotNetConfig.remote_extrapolation_sec: a remote where it is at an input tick, to bump against. 17: DotNetVar.server_driven() / client_predicts.
# 18: DotNetConfig.predict_fill_ticks: predict_tick predicts the ticks a clock jump stepped over.
const LEVEL := 18
const OLDEST := 1
