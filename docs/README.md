# dot-net docs

The reasoning behind the netcode, one subject per file. [CLAUDE.md](../CLAUDE.md) has the short rules; these say why.

| File | What it covers |
| --- | --- |
| [timelines.md](timelines.md) | The three timelines, drift and catch-up, the input lead the server reports, the receive timeline, the render time and the delay in snapshots, `_net_interpolated`, and the open jitter/loss gaps |
| [prediction.md](prediction.md) | Determinism, reconciliation (inputs, holes, the newest input), absent-means-unchanged, the open `max_rate` gap, bumping a remote (measured, and the extrapolation chosen), input batches, lag compensation |
| [replication.md](replication.md) | The funnel, acked baselines, what stays owed until confirmed, the interest cache, what a snapshot costs, identities, and what is deliberately not here |
| [wire.md](wire.md) | Bit format, derived message ids and framing, the schema exchange, the rule for changing a message, unreliable-means-unordered, snapshot parts and the MTU, unchanged entities listed by id, the input lead |
| [native.md](native.md) | The optional native snapshot core: turning it on, installing and building it, what it keeps the same, what it costs |
| [security.md](security.md) | The security decisions worth not undoing |
| [testing.md](testing.md) | The three suites, what a green run here cannot see, the UDP relay, GDScript traps |
| [history.md](history.md) | The numbered bug list the code cites, and the unnumbered stories |
