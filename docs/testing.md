# Testing

The family's method is in [game-dev/docs/testing.md](../../../docs/testing.md); this is what is specific here.

## The suites

| Scene | What it covers |
| --- | --- |
| `examples/netcode_demo.tscn` | wire round-trips, input batches, quantisation, message direction, two builds with different message sets, batching and fragmentation, clock convergence and the receive timeline under a late packet, replication and per-peer dirty tracking, interest strategies agreeing, budget fairness, interpolation and extrapolation bounds, the render delay at 128/20 (clean, lossy, 120 ms round trip), rewind/restore, prediction replay against a changing input and across a hole, correction offsets (every one eased, and added up), the interpolation buffer growing without moving the render time back and covering lateness, drawing through slips (a drifting clock, a re-anchored receive timeline and a resumed stream, each beside its control), a predicted entity the server holds still, reordered and repeated snapshots, snapshot parts (split at the MTU, a lost part costing only its entities, late parts superseded, at most sixteen), unchanged entities (listed rather than written to a client that reads the list and not to one that does not, the per-snapshot hook and interpolation samples unchanged, relevance, an empty world still sent, the run codec, a truncated list), staggered snapshots, freed entities, and a server+client integration run under simulated loss |
| `examples/diagnostics_demo.tscn` | `DotNetStats` and `DotNetSnapshot` on their own: inferred loss counted in snapshot periods, reordering against duplication, rates on a connection that stopped, rtt percentiles, delta/apply round-trips, baseline isolation |
| `examples/relay_demo.tscn` | the UDP relay against real sockets, and a real ENet pair through it |

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

`addons/dot_net/testing/dot_net_udp_relay.gd` listens on a port, forwards every client it hears to a target, and drops, delays (`delay_ms` ± `jitter_ms`, so a spread wider than the gap between packets reorders them as a real path does), holds back (`reorder`, `reorder_ms`) and duplicates each datagram, each direction on its own seeded generator. It runs on its own thread so a hitch in the game being measured is not a burst in the network measuring it (`threaded = false` and `poll()` to step it by hand). No `class_name`: it ships inside the addon so a game linking `dot_net` can preload it by path, and a test tool should not reserve a global name in every project. The kernel's queueing discipline would do the same but needs root; ENet's own simulated loss is an engine compile flag. game-arena's `headless_lossy` uses it on a real game.

## GDScript traps

The family's are in [gdscript-hazards.md](../../../docs/gdscript-hazards.md). Two hit here:

- **`var x := something_returning_Variant()`** is a parse error under the project's warning settings. Write `var x: Variant = ...`. A script that fails to load makes a headless run hang rather than error.
- **Fan-out**: bare statement calls plus a member counter, not a signal count.
