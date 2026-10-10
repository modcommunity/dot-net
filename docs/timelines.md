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
- `sample_count()`, `stall_count()` and `extrapolation_count()` (with `reset_counts()`) exist so a suite can assert nothing extrapolated, not just read it in `describe()`.

## _net_interpolated

`DotNetInterpolator.apply` writes the smoothed value of every property declared `interpolated()` and then calls `DotNetBehaviour._net_interpolated(render_tick)`. That call is the whole point: the obvious hook, `_net_state_applied`, fires when a snapshot arrives, a few times a second, and a game with only that hook moves every remote entity in 20 Hz steps while the interpolated value sits in a property nobody reads. The symptom is an interpolator that appears not to work.

It deliberately carries none of `_net_state_applied`'s bookkeeping: its tick is a render tick, and recording it as the newest state applied would make reconciliation rewind to a tick the server never sent. A predicted entity is never notified, because writing interpolated state over a prediction fights the predictor every frame.

## Open: jitter and loss

Found by game-arena's `headless_lossy` through the UDP relay, not fixed:

- **The clock's jitter is always about zero on ENet.** It is the spread of the round-trip samples it is fed, a game feeds one per snapshot, and the number it feeds (ENet's smoothed round trip, or a two-second heartbeat) barely moves, so `adaptive_margin` never widens the margin. The receive-timeline filter covers jitter in practice, at the price of an input lead 2-4 ticks over what the transit needs. The real fix is for the server to say how early each peer's commands arrive, which is a snapshot wire change.
- **The adaptive interpolation buffer is sized for jitter, not for loss.** At 20% loss some frames still extrapolate, bounded by `max_extrapolation_sec` and drawn within a few centimetres of the truth.
