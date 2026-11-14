# dot-net

Multiplayer netcode for Godot 4. It keeps clocks in step, packs data tightly, copies game state from the server to clients, smooths what remote players do, predicts your own movement, checks hits fairly despite lag, and sends each player only what they need. It needs only [dot-core](https://github.com/modcommunity/dot-core), so you can use it with [dot-server](https://github.com/modcommunity/dot-server), Godot's own multiplayer, or your own transport. Part of TMC's open source **Dot** collection (MIT licence).

> Built with Claude Code. Every addon has a headless test suite and the suites pass, but little of this has met real players yet. Please report rough edges.

## Install

Copy `addons/dot_core/` and `addons/dot_net/` into your project and enable both under **Project > Project Settings > Plugins**. Needs Godot 4.7 or newer.

## Use

```gdscript
var net := DotNetManager.new()
net.is_server = true
net.config = DotNetConfig.new()
add_child(net)

net.spawner.register_prefab(&"player", preload("res://player.tscn"))
net.interest = DotNetInterestGrid.new()
net.send_fn = func(peer, payload, delivery): my_transport.send(peer, payload)

net.start()
```

The manager never owns a socket: you give it `send_fn` and feed it what arrives.

Make something networked by adding a `DotNetIdentity` and listing what replicates:

```gdscript
class_name PlayerMovement extends DotNetBehaviour

var position: Vector3
var velocity: Vector3
var ammo: int

func _register_net_vars() -> void:
    replicate(&"position", DotNetVar.Type.VECTOR3_POSITION).interpolated()
    replicate(&"velocity", DotNetVar.Type.VECTOR3_VELOCITY).with_epsilon(0.05)
    replicate(&"ammo", DotNetVar.Type.UINT).bits(9).to_owner_only()

func _net_simulate(tick: int, delta: float) -> void:
    position += velocity * delta      # runs on the server AND the owning client
```

Change tracking, quantising, who gets what, rate limiting, interpolation and prediction all follow from that list.

## What it does

| Feature | How it works |
| --- | --- |
| Compact wire format | Positions are quantised (default step 0.01 m over a 2048 m world), rotations use smallest-three, with bit packing, varints and a per-property deadband. `describe_budget()` reports what your settings cost per client per second. |
| Prediction | The owning client simulates at once, the server corrects, and the client replays unconfirmed inputs on top. Small errors ease out (0.1 s by default); large ones snap, because easing across a teleport drags you through geometry. |
| Interpolation | Remote entities render slightly in the past so the bracketing snapshots have arrived. The buffer grows fast under jitter and shrinks slowly. |
| Lag compensation | The server rewinds other entities to where the shooter saw them, tests the shot, and restores. The rewind is bounded (`max_rewind_sec`), so a client cannot claim any rewind it likes. |
| Interest management | Distance, a spatial grid, or everything. Subclass `DotNetInterest` for teams, rooms, line of sight or fog of war. Data never sent cannot be drawn by a wallhack. |
| Bandwidth budget | A per-client byte budget with a priority accumulator: important entities update often, others eventually, and nothing is starved. |
| Stats that name the cause | A high correction rate points at a determinism bug, starvation at bandwidth, late inputs at the clock. |

## Settings

`DotNetConfig` is layered like every Dot config (defaults, JSON, `DOT_NET_*` environment, command line). The most useful ones:

| Setting | Default | What it does |
| --- | --- | --- |
| `tick_rate` | 60 | Simulation ticks per second. |
| `snapshot_rate` | 20 | Snapshots per second sent to each client. |
| `interpolation_buffer` | 2.0 | Snapshots of delay for remote entities. |
| `max_extrapolation_sec` | 0.25 | How long a remote entity is extrapolated when snapshots stop. |
| `enable_prediction` | true | Client-side prediction. |
| `input_history_ticks` | 120 | Inputs kept for replay. |
| `reconcile_snap_distance` | 2.0 | Error in metres above which the client snaps rather than eases. |
| `enable_lag_compensation` | true | Rewind for hit tests. |
| `max_rewind_sec` | 1.0 | Furthest the server will rewind. |
| `world_extent` | 2048.0 | Half-size of the quantised world in metres. |
| `position_step` | 0.01 | Position accuracy in metres. |
| `max_speed` | 100.0 | Fastest an entity may move, for quantising velocity. |
| `mtu` | 1200 | Largest snapshot packet in bytes; bigger snapshots are split into parts. |
| `per_client_budget` | 65536 | Bytes per second to one client. 0 = unlimited. |
| `per_client_packet_rate` | 60 | Packets per second to one client. 0 = unlimited. |
| `interest_radius` | 200.0 | Metres within which entities always replicate. |
| `max_entities_per_snapshot` | 4096 | Entities per client per snapshot. 0 = unlimited. |
| `max_tracked_entities` | 4096 | Entities one client may be told about at once. 0 = unlimited. |
| `client_message_rate` | 240 | Messages per second a client may send before being throttled. |
| `max_client_payload` | 4096 | Largest payload accepted from a client, in bytes. |
| `native` | true | Use the optional native snapshot core when installed; falls back to GDScript. See [docs/native.md](docs/native.md). |

The rest (stagger, workers, input margins, reconcile easing, far-entity rates) are in `addons/dot_net/core/dot_net_config.gd`, each with a comment.

## Extending it

You should not need a fork. Subclass `DotNetBehaviour` for components, `DotNetInput` for controls, `DotNetMessage` for your own messages and `DotNetInterest` for relevance rules. `DotNetVar.Type.CUSTOM` with a write and read pair replicates any type.

## Limits worth knowing

- `_net_simulate` must give the same result on every machine, or reconciliation will not converge. That rules out Godot's physics for anything needing exact agreement. See [docs/prediction.md](docs/prediction.md#determinism-is-a-requirement-not-an-aspiration).
- A snapshot is split into at most 16 parts (a fixed constant in the code, not a setting). What does not fit waits for a later tick.
- Rollback netcode, matchmaking and voice are not part of dot-net.

## More documentation

| File | Covers |
| --- | --- |
| [docs/wire.md](docs/wire.md) | Bit format, message ids, the schema exchange, snapshot parts. |
| [docs/replication.md](docs/replication.md) | How state reaches clients and what it costs. |
| [docs/prediction.md](docs/prediction.md) | Determinism, reconciliation, inputs, lag compensation. |
| [docs/timelines.md](docs/timelines.md) | The clock and the interpolator. |
| [docs/native.md](docs/native.md) | The optional native snapshot core. |
| [docs/security.md](docs/security.md) | Decisions worth not undoing. |
| [docs/testing.md](docs/testing.md) | The test suites. |
| [docs/history.md](docs/history.md) | Numbered bug list the code cites. |

## Testing

```bash
godot --headless --path . --import
godot --headless --path . res://examples/netcode_demo.tscn
```

The demo runs offline checks: wire round trips, schema mismatch detection, batching and fragments, clock convergence, replication, interest strategies, budget fairness, interpolation limits, rewind and restore, and a full server and client over a loopback with packet loss. Other suites are in `examples/`.

## Licence

MIT. See [LICENSE](LICENSE).
