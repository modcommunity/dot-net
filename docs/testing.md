# Testing

The family's method is in [docs/testing.md](../../../docs/testing.md); this is what is specific here.

## The suites

| Scene | What it covers |
| --- | --- |
| `examples/netcode_demo.tscn` | wire round-trips, input batches, quantisation, message direction, two builds with different message sets, batching and fragmentation, clock convergence and the receive timeline under a late packet, replication and per-peer dirty tracking, interest strategies agreeing, budget fairness, interpolation and extrapolation bounds, the render delay at 128/20 (clean, lossy, 120 ms round trip), rewind/restore, prediction replay against a changing input and across a hole, correction offsets (every one eased, and added up), the interpolation buffer growing without moving the render time back and covering lateness, drawing through slips (a drifting clock, a re-anchored receive timeline and a resumed stream, each beside its control), a predicted entity the server holds still, bumping a remote under loss (the prediction error of each estimate at 0, 5 and 15% loss and two bot speeds, beside a control told the truth), reordered and repeated snapshots, snapshot parts (split at the MTU, a lost part costing only its entities, late parts superseded, at most sixteen), unchanged entities (listed rather than written to a client that reads the list and not to one that does not, the per-snapshot hook and interpolation samples unchanged, relevance, an empty world still sent, the run codec, a truncated list), the input lead the server reports (a client that reads it beside one from before on a simulated link going 40 to 70 ms each way and back: commands on time, the lead given back, the receive timeline not carried ahead, the old client's snapshots unchanged), the input lead under packet loss (a modelled link losing 20% each way at 22 and 33 Hz: the clock jumping when every input is measured, never when a packet's newest is; a replay starting inside a hole after its predecessor was acknowledged), time the engine drops (a first visit's stalls and 150 ms frames under the engine's step cap at 60 and 128, beside a clock handed only the steps; the same with the snapshots read inside the physics step; frames the engine keeps up with, where the two clocks must agree; the floor on its own; and through the engine itself, a half-second stall inside a physics step credited with no server in the process, not with a server's clock beside it, and not by a clock advanced by hand), staggered snapshots, freed entities, and a server+client integration run under simulated loss |
| `examples/diagnostics_demo.tscn` | `DotNetStats` and `DotNetSnapshot` on their own: inferred loss counted in snapshot periods, reordering against duplication, rates on a connection that stopped, rtt percentiles, delta/apply round-trips, baseline isolation |
| `examples/transport_fit_selftest.tscn` | the worst-case snapshot (255 fragments of `mtu` less 8 = 303,960 B) against `max_message_bytes()` of the WebSocket and ENet defaults, the WebRTC 16 KB message ceiling, and the WebSocket queue holding eight worst-case snapshots. Raise a transport default, not this test, when it fails |
| `examples/loss_demo.tscn` | a server and two clients over a seeded link (loss, repeats, jitter wider than the packet gap, in both directions, so acknowledgements are lost too): clients agree with the server within 30 ticks of the link healing, nothing older than what was applied is applied, a stream (late, never lost) reports no loss, a blackout's one-time changes come back, snapshot parts under loss, a stale snapshot twice, and the counters against what the link injected. `-- --seed=N` runs one seed. Armed: without the `acked.erase` in `_sync_view` seed 2026 never converges (#35) |
| `examples/relay_demo.tscn` | the UDP relay against real sockets, a real ENet pair through it, and ENet's packet throttle under a reliable burst and long frames on a steady 60 ms (the stock pair the control, dot-core's `DotTransportENet` delivering every unreliable packet) |
| `examples/visibility_selftest.tscn` | `DotNetVisibility` and the distance interest with it: the PVS row codec, hand-made rooms and a one-plane BSP walked to their clusters, the conservative answers (outside the bounds, inside solid, a broken tree, no data), the per-snapshot cluster cache, the owner, always-relevant, `always_tags` and audible-radius pins, the switch, the fast and generic interest paths agreeing on 120 random entities, a save/load round trip. The native core is checked against it by digest: `tools/visibility_bench.tscn -- --map=<bsp_vis_export.py json> --vis=on --hash` with and without `--native-interest` |

Every one of the bugs in [history.md](history.md) passed the parse check; only running found them.

## What a green run here cannot see

Most bugs in this addon were found by a game, because the suites here had one shape where the bug needed another. When adding a check, ask which of these it lacks:

- **A second peer.** A code path only one deployment shape reaches is a code path nothing has run: per-peer dirty tracking behaved like a shared dictionary with one peer.
- **A changing input.** A constant input is not an input: a replay with the wrong input gave the right answer for sixty ticks.
- **A real socket and a real round trip.** A loopback has zero flight time and in-order delivery; the render-delay and timeline bugs needed a 120 ms round trip and jitter. Use the relay.
- **The unhealthy path.** `diagnostics_demo` exists because the healthy path reached no branch describing an unhealthy one.
- **The clock in the path.** Calling `DotNetInterpolator.sample()` at hand-picked ticks, written in the same unit as the code, cannot catch a unit or timeline error.
- **A real pool.** A pool that parks its nodes in the live container is not a pool.

Recent checks are **armed**: the section states what it measured with the fix reverted. Revert the fix and watch it fail before trusting it.

**A test count is not coverage.** A suspending section called without `await` runs to its suspension and stops while `_run()` carries on to `quit()`, and a count of checks that ran cannot reveal it. `_run()` compares suspending sections entered against sections completed. The demo also counts engine errors with a `Logger` and asserts zero, the only way a suite sees a line that goes to stderr and changes no exit code.

## The UDP relay

`addons/dot_net/testing/dot_net_udp_relay.gd` listens on a port, forwards every client it hears to a target, and drops, delays (`delay_ms` ± `jitter_ms`, so a spread wider than the gap between packets reorders them as a real path does), holds back (`reorder`, `reorder_ms`) and duplicates each datagram, each direction on its own seeded generator. It runs on its own thread so a hitch in the game being measured is not a burst in the network measuring it (`threaded = false` and `poll()` to step it by hand). No `class_name`: it ships inside the addon so a game linking `dot_net` can preload it by path, and a test tool should not reserve a global name in every project. The kernel's queueing discipline would do the same but needs root; ENet's own simulated loss is an engine compile flag. game-fatal-contact's `headless_lossy` uses it on a real game.

## Artificial client latency

`DotNetManager.latency` (`DotNetLatency`) holds a client's packets for `cl_latency_baseline` seconds on top of the real latency, to test lag: outgoing through `send_fn` (the manager hands the host a wrapper while it is on, so the host's own `send_fn` is untouched) and incoming through `receive` and `receive_snapshot`; the held queue is drained from `step()`. At 0 nothing is wrapped or queued, one float compare per packet. The server's `sv_allow_client_latency` (default 1) at 0 forces the effective value to 0 and releases whatever is held, in order; the client's own request is kept. The host registers the cvars (dot-net has no console): `latency.bind_client_cvar(add)` on a client, `latency.bind_server_cvar(add, replicate_flag)` on a server, `latency.follow_cvars(link)` on a client so the server's switch arrives through `replicated_cvar`. `netcode_demo` section `[client latency baseline]` covers the behaviour. It delays what the manager sees, not the transport: a game's own raw channel traffic is untouched.

## GDScript traps

The family's are in [gdscript-hazards.md](../../../docs/gdscript-hazards.md). Two hit here:

- **`var x := something_returning_Variant()`** is a parse error under the project's warning settings. Write `var x: Variant = ...`. A script that fails to load makes a headless run hang rather than error.
- **Fan-out**: bare statement calls plus a member counter, not a signal count.
