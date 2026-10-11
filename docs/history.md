# History

The numbered bug list. Code comments cite these numbers (`#17`), so the numbering is kept, gaps included (there was never a #11). Each rule they left is in the topic docs; this is how each looked when it happened, so it can be recognised if it comes back. Every one passed the parse check.

1. **`DotNodeRef.of_created(&"X", Node)` produced a garbage class name** (`str()` on a `GDScriptNativeClass`). A dot-core bug that also broke dot-server's game root; fixed in dot-core's `_class_name_of`.
2. **`HashingContext.update()` errors on empty input**, so an empty message schema hashed to an engine error. Fixed in dot-core's `DotHash.sha256_bytes`.
3. **Reader exhaustion was not sticky**, so a decoder ignoring `ok()` got a plausible value for the field after the overrun.
4. **History was sized from `snapshot_rate`** while the caller recorded per tick, so rewinds landed on the buffer boundary.
5. **The priority accumulator starved a 100x-lower-priority entity for 100 ticks.** Superlinear starvation boost added.
6. **A suspending test section was called without `await`.** Its last assertion never ran once, and its suspended locals were the seven objects Godot reported leaked at exit, which three audits had chased as a reference cycle in `DotNetInterpolator`. There was no cycle.
7. **Reconciliation replayed without the inputs**, on whatever the behaviour held. Invisible under a constant input; with a zig-zag the client ended over a metre from the server after ten replayed ticks.
8. **Respawning a pooled entity put it in the wrong parent and returned ok.** The first test could not catch it: it pooled without re-parenting.
9. **A prefab declared in the inspector failed silently**, surfacing much later as "unknown prefab" on the first spawn.
10. **The three diagnostics each pointed elsewhere.** `loss_rate()` divided by all packets received (a server reported 0.0 whatever happened); a reordered packet counted as lost and then out-of-order (steady loss while losing nothing); rolling rates closed only on traffic (a quiet connection kept its old throughput). `stats.roll()` now runs every frame.
12. **Dirty tracking was one dictionary shared by every peer.** A two-client game replicated to one of them. Survived because the integration run had one peer.
13. **A lost snapshot stranded every property it carried, permanently**, because the baseline was updated at send time. Fixed by acked baselines.
14. **`DotNetSnapshot.net_ids()` returned insertion order**, which differs between peers. Sorted.
15. **`DotNetHistory.record` read `global_basis` off entities not in the tree.** mg-smash-copter's server printed ten `!is_inside_tree()` backtraces a round on a green run. Such entities are skipped now.
16. **A peer id set after `setup()` never reached the registry**, so over a real socket a client predicted nothing, while its loopback suite (which sets the id first) passed.
17. **A predicted entity the server held still walked away from it**, at twice its speed and growing. First written down as "the snapshot does not carry the entity", which was the wrong mechanism: reconcile was handed the client's own prediction as the server's word. Fixed on both sides (`authoritative_values()`, `until_acked`). The games' naive freeze controls now also assert the rubber band's floor does not climb.
18. **The interpolation buffer was in snapshots and was subtracted from ticks**, so at 128/20 it was under one snapshot interval and every remote entity in the family was extrapolated. Nothing failed: extrapolation is bounded and exact in a straight line, and the only check was written in the same wrong unit.
19. **The interpolator was fed its own output back as the server's word.** A remote player who turned to 90° was drawn at 82.5° forever; one who stopped was drawn a quarter metre short. Hidden behind #18 until it was fixed; found by game-playground's and mg-buses-from-hell's facing checks.
20. **Open: a predicted `max_rate` property that stops changing is never rewound.** See [prediction.md](prediction.md#open-a-rate-limited-predicted-property).
21. **`unregister` typed a freed identity**: 171 script errors on one `changelevel` away from mg-buses-from-hell, on a run that passed.
22. **`DotNetStats` counted a gap in ticks as that many lost snapshots.** At 64 ticks and 32 snapshots a clean link reported half lost. `snapshot_interval_ticks` makes a gap a number of periods.
23. **The render timeline went backwards on every late packet**, drawing a remote player back and forth through a real relay with every position correct.
24. **The interpolation delay was counted back from the server's tick**, so the flight time came out of it and nearly every frame on a 120 ms round trip was extrapolated. Never shows on a loopback.
25. **Nothing resent an input.** The buffer's comment said clients resend recent inputs; none did. Input batches added.
26. **A replay stopped at a hole the clock's catch-up had made**, leaving the prediction metres short; the first fix replayed past the newest input and predicted ticks twice.
27. **`DotNetConfig.mtu` was declared and read by nothing**, so the only bound on a snapshot was an entity count. mg-buses-from-hell's round-start snapshot (88 crates and buses all falling, about 16.6 bytes each) was 1450 to 1478 bytes, over the 1392 that Godot's ENet peer carries in one unreliable packet; ENet fragmented it, and losing either fragment lost the snapshot, so a native client lost about twice as many of the snapshots that mattered most. Nothing failed: a lost snapshot is one stale frame, and the only sign was ENet's once-per-process "above the MTU" warning in a dot-server-deploy suite. Snapshots are cut into parts at `mtu` now ([wire.md](wire.md#snapshot-parts)).

Not numbered, kept for recognition:

- **Behind was smoothed like drift** (2026-10-03): a browser's first-connect stalls put the clock behind, and a half-second hitch became ten seconds of a player who could not steer, in every game, "fixing itself". Found from screen recordings and a cold browser profile against a live server.
- **The snap threshold was a tick count**, so a 128-tick server snapped at 0.47 s.
- **The render timeline did not move between packets**: six frames in seven redrew the previous one. Found from game-hungario (then dot-2d-hungry), which asked why a remote monster had not moved; the interpolator's suite called `sample()` directly, so the clock was never in the path.
- **`_net_interpolated` did not exist**, so game-hungario and game-arena copied state only on snapshot arrival, in 20 Hz steps.
- **The interest cache held one instant**: a respawned monster's mass stayed frozen on its client while positions agreed to a hundredth.
- **The server's clock read 0 forever** on game-driven servers.
- **A full server's snapshots** (game-g2gfast's 32-player load probe): the per-peer repeats in [replication.md](replication.md#what-a-snapshot-costs). The first shared-encoding version sent game-playground's NPC weapon id as garbage, because a string's alignment depends on the bit it starts at; its `headless_net` caught it.
- **Reordered snapshots** (native clients on ENet, 2026-10-09): re-sending a lost property once never converged on a link that held back every other snapshot; `PeerView.relost` keeps it owed.

Cross-repo: the dot-core bugs (#1, #2) are also in [game-dev/docs/bugs-found.md](../../../docs/bugs-found.md); dot-server's scoreboard ordering is in [wire.md](wire.md#unreliable-means-unordered).
