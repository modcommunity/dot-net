# dot-net

Multiplayer netcode for Godot 4: tick synchronisation, a bit-packed wire format,
declarative state replication, snapshot interpolation, client-side prediction with
server reconciliation, lag-compensated rewind, and pluggable interest management.

**The distributable is `addons/dot_net/`.** It requires [dot-core](../dot-core).
It does not depend on dot-server — a game can use dot-net over Godot's raw
multiplayer, over dot-core's transports, or over anything else that moves bytes.

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

## Three timelines, not one

The thing most often got wrong, and the reason `DotNetClock` is the first file to
read. At any instant a client is dealing with three tick numbers:

```
  render tick        server tick        input tick
  (behind)           (estimated)        (ahead)
  ────────────────────────●────────────────────────>
       ↑ interpolate           ↑ predict
```

- **Input runs ahead.** A command for tick N must be in the server's hands *before*
  it simulates N. Running level with the server means every command arrives late.
- **Render runs behind.** Interpolating needs both bracketing snapshots to have
  arrived.
- **Server tick is estimated**, never known.

Drift is corrected by **scaling tick duration**, not by jumping the tick number —
snapping teleports every predicted object and re-runs applied inputs. Past
`SNAP_THRESHOLD_TICKS` it does snap, because a suspended tab is not drift.

## The extension points

This is the part to preserve. A game should never need to fork dot-net.

| To change | Subclass / assign | Notes |
| --- | --- | --- |
| What replicates, and how precisely | `DotNetVar` declarations in `_register_net_vars()` | `Type.CUSTOM` + `.codec(w, r)` replicates *anything* |
| Simulation | `DotNetBehaviour._net_simulate` | Must be deterministic — see below |
| Player controls | `DotNetInput` subclass | `_sanitise()` is not optional |
| Message types | `DotNetMessageRegistry.register` | Ids from sorted names; schema hash catches mismatch |
| Who sees what | `DotNetInterest` subclass | The biggest lever on bandwidth *and* the only real anti-cheat |
| How entities are made | `DotNetSpawner.register_factory` | For pooling or procedural entities |
| Where bytes go | `DotNetManager.send_fn` | Transport-agnostic by construction |
| Reading a computed property | `_net_read_property` / `_net_write_property` | Replicate something you do not store |
| Extra rewind state | `_net_record_history()` on a behaviour | Crouch flags, animation frames |

`DotNetInterest` is worth calling out. `_is_relevant` is the whole interface for most
strategies; `_candidates` exists for spatial indexes that can answer in bulk;
`_score` feeds prioritisation when the budget bites. `examples/netcode_demo.gd`
defines `TagInterest` in a dozen lines to prove the claim.

## Determinism is a requirement, not an aspiration

`_net_simulate` runs on the server **and** on the owning client, for the same tick,
and reconciliation only converges if both get the same answer. Anything that differs
between machines breaks it:

- wall-clock time, or `randf()` without a shared seeded stream;
- another player's *unpredicted* state;
- a physics query against geometry only one side has loaded;
- iteration over an unordered collection whose order differs.

`DotNetPredictor.correction_rate()` is the number that tells you. Near zero means
the two agree. Consistently high means the simulation is not deterministic, and no
amount of smoothing will fix that — it will just hide it badly.

## Security decisions worth not undoing

- **Clients send inputs, never state.** A client that sent positions could send any
  position.
- **`DotNetInput._sanitise()` runs on the server after decode.** Quantisation bounds
  each field; it cannot bound the relationship between them. A move vector of length
  40 is representable and would make a player 40× faster.
- **`DotNetMessage.Direction` is enforced on receipt.** Without it any client can send
  the server a spawn or a "you have been kicked". Checked against the *transport's*
  view of the sender, never a peer id inside the payload.
- **Spawns name a prefab id, never a scene path.** A path would let a peer ask others
  to load any scene in the build.
- **Net ids are never reused.** A reused id means a snapshot in flight for a dead
  entity is applied to a live one.
- **`DotNetReader` is the untrusted side.** Reads past the end return zero and set a
  sticky `exhausted`; length prefixes are bounded *before* allocating — a varint of
  4 billion must not cause an allocation attempt.
- **`DotNetVar.Audience.OWNER`** keeps ammo and cooldowns off the wire to opponents.
- **Interest management is the anti-cheat that works.** Data never sent cannot be
  drawn on a wallhack.
- **Rewind is bounded** by `max_rewind_sec`; an excessive claim is clamped, not
  honoured.

## Bugs the demo caught (and what they mean for you)

Every one of these passed the parse check. Run `examples/netcode_demo.tscn`.

1. **`DotNodeRef.of_created(&"X", Node)` produced a garbage class name.** `str()` on a
   `GDScriptNativeClass` yields `<GDScriptNativeClass#-92233…>`, so the ref resolved to
   nothing. This was a **dot-core** bug that also silently broke dot-server's game
   root — `DotGameManager` could not load a scene. Fixed in `_class_name_of`.
2. **`HashingContext.update()` errors on empty input.** An empty message schema hashed
   to an engine error. Fixed in `DotHash.sha256_bytes`.
3. **Reader exhaustion was not sticky**, so a decoder ignoring `ok()` got a plausible
   value for the field *after* the overrun.
4. **History was sized from `snapshot_rate`** while the caller recorded per tick, so
   rewinds silently landed on the buffer boundary. Now sized from `tick_rate` —
   over-allocating costs memory, under-allocating costs hit registration.
5. **The priority accumulator starved a 100×-lower-priority entity for 100 ticks.**
   Eventually-sent is not good enough at 20 Hz. Added a superlinear starvation boost.
6. **A suspending test section was called without `await`, and nothing said so.**
   `_test_interpolation()` suspends on `get_tree().process_frame`. Called without
   `await`, it ran to that suspension and stopped; `_run()` carried on to
   `quit()`. Its last assertion — "adaptive buffer responds" — therefore never ran
   once, and the count printed at the end could not reveal it, because that count
   is of checks that *ran*. The suspended coroutine's locals were also exactly the
   seven objects Godot reported leaked at exit, which three audits had chased as a
   reference cycle in `DotNetInterpolator`. There is no cycle. **A test count is
   not coverage.** `_run()` now compares suspending sections entered against
   sections completed, so a dropped section is a failed check.

7. **Reconciliation replayed without the inputs.** `DotNetPredictor.reconcile`
   looked up each unacked tick's input and then never applied it, so the whole
   replay ran on whatever input the behaviour was still holding — the newest one.
   `DotNetManager.server_tick` applies the input and *then* simulates; the replay
   has to do the same or the two do not agree, which is the one property this
   class exists to provide. It was invisible because it only shows up when the
   input changes inside the unacked window, and the integration run fed a constant
   input for all sixty ticks: replaying with the wrong input gave the right answer.
   `_test_prediction` zig-zags the input instead, and reverting the fix leaves the
   client **1.18 m** from the server after ten replayed ticks — a correction of
   that size, arriving with every snapshot, is exactly the rubber-banding
   `correction_rate()` is meant to warn about.

8. **Respawning a pooled entity put it in the wrong parent and said it worked.**
   `DotNetSpawner._instantiate` called `_container.add_child(node)`
   unconditionally. A factory handing back a pooled instance — which is the
   documented reason `register_factory` and `free_on_despawn` exist — passes a
   node that already has a parent, and a real pool keeps its idle instances
   under its own node rather than in the live container. `add_child` does not
   fail that call: it pushes an engine error and returns, so the entity is
   registered, live, and still under the pool, with `_apply_transform`
   subsequently setting a global transform through the wrong parent. The
   returned `DotResult` is `ok`. It now moves the node if it needs moving and
   leaves it alone if it is already in the container.

   **The first version of the test could not have caught it.** It pooled the node
   without re-parenting it, so the reused node was already in the container and
   every assertion after the engine error still passed — the same shape as #7,
   found the same way, in a test written the same afternoon. A pool that parks
   its nodes in the live container is not a pool.

9. **A prefab declared in the inspector failed silently.** `_ready()` called
   `register_prefab` for each entry of the exported `prefabs` dictionary and
   discarded the result, so the contract that a prefab with no `DotNetIdentity`
   is a *startup* error held only for games registering in code. From the
   inspector the id was simply absent and surfaced much later, on the first
   spawn, as "unknown prefab". Both failure modes now log an error naming the id.
   **The lesson is about the test, not the code: a constant input is not an
   input.**

10. **The three diagnostics were each wrong in a way that pointed elsewhere.**
    Found by writing `diagnostics_demo`, which is the first thing to name
    `DotNetStats` or `DotNetSnapshot` — `netcode_demo` drives both, but only
    along the healthy path, so every branch describing an *unhealthy* one was
    reached by nothing.

    `loss_rate()` divided snapshot losses by `packets_received`, which counts
    packets of every kind. A client sends inputs every tick and receives
    snapshots more slowly, so its reported loss fell as unrelated traffic rose;
    a server, which receives no snapshots at all, reported 0.0 no matter what
    it had recorded. It now divides by `snapshots_received`.

    `note_snapshot` counted a reordered packet twice over: once as lost when
    the gap it left was measured, and again as out-of-order when it arrived. A
    path that reorders therefore reported steady loss while losing nothing —
    a diagnosis pointing at the wrong subsystem, which is the one thing this
    class must not do. A tick older than the newest now un-counts the loss it
    was blamed for; a repeat of the newest is a duplicate and does not.

    The rolling rates were only ever closed from `note_sent`/`note_received`,
    so a connection that went quiet kept reporting the throughput it had when
    it stopped — stale at exactly the moment someone reads it to find out why.
    `DotNetManager._physics_process` now calls `stats.roll()` every frame,
    before `step()` and regardless of traffic.

12. **Dirty tracking was one dictionary shared by every peer.** Snapshots are built
    one peer at a time, and `write_state` marked a property clean on the behaviour
    itself — so the first peer served received the change and **every other peer
    received nothing**. A two-client game replicated to one of them; a third client
    coming into range of an entity saw only whatever changed after it arrived; and
    a `max_rate` limit set for one peer silenced the property for all of them.

    It survived because **the integration run has exactly one peer**, which is the
    only shape in which the shared dictionary and a per-peer one behave the same.
    Same lesson as #7 and #8, and the same lesson the family CLAUDE.md draws from
    dot-server: *a code path only one deployment shape reaches is a code path
    nothing has run.* `_test_acked_baselines` uses two peers for this reason.

13. **A lost snapshot stranded every property it carried, permanently.** Snapshots
    are unreliable and carry only what changed, and the baseline was updated at
    send time — so a property written into a dropped packet was never sent again
    until it happened to change. Invisible for a position that moves every tick,
    which is all the integration run replicates; indefinite divergence for health,
    a team, a weapon or a name. Fixed by the acked baselines above.

14. **`DotNetSnapshot.net_ids()` returned insertion order.** It is the public
    way to iterate a snapshot's entities, and "iteration over an unordered
    collection whose order differs" is on the determinism list above. Two peers
    that inserted the same ids in a different order walked them in a different
    order. Sorted now.

## The render timeline has to move between packets

`DotNetClock.server_tick()` is what `render_tick()` is derived from, and therefore what
every interpolated position is sampled at. It used to be *only* set — by
`sync_from_server`, when a snapshot arrived — and never advanced.

So the rendered tick was a step function of arrivals: the interpolator produced a new
value on the frames a packet happened to land on and the same value on every frame in
between. At 20 Hz snapshots and 144 Hz rendering, six frames in seven drew the previous
one — which is exactly the stepping interpolation exists to remove, arrived at by the one
route the interpolator itself cannot see.

`advance()` now walks the estimate forward with the local clock, and `sync_from_server`
re-anchors it absolutely. A stall that drops ticks drops them from both timelines, or the
input lead would appear to have grown by the length of the stall and the next sample would
correct it as drift.

It hid because `_test_interpolation` called `DotNetInterpolator.sample()` directly with
hand-picked ticks — the clock was never in the path. It was found from `dot-2d-hungry`,
which asked why a remote monster it was interpolating had not moved.

## An interpolated value that nothing is told about is a value nobody uses

`DotNetInterpolator.apply` writes the smoothed value of every property declared
`interpolated()` and then calls `DotNetBehaviour._net_interpolated(server_tick)`.

That call is the whole point. A game copies replicated state into a node or a simulation
from a hook, and the obvious hook is `_net_state_applied` — which fires when a *snapshot*
arrives, a few times a second. A game with only that hook moves every remote entity in
20 Hz steps while the interpolated value sits in the property nobody read, and the
symptom is an interpolator that appears not to work. It was written that way here, and in
game-arena, until `dot-2d-hungry` looked for where the interpolated position went.

`_net_interpolated` deliberately carries none of `_net_state_applied`'s bookkeeping. Its
tick is a *render* tick, behind the server's, and recording it as the newest state applied
would make reconciliation rewind to a tick the server never sent. A predicted entity is
never notified at all, for the reason `apply` already returns early: writing interpolated
state over a prediction fights the predictor every frame.

## The interest cache is a cache of one instant

`DotNetInterest.relevant_for` caches its answer per peer for
`evaluation_interval_sec`. That cache holds **which entities were relevant at one
instant**, so an entity spawned since is in nobody's cached set — and two of the
guarantees `_evaluate` makes are not heuristics that may wait:

- an observer always receives what it **owns**;
- anything **`always_relevant`** always goes.

Both are now pinned into a cached answer before it is returned, because the window is
not small. In a game where players respawn, split or fire projectiles it is a quarter
of a second of an entity that exists only by prediction. And on a host that ticks
faster than the wall clock — every headless test, every fast-forwarded replay — the
age never reaches the interval at all and the entity is **never sent once**.

What makes it hard to see: the position looks right the whole time, because the owning
client is predicting it. Only what cannot be predicted goes missing — mass, health,
ammunition, a team change — and it goes missing silently. It was found in
`dot-2d-hungry`, where a monster respawned by the server kept its client-side mass
frozen at the value the spawn message carried while the server's climbed, with the two
positions agreeing to a hundredth of a unit.

The pin returns a new dictionary rather than mutating the cached one: an entry written
into the cache would survive the expiry that is supposed to re-evaluate it.

## Wire format notes

- Bits are written LSB-first within each byte, bytes in order. **This is the wire
  format**; changing it is a protocol break.
- `write_bytes`/`write_string` byte-align first, so bulk data copies in one call
  rather than shifting per bit. Alignment costs ≤7 bits.
- Quaternions use smallest-three: 2 bits for the dropped index plus three components
  in ±1/√2. 29 bits at 9-bit components, against 128 for four raw floats, accurate to
  well under a degree.
- Positions **clamp** at the world bounds; angles **wrap**. Clamping a position is
  visibly wrong at the edge; wrapping one teleports across the map.
- `read_quaternion` guards `sqrt(max(0, …))` — quantisation can push the sum of
  squares past 1, and `sqrt` of a small negative is NaN that propagates into every
  derived transform.

## Batching, budget, interest — the three-stage funnel

```
all entities
  → interest.relevant_for()     what this client may know about
  → interest.prioritise()       cap at max_entities_per_snapshot
  → budget.accumulate()         order by accumulated priority
  → write until the byte budget runs out
```

An entity dropped by the budget stays dirty — `write_state` updates the record, not
`collect_dirty` — so it goes out next tick rather than being silently skipped.

## Acked baselines: what the server believes each client has

`DotNetBehaviour.PeerView`, one per peer per behaviour. Three fields, because a
snapshot goes out unreliably and being *sent* is not being *received*:

- `acked` — confirmed by the peer.
- `pending` — sent since, unconfirmed, oldest first.
- `believed` — `acked` with `pending` laid over it. Dirty tracking compares against
  this, so a property is sent once rather than every tick while its ack is in flight.

When a snapshot is confirmed lost its entry leaves `pending` without reaching
`acked`, `believed` is rebuilt without it, and the properties it carried go dirty
again. That is the whole loss-recovery mechanism: no retransmit queue, no timers,
and nothing extra on the wire — the next snapshot was going out anyway.

**Acks are optional and the host carries them.** dot-net owns no client-to-server
channel (it does not carry inputs either), so `encode_ack()` hands you four bytes to
put inside the input packet you already send, and `receive_ack_payload()` takes them
on the server. Wire it and a lost property is re-sent; do not, and an unconfirmed
send is assumed delivered once it ages out of `ack_window_snapshots` — exactly what
this addon did before, so nothing regresses by leaving it alone.

**A client acks only on the fully-applied path.** `receive_snapshot` abandons the
rest of a packet when it meets an entity it has not been told to spawn — it cannot
skip a variable-length body without the declarations — and acking that would strand
every entity after it at a value the peer never received.

## The GDScript traps that apply here

Same as the rest of the family, plus one specific to this repo:

- **Fan-out**: bare statement calls plus a *member counter*, not a signal count. See
  the root CLAUDE.md.
- **`var x := something_returning_Variant()`** is a parse error under the project's
  warning settings. Write `var x: Variant = …`. Three of these blocked the demo from
  loading, and a script that fails to load makes a headless run hang rather than
  error visibly.

## Validating changes

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done

# 186 checks: wire round-trips, quantisation accuracy, message direction and
# schema mismatch, batching and fragmentation, clock convergence, replication and
# dirty tracking, interest strategies agreeing, budget fairness, interpolation and
# extrapolation bounds, rewind/restore, prediction replay against a server
# simulating the same changing input, and a server+client integration run with
# 20% simulated packet loss.
godot --headless --path . res://examples/netcode_demo.tscn

# 67 checks over DotNetStats and DotNetSnapshot on their own: inferred loss,
# reordering vs. duplication, rates on a connection that stopped, rtt
# percentiles and the bounded sample window, delta/apply round-trips, and
# baseline isolation.
godot --headless --path . res://examples/diagnostics_demo.tscn
```

The integration test runs both managers in one process over a lossy loopback, which
is why there are no autoloads and why `DotNetManager.service_scope` exists.

## File map

```
addons/dot_net/
  dot_net_manager.gd             Tick loop, snapshot send/receive, message routing.
  core/
    dot_net_clock.gd             Three timelines. Read this first.
    dot_net_config.gd            All tuning. describe_budget() shows what it costs.
  wire/
    dot_net_writer.gd            Bit packing + quantisation.
    dot_net_reader.gd            The untrusted side.
    dot_net_message.gd           Base message. Delivery + Direction.
    dot_net_message_registry.gd  Ids, schema hash, direction enforcement, dispatch.
    dot_net_packet.gd            Batching, fragmentation, reassembly.
  replication/
    dot_net_var.gd               The declaration. Type.CUSTOM is the escape hatch.
    dot_net_identity.gd          netId, ownership, authority model.
    dot_net_behaviour.gd         What a game subclasses most.
    dot_net_registry.gd          netId table. Ids are never reused.
    dot_net_spawner.gd           Prefab allow-list + factories.
  snapshot/
    dot_net_snapshot.gd          A tick's state; delta to/from a baseline.
    dot_net_interpolator.gd      Render-in-the-past, adaptive buffer.
  prediction/
    dot_net_input.gd             Input base + the jitter/replay buffer.
    dot_net_predictor.gd         Rewind, replay, ease the correction.
  lagcomp/
    dot_net_history.gd           Rewind the world to what the shooter saw.
  interest/
    dot_net_interest.gd          Base. Subclass this.
    dot_net_interest_builtin.gd  All — correct for co-op, wrong for competitive.
    dot_net_interest_distance.gd Radius, with per-tag overrides.
    dot_net_interest_grid.gd     Spatial hash for large worlds.
  bandwidth/
    dot_net_budget.gd            Per-peer budget + starvation-bounded accumulator.
  stats/
    dot_net_stats.gd             The counters that turn "feels laggy" into a cause.
                                 roll() must be called each frame; see below.
```

## Things deliberately not here

- **Rollback netcode** (GGPO-style, for fighting games). A different model —
  everyone predicts everyone, and rollback is per-frame rather than per-correction.
  The input buffer and determinism requirements are already here; the rollback loop
  is not.
- **Reliable delivery over an unreliable transport.** `Delivery.RELIABLE` maps to the
  transport's own reliability. Implementing acks and retransmits here would duplicate
  what ENet and WebSocket already do.
- **Whole-snapshot deltas.** `DotNetSnapshot.delta_to` and `apply_delta` exist and
  are tested, and the manager deliberately does not use them. Acked baselines are
  now per *peer* and per *behaviour* (see below), which is what interest management
  forces: no two peers are sent the same set of entities, so a single world-wide
  baseline snapshot is not a baseline for anybody. The manager used to build and
  store one every snapshot tick against the day this landed; nothing ever read it,
  and it is gone.
- **Bitfield acknowledgements.** A client acks one tick, the newest it applied in
  full. Acking the last 32 in a bitmask would let the server confirm a snapshot that
  arrived *after* a newer one, which single-tick acks write off as lost and re-send.
  That costs a little bandwidth on a reordering path and nothing on a clean one.
- **Physics-engine determinism.** Godot's physics is not deterministic across
  platforms. Games needing exact reconciliation should simulate movement themselves —
  the demo's `Movement` does.
- **Matchmaking, lobbies, NAT punchthrough, voice.** Session-level concerns above
  this layer.
