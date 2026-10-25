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
- **`reconcile_once_per_frame` replays once a frame, not once a snapshot** (off by default). A replay costs (lead) ticks of simulation, and a client that stalls receives its queued snapshots in one frame: each replayed the whole lead, the frame got longer, the next backlog bigger, and a single-threaded browser client never recovered (2-8 fps, 470-660 replayed ticks a frame). With it on, `_apply_entity` keeps the predicted values in place and records only the newest snapshot's tick and values per entity; `flush_reconcile()` (called by `client_tick` before predicting and by `interpolate_frame`) replays from that one. The correction lands up to a frame later, which is why it is a choice and not the default. `describe()` reports `prediction.coalesced`, the snapshots it skipped.
- **`skip_matching_replays` skips a reconcile the prediction already reached** (off by default; needs `reconcile_once_per_frame`). The predictor remembers what each predicted tick produced, and a snapshot whose state for tick T matches it within the wire's quantisation (`DotNetVar.matches`) is neither rewound nor replayed, which takes the round trip out of the frame cost. **A skip hands the game's simulation the prediction back** by running `_net_state_applied` again on the restored properties: reading the snapshot ran that hook with the server's older state, and the manager restores only the properties. Without it the next tick simulated from a round trip ago (history #33). **Only ticks the predictor ran are remembered**: a host with its own client tick predicts through `DotNetManager.predict_tick(tick, input)`, never by calling `_net_simulate` itself, and the input is rounded to what the server decodes first (`DotNetInput.round_trip`, `predict_wire_input`). **A behaviour that would simulate nothing answers `_net_predicts()` false** (a dead player, whose body the server moves): the reconcile keeps the rewind and replays nothing, where every snapshot used to replay the whole lead to land in the same place (history #34).

## What a correction is, and how large one may be

- **A move from a state that was not a prediction is not a correction.** The reconcile after one whose entity was not predicting (`_net_predicts()` false: a dead player) moves it to wherever the server put it, often a spawn 40 m away. It is eased or snapped as any move is, but counted in `describe()["unpredicted_moves"]`, not in `corrections` or `worst_error`; counted, every respawn read as the worst misprediction of the run.
- **Blackouts.** While nothing arrives the client keeps predicting on real input and the server, starved, repeats the last one, so the correction when the link returns grew with the silence (13-27 m after 3 s). Two holds bound it, and both act through `DotNetInput._neutralise()` (stand still, hold fire, keep the aim). **The default calls `neutralise()` on every member that has one**, and `DotFpsCommand` (dot-player-controller) has one, so a game whose input is made of `DotFpsCommand` members needs no override; override (calling `super()`) only for plain fields such as a held-action bitmask: the server applies the last input neutralised once a peer has been silent for `starved_input_hold_sec` (0.25 s), and the client predicts on its input neutralised once no snapshot has come for `prediction_hold_sec` (0.5 s; `describe()["held_ticks"]`). The correction after a blackout of any length is then at most about top speed x (0.25 + 0.5) s, 5 m at 7 m/s, and a loss short of either hold is untouched.
- **The bounds the network rig holds a client to** (game-arena's `tools/netchaos_eval.py`): under 0.5 m worst on a clean link, and the blackout's bound above after one. Bumping a remote is the open source of clean-link corrections (below).

`netcode_demo`'s *respawn* and *starved input* checks.

## Corrections are eased on screen, every one of them

`DotNetPredictor.visual_offset(net_id)` is what a renderer adds to a predicted entity so a correction moves the simulation at once and the drawing over `reconcile_smooth_sec`. Two rules, both since 2026-10-10, when game-g2gfast became the first game to read it (its `headless_feel` measured a 30 cm correction jumping the eye in one frame; eased, 4.2 cm at most):

- **Every move a reconciliation makes is eased, not only the ones it counts.** `reconcile_position_epsilon` decides what is reported as a misprediction (`corrections`, `correction_rate()`); it is not a size below which a jump is invisible. A replay starts from the server's quantised state, so on a link that delivers everything the drawn player moved a few millimetres on every snapshot. Eased, the frame-to-frame speed of the eye at 144 Hz went from 0.92-1.16 of the true speed (5th-95th percentile) to 0.96-1.05.
- **A new correction is added to what is still easing, not put in its place.** Replacing it moved the drawing by whatever was left of the last one, and at 32 snapshots a second the last one has always not finished. An offset that adds up past `reconcile_snap_distance` is dropped, as a single correction that large always was.

`netcode_demo`'s *correction offsets* (armed with the old `_begin_correction`: a 4 mm correction drew no offset, and a second one replaced the first).

## What the server said

A snapshot carries an entity whenever it is relevant, with an empty body when nothing changed, and **absent means unchanged**. The client has to believe that:

- `read_state(reader, tick, rewind = true)` on a predicted entity puts every property the snapshot left out back to what the server last sent, **before** `_net_state_applied`, and `DotNetBehaviour.authoritative_values()` (the receive-side baseline overlaid with this snapshot) is what goes to `reconcile`.
- It must not be filled from `snapshot_values()` or the properties: on the owning client those hold its own prediction, because every game's `_net_simulate` copies each predicted tick into them. Read that way, "nothing new" became "the server agrees with you", and a client predicting a move the server refused (a server-only freeze, a wall only the server has) walked away from the server at twice its speed.
- Every game rewinds inside `_net_state_applied` by copying the properties into its simulation, which is why the fix restores the properties rather than only the values handed to `reconcile`.
- **A property with a `max_rate` is left alone unless it arrived**: its absence may mean the limit held it back.

The send side has to make "absent means unchanged" true under loss: see [replication.md](replication.md#owed-until-confirmed). Alternatives refused: always sending the owner's entity in full (pays a stationary player's full state every snapshot, and the client fix was still needed), and an explicit "unchanged" marker (it already exists: the entity's presence with an empty body).

## Open: a rate-limited predicted property

`authoritative_values()` leaves out a rate-limited property the snapshot did not carry, because the receiver cannot tell "held back" from "stood still". So a predicted `max_rate` property the server holds still is never rewound. No game sets `max_rate` on a predicted property. The fix, when one does, is on the send side: mark a property skipped for rate, so an unmarked absence means "unchanged since the acked baseline".

## Bumping a remote

A client predicts its own player at an input tick ahead of everything it has heard: the newest snapshot is the input lead plus up to one snapshot interval old when nothing is lost, and another interval older for each one lost. Anything it does not predict (another player, a bot) it knows only as of that snapshot, so **a bump predicted against where a remote was last heard is off by the remote's speed times that age**, and the server, which pushes the player out of where the remote really is, corrects it on the next snapshot.

`netcode_demo`'s *bumping a remote under loss* measures it. A player walking at 3 m/s into a bot that comes at it head on, pushes it back, turns at once and walks away; 60 Hz, 20 snapshots a second, an input lead of 6 ticks (100 ms), 20 s per run, snapshots lost at random with the same draws for every estimate; the gap between where the client first predicted its player at a tick and where the server had it, worst / mean in metres. Told the bot's true position, the same harness agrees within 7 mm, so every gap is the estimate's.

| bot, loss | last heard | ignore the remote | line through two positions | replicated velocity, 0.15 s cap |
| --- | --- | --- | --- | --- |
| 4 m/s, 0% | 0.60 / 0.268 | 1.05 / 0.384 | 0.85 / 0.141 | 0.70 / 0.027 |
| 4 m/s, 5% | 0.80 / 0.274 | 1.40 / 0.391 | 0.66 / 0.217 | 0.70 / 0.029 |
| 4 m/s, 15% | 1.00 / 0.285 | 1.75 / 0.418 | 1.01 / 0.220 | 1.00 / 0.052 |
| 8 m/s, 0% | 1.20 / 0.322 | 1.65 / 0.400 | 1.25 / 0.217 | 1.10 / 0.069 |
| 8 m/s, 5% | 1.60 / 0.326 | 2.20 / 0.407 | 0.89 / 0.287 | 1.40 / 0.077 |
| 8 m/s, 15% | 2.00 / 0.338 | 2.75 / 0.420 | 0.86 / 0.288 | 1.40 / 0.080 |

**The decision: extrapolate the remote along its replicated velocity, capped at about the input lead plus one snapshot interval** (`DotNetBehaviour.extrapolated_value(property, velocity_property, tick)` with `DotNetConfig.remote_extrapolation_sec`; API 8). The mean error falls by four to ten times at every speed and loss, and the worst at 15% loss is no worse. A game's collision asks it for the tick being simulated, replays included, so a replay agrees with itself. **Off by default** (`remote_extrapolation_sec = 0` returns the last heard value, and the suite checks that it does): it changes what every game's prediction collides with, and none has been measured with it on yet.

Why not the others:

- **Accept the error (last heard, today).** A steady 0.27-0.34 m off for the whole of every contact, rising to 2 m with the bot at 8 m/s and 15% loss. It is right only when the remote stands still.
- **Ignore remotes in prediction.** Worse everywhere: the replay walks the player through the remote for the whole lead and the server pushes it back out every snapshot, 1-2.75 m worst and a mean a quarter to a half larger than last heard. It is right only for contact so brief no snapshot sees it.
- **The interpolator's line through the last two positions** (`DotNetInterpolator.sample` at the input tick). The line lags every change of velocity by a snapshot interval, reads a lost snapshot as a slower remote, and past `max_extrapolation_sec` falls back to the last heard position, so its mean is three to eight times the velocity's. Its lower worst at 8 m/s under loss is that fallback, not accuracy. Sampling it also counts as a drawn extrapolation in the interpolator's statistics.
- **Uncapped, or a longer cap.** Every worst case in the table is the bot's instant turn while it is pushing: the extrapolation carries it on into the player for the whole age of the snapshot. Capped at 3, 6, 9 and 12 ticks, the 4 m/s, 15% row read 0.80 / 0.180, 0.80 / 0.099, 1.00 / 0.052, 1.05 / 0.046, and uncapped 1.39 / 0.046: past the lead plus an interval a longer cap buys nothing on the mean and loses on the worst. A shorter one is a blend of the two and keeps a share of last heard's mean. 0.15 s is that age here; at a different lead or snapshot rate it is `(lead + ticks_per_snapshot) / tick_rate`.
- **The server colliding against where the client saw the remote** (lag compensation for bumps). Refused here for a game where a bump moves the remote: the server would let a player shove a remote that has already left, and the remote's own client would be shoved by nothing it can see. Where a bump only stops the mover it is the right answer, below.

### Solid players that only stop the mover: collide where the mover's client drew them

When players are solid but never push each other (a sweep stops the mover; nobody is moved by being bumped), **the server moves each player against the others rewound to that player's view tick, and the client predicts against the others at the same view tick**: lag-compensated collision, the movement half of the rewind a shot already gets. The command carries its view lag (the tick minus the render tick, which is `received_tick() - delay_ticks()`), the server reads its position history at `tick - lag`, and the client asks `DotNetInterpolator.value_at(net_id, property, render_tick)` (API 14) for what it drew there. Both ends read the same command, so a replay asks the same question as the first prediction and the server agrees with it to the wire's quantisation. Bots and players without a view lag collide with the present.

Measured in game-arena's network rig with `mp_solidplayers` 1, three clients bumping on one link: against the interpolated render position (the old way) 12-36% of replays corrected on a 13 ms link, up to 0.52 m; against the last heard or extrapolated position 1-43%, up to 0.71 m, because the server's mover meets the remote somewhere neither estimate is; at the view tick 0-2%, 4 cm worst. The rig's numbers per profile are in game-arena's `docs/netcode.md`.

Both ends must reach the same answer at the edges too. The view lag a server collides with is clamped (a client could claim any lag and walk through players), and the client clamps the same way, with the limit sent to it; the clamp keeps the view tick inside the client's interpolation buffer. `value_at` returns null before its oldest sample, as the server's rewind does past its history, and with `cut` it returns null before a jump longer than `cut` (a teleport or respawn, where the server starts its history again): null means the present on both ends.

What it costs: a mover is stopped by where the remote was a view lag ago, so two players can end a tick overlapping where neither client drew it; the family's pass-out rule (a sweep ignores a hull it starts inside) lets them walk apart. A shooter-style engine that predicts against interpolated players accepts the bump corrections instead; with a hard hull and our 0.5 m clean-link bound that was not acceptable. A physics game whose capsules push (`DotPlayerBodyRules.apply_hull` with `move_and_slide` against a rigid body) does not qualify, and the extrapolation above remains its tool.

## Input batches

Each input packet carries the last few inputs, because every lost input packet is otherwise a tick the server runs on the previous command. `DotNetInput.write_batch` / `read_batch` encode them (count, the first tick in full, each later one as a varint step); `Buffer.recent(count, upto_tick)` gives a client its copies from the replay history; `Buffer.last_consumed_tick()` lets a server skip copies it has already simulated rather than count each as late. Duplicates are counted, not applied twice.

Wiring it is each game's bridge; every game's bridge and the game template batch their inputs, each sending the last five (`INPUT_COPIES`).

## Inputs are untrusted

`DotNetInput._sanitise()` runs on the server after decode and is not optional; see [security.md](security.md).

## Lag compensation

`DotNetHistory` records per tick (sized from `tick_rate`, not `snapshot_rate`: over-allocating costs memory, under-allocating costs hit registration) and rewinds the world to `client_view_tick` for a shot. `_net_record_history()` adds extra state (crouch flags, animation frames). An entity not in the tree is skipped when recording, rewinding and restoring: a sample at the origin would drag a hitbox through the middle of the map. Rewind is bounded by `max_rewind_sec` (1 s by default, so a 300-400 ms player is compensated); a larger claim is clamped.
