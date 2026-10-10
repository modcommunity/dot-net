# Prediction, reconciliation and inputs

## Determinism is a requirement, not an aspiration

`_net_simulate` runs on the server **and** on the owning client for the same tick, and reconciliation only converges if both get the same answer. Anything that differs between machines breaks it:

- wall-clock time, or `randf()` without a shared seeded stream;
- another player's unpredicted state;
- a physics query against geometry only one side has loaded;
- iteration over an unordered collection whose order differs (which is why `DotNetSnapshot.net_ids()` is sorted).

Godot's physics is not deterministic across platforms; a game needing exact reconciliation simulates movement itself (the demo's `Movement` does, and so does dot-player-controller's motor).

`DotNetPredictor.correction_rate()` is the number that tells you. Near zero means the two agree. Consistently high means the simulation is not deterministic, and no amount of smoothing will fix that; it will just hide it badly.

## Reconciliation

- **A replay applies each tick's input, then simulates**, exactly as `DotNetManager.server_tick` does. Replaying on whatever input the behaviour still held (the newest) gives the right answer only while the input is constant, which is why the suite zig-zags it.
- **A hole is replayed on the older input.** When the clock catches up it jumps over ticks that get no command, and the server runs them on the previous one. A tick with no input but inputs on both sides of it (`Buffer.latest_before`, `Buffer.since`) is replayed on the older one. Stopping at the hole left the prediction a catch-up's worth of running short of the server.
- **Nothing past the newest input is replayed.** Those are ticks the client has not played yet (a lockstep host reconciles before it records the tick), and replaying them predicted them twice.

## What the server said

A snapshot carries an entity whenever it is relevant, with an empty body when nothing changed, and **absent means unchanged**. The client has to believe that:

- `read_state(reader, tick, rewind = true)` on a predicted entity puts every property the snapshot left out back to what the server last sent, **before** `_net_state_applied`, and `DotNetBehaviour.authoritative_values()` (the receive-side baseline overlaid with this snapshot) is what goes to `reconcile`.
- It must not be filled from `snapshot_values()` or the properties: on the owning client those hold its own prediction, because every game's `_net_simulate` copies each predicted tick into them. Read that way, "nothing new" became "the server agrees with you", and a client predicting a move the server refused (a server-only freeze, a wall only the server has) walked away from the server at twice its speed.
- Every game rewinds inside `_net_state_applied` by copying the properties into its simulation, which is why the fix restores the properties rather than only the values handed to `reconcile`.
- **A property with a `max_rate` is left alone unless it arrived**: its absence may mean the limit held it back.

The send side has to make "absent means unchanged" true under loss: see [replication.md](replication.md#owed-until-confirmed). Alternatives refused: always sending the owner's entity in full (pays a stationary player's full state every snapshot, and the client fix was still needed), and an explicit "unchanged" marker (it already exists: the entity's presence with an empty body).

## Open: a rate-limited predicted property

`authoritative_values()` leaves out a rate-limited property the snapshot did not carry, because the receiver cannot tell "held back" from "stood still". So a predicted `max_rate` property the server holds still is never rewound. No game sets `max_rate` on a predicted property. The fix, when one does, is on the send side: mark a property skipped for rate, so an unmarked absence means "unchanged since the acked baseline".

## Input batches

Each input packet carries the last few inputs, because every lost input packet is otherwise a tick the server runs on the previous command. `DotNetInput.write_batch` / `read_batch` encode them (count, the first tick in full, each later one as a varint step); `Buffer.recent(count, upto_tick)` gives a client its copies from the replay history; `Buffer.last_consumed_tick()` lets a server skip copies it has already simulated rather than count each as late. Duplicates are counted, not applied twice.

Wiring it is each game's bridge, and most send three. mg-look-at-me and dot-game-template still send one input per packet: not yet converted; reason unknown.

## Inputs are untrusted

`DotNetInput._sanitise()` runs on the server after decode and is not optional; see [security.md](security.md).

## Lag compensation

`DotNetHistory` records per tick (sized from `tick_rate`, not `snapshot_rate`: over-allocating costs memory, under-allocating costs hit registration) and rewinds the world to `client_view_tick` for a shot. `_net_record_history()` adds extra state (crouch flags, animation frames). An entity not in the tree is skipped when recording, rewinding and restoring: a sample at the origin would drag a hitbox through the middle of the map. Rewind is bounded by `max_rewind_sec` (1 s by default, so a 300-400 ms player is compensated); a larger claim is clamped.
