extends RefCounted

## dot-net's API level. The rule for bumping it is on [DotAddonApi]. LEVEL rises by one for anything a
## game could call that did not exist before.

# 7: DotNetClock.adopt_tick_rate(rate), the engine's tick rate plus a step cap of a quarter second. 8:
# DotNetBehaviour.extrapolated_value(property, velocity_property, tick) and
# DotNetConfig.remote_extrapolation_sec: a remote where it is at an input tick, to bump against.
const LEVEL := 16
const OLDEST := 1
