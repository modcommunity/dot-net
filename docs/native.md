# The native snapshot core

An optional C++ library (a GDExtension built with godot-cpp) that does the per-peer half of a server's snapshot send: what each peer is believed to hold, what is dirty for it, the encoding, and its snapshot parts. Off by default; the GDScript path is always there and is what runs whenever the library is not asked for or cannot load. It changes no byte on the wire, so clients, browsers included, are unaffected and never load it.

## Why

At 100 players a snapshot's cost is bookkeeping, not bandwidth: a few microseconds per (peer, entity) pair of dictionary lookups, comparisons and small writes, about 30 000 pairs a snapshot. GDScript spends most of a 64 Hz server's 15.6 ms tick on it; the same rules in C++ take a fraction. What stays in GDScript is what a game can override: interest (relevance, thinning, scores, the cap), the budget's accumulator, `_net_read_property`, custom codecs, and the send.

## Turning it on

`DotNetConfig.native = true`, or `DOT_NET_NATIVE=1`, or `--net-native` on the server's command line. The manager logs one line either way: `snapshots are built natively` with the library's path, or `native snapshots asked for but unavailable; GDScript in use` with the reason (no library for this platform, not a desktop or server build, an ABI mismatch). `describe_lines()` has a `native` line. With `snapshot_workers` on as well, interest runs on dot-core's workers as before and the builds on the library's own threads.

The library is looked for at `DotNetConfig.native_path` (`DOT_NET_NATIVE_PATH`), else `addons/dot_net/native/dot_net_native.cfg`, else `dot_net_native/dot_net_native.cfg` next to the executable. It is a `.cfg`, not a `.gdextension`, so an editor or a client never loads it on its own; `DotNetNative.load_library()` loads it once per process when a server asks.

## Installing it on a server

Linux x86_64 binaries (`template_debug`, which the editor binary a server runs headless loads, and `template_release` for an exported server) are committed in `addons/dot_net/native/bin/`, so a Linux server needs nothing but the switch. Anywhere else, build it:

```bash
cd addons/dot_net/native
./build.sh all          # or debug / release; needs git, python3 and a C++17 compiler
```

`build.sh` clones the pinned godot-cpp into `~/.cache/dot-net-native` (`DOT_NET_NATIVE_CACHE`), installs scons there in a venv if it is not on the path, and writes `bin/libdot_net_native.<platform>.<target>.<arch>`. Windows (MSVC or MinGW) and macOS (`universal`) are build-it-yourself: the `.cfg` already names their files, and nothing in the source is platform-specific beyond `std::thread`. A web export has nothing to load and never asks.

## What it keeps the same

Every rule of `DotNetBehaviour._collect_dirty`, `write_state`, `_sync_view` / `_trim_view` and `DotNetManager._send_to_peer` is ported line for line: audiences, `max_rate`, epsilon, `once()`, owed-until-confirmed, lost sends going dirty again, the ack window, the budget, parts at the MTU, the unchanged tail, the input lead. Floats are compared and quantised as GDScript does them (doubles; vectors as single-precision `Vector3`, built without fused multiply-add). A value the library cannot convert the way `DotNetVar.write` would (a custom codec, an unusual type in a declaration) is encoded by GDScript when the snapshot opens, at each bit of a byte it could start at if it may align, and copied in. The records of what each peer holds live in the library while it is on; `peer_view_state`, `peer_view_snapshot`, `forget_peer` and `reset_baseline` answer from it.

netcode_demo's `[native]` section is the proof: every encoder against `DotNetVar.write` at every pad on random values, then the scripted ten-peer game of `[snapshot threads]` (loss in the acks, a starving budget, parts, both wire formats, strings, bytes, a rate limit, a custom codec, rotations, thinning, the grid) built by GDScript and by the library, inline and on three threads, payload for payload and view for view. `tools/snapshot_bench.tscn -- --hash --native` prints the digest of a 100-player run to compare against the same run without `--native`. Without the library built the section checks the fallback instead.

A change to any of those GDScript methods is a change to `src/dot_net_native_core.cpp` too, and to `DotNetNative.ABI` and `abi_version()` when the GDScript side's calls change.

## What it costs

`tools/snapshot_bench.tscn -- --peers=100 --npcs=213 --hash --split`, one dev VM, debug library, mean of 60 snapshots: GDScript 108.5 ms, native 26.1 ms, native with 4 workers 24.6 ms; the same digest each time. What is left is interest, ranking and the per-entity reads, all GDScript.

A whole zombie-survival server tick (`tools/server_probe.tscn -- --n=N --rate=64 --acks --lead=45`, about 230 NPCs, 768 ticks, mean ms per tick, snapshot send / whole tick, on a shared VM with other jobs running):

| Players | GDScript | GDScript, 4 workers | native | native, 4 workers |
| --- | --- | --- | --- | --- |
| 100 | 134.8 / 177.3 | 96.2 / 142.1 | 33.9 / 76.6 | 26.9 / 71.7 |
| 128 | 181.0 / 235.3 | 120.4 / 176.1 | 49.1 / 103.4 | 33.8 / 87.7 |

The snapshot send drops about fourfold; the rest of that tick (bots, brains, players) is the game's and is now the larger part.
