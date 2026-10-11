# dot-net

Multiplayer netcode for Godot 4: tick synchronisation, a bit-packed wire format, declarative state replication, snapshot interpolation, client-side prediction with server reconciliation, lag-compensated rewind, and pluggable interest management.

**The distributable is `addons/dot_net/`.** It requires [dot-core](../dot-core) and does not depend on dot-server: a game can use dot-net over Godot's raw multiplayer, over dot-core's transports, or over anything else that moves bytes. It owns no socket and no client-to-server channel.

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to dot-net. The reasoning is in [docs/](docs/README.md).

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/timelines.md](docs/timelines.md) | `DotNetClock`, the interpolator, anything about when something is drawn or which tick a command is for |
| [docs/prediction.md](docs/prediction.md) | `_net_simulate`, `DotNetPredictor`, `DotNetInput`, reconciliation, lag compensation |
| [docs/replication.md](docs/replication.md) | `DotNetVar`, `DotNetBehaviour`, acked baselines, interest, the budget, snapshot cost |
| [docs/wire.md](docs/wire.md) | the bit format, message ids, framing, the schema exchange, changing a message, unreliable delivery, snapshot parts and the MTU |
| [docs/security.md](docs/security.md) | anything a client sends, spawns, message direction, the reader |
| [docs/testing.md](docs/testing.md) | the three suites, the UDP relay, adding a check |
| [docs/history.md](docs/history.md) | a netcode bug that "cannot be happening"; the numbered bug list the code comments cite |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_net/dot_net_manager.gd` | tick loop, snapshot send/receive, message routing |
| `addons/dot_net/core/` | `DotNetClock` (three timelines: read it first), `DotNetConfig` (all tuning; `describe_budget()`) |
| `addons/dot_net/wire/` | writer (bit packing, quantisation), reader (the untrusted side), messages, the registry (derived ids, framing, schema exchange), packets (batching, fragmentation) |
| `addons/dot_net/replication/` | `DotNetVar`, `DotNetIdentity`, `DotNetBehaviour` (what a game subclasses most), registry (ids never reused), spawner (prefab allow-list, factories) |
| `addons/dot_net/snapshot/` | `DotNetSnapshot`, `DotNetInterpolator` |
| `addons/dot_net/prediction/` | `DotNetInput` and its buffer, `DotNetPredictor` |
| `addons/dot_net/lagcomp/` | `DotNetHistory`: rewind the world to what the shooter saw |
| `addons/dot_net/interest/` | base, all, distance, grid |
| `addons/dot_net/bandwidth/`, `stats/` | per-peer budget with a starvation-bounded accumulator; `DotNetStats` |
| `addons/dot_net/testing/dot_net_udp_relay.gd` | a lossy UDP relay for tests. No `class_name`: preload by path |
| `examples/` | `netcode_demo`, `diagnostics_demo`, `relay_demo` |

## Running and testing

- The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then all three scenes: `netcode_demo.tscn` (everything, including a two-manager integration run under loss), `diagnostics_demo.tscn` (`DotNetStats`, `DotNetSnapshot`), `relay_demo.tscn` (the relay and a real ENet pair). [testing](docs/testing.md)
- **A dot-net change is not done until the games' `headless_net` suites agree**, and game-arena's `headless_lossy` for anything about loss or timing: most bugs here were found there, by a second peer, a real socket or a real round trip that this repo's suites lacked.
- The integration test runs both managers in one process, which is why there are no autoloads and why `DotNetManager.service_scope` exists.

## Extension points

A game should never need to fork dot-net. Family rules: [extension-points.md](../../docs/extension-points.md).

| To change | Subclass / assign | Notes |
| --- | --- | --- |
| What replicates, and how precisely | `DotNetVar` declarations in `_register_net_vars()` | `Type.CUSTOM` + `.codec(w, r)` replicates anything |
| Simulation | `DotNetBehaviour._net_simulate` | Must be deterministic |
| Player controls | `DotNetInput` subclass | `_sanitise()` is not optional |
| Message types | `DotNetMessageRegistry.register` | Id derived from the name; `required = false` for a type a peer may lack |
| Who sees what | `DotNetInterest` subclass | The biggest lever on bandwidth and the only real anti-cheat |
| How entities are made | `DotNetSpawner.register_factory` | For pooling or procedural entities |
| Where bytes go | `DotNetManager.send_fn` | Transport-agnostic by construction |
| Reading a computed property | `_net_read_property` / `_net_write_property` | Replicate something you do not store |
| Extra rewind state | `_net_record_history()` on a behaviour | Crouch flags, animation frames |
| Drawing interpolated state | `_net_interpolated(render_tick)` | Not `_net_state_applied`, which fires per snapshot |

`DotNetInterest`: `_is_relevant` is the whole interface for most strategies; `_candidates` is for spatial indexes that answer in bulk; `_score` feeds prioritisation. `netcode_demo`'s `TagInterest` is a dozen lines.

## Rules that bite

Short forms; the reasoning is in the linked file.

**Time**

- Input runs ahead of the server, render behind it, and the server tick is only estimated. [timelines](docs/timelines.md#three-timelines-not-one)
- A client AHEAD is smoothed by scaling tick duration; a client BEHIND by more than the input margin jumps forward at once. Never smooth "behind". [timelines](docs/timelines.md#drift-and-catch-up)
- `SNAP_THRESHOLD_SECONDS` is a duration, never a tick count. [timelines](docs/timelines.md#drift-and-catch-up)
- A game-driven server (`auto_tick = false`) must call `server_tick(tick)` or its clock reads 0 forever. [timelines](docs/timelines.md#drift-and-catch-up)
- The interpolation buffer is in SNAPSHOTS; `delay_ticks()` is the one conversion, and the render time is `received_tick()` minus it, never `server_tick()` minus it. [timelines](docs/timelines.md#the-render-time)
- The receive timeline follows the quickest arrivals and goes back only after `SETTLE_SAMPLES` all behind. [timelines](docs/timelines.md#the-receive-timeline)
- The interpolation buffer is sized from `note_lateness` and grows at `GROW_RATE` through `advance`, never at once: a jump in the buffer is the render time going backwards. Call `interpolate_frame` once a frame. [timelines](docs/timelines.md#the-render-time)
- Copy interpolated state from `_net_interpolated`; it carries none of `_net_state_applied`'s bookkeeping and never fires for a predicted entity. [timelines](docs/timelines.md#_net_interpolated)

**Prediction**

- `_net_simulate` must be deterministic across machines: no wall clock, no unseeded random, no unpredicted state of another player, no physics query against geometry one side lacks, no unordered iteration. `correction_rate()` tells you. [prediction](docs/prediction.md#determinism-is-a-requirement-not-an-aspiration)
- A replay applies each tick's input and then simulates, exactly as `server_tick` does; a hole between two inputs replays on the older one; nothing past the newest input is replayed. [prediction](docs/prediction.md#reconciliation)
- A predicted entity rewinds to `authoritative_values()` (absent means unchanged), a remote one is interpolated from `received_values()`. Never feed either from the properties, which hold the client's own prediction or blend. [prediction](docs/prediction.md#what-the-server-said)
- A renderer adds `predictor.visual_offset(net_id)` to the predicted entity it draws; every reconciliation that moves it is eased and offsets add up. [prediction](docs/prediction.md#corrections-are-eased-on-screen-every-one-of-them)
- Send the last few inputs in each packet (`write_batch` / `read_batch`, `Buffer.recent`). [prediction](docs/prediction.md#input-batches)
- Rewind is bounded by `max_rewind_sec` (1 s); a larger claim is clamped. [security](docs/security.md)

**Replication**

- Dirty tracking is per peer (`PeerView`: acked, pending, believed); a lost snapshot's properties go dirty again. [replication](docs/replication.md#acked-baselines)
- Acks are optional and carried by the host (`encode_ack` in the input packet). A client acks only a fully-applied snapshot. [replication](docs/replication.md#acked-baselines)
- The owner's predicted entity, and any property lost once, stay owed until confirmed. [replication](docs/replication.md#owed-until-confirmed)
- The interest cache is pinned with what the peer owns and everything `always_relevant`, as a new dictionary. [replication](docs/replication.md#the-interest-cache-is-a-cache-of-one-instant)
- A property set with anything byte-aligned (`may_align`) is encoded per bit offset, never shifted. [replication](docs/replication.md#what-a-snapshot-costs)
- Snapshots read each property once, inside `begin_snapshot_reads` / `end_snapshot_reads`. [replication](docs/replication.md#what-a-snapshot-costs)
- Net ids are never reused; a freed identity is dropped from every table without being typed. [replication](docs/replication.md#identities)
- `local_peer_id` forwards to the registry through a setter: never keep a second copy of it. [replication](docs/replication.md#identities)

**The wire**

- Bits are LSB-first; positions clamp, angles wrap. Changing either is a protocol break. [wire](docs/wire.md#format)
- Message ids are derived from the name. **Append fields, never reorder, retype, re-width or remove one**; read a late-added field only `if reader.has_more()`. Anything else is a new type with a new name. [wire](docs/wire.md#changing-a-message)
- A required type the peer lacks raises `peer_schema_refused`; **the host must drop the peer** (dot-net owns no socket). [wire](docs/wire.md#the-schema-exchange)
- Godot's ENet sends UNRELIABLE as unsequenced: nothing sent unreliable may assume order. [wire](docs/wire.md#unreliable-means-unordered)
- A snapshot over `config.mtu` goes out in parts, each applying alone; a client acks a tick only when every part is in, and a part of an older tick than one already read is superseded. [wire](docs/wire.md#snapshot-parts)
- Clients send inputs, never state; `_sanitise()` runs on the server after decode; message direction is checked against the transport's sender. [security](docs/security.md)

**GDScript**

- `var x := something_returning_Variant()` is a parse error here: write `var x: Variant = ...`. [testing](docs/testing.md#gdscript-traps)
- A suspending test section called without `await` silently stops; suites count sections entered against completed. [testing](docs/testing.md)

## Known gaps

Open, each with its reason in the linked file: a predicted property with a `max_rate` that stops changing is never rewound (no game sets one) [prediction](docs/prediction.md#open-a-rate-limited-predicted-property); the clock's jitter reads about zero on ENet, so `adaptive_margin` never widens [timelines](docs/timelines.md#open-jitter-and-loss). Deliberately not here (rollback netcode, reliable delivery, whole-snapshot deltas, bitfield acks, physics determinism, matchmaking): [replication](docs/replication.md#deliberately-not-here).
