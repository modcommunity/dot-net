# The wire

## Format

- Bits are written LSB-first within each byte, bytes in order. **This is the wire format**; changing it is a protocol break.
- `write_bytes` / `write_string` byte-align first, so bulk data copies in one call rather than shifting per bit. Alignment costs at most 7 bits. (It is also why a property set containing one is encoded per bit offset: [replication.md](replication.md#what-a-snapshot-costs).)
- Quaternions use smallest-three: 2 bits for the dropped index plus three components in ±1/√2. 29 bits at 9-bit components against 128 for four raw floats, accurate to well under a degree.
- Positions **clamp** at the world bounds; angles **wrap**. Clamping a position is visibly wrong at the edge; wrapping one teleports across the map.
- `read_quaternion` guards `sqrt(max(0, ...))`: quantisation can push the sum of squares past 1, and `sqrt` of a small negative is NaN that propagates into every derived transform.
- `DotNetReader` is the untrusted side: see [security.md](security.md).

## Two builds on one wire

**A server and a client built from different dot-* sources can play, as long as neither lacks something the other REQUIRES.**

- **Wire ids are derived from the type's name** (`DotNetMessageRegistry.wire_id_for`: the first 32 bits of its SHA-256). Assigning ids by sorting the registered names made two processes agree only while they registered exactly the same set; one added type renumbered every type after it.
- **Every message body is framed with its length in bits**: `id (32) | varint bit length | align | body`. A receiver without the type skips exactly that message and carries on, mid-batch included; a receiver with an older version reads what it knows and skips the rest. Bits, not bytes, because a body ending mid-byte is padded with zeroes that look exactly like a one-bit field set to false; `DotNetReader.limit_bits` bounds the body reader so `has_more()` means "the sender wrote nothing further".
- **Why derived ids and not a negotiated per-peer table.** A negotiated table has to reach the receiver before the first message that uses it, and nothing can guarantee that here: every game encodes its events with `messages.encode` and routes them through its own link, around the manager. A message decoded against a table that has not arrived is dropped or misread, silently. A derived id cannot be misread in any order. It costs 20 bits per event or request; snapshots carry no message id.

## The schema exchange

The table is still exchanged, for what only it can do. `DotNetManager` sends `messages.schema_payload()` through `send_fn` as RELIABLE (a server in `add_peer`, a client in `start()`, and `announce_schema(peer)` for a host whose route was not up yet), and the receiver's `decode` adopts it (reserved id 0).

- A type registered `required` (the default: a game's own event and request types are the game) that the peer does not know refuses the pair with a sentence ("This server's game needs a newer game client.") on `peer_schema_refused`; nothing that peer sends is decoded after it.
- **dot-net cannot drop a peer, because it owns no socket, so the host must.** dot-game's `DotGameNetcode` kicks with `error.message`; a game building its own manager connects the signal itself.
- An optional type the peer lacks is skipped and costs nothing. Two names whose derived ids collide are refused at registration, or at adoption when only the peer has one of them.
- `schema_hash()` covers **only the required names**: what must match, printed as twelve characters, so a peer with one extra optional type does not read as incompatible.

## Changing a message

Derived ids no longer protect you from a careless change, so: **append fields, never reorder, retype, re-width or remove one**, and read a field added after the type first shipped only `if reader.has_more()`, so a message from an older sender keeps the field's default. A change that cannot be an append is a **new type with a new name** (renaming a type is making one, because its id is its name), registered beside the old until nothing sends the old one. `netcode_demo`'s `[mismatched schemas]` is the proof of all of this.

## Unreliable means unordered

Godot's ENet sends `TRANSFER_MODE_UNRELIABLE` **unsequenced**: through a real lossy link the unreliable packets arrive out of order (most of them behind a newer one), while reliable ones arrive exactly once and in order. Over WebSocket "unreliable" is reliable and in order, so a bug of this kind shows only on a native client over UDP.

**Nothing sent unreliable may assume order.** Snapshots are superseded by tick in `receive_snapshot`; the input buffer is sorted by tick; dot-voice's jitter buffer orders by sequence; dot-server's heartbeat and ping echo a value. dot-server's scoreboard was the exception (the client kept whatever payload arrived last) and carries a `seq` that the client checks. A new unreliable message needs a tick or a sequence, or must be a value whose latest copy is always right.
