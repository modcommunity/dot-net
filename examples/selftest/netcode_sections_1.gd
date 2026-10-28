extends "netcode_tests.gd"

## Sections of netcode_demo.gd, moved unchanged; part 1 of 7.


# --- Messages --------------------------------------------------------------

func _test_messages() -> void:
	print("")
	print("[messages]")

	var registry := DotNetMessageRegistry.new()

	_check(
		"register",
		registry.register(&"demo.chat", ChatMessage).ok
	)
	_check(
		"register second",
		registry.register(
			&"demo.notice", ServerNotice,
			DotNetMessage.Delivery.RELIABLE,
			DotNetMessage.Direction.TO_CLIENT
		).ok
	)
	_check(
		"duplicate refused",
		not registry.register(&"demo.chat", ChatMessage).ok
	)

	registry.seal()
	_check("sealed", registry.is_sealed())
	_check(
		"register after seal refused",
		not registry.register(&"demo.late", ChatMessage).ok
	)

	# Ids come from sorted names, so two peers agree without negotiating.
	var other := DotNetMessageRegistry.new()
	other.register(&"demo.notice", ServerNotice, DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.TO_CLIENT)
	other.register(&"demo.chat", ChatMessage)
	other.seal()

	_check(
		"ids agree regardless of registration order",
		registry.id_of(&"demo.chat") == other.id_of(&"demo.chat")
	)
	_check(
		"schema hashes match",
		registry.schema_hash() == other.schema_hash()
	)

	var third := DotNetMessageRegistry.new()
	third.register(&"demo.chat", ChatMessage)
	third.seal()
	_check(
		"different schema hashes differ",
		registry.schema_hash() != third.schema_hash()
	)

	# Round trip.
	var message := ChatMessage.new()
	message.text = "hello from the client"

	var w := DotNetWriter.new()
	_check("encode", registry.encode(message, w).ok)

	var decoded := registry.decode(w.to_reader(), 5, true)
	_check("decode", decoded.ok)
	_check(
		"payload survived",
		decoded.ok and (decoded.value as ChatMessage).text == "hello from the client"
	)
	_check(
		"sender is the transport's view",
		decoded.ok and (decoded.value as DotNetMessage).sender_peer_id == 5
	)

	# A client must not be able to send a server-to-client message.
	var notice := ServerNotice.new()
	notice.notice = "you have been kicked"
	var nw := DotNetWriter.new()
	registry.encode(notice, nw)

	var violation := registry.decode(nw.to_reader(), 7, true)
	_check(
		"direction violation refused",
		not violation.ok and violation.code() == DotError.CODE_FORBIDDEN
	)

	# The same message is fine going the other way.
	var legitimate := registry.decode(nw.to_reader(), 1, false)
	_check("server-to-client accepted on a client", legitimate.ok)

	# Validation runs before the handler sees it.
	var empty := ChatMessage.new()
	empty.text = "   "
	var ew := DotNetWriter.new()
	registry.encode(empty, ew)
	_check(
		"validation rejects",
		not registry.decode(ew.to_reader(), 3, true).ok
	)

	# An unknown id is a type this end does not have -- what a peer one build ahead
	# sends. It is skipped, by its framed length, and is not an error.
	var bogus := DotNetWriter.new()
	bogus.write_uint(4000, DotNetMessageRegistry.ID_BITS)
	bogus.write_varint(0)
	var before := registry.skipped
	var unknown := registry.decode(bogus.to_reader(), 3, true)
	_check(
		"an unknown id is skipped rather than refused",
		unknown.ok and unknown.value == null and registry.skipped == before + 1
	)

	# A body claiming more bits than the payload holds is truncated, and that still is an
	# error: the length is what makes skipping possible, so it has to be believable.
	var short := DotNetWriter.new()
	short.write_uint(registry.id_of(&"demo.chat"), DotNetMessageRegistry.ID_BITS)
	short.write_varint(4000)
	_check(
		"a body longer than the payload is a parse failure",
		registry.decode(short.to_reader(), 3, true).code() == DotError.CODE_PARSE
	)

	# Dispatch.
	var received: Array[String] = []
	registry.on(&"demo.chat", func(m: DotNetMessage) -> void:
		received.append((m as ChatMessage).text))
	registry.dispatch(decoded.value)
	_check("dispatched to the handler", received.size() == 1)


## Two ends built from different sources: the point of deriving ids from names.
##
## "Old" registers less than "new". Old must skip what it does not have and carry on --
## mid-batch included -- a field appended to a shared type must cross in both directions,
## and a REQUIRED type one end lacks must be refused with a sentence rather than a
## decode error an hour later.
func _test_mismatched_schemas() -> void:
	print("")
	print("[mismatched schemas]")

	var old := DotNetMessageRegistry.new()
	old.register(&"demo.chat", ChatMessage)
	old.seal()

	var new := DotNetMessageRegistry.new()
	new.register(&"demo.chat", ChatMessageV2)
	new.register(&"demo.extra", ExtraMessage, DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.BOTH, false)
	new.seal()

	_check(
		"a type has the same wire id whatever else is registered",
		old.id_of(&"demo.chat") == new.id_of(&"demo.chat")
			and old.id_of(&"demo.chat") == DotNetMessageRegistry.wire_id_for(&"demo.chat")
	)
	_check(
		"an extra OPTIONAL type does not change the schema hash",
		old.schema_hash() == new.schema_hash()
	)

	# The tables cross, both ways, and neither end refuses.
	_check(
		"the old end adopts the new end's table",
		old.adopt_peer_schema(1, _schema_body(new.schema_payload()), false).ok
	)
	_check(
		"and the new end adopts the old end's",
		new.adopt_peer_schema(5, _schema_body(old.schema_payload()), true).ok
	)
	_check(
		"each knows what the other has",
		old.peer_has(1, &"demo.extra") and not new.peer_has(5, &"demo.extra")
	)

	# New sends [extra, chat, extra] in one batch. Old has no idea what an extra is.
	var batch := DotNetPacket.Batch.new(9)
	var e1 := ExtraMessage.new()
	e1.value = 1234
	batch.add(e1, 4)
	var line := ChatMessageV2.new()
	line.text = "still here"
	line.colour = 42
	batch.add(line, 16)
	batch.add(ExtraMessage.new(), 4)

	var encoded := DotNetPacket.encode_batch(batch, new)
	var skipped_before := old.skipped
	var decoded := DotNetPacket.decode_batch(encoded.value, old, 1, false)
	var got: Array = (decoded.value as Dictionary)["messages"] if decoded.ok else []
	_check(
		"the old end skips both unknown messages and keeps the one between them",
		decoded.ok and got.size() == 1 and old.skipped == skipped_before + 2
	)
	_check(
		"reading the fields it knows of a newer version of its own type",
		got.size() == 1 and (got[0] as ChatMessage).text == "still here"
	)

	# And the other way: an old chat into a new reader, whose appended field keeps its
	# default because the older sender never wrote it.
	var old_line := ChatMessage.new()
	old_line.text = "from the past"
	var ow := DotNetWriter.new()
	old.encode(old_line, ow)
	var into_new := new.decode(ow.to_reader(), 5, true)
	_check(
		"a newer reader gets the old fields",
		into_new.ok and (into_new.value as ChatMessageV2).text == "from the past"
	)
	_check(
		"and keeps its default for the field the old sender did not write (%s)"
			% (str((into_new.value as ChatMessageV2).colour) if into_new.ok else "-"),
		into_new.ok and (into_new.value as ChatMessageV2).colour == 7
	)

	# A REQUIRED type one end lacks. The old client meets a server that requires
	# demo.vital, in both of the places the check runs.
	var strict := DotNetMessageRegistry.new()
	strict.register(&"demo.chat", ChatMessageV2)
	strict.register(&"demo.vital", VitalMessage)
	strict.seal()

	_check(
		"a REQUIRED type changes the schema hash",
		strict.schema_hash() != old.schema_hash()
	)

	var refusals: Array = []
	strict.peer_refused.connect(func(peer: int, err: DotError) -> void: refusals.append([peer, err]))

	var at_server := strict.adopt_peer_schema(5, _schema_body(old.schema_payload()), true)
	_check(
		"the server refuses a client missing a type it requires",
		not at_server.ok and at_server.code() == DotError.CODE_VERSION
	)
	_check(
		"with a sentence a player can act on (%s)" % (at_server.error.message if not at_server.ok else ""),
		not at_server.ok and at_server.error.message == "This server's game needs a newer game client."
	)
	_check(
		"and the type named where an operator reads it",
		not at_server.ok and at_server.error.detail.contains("demo.vital")
	)
	_check("it says so on its signal", refusals.size() == 1 and int(refusals[0][0]) == 5)

	var at_client := old.adopt_peer_schema(1, _schema_body(strict.schema_payload()), false)
	_check(
		"and the client refuses it too, from its side (%s)" % (at_client.error.message if not at_client.ok else ""),
		not at_client.ok and at_client.error.message == "This server's game needs a newer game client."
	)

	# Nothing from a refused peer is handed to a game.
	var cw := DotNetWriter.new()
	var after := ChatMessageV2.new()
	after.text = "ignored"
	strict.encode(after, cw)
	var from_refused := old.decode(cw.to_reader(), 1, false)
	_check(
		"and nothing a refused peer sends is decoded",
		from_refused.ok and from_refused.value == null
	)

	# Forgetting the peer clears the refusal, so a reconnect is judged afresh.
	old.forget_peer(1)
	_check("forgetting a peer forgets its refusal", not old.is_refused(1) and not old.knows_peer(1))

	# The manager: a server announces as it adds a peer, the client as it starts, and a
	# refusal reaches the host on the manager's own signal.
	var s := DotNetManager.new()
	s.is_server = true
	s.auto_tick = false
	s.config_file = ""
	s.service_scope = &"schema_server"
	var c := DotNetManager.new()
	c.is_server = false
	c.local_peer_id = 3
	c.auto_tick = false
	c.config_file = ""
	c.service_scope = &"schema_client"
	add_child(s)
	add_child(c)
	s.setup()
	c.setup()
	s.messages.register(&"demo.chat", ChatMessageV2)
	s.messages.register(&"demo.vital", VitalMessage)
	c.messages.register(&"demo.chat", ChatMessage)

	var wire: Array = []
	s.send_fn = func(peer: int, payload: PackedByteArray, _d: int) -> void: wire.append([1, peer, payload])
	c.send_fn = func(peer: int, payload: PackedByteArray, _d: int) -> void: wire.append([3, peer, payload])

	var manager_refusals: Array = []
	s.peer_schema_refused.connect(func(peer: int, err: DotError) -> void: manager_refusals.append([peer, err.message]))

	s.start()
	c.start()
	s.add_peer(3)

	_check("both ends announced a table (%d payloads)" % wire.size(), wire.size() == 2)

	for w in wire:
		if int(w[0]) == 1:
			c.receive(w[2], 1)
		else:
			s.receive(w[2], 3)

	_check(
		"the server's manager reports the client it cannot play with",
		manager_refusals.size() == 1 and int(manager_refusals[0][0]) == 3
	)
	_check(
		"and a refused schema is not counted as a decode failure",
		s.stats.decode_failures == 0
	)

	s.stop()
	c.stop()
	remove_child(s)
	remove_child(c)
	s.free()
	c.free()


# --- Clock -----------------------------------------------------------------

func _test_clock() -> void:
	print("")
	print("[clock]")

	var authority := DotNetClock.new(60, true)
	var ticks := authority.advance(1.0 / 60.0 * 3.0)
	_check("advances by whole ticks", ticks == 3)
	_check("tick advanced", authority.tick == 3)

	# A long stall must not produce an unbounded catch-up burst.
	var stalled := DotNetClock.new(60, true)
	var burst := stalled.advance(2.0, 8)
	_check("catch-up is bounded", burst == 8)

	var follower := DotNetClock.new(60, false)
	_check("starts unsynced", not follower.is_synced())

	# First sample adopts outright.
	follower.sync_from_server(1000, 100.0)
	_check("syncs on the first sample", follower.is_synced())

	# The client must run AHEAD of the server, or every input arrives late.
	_check(
		"input timeline leads the server (%d vs %d)"
			% [follower.tick, follower.server_tick()],
		follower.tick > follower.server_tick()
	)

	# Half of a 100 ms round trip at 60 Hz is 3 ticks.
	_check(
		"server estimate accounts for one-way latency",
		follower.server_tick() >= 1002 and follower.server_tick() <= 1004
	)

	# Render must be behind the server, or there is nothing to interpolate between.
	_check("render tick lags the server", follower.render_tick(4) < follower.server_tick())

	# Small drift corrects by changing tick length, not by jumping. One tick behind is
	# inside the margin: a command still lands in time, so nothing is lost by smoothing.
	var before := follower.tick
	follower.sync_from_server(1001, 100.0)
	_check("small drift does not snap", absi(follower.tick - before) < 5)
	_check("drift correction applied", absf(follower.drift_percent()) > 0.0)

	# A huge error is not drift; it must snap.
	follower.sync_from_server(50000, 100.0)
	_check("large error snaps", follower.tick > 49000)

	# [b]The threshold is a DURATION, and every check above runs at the rate it was
	# written as a tick count for.[/b] 60 ticks is one second at 60 Hz and 0.47 s at 128,
	# so a 128-tick server -- the rate this genre runs and the rate g2gfast ships --
	# snapped on any half-second hitch: a map change, a stalled frame, a browser tab
	# doing layout. A snap discards everything predicted, so the world jumps, and it
	# jumped only on the one game nothing was tested at.
	var fast := DotNetClock.new(128, false)
	fast.sync_from_server(10000, 0.0)
	fast.sync_from_server(10000, 20.0)

	var fast_before := fast.tick
	# Half a second AHEAD: 64 ticks at 128. A client ahead of its target only adds input
	# latency, and stepping back would re-stamp ticks already sent, so it is drift.
	fast.sync_from_server(fast.server_tick() - 64, 20.0)
	_check(
		"a client half a second ahead at 128 ticks drifts back, not a snap",
		absi(fast.tick - fast_before) < 5
	)

	# [b]Half a second BEHIND is not drift, and smoothing it was the bug.[/b] That is what
	# a hitch does — the engine drops every physics step past eight in a frame, so the
	# clock loses the stall's length — and a client behind its target stamps every
	# command for a tick the server has already simulated. At 5% that took ten seconds at
	# 128 ticks, every command of them discarded: a browser's first connect, where every
	# load and shader compile is a stall, was a player who could not steer until the
	# clock crawled back. Armed: smoothing this leaves the clock 60 ticks short.
	var behind := DotNetClock.new(128, false)
	behind.sync_from_server(10000, 0.0)
	behind.sync_from_server(10000, 20.0)
	var lead := behind.tick - behind.server_tick()
	behind.sync_from_server(behind.server_tick() + 64, 20.0)
	_check(
		"a client half a second BEHIND catches up at once (%d ahead of the server)"
			% (behind.tick - behind.server_tick()),
		behind.tick - behind.server_tick() == lead
	)

	# Two seconds is a different session, at any rate.
	var before_snap := behind.tick
	behind.sync_from_server(behind.server_tick() + 256, 20.0)
	_check("and two seconds still snaps", absi(behind.tick - before_snap) > 200)

	# The same, at 60.
	var slow := DotNetClock.new(60, false)
	slow.sync_from_server(10000, 0.0)
	slow.sync_from_server(10000, 20.0)
	var slow_before := slow.tick
	slow.sync_from_server(slow.server_tick() - 30, 20.0)
	_check(
		"half a second ahead at 60 ticks is drift too, as it always was",
		absi(slow.tick - slow_before) < 5
	)

	_check(
		"the threshold is one second whatever the rate",
		fast.snap_threshold_ticks() == 128 and slow.snap_threshold_ticks() == 60
	)

	# Jitter must widen the margin, or a jittery connection loses inputs.
	var jittery := DotNetClock.new(60, false)
	for i in range(20):
		jittery.sync_from_server(100 + i, 50.0 + float(i % 2) * 80.0)
	_check("jitter measured", jittery.jitter_ms() > 5.0)


func _replication_wire_round_trip(config: DotNetConfig, second: DotNetIdentity, movement: Movement) -> void:
	# Round trip through the wire.
	var receiver := _make_entity(&"player", 7)
	add_child(receiver.get_parent())
	var client_registry := DotNetRegistry.new(false, 2)
	client_registry.register(receiver, second.net_id, 0, config)

	movement.position = Vector3(12.0, 3.0, -4.0)
	movement.health = 55
	movement.grounded = false

	var state := DotNetWriter.new()
	movement.write_state(state, movement.collect_dirty(7, true), 7)

	var applied := (receiver.behaviours[0] as Movement).read_state(
		state.to_reader(), 0
	)
	_check("state applied", applied.ok)

	var received := receiver.behaviours[0] as Movement
	_check(
		"position replicated",
		received.position.distance_to(Vector3(12.0, 3.0, -4.0)) < 0.05
	)
	_check("int replicated exactly", received.health == 55)
	_check("bool replicated", received.grounded == false)

	# Owner-only properties must not reach observers.
	var secret := movement.find_var(&"health")
	secret.audience = DotNetVar.Audience.OWNER
	_check("owner sees owner-only", secret.visible_to(7, 7))
	_check("observer does not", not secret.visible_to(9, 7))
	secret.audience = DotNetVar.Audience.EVERYONE


# --- Replication -----------------------------------------------------------

func _test_replication() -> void:
	_sections_entered += 1
	print("")
	print("[replication]")

	var config := DotNetConfig.new()

	var registry := DotNetRegistry.new(true, 1)
	var identity := _make_entity(&"player", 7)
	add_child(identity.get_parent())

	var registered := registry.register(identity, 0, 0, config)
	_check("registered", registered.ok)
	_check("id allocated", identity.net_id > 0)
	_check("found by id", registry.get_identity(identity.net_id) == identity)
	_check("behaviours collected", identity.behaviours.size() == 1)
	_check("behaviour bound", identity.behaviours[0].is_bound())
	_check("owner tracked", registry.owned_by(7).size() == 1)

	# Ids must never be reused: a snapshot in flight for a dead entity must not be
	# applied to a live one.
	var first_id := identity.net_id
	registry.unregister(first_id)
	var second := _make_entity(&"player", 7)
	add_child(second.get_parent())
	registry.register(second, 0, 0, config)
	_check("ids are not reused", second.net_id != first_id)
	_check("despawn is remembered", registry.was_recently_removed(first_id))

	# Dirty tracking.
	var movement := second.behaviours[0] as Movement
	var dirty := movement.collect_dirty(7, false)
	_check("everything dirty initially", dirty.size() == 4)

	var w := DotNetWriter.new()
	movement.write_state(w, dirty, 7)
	_check("nothing dirty after sending", movement.collect_dirty(7, false).is_empty())

	movement.position = Vector3(5, 0, 5)
	_check("change marks dirty", movement.collect_dirty(7, false).size() == 1)

	# Epsilon suppresses noise below the threshold.
	movement.velocity += Vector3(0.001, 0, 0)
	var after_noise := movement.collect_dirty(7, false)
	var velocity_dirty := false
	for declaration in after_noise:
		if declaration.property == &"velocity":
			velocity_dirty = true
	_check("epsilon suppresses noise", not velocity_dirty)

	movement.velocity += Vector3(1.0, 0, 0)
	var after_real := movement.collect_dirty(7, false)
	velocity_dirty = false
	for declaration in after_real:
		if declaration.property == &"velocity":
			velocity_dirty = true
	_check("real change passes epsilon", velocity_dirty)

	_replication_wire_round_trip(config, second, movement)

	await get_tree().process_frame
	_sections_completed += 1


## The render timeline moves between packets, and a late packet does not pull it back.
func _check_render_timeline() -> void:
	# --- the render timeline has to move between packets ----------------------
	#
	# `server_tick()` is what `render_tick()` — and therefore every interpolated position
	# — is derived from. An estimate that only moved when a snapshot arrived would make
	# the rendered tick a step function of arrivals: the interpolator would produce a new
	# value on the frames a packet happened to land on and the same value on every frame
	# in between, which is the 20 Hz stepping interpolation exists to remove.
	var clock := DotNetClock.new(60, false)
	clock.adaptive_margin = false
	clock.sync_from_server(1000, 0.0)

	var anchored := clock.server_tick()
	_check("the estimate is anchored by a sample (%d)" % anchored, anchored == 1000)

	# Six ticks of local time, no packet.
	for _i in range(6):
		clock.advance(1.0 / 60.0)

	_check(
		"and advances between them (%d -> %d)" % [anchored, clock.server_tick()],
		clock.server_tick() > anchored
	)
	_check(
		"at the tick rate (%d)" % (clock.server_tick() - anchored),
		clock.server_tick() == anchored + 6
	)
	_check(
		"so the render tick follows it",
		clock.render_tick(2) == clock.server_tick() - 2
	)

	# A sample moves it TO the sample, never by it -- and only forward, at once.
	clock.sync_from_server(1010, 0.0)
	_check(
		"a quicker packet moves it forward to the sample, not by it (%d)" % clock.server_tick(),
		clock.server_tick() == 1010
	)

	# [b]A late packet is not the server going back in time.[/b] It was: every sample
	# re-anchored the timeline absolutely, so on a link whose packets take 30..80 ms the
	# render timeline went back and forth with each one -- measured through a real relay
	# on ENet, 35 times backwards in ten seconds by up to 3.9 ticks.
	clock.sync_from_server(1004, 0.0)
	_check(
		"one late packet does not pull it back (%d)" % clock.server_tick(),
		clock.server_tick() == 1010
	)
	# A frame apart: a burst read in one frame counts once (see the dropped-time section).
	for _i in range(DotNetClock.SETTLE_SAMPLES):
		var _none := clock.advance(0.0001)
		clock.sync_from_server(1004, 0.0)
	_check(
		"a whole window of them does, by one tick (%d)" % clock.server_tick(),
		clock.server_tick() == 1009
	)

	_check_render_timeline_jitter()


func _test_interest() -> void:
	print("")
	print("[interest]")

	_check("the stock strategies are thread-safe, a subclass is not unless it says so",
		DotNetInterestDistance.new().is_thread_safe() and DotNetInterestGrid.new().is_thread_safe()
		and DotNetInterestAll.new().is_thread_safe() and not PlainDistance.new().is_thread_safe())

	var config := DotNetConfig.new()
	var context := {"tick": 0, "config": config}

	var observer := _make_entity(&"player", 1)
	add_child(observer.get_parent())
	(observer.entity as Node3D).global_position = Vector3.ZERO
	observer.net_id = 1

	var near := _make_entity(&"prop", 0)
	add_child(near.get_parent())
	(near.entity as Node3D).global_position = Vector3(10, 0, 0)
	near.net_id = 2

	var far := _make_entity(&"prop", 0)
	add_child(far.get_parent())
	(far.entity as Node3D).global_position = Vector3(5000, 0, 0)
	far.net_id = 3

	var beacon := _make_entity(&"objective", 0)
	add_child(beacon.get_parent())
	(beacon.entity as Node3D).global_position = Vector3(9000, 0, 0)
	beacon.always_relevant = true
	beacon.net_id = 4

	var all: Array[DotNetIdentity] = [observer, near, far, beacon]

	var distance := DotNetInterestDistance.new()
	distance.radius = 100.0
	distance.evaluation_interval_sec = 0.0

	var relevant := distance.relevant_for(observer, all, 1, context)
	var ids := {}
	for identity in relevant:
		ids[identity.net_id] = true

	_check("near entity included", ids.has(2))
	_check("far entity excluded", not ids.has(3))
	_check("always_relevant included regardless of distance", ids.has(4))
	_check("observer's own entity included", ids.has(1))

	_check_interest_thinning(config, observer, all)

	# The grid must agree with the brute-force answer — that is the whole
	# correctness requirement for a spatial index.
	var grid := DotNetInterestGrid.new()
	grid.radius = 100.0
	grid.cell_size = 64.0
	grid.evaluation_interval_sec = 0.0
	grid._prepare(all, context)

	var grid_relevant := grid.relevant_for(observer, all, 1, context)
	var grid_ids := {}
	for identity in grid_relevant:
		grid_ids[identity.net_id] = true

	_check("grid agrees with distance", grid_ids.has(2) and not grid_ids.has(3))
	_check("grid keeps always_relevant", grid_ids.has(4))

	# The config's cell size reaches a grid the host assigned — a knob documented
	# from the first version and applied by nothing.
	var sized := DotNetManager.new()
	sized.name = "Sized"
	sized.is_server = true
	sized.auto_tick = false
	sized.config_file = ""
	var sized_config := DotNetConfig.new()
	sized_config.interest_cell_size = 48.0
	sized.config = sized_config
	var sized_grid := DotNetInterestGrid.new()
	sized.interest = sized_grid
	add_child(sized)
	sized.setup()
	_check("interest_cell_size reaches an assigned grid", sized_grid.cell_size == 48.0)
	sized.queue_free()

	_check_entity_caps()

	# The reason the cap goes through prioritise: a cut that drops what the
	# observer owns is the bug this family has already shipped once.
	var crowd: Array[DotNetIdentity] = [beacon]
	for i in range(20):
		crowd.append(_make_entity(&"prop", 0))
	var kept: Array[DotNetIdentity] = distance.prioritise(observer, crowd, 3, context)
	var kept_ids := {}
	for identity in kept:
		kept_ids[identity.net_id] = true
	_check("a tight cap keeps always_relevant", kept.size() == 3 and kept_ids.has(beacon.net_id))

	# "All" includes everything, which is what makes it the wrong default for a
	# competitive game.
	var everything := DotNetInterestAll.new()
	_check(
		"all strategy includes the far entity",
		everything.relevant_for(observer, all, 1, context).size() == 4
	)

	# Prioritisation must keep always_relevant when the cap bites.
	var capped := distance.prioritise(observer, all, 2, context)
	var capped_ids := {}
	for identity in capped:
		capped_ids[identity.net_id] = true
	_check("cap applied", capped.size() == 2)
	_check("always_relevant survives the cap", capped_ids.has(4))

	# --- what a cached answer must never drop ---------------------------------
	#
	# The cache holds which entities were relevant at one instant. An entity spawned
	# since is in nobody's cached set, so an observer would not receive its own new
	# entity — nor an always-relevant one — until the cache expired.
	#
	# [b]That window is not small and on some hosts it never closes.[/b] In a game where
	# players respawn, split or fire projectiles it is a quarter of a second of an entity
	# that exists only by prediction; and on a host that ticks faster than the wall clock
	# — which is every headless test and every fast-forwarded replay — the age never
	# reaches the interval and the entity is never sent at all. The position still looks
	# right the whole time, because the owner is predicting it, so the symptom is only in
	# what cannot be predicted: mass, health, ammunition, a team change.
	var cached := DotNetInterestDistance.new()
	cached.radius = 100.0
	cached.evaluation_interval_sec = 5.0

	# Populate the cache with the world as it is now.
	cached.relevant_for(observer, all, 1, context)

	var newborn := _make_entity(&"player", 1)
	add_child(newborn.get_parent())
	(newborn.entity as Node3D).global_position = Vector3(4000, 0, 0)
	newborn.net_id = 5

	var newborn_beacon := _make_entity(&"objective", 0)
	add_child(newborn_beacon.get_parent())
	(newborn_beacon.entity as Node3D).global_position = Vector3(8000, 0, 0)
	newborn_beacon.always_relevant = true
	newborn_beacon.net_id = 6

	var grown: Array[DotNetIdentity] = [
		observer, near, far, beacon, newborn, newborn_beacon
	]

	var after := cached.relevant_for(observer, grown, 1, context)
	var after_ids := {}
	for identity in after:
		after_ids[identity.net_id] = true

	_check("a cached answer still includes what the observer owns", after_ids.has(5))
	_check("and anything always relevant", after_ids.has(6))
	_check("without losing what it already had", after_ids.has(2))
	_check("or gaining what it should not", not after_ids.has(3))

	# Pinning must not grow the cache: an entry added to it would survive the expiry
	# that is supposed to re-evaluate it.
	(newborn.entity as Node3D).global_position = Vector3(4000, 0, 0)
	newborn.owner_peer_id = 99
	var repinned := cached.relevant_for(observer, grown, 1, context)
	var repinned_ids := {}
	for identity in repinned:
		repinned_ids[identity.net_id] = true
	_check(
		"and a pin is not remembered as if it had been evaluated",
		not repinned_ids.has(5)
	)

	# A custom strategy is a subclass and nothing else — the extensibility claim.
	var custom := TagInterest.new()
	var tagged := custom.relevant_for(observer, all, 1, context)
	var tagged_ids := {}
	for identity in tagged:
		tagged_ids[identity.net_id] = true
	_check("custom strategy filters by tag", tagged_ids.has(4) and not tagged_ids.has(2))
