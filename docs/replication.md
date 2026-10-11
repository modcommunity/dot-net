# Replication

## The funnel

```
all entities
  → interest.relevant_for()     what this client may know about
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
- **`DotNetConfig.stagger_snapshots`** (off by default): peer `p` gets its snapshot on ticks where `p % ticks_per_snapshot() == tick % ticks_per_snapshot()`, so no one tick builds all of them. Every peer still hears at the same rate. Lag-compensation history is recorded every tick when it is on.

On the wire, an entity with nothing dirty for this peer is listed by id in the part's tail rather than written with an empty body, for a client that reads the list ([wire.md](wire.md#unchanged-entities)); it costs the budget nothing and resets its accumulator as a sent one does.

What is left after that is the game half of the tick, not the network.

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
