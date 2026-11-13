extends RefCounted

## dot-net's API level. The rule for bumping it is on [DotAddonApi]. LEVEL rises by one for anything a
## game could call that did not exist before.

# 7: DotNetClock.adopt_tick_rate(rate). 8: DotNetBehaviour.extrapolated_value(property,
# velocity_property, tick) and DotNetConfig.remote_extrapolation_sec. 17: DotNetVar.server_driven()
# / client_predicts. 18: DotNetInput.Buffer.push_batch(inputs), the lead measured per packet.
# 19: DotNetManager.snapshot_due().
const LEVEL := 19
const OLDEST := 1
