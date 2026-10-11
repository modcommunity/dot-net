# Timelines: the clock and the interpolator

## Three timelines, not one

The thing most often got wrong, and the reason `DotNetClock` is the first file to read. At any instant a client deals with three tick numbers:

```
  render tick        server tick        input tick
  (behind)           (estimated)        (ahead)
  ────────────────────────●────────────────────────>
       ↑ interpolate           ↑ predict
```

- **Input runs ahead.** A command for tick N must be in the server's hands before it simulates N. Running level with the server means every command arrives late.
- **Render runs behind.** Interpolating needs both bracketing snapshots to have arrived.
- **The server tick is estimated**, never known.

## Drift and catch-up

- **A client ahead of its target is smoothed by scaling tick duration**, not by jumping the tick number: snapping teleports every predicted object and re-runs applied inputs (`MAX_DRIFT_RATE`).
- **Behind is not drift.** A client behind its target stamps every command for a tick the server has already simulated, and the server discards each as late. The engine drops every physics step past eight in a frame, so every stall (a scene loading, a shader compiling on first draw, both of which a browser does for seconds on a first connect) puts the clock behind by the stall's length. Smoothing that at the drift rate turned a half-second hitch into ten seconds of a player who could not steer. So a client behind by more than the input margin (`catch_up_threshold_ticks()`) **jumps forward at once**: the ticks jumped over are never sent and the server repeats the last command for them, as for a lost packet. Prediction has to replay across that hole; see [prediction.md](prediction.md#reconciliation).
- **Past `SNAP_THRESHOLD_SECONDS` it snaps** either way, because a suspended tab is not drift. It is a **duration**: as a tick count, 60 ticks was one second only at 60 Hz, and a 128-tick server snapped at 0.47 s and threw a predicted state away for every half-second hitch.
- **A game-driven server's clock follows `server_tick(tick)`.** With `auto_tick = false` (every game here) nothing else advances it; without it `clock.tick` read 0 for the server's life and every HELLO told a joiner to sync to tick 0.

## The receive timeline

The timeline the clock walks is the RECEIVE timeline: `received_tick()`, the newest snapshot tick as the quickest recent packets place it. `server_tick()` is that plus the flight time (`one_way_ticks()`).

- **It moves between packets.** `advance()` walks the estimate forward with the local clock and `sync_from_server` re-anchors it. Set only on arrival, the rendered tick was a step function of arrivals: at 20 Hz snapshots and 144 Hz rendering, six frames in seven drew the previous one. A stall that drops ticks drops them from both timelines, or the input lead would appear to have grown by the stall and the next sample would correct it as drift.
- **It follows the quickest arrivals.** Re-anchoring to `sample + one_way` on every snapshot moved the timeline back with every slow packet and forward with the next: a remote player drawn half a metre back and forth with every position correct (the truth moves back with the time it is sampled at, so no position check can see it). Now it moves forward at once to a sample ahead of it, ignores one behind it, and goes back one tick only after a whole `SETTLE_SAMPLES` (16) of samples all behind it. Following the quickest packets also puts the input lead about half the jitter higher, which is what stops late commands on a jittery link.

## The render time

- **The interpolation buffer is in snapshots.** `DotNetConfig.interpolation_buffer` says "snapshots of delay" and `_delay_snapshots` holds it. `delay_ticks()` (`_delay_snapshots * ticks_per_snapshot()`) is the one conversion and the only thing `sample()` subtracts. It lives in the interpolator, not the manager, because `sample()` and `apply()` are public and take a tick. It uses `ticks_per_snapshot()` (the integer the manager sends on: 6 at 128/20, not 6.4), so "two snapshots" means two that arrive; `delay_ms()`, `_adapt` and `DotNetConfig.interpolation_delay()` use the same. `delay_snapshots()` is the old number under an honest name; `delay_ticks()` is what `DotNetHistory.client_view_tick` wants.
- **The render time is `received_tick() - delay_ticks()`**, not `server_tick() - delay`. Counting back from the server tick spent part of the buffer waiting for a snapshot still in the air, and on a 120 ms round trip nearly every frame was extrapolated. It never shows on a loopback, where the flight time is zero. `DotNetHistory.client_view_tick` (`current - one_way - delay`) always assumed this.
- **The interpolator is fed what the server said** (`DotNetBehaviour.received_values()`, the receive-side baseline), never the properties, which between snapshots hold the interpolator's own last blend. Fed its own output, anything that changed once and stood still froze part of the way there.
- **The buffer is sized from how late snapshots arrive** (2026-10-10). The manager calls `note_lateness(tick, clock.received_tick())` on every applied snapshot: how far behind the receive timeline it came, in ticks. The buffer has to cover one interval to the snapshot after the render time, the 95th percentile of that lateness over the last 64 arrivals, and one more interval if any of those 64 never arrived (`_adapt` takes the larger of that and the old arrival-gap estimate). A tick more for the frame's fraction would be exact and is left out: it cost every clean link a tick (game-arena steady: 4.1 ticks with it, 3.0 without, 2.5 before) to cover what the bounded extrapolation draws within millimetres. The gap estimate alone (one interval plus two mean deviations of the gap between arrivals) came to about two thirds of what a 30..80 ms link needs. Measured over real ENet through the relay at 5% and 20% loss, 30..80 ms: game-g2gfast's `headless_feel` (128 ticks, 32 snapshots) extrapolated 7.5-11% of frames (37% in the window after a steady link turned jittery), now 0.7-2.4%, worst error 3.5 cm against 4.6-8.3; game-arena's `headless_lossy` (64 ticks, 32 snapshots) 13-14%, now 0.3-2%. The cost is latency under loss: 15 ticks (117 ms) at 128 where it was about 9-11, and 8 (125 ms) at 64 where it was 5 (80 ms).
- **The drawn buffer follows its target at `GROW_RATE` (0.2), never jumps to it.** The render time is the receive timeline minus the buffer, so a buffer that grows from 1.3 snapshots to 2.2 at once draws every remote entity 3.6 ticks back in one frame: the same `headless_feel` measured the render time stepping back 11 times in eight seconds, by up to 3.45 ticks, when a steady link turned jittery. `_target_snapshots` is where it is heading (grows at once, shrinks 1% an arrival, as the buffer itself did), `_delay_snapshots` is what is drawn, and `advance(elapsed)` (called by `DotNetManager.interpolate_frame`, once a frame) moves one toward the other by at most a fifth of the time that passed: a remote player slowed to 80% for a moment instead of one sent backwards. A host that never calls `advance` gets the old behaviour, the buffer following its target at once. `netcode_demo`'s *the buffer growing* plays a link that turns late, tick by tick: armed with `GROW_RATE` 1000 the render time steps back 3 ticks, and without the lateness term 115 of 256 ticks extrapolate.
- `sample_count()`, `stall_count()` and `extrapolation_count()` (with `reset_counts()`) exist so a suite can assert nothing extrapolated, not just read it in `describe()`.

## Drawing through slips

A client's timelines move in whole ticks in three places, and anything drawn from them jumped with them. Found by game-arena's `headless_feel`, which judges each rendered frame against the motion it was drawn on (2026-10-11); `netcode_demo`'s *drawing through slips* plays each at 144 Hz against 64 ticks beside its control.

- **A physics frame that ran no tick, or two.** The engine's fraction is through a physics frame, a fraction through a tick only while each physics frame runs one. A drifting clock stretches or shrinks its ticks (up to `MAX_DRIFT_RATE`), so now and then one runs none and a later one two, and drawn at the engine's fraction the frame after went back over the step it drew or moved double (game-arena: 4 to 8 frames in 5 s, 10 to 16 cm off, at 60 Hz and through 5% loss). `advance` counts the tick a frame gained or lost into `_slip`, and **`render_alpha()` is the engine's fraction plus what is left of it**, taken back at `SLIP_RECOVERY` (a tenth of a tick per tick: twice the most drift can make, and a tenth slow or fast reads as nothing). It runs from -1 to 2 for a moment, so a renderer drawing between its last two ticks extrapolates along the last step past 1 and needs the tick before below 0. `interpolate_frame` uses it by default. Tried first and worse: the clock's own accumulator, which is continuous but sits up to a tick past the newest tick all the time and extrapolated through every wall (474 of 719 frames off at 144 Hz).
- **The receive timeline re-anchoring**: forward at once to a quicker sample, back one tick after `SETTLE_SAMPLES` slower ones. The timeline and the buffer sizing still move at once; **what is drawn follows at `RECEIVE_RECOVERY` (20%, the buffer's own `GROW_RATE`) through `receive_slip()`**, which `interpolate_frame` adds. Drawn as it was, every remote entity jumped a tick at that moment: 2 to 5 frames a window drawn behind the one before, after a link's delay changed.
- **A resumed stream after an extrapolation.** The line guessed past the newest snapshot was off by however far the entity turned, and the next snapshot snapped it back (17 to 32 cm in one frame through 20% loss). **`apply` measures the jump exactly** (what the last frame's extrapolation would draw now, less what is drawn now) and eases it out over `RESUME_EASE_SEC` (60 ms, exponential); a jump past `RESUME_EASE_MAX` (1.5 m) is a teleport. Positions only, and only once a host drives frames through `advance`. `sample()` is untouched: lag compensation and suites read the truth.

## _net_interpolated

`DotNetInterpolator.apply` writes the smoothed value of every property declared `interpolated()` and then calls `DotNetBehaviour._net_interpolated(render_tick)`. That call is the whole point: the obvious hook, `_net_state_applied`, fires when a snapshot arrives, a few times a second, and a game with only that hook moves every remote entity in 20 Hz steps while the interpolated value sits in a property nobody reads. The symptom is an interpolator that appears not to work.

It deliberately carries none of `_net_state_applied`'s bookkeeping: its tick is a render tick, and recording it as the newest state applied would make reconciliation rewind to a tick the server never sent. A predicted entity is never notified, because writing interpolated state over a prediction fights the predictor every frame.

## Open: jitter and loss

Found by game-arena's `headless_lossy` through the UDP relay, not fixed:

- **A link that slows mispredicts for seconds.** When the round trip grows (40 to 70 ms each way in game-arena's `headless_feel`), the input lead follows ENet's smoothed round trip and two medians of it, so for seconds the commands reach the server after their ticks: 70 to 115 late and 120 to 180 starved in 5 s, 40 to 90 corrections. The same fix as below (`dot-net-input-lead-1`).
- **The clock's jitter is always about zero on ENet.** It is the spread of the round-trip samples it is fed, a game feeds one per snapshot, and the number it feeds (ENet's smoothed round trip, or a two-second heartbeat) barely moves, so `adaptive_margin` never widens the margin. The receive-timeline filter covers jitter in practice, at the price of an input lead 2-4 ticks over what the transit needs. The real fix is for the server to say how early each peer's commands arrive, which is a snapshot wire change.
- ~~**The adaptive interpolation buffer is sized for jitter, not for loss.**~~ Sized from lateness and loss since 2026-10-10: see [the render time](#the-render-time).
