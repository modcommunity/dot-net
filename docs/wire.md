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

## Snapshot parts

**A snapshot never goes to `send_fn` bigger than `DotNetConfig.mtu` (1200 by default) unless one entity alone is bigger.** Godot's ENet peer carries 1392 bytes in one unreliable packet and fragments anything bigger into unreliable fragments; losing any fragment loses the packet, so a two-fragment snapshot is lost about twice as often, and the snapshot most likely to be big (a round's spawn, everything moving at once) is the one a client most needs. Over WebSocket nothing is lost either way. Bug #27 in [history.md](history.md).

- **Each part is a whole snapshot of its own entities**: the same header (tick, count) and entity layout, plus an 8-bit trailer after the last entity (part index, part count less one; four bits each, so at most `MAX_SNAPSHOT_PARTS` = 16). An entity is never split across parts. A part applies without the others, so a lost part loses only its entities.
- **A snapshot that fits is byte for byte the format before parts**: no trailer. The receiver tells the two apart by what is left after the entities: under 8 bits is padding, 8 to 15 is a trailer, 16 or more is an unchanged-entity tail ([below](#unchanged-entities)).
- **The cut is decided before an entity is written**, from its exact size (`DotNetBehaviour.state_bits`, which reads the same encoding cache `write_state` then copies). It cannot be decided after: `write_state` updates the peer's record, and a byte-aligned encoding depends on the bit it starts at, so a written entity cannot be moved. The exact size is asked only when the part is within twice the entity's full-update estimate of the limit.
- **Entities that would need a seventeenth part wait**, as the budget makes them wait (`note_starved`), and the accumulator puts them first next time.
- **The client acknowledges a tick only once every part of it has been applied**, so the acknowledgement stays four bytes, which every game's input packet has as a fixed prefix (`ACK_BYTES`). A tick with a part missing is never acknowledged; the next complete tick's acknowledgement resolves it as lost and the server re-sends what it carried, including what the parts that did arrive carried. That redundancy only follows a loss. A per-part acknowledgement would avoid it and change every game's bridge.
- **Superseding is by the newest tick any part of which has been read**, not the newest acknowledged: a part of an older tick arriving after a part of a newer one is dropped, because entities are not in the same part every tick (the order is the priority accumulator's) and it may carry an entity the newer part already moved. Only the first part of a tick feeds the clock, the arrival time and `DotNetStats.note_snapshot`; `snapshot_applied` fires once per part.
- **Mixed versions**: a client from before parts reads the first part to arrive, drops the others as repeats of its tick, and acknowledges the tick, which the server takes as all of it; the entities in the dropped parts stay stale until they change again. A client must not run an older dot-net than its server.
- `largest_part_bytes` and `snapshots_split` on the server's manager say how often it happens; `describe_lines()` prints both. One entity too big for `mtu` on its own is sent oversized and logged once as a WARN.

## Unchanged entities

**An entity with nothing to say is listed by id, not written.** Every relevant entity used to go out in every snapshot as its 24-bit id, a 6-bit behaviour count and a 6-bit property count per behaviour, even with no property in it: mg-buses-from-hell's steady snapshot was about 429 bytes for 88 entities, some 396 of them headers of entities that had not moved.

- **The tail**: after a part's entities, `UNCHANGED_TAIL_MARK` (8 bits, `0x0F`), the number of runs, then each run of consecutive ids as its gap from the end of the previous run and its length less one, all Elias gamma (zero is one bit), then the part trailer, always (`part 0 of 1` for an unsplit snapshot). A block of ids costs a few bits whatever its size; a scatter a few bits an entity. The tail goes at the end of the last part if it fits under `mtu`, else in a part of its own, else (sixteen parts already) not at all, and those entities miss one refresh as a starved one does.
- **The receiver tells the formats apart by length**: at least 16 bits after the entities is a tail (mark, runs, trailer); fewer is the format before it. Nothing in the header changes.
- **A listed entity is applied exactly as an empty body**: `DotNetBehaviour.apply_unchanged` runs the same rewind and `_net_state_applied(tick)` that `read_state` runs after reading nothing, the predictor reconciles a predicted one (and the client's inputs are acknowledged there), and the interpolator gets a sample at the tick for a remote one. So every game's per-snapshot bookkeeping (`last_state_tick`, game-hungario's relevance check, a redraw) means what it meant. Ignoring the list walked a held-still predicted entity 19.5 m off in `netcode_demo` (#17's shape).
- **Absence still means what it meant**: not relevant, starved, or in a part that was lost. An entity is listed only when it is relevant and served this snapshot, so one that leaves relevance is neither written nor listed and hears nothing, as before. Despawning is the spawner's reliable message, never absence.
- **An id the client does not hold is skipped**, which a body cannot be (it would need the declarations to step over). The whole list is read before any of it is applied, so a truncated list changes nothing and is a decode failure.
- **Only to a client that says it reads it.** The schema table carries a features varint after the types (`DotNetMessageRegistry.features`, an append an older reader never reaches), and the server lists only for a peer whose table has arrived naming `FEATURE_UNCHANGED_RUNS` (`peer_supports`, false until it arrives). Every other peer gets the format before. If the gate were ever wrong, an older client would read the mark as part 15 of 1 and refuse the snapshot as a bad trailer, never misread it.
- **A snapshot goes out every snapshot tick, even with nothing in it** (six bytes: tick and a zero count). It is the client's clock and its acknowledgement; before the list a peer with nothing relevant was sent nothing.
- `unchanged_listed` and `unchanged_bytes_saved` on the server's manager; `describe_lines()` prints both. A host whose client never routes its schema to the server (a test loopback wired after `start()`) keeps the old format without a sign beyond those staying zero.

## The input lead

**A snapshot part may end with how early the client's commands are reaching the server**, for its clock to steer by ([timelines.md](timelines.md#the-input-lead-the-server-reports)).

- **After a tail's trailer**: the least arrival lead of the period and the input tick it was measured on less the snapshot's tick, twelve bits each, signed. A part that has no unchanged list carries an empty one (the mark, zero runs, the trailer: 17 bits), so a part with a lead always has the tail form and the receiver reads it when at least 24 bits follow the trailer; anything else there is under a byte of padding. 41 bits a part at most.
- **In every part of the snapshot**, so a lost part does not lose it; the client takes the same report more than once and it changes nothing. A peer that sent nothing new in the period gets none.
- **Only to a client whose schema says `FEATURE_INPUT_LEAD`** (`peer_supports`). Every other peer gets the format before, byte for byte (`netcode_demo`: an empty snapshot to the old client is still six bytes). A client from before reads its features and never names the bit.
- **The client to server direction is unchanged**: the four-byte acknowledgement every game's input packet starts with (`ACK_BYTES`) and the input batch after it. The server measures arrival in `DotNetInput.Buffer.push`, which every bridge already calls.
- `input_leads_sent` on the server's manager, and the clock's `describe_lead()` on a client (`net_status` prints both).
