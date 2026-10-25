# Replication

## The funnel

```
all entities
  → interest.relevant_for()     what this client may know about
  → interest.thin_into()        far entities only every far_every-th snapshot (off by default)
  → interest.prioritise()       cap at max_entities_per_snapshot
  → budget.accumulate()         order by accumulated priority
  → write until the byte budget runs out
```

An entity dropped by the budget stays dirty (`write_state` updates the record, not `collect_dirty`), so it goes out next tick rather than being skipped. The priority accumulator has a superlinear starvation boost: a linear one starved a 100x-lower-priority entity for 100 ticks, and eventually-sent is not good enough at 20 Hz.

## Acked baselines

`DotNetBehaviour.PeerView`, one per peer per behaviour. Three fields, because a snapshot goes out unreliably and being sent is not being received:

- `acked`: confirmed by the peer.
- `pending`: sent since, unconfirmed, oldest first.
- `believed`: `acked` with `pending` laid over it. Dirty tracking compares against this, so a property is sent once rather than every tick while its ack is in flight.

**Dirty tracking is per peer.** It was once one dictionary on the behaviour, so the first peer served got each change and every other peer got nothing; it survived because the integration run had one peer. `_test_acked_baselines` uses two.

When a snapshot is confirmed lost its entry leaves `pending` without reaching `acked`, `believed` is rebuilt without it, and the properties it carried go dirty again. That is the whole loss-recovery mechanism: no retransmit queue, no timers, nothing extra on the wire. Without it a property written into a dropped packet was never sent again until it changed: invisible for a position, indefinite divergence for health, a team or a name.

**Acks are optional and the host carries them.** dot-net owns no client-to-server channel (it does not carry inputs either), so `encode_ack()` hands you four bytes to put inside the input packet you already send, and `receive_ack_payload()` takes them on the server. Without acks an unconfirmed send is assumed delivered once it ages out of `ack_window_snapshots`, which is a bounded blind re-send.

**A client acks only on the fully-applied path.** `receive_snapshot` abandons the rest of a packet when it meets an entity it has not been told to spawn (it cannot skip a variable-length body without the declarations), and acking that would strand every entity after it. A client acks one tick, the newest applied in full; a late snapshot is ignored by tick as superseded.

## Owed until confirmed

Two cases keep a property in every snapshot until the peer confirms its current value, rather than sending once and trusting it:

- **The entity a peer owns and predicts** (`owner_peer_id == peer` and `Authority.SHARED`): `collect_dirty(..., until_acked = true)`. Its client reads a property's absence as "unchanged" and rewinds to the value last received ([prediction.md](prediction.md#what-the-server-said)), so a stale value there is a correction toward the wrong place, every snapshot for a round trip. A property that changes every snapshot costs nothing extra; an entity held still and confirmed costs its share of a run of ids ([wire.md](wire.md#unchanged-entities)), or its 36-bit header to a client that does not read the list.
- **A property lost once** (`PeerView.relost`, set when an unconfirmed send is dropped as lost, cleared on confirmation). Re-sending once, in the very next snapshot, never converged on a link that held back every other snapshot. A clean link pays nothing.

## The interest cache is a cache of one instant

`DotNetInterest.relevant_for` caches its answer per peer for `evaluation_interval_sec`, so an entity spawned since is in nobody's cached set. Two guarantees are not heuristics that may wait, and are pinned into a cached answer before it is returned:

- an observer always receives what it **owns**;
- anything **`always_relevant`** always goes.

The window is not small: a quarter of a second of an entity that exists only by prediction, and on a host that ticks faster than the wall clock (every headless test, every fast-forwarded replay) the age never reaches the interval and the entity is never sent. It is hard to see because the owner's position looks right (it is predicting it); only what cannot be predicted (mass, health, a team change) goes silently missing. The pin returns a new dictionary: an entry written into the cache would survive the expiry meant to re-evaluate it.

Interest management is also the anti-cheat that works: data never sent cannot be drawn on a wallhack. The built-in "all" strategy is correct for co-op and wrong for competitive.

## Thinning far entities

`DotNetInterest.far_every` (1, off) and `far_distance` (or `far_distance_by_tag`) send an entity farther than that from the observer in one snapshot of `far_every`, staggered by net id and peer so each snapshot carries an even share. The observer's own entities are never thinned, always-relevant ones are (a teammate across the map is still updated, less often). It cuts both the build and the budget's work, on the inline and the pooled path alike (netcode_demo's `thin` scenario proves them byte for byte the same). A skipped entity is the same as one the budget dropped: it stays dirty against its acked baseline and goes out on its turn, so keep `far_every` near `DotNetConfig.interpolation_buffer` or the far mirrors hold between samples. A game exposes the two as server settings (game-zombie-zone: `zz_net_far_every`, `zz_net_far_distance`); both are read per snapshot, so they change live.

## What a snapshot costs

Measured with 32 players at 128 ticks (game-g2gfast's `tools/load_probe`), nearly all of a snapshot tick was per-entity bookkeeping done once **per peer**. What was done, none of it changing a byte on the wire:

- **`_rebuild_believed` only when an entry was dropped unconfirmed.** Promotion of resolved entries cannot change `believed` (it is `acked` with pending laid over in tick order, and the resolved entries are the oldest), so `sync_peer_acks` and `trim_pending` rebuild only in the loss case.
- **Each property is read once a snapshot.** The manager opens `begin_snapshot_reads()` on every behaviour before its peer loop and `end_snapshot_reads()` after; inside, `_read_for_send` reads once. Outside a snapshot it reads live, so nothing else sees a stale value.
- **`estimated_bits(peer)`** depends only on whether the peer is the owner, so it is two cached numbers.
- **Encoded once per distinct set of properties** (`write_state` / `_encode` / `_signature`). For a moving player that set is the same for every peer but its owner. The bits are laid into each peer's packet with `DotNetWriter.write_bit_run`; the per-peer record is still per peer, and the recorded values are one dictionary shared by every peer's pending entry, which nothing writes to. A set out of declaration order is encoded fresh, since a bitmask cannot tell two orders apart.
- **A set with anything byte-aligned is encoded per bit offset and copied, never shifted** (`DotNetVar.may_align`: strings, bytes, custom codecs). A string aligns before its bytes, so its padding depends on the bit it starts at; shifting a bit-0 encoding into place sent garbage strings. Everything else is one copy shifted into place (`write_shifted_run`).
- **`write_state`'s per-peer half is one `merge` into `believed`**, a send time only for a rate-limited property (nothing else reads one), and whether a set may byte-align is its signature against a mask built at `_bind`.
- **`collect_dirty` is written out** rather than calling `visible_to`, `_read_for_send` and `_is_dirty` per property, and `DotNetVar.differs` is inlined for a declaration with no epsilon; at 32 players the calls cost more than the comparisons. Same rules, same order.
- **`trim_pending` returns on its oldest entry** when that is inside the window, and otherwise pops the aged-out prefix off the front rather than rebuilding the list. A host without acks ages one entry out per snapshot, and the rebuild was 2.9 of 8.8 ms at 32 players.
- **Dirty sets are shared between peers that are in step** (`DotNetConfig.share_dirty_sets`, on by default). A peer whose `believed` is exactly the reads of snapshot K (it was sent everything dirty at K, or nothing was) is owed exactly what changed between K and now, so that answer is computed once per (K, is-owner) and handed to every such peer; the identical array then hits the encode cache without building a signature. The last 17 snapshots' reads are kept for it. It stands aside (the per-peer walk runs) for a behaviour with any epsilon or `at_most` declaration, a forced send, `until_acked`, a peer with lost values to resend, and after `believed` is rebuilt. The netcode demo checks byte-for-byte equality against the walk over 400 snapshots of loss, starvation and late acks.
- **A shifted run is shifted once per bit offset, not once per peer** (`_shifted`): the eight possible shifts of an encoding are built on first use and laid in with `write_bit_run`, a byte copy, where `write_shifted_run` was a GDScript loop per byte per peer.
- **One call per behaviour per peer to resolve and collect** (`collect_for_peer`: `sync_peer_acks`, `trim_pending` and `collect_dirty` with the view looked up once), the entity's id and behaviour count as one 30-bit write (bits go low first, so the same bits), and `note_sent` inlined.
- **`DotNetBudget.accumulate` orders with a native integer sort** (`_by_accumulator`), not `sort_custom`: a non-negative double's bits order as the double does, with the candidate's index in the low bits. The comparator was 0.7 ms of a 128-tick tick at 32 players.
- **One pending entry per encoding, shared by every peer it is laid into.** The encode cache keeps the entry (`_pending_entry`) next to the bytes, so a peer in step costs a lookup and an append, not a dictionary per peer. Nothing writes to a pending entry after it is made.
- **Lingering entities are found through a per-snapshot index** (`DotNetInterest.index_snapshot`), not a linear search of the identity list per peer, and the index is cleared after the loop.
- **Scores are computed once per peer** (`scores_for`) and handed to both `prioritise` and `ranked`; they were computed twice.
- **The size estimate is made after the compact and unchanged checks**, which skip most entities before it is needed, and positions are frozen on the inline path too, so interest reads a copy rather than a node.
- **`DotNetConfig.stagger_snapshots`** (off by default): peer `p` gets its snapshot on ticks where `p % ticks_per_snapshot() == tick % ticks_per_snapshot()`, so no one tick builds all of them. Every peer still hears at the same rate. Lag-compensation history is recorded every tick when it is on.

On the wire, an entity with nothing dirty for this peer is listed by id in the part's tail rather than written with an empty body, for a client that reads the list ([wire.md](wire.md#unchanged-entities)); it costs the budget nothing and resets its accumulator as a sent one does.

What is left after that is the game half of the tick, not the network.

## Snapshots on worker threads

`DotNetConfig.snapshot_workers` (default 0, off; -1 is the processor count less one, at most eight; environment `DOT_NET_SNAPSHOT_WORKERS`, command line `--net-snapshot-workers`) builds each peer's snapshot on dot-core's `DotParallel`, a fork/join on the engine's worker pool that returns inside the tick. Most of a big server's snapshot time is per peer and independent, so it divides by the workers; everything else in the tick stays on the main thread.

How it stays the same answer:

- **With 0 workers nothing changed.** The inline loop is the original `_send_to_peer` with the original interest, budget and behaviour calls; the pooled path is a separate copy (`_build_chunk`, `_build_peer`, `_apply_build`) that only runs when workers are on. The first version routed the inline path through the threaded design (a job and a result object per peer, copies of the interest and budget answers, an `EncodeCache` indirection and copy-on-write checks in every behaviour call) and cost 14% of snapshot time with threads off; one extra GDScript call per behaviour per peer is measurable at eight thousand a snapshot. A change to `_send_to_peer` is made to `_build_peer` too, and the byte comparison below fails until it is.
- **Everything a worker reads is frozen first.** `begin_snapshot_reads(now_ms, true)` reads every property and both bit estimates before the fork, and each identity's position is copied (`freeze_position`), because a worker may not touch a node. The clock is read once per snapshot (`context["now_ms"]`), so interest linger and `max_rate` see the same instant on every thread.
- **A task writes only its own peers' records.** One task per worker owns a contiguous run of peers (the pool gives a task an item index, never a worker index) and its own `EncodeCache`s. Every `PeerView` and budget record the build could touch is made on the main thread before the fork (`view_for`, `budget.begin_tick`), so a worker only reads the shared tables and writes into records no other task holds: views through `collect_for_view` / `write_for_view`, accumulators through `accumulate_record`, interest through `relevance` and `ranked`, which do not write the shared cache. An earlier version built a copy-on-write shadow of every view and installed it after the join: 15 ms of apply per snapshot at 64 players, for a purity only the verify mode used.
- **Shared state and sends stay on the main thread, in peer order**: interest's cache and cap notes (`commit_relevance`, `note_cap`), the counters, the oversize warning, `send_fn`, the budget's packet note and stats.
- **Opt-in per interest strategy.** `DotNetInterest.is_thread_safe()` is false unless a strategy says otherwise; the built-in All, Distance and Grid say true for exactly their own class, so a subclass that overrides `_is_relevant` is inline until it opts in. A custom `DotNetVar` codec runs on a worker too: it must not touch nodes.
- **Off on the web**, threads or not (`DotParallel.available()`), and wherever it is off the reason is logged once and shown in `describe_lines()`; when it is on, one INFO line says so (`snapshots are built on worker threads`), which is how a suite forced on shows that it pooled.

`netcode_demo`'s `[snapshot threads]` section runs a scripted ten-peer game (distance interest that changes with motion, an owner per peer, lossy acks, a starving budget, parts at a small MTU, half the peers on the old wire format) inline, on four workers and on two with `DotParallel.verify` on, and compares every payload and every `PeerView` and budget after each tick byte for byte; it checks that a pooled build which ignores its peer's acks is caught. A build writes in place, so it is not a pure task and `DotParallel.verify` never re-runs it (the section checks that too): the comparison with the inline path is the proof instead. A view made before the fork that nothing was ever written into reads the same as no view (`PeerView.is_fresh`): the pooled path makes one for every entity and peer, the inline path only those it collects into.

**What it costs: threads off is back to what it was; threads on is not worth turning on yet.** g2gfast `tools/load_probe surf_mesa 32 64` with `LOAD_ACKS=1`, dev02 (6 cores, shared with two other suites), snapshot ms per tick, three runs each:

| | 32 players | 64 players |
| --- | --- | --- |
| before threads existed | 3.22 / 3.30 / 3.27 | 11.81 / 12.00 / 12.02 |
| first version, 0 workers | 3.71 | 13.44 |
| first version, 4 workers | 5.42 | 15.20 |
| now, 0 workers | 3.27 / 3.23 / 3.36 | 12.01 / 12.03 / 12.27 |
| now, 2 workers | 3.48 / 3.18 / 5.36 | 13.95 / 10.64 / 20.07 |
| now, 4 workers | 3.22 / 4.26 / 5.02 | 9.92 / 13.63 / 15.84 |

The threaded rows swing with whatever else the box is running: the probe's single-threaded game time, which this work does not touch, went from its usual 5.8 / 11.8 ms up to 10.2 / 23.6 in the slowest runs. The one 4-worker run with game time at its usual value (6.3 / 12.1) was 3.22 / 9.92: no gain at 32 players and 17% at 64. Scaled by game time, every 4-worker run lands near 2.95 / 8.6 and every 2-worker run near 3.05 / 10.8. So on an idle box four workers might take a sixth to a quarter off snapshot time at 64 players and nothing at 32; on a box that is also running other servers, which is how a host runs, they are as likely to cost as to save. Instrumented per snapshot, with the box at about 1.8 times its usual game time: fork to join 26 ms at 32 players and 92 at 64 on one worker, 13.3 and 48 on four (twice as fast, not four times, with two other suites on six cores); the main thread's freeze 1.6 and 4.6 ms and apply 0.8 and 3.0 ms. One worker costs about a tenth more than inline; what four buy depends on how many cores are actually free. Until a probe on an otherwise idle machine shows a steady gain, leave it off; it is for testing the pooled path, not for capacity.

Zombie Zone `tools/server_probe.sh` rows at 64 Hz with the horde at its cap, after the two-phase pooled views (562c178), dev02 shared with other jobs, one run each, ms per tick averaged over all ticks (snapshots go out every other tick), `net_snapshot` mean / p95 and whole-tick mean, peak RSS: 32 players off 29.0 / 63.1 / 43.5 ms, 421 MB; 2 workers 25.9 / 64.5 / 41.6, 484 MB; 4 workers 24.0 / 59.6 / 39.8, 488 MB. 100 players off 184.6 / 410.2 / 234.9 ms, 1020 MB; 2 workers 124.5 / 282.2 / 172.4, 1217 MB; 4 workers 117.7 / 274.8 / 168.6, 1228 MB. So 4 workers cut the snapshot time by about 17% at 32 and 36% at 100 (2 workers: 11% and 33%) for 16% to 20% more memory; a fresh `PeerView` is about 2 KB. Both are far over the 15.6 ms budget at 100, so interest and cost per entity still matter more than threads. Off stays the default.

`tools/snapshot_bench.tscn` times snapshots alone, with no game: `-- --peers=100 --npcs=213 --workers=N [--relevance=off] [--hash]`. `--hash` prints an MD5 of every payload with linger at 0, so the inline and pooled paths and any refactor can be compared byte for byte. At 100 peers and 213 entities with relevance on, the shared entries, linger index and single scoring took the inline path from 149 to about 130 ms a snapshot, 2 workers to 107 and 4 to about 100 (relevance off: 285 to 263 inline), payload hashes unchanged.

**Why four workers buy so little: the debug engine serialises object access across threads.** A probe calling `get_instance_id()` on one shared Node from a group task took 25 ms on one task and 238 on four; an integer loop in a RefCounted method went from 11 to 30 ms, a dictionary read from 53 to 68. Any GDScript touching a shared Object (every `PeerView`, behaviour and array is one) pays a process-wide lock in a debug build, so the pooled path scales sub-linearly by construction. A release export template is the next measurement; until it shows linear scaling, the snapshot cost at 100 players is bounded by GDScript bookkeeping at about 4 µs per (peer, entity) pair, and 15 ms a tick is not reachable without moving the per-peer loop into native code.

## Identities

- **Net ids are never reused.** A reused id means a snapshot in flight for a dead entity is applied to a live one.
- **A freed identity is dropped, not typed.** The registry holds identities it does not own, and a game change frees the old world before its manager stops, so `unregister`/`clear()` take a freed entry out of every table without assigning it to a typed local (which is a script error per entity).
- **`local_peer_id` has a setter that forwards to the registry.** The registry decides `is_owner` (so `is_predicted`) at registration from its own copy; a client that learned its id after `setup()` registered its own player as somebody else's and predicted nothing. Two copies of one value is the bug.
- **Spawns name a prefab id**, never a scene path. A prefab with no `DotNetIdentity` is a startup error whether registered in code or in the exported `prefabs` dictionary (both log naming the id).
- **A pooled entity is moved into the container only if it needs moving.** `add_child` on a node that already has a parent pushes an engine error and returns, leaving a registered, live entity under the pool.

## Deliberately not here

- **Rollback netcode** (everyone predicts everyone, rollback per frame). The input buffer and determinism requirements are here; the rollback loop is not.
- **Reliable delivery over an unreliable transport.** `Delivery.RELIABLE` maps to the transport's own reliability; acks and retransmits here would duplicate ENet and WebSocket.
- **Whole-snapshot deltas.** `DotNetSnapshot.delta_to` / `apply_delta` exist and are tested; the manager does not use them. Interest management means no two peers get the same set of entities, so a world-wide baseline is a baseline for nobody; baselines are per peer and per behaviour.
- **Bitfield acknowledgements.** Acking the last 32 would let the server confirm a snapshot that arrived after a newer one, which single-tick acks write off as lost and re-send: a little bandwidth on a reordering path, nothing on a clean one.
- **Physics-engine determinism.** See [prediction.md](prediction.md#determinism-is-a-requirement-not-an-aspiration).
- **Matchmaking, lobbies, NAT punchthrough, voice.** Session-level concerns above this layer.
