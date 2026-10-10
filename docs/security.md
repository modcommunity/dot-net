# Security decisions worth not undoing

- **Clients send inputs, never state.** A client that sent positions could send any position.
- **`DotNetInput._sanitise()` runs on the server after decode, and is not optional.** Quantisation bounds each field; it cannot bound the relationship between them. A move vector of length 40 is representable and would make a player 40 times faster.
- **`DotNetMessage.Direction` is enforced on receipt.** Without it any client can send the server a spawn or a "you have been kicked". It is checked against the **transport's** view of the sender, never a peer id inside the payload.
- **Spawns name a prefab id, never a scene path.** A path would let a peer ask others to load any scene in the build.
- **Net ids are never reused.** A reused id means a snapshot in flight for a dead entity is applied to a live one.
- **`DotNetReader` is the untrusted side.** Reads past the end return zero and set a sticky `exhausted`, so a decoder that ignores `ok()` does not get a plausible value for the field after the overrun. Length prefixes are bounded before allocating: a varint of 4 billion must not cause an allocation attempt.
- **`DotNetVar.Audience.OWNER`** keeps ammo and cooldowns off the wire to opponents.
- **Interest management is the anti-cheat that works.** Data never sent cannot be drawn on a wallhack.
- **Rewind is bounded** by `max_rewind_sec`; an excessive claim is clamped, not honoured.
