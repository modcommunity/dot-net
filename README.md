This is the **netcode** asset for TMC's **Dot** collection. It is what makes a game multiplayer, and it is independent enough to drop into a project that uses none of the rest.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Multiplayer Netcode
Multiplayer netcode for Godot 4. Tick synchronisation, a bit-packed wire format,
declarative state replication, snapshot interpolation, client-side prediction with
server reconciliation, lag-compensated hit detection, and interest management.

Part of the `dot-*` family alongside [dot-core](../dot-core),
[dot-server](../dot-server), [dot-auth](../dot-auth) and [dot-cloud](../dot-cloud).
It needs only dot-core — use it with dot-server, with Godot's raw multiplayer, or
with your own transport.

## Install

Copy `addons/dot_core/` and `addons/dot_net/` into your project and enable both in
*Project → Project Settings → Plugins*. Requires Godot 4.4+.

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

Make something networked by adding a `DotNetIdentity` and describing what replicates:

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

Dirty tracking, quantisation, audience filtering, rate limiting, interpolation and
prediction all follow from that declaration.

## What it gives you

**A wire format that fits.** Positions quantised to a centimetre over a 4 km world
cost 19 bits an axis instead of 32. Rotations use smallest-three: 29 bits instead of
128, accurate to under a degree. Bit packing, varints, per-property deadbands, and a
`describe_budget()` that tells you what your settings cost per client per second.

**Prediction that converges.** The owning client simulates immediately, the server
corrects, and the client replays its unacknowledged inputs on top of the correction.
Small errors ease out over a tenth of a second; large ones snap, because easing
across a teleport drags you through geometry.

**Interpolation that hides jitter.** Remote entities render slightly in the past, far
enough that the bracketing snapshots have arrived. The buffer grows quickly under
jitter and shrinks slowly, so a good connection sees less delay than a bad one.

**Lag compensation.** The server rewinds every other entity to where the shooter saw
them — accounting for both their latency and their interpolation buffer — tests the
shot, and restores. Bounded, so a client cannot claim an arbitrary rewind.

**Interest management you can replace.** Distance, spatial grid, or everything — or
subclass `DotNetInterest` and implement one method for teams, rooms, line of sight or
fog of war. It is the biggest lever on bandwidth and the only anti-cheat that
actually works: data never sent cannot be drawn on a wallhack.

**Bandwidth budgeting.** A per-client byte budget with a priority accumulator, so
important entities update often, unimportant ones update eventually, and nothing is
starved — with an explicit bound on how long "eventually" can be.

**Stats that name the cause.** Netcode fails quietly, and players call every failure
"lag". A high correction rate is a determinism bug; high starvation is bandwidth;
high late-input counts are the clock. Different fixes.

## Extending it

Nothing here should require a fork. Subclass `DotNetBehaviour` for components,
`DotNetInput` for controls, `DotNetMessage` for your own messages, `DotNetInterest`
for relevance rules. `DotNetVar.Type.CUSTOM` with a write/read pair replicates any
type at all. `DotNetManager.send_fn` means it never owns a socket.

## Try it

```bash
godot --headless --path . res://examples/netcode_demo.tscn
```

125 offline checks: wire round-trips and quantisation accuracy, message direction
enforcement and schema-mismatch detection, batching and fragment reassembly, clock
convergence and drift correction, replication and dirty tracking, three interest
strategies agreeing with each other, budget fairness, interpolation and extrapolation
bounds, rewind and restore, and a full server-plus-client run over a loopback with
20% packet loss.

## Honest limits

`_net_simulate` must be deterministic across machines or reconciliation will not
converge — which rules out Godot's physics for anything needing exact agreement. See
[CLAUDE.md](CLAUDE.md#determinism-is-a-requirement-not-an-aspiration). Rollback
netcode, matchmaking and voice are out of scope.

## Licence

MIT — see [LICENSE](LICENSE).
