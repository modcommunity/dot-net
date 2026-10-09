extends Node

const Relay := preload("res://addons/dot_net/testing/dot_net_udp_relay.gd")

## The lossy UDP relay, checked against real sockets before anything is measured through it.
##
## [codeblock]
## godot --headless --path . res://examples/relay_demo.tscn
## [/codeblock]
##
## A tool that measures loss has to be shown to inject what it says it injects, or every
## number taken through it is a number about the tool. So: raw datagrams both ways, with the
## loss, delay window, duplication and reordering each measured at the far end rather than
## read off the relay's own counters; the seed shown to fix the fate of each datagram; and a
## real ENet pair through it, which is the reason it exists. The last section is also the
## family's only statement of fact about what ENet does with an unreliable packet in this
## engine: it is UNSEQUENCED, so a newer one can arrive first, and nothing sent unreliable
## may assume its order (see CLAUDE.md, "Real loss").

## Every check this suite makes, the last one included. See docs/testing.md.
const CHECKS := 28

const COUNT := 1000

var _failures: int = 0
var _checks: int = 0
var _sections_started: int = 0
var _sections_finished: int = 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	await _run()


func _run() -> void:
	_line("dot-net: the lossy UDP relay")
	_line("")

	await _section_datagrams()
	_section_seed()
	await _section_enet()

	_line("")
	_check("every section ran", _sections_finished == _sections_started,
		"%d/%d" % [_sections_finished, _sections_started])
	_check("every check ran", _checks + 1 == CHECKS, "%d of %d" % [_checks + 1, CHECKS])
	_line("")
	_line("%d checks, %d failed" % [_checks, _failures])
	await get_tree().process_frame
	get_tree().quit(1 if _failures > 0 else 0)


# --- 1. Raw datagrams ----------------------------------------------------------

## What arrived at one end: unique sequence numbers, copies, inversions and delays.
class Tally extends RefCounted:
	var seen: Dictionary = {}
	var copies: int = 0
	var inversions: int = 0
	var newest: int = -1
	var min_ms: float = INF
	var max_ms: float = 0.0
	var total: int = 0

	func take(bytes: PackedByteArray) -> void:
		total += 1
		var seq := bytes.decode_u32(0)
		var sent := bytes.decode_u64(4)
		var ms := float(Time.get_ticks_usec() - sent) / 1000.0
		min_ms = minf(min_ms, ms)
		max_ms = maxf(max_ms, ms)

		if seen.has(seq):
			copies += 1
		seen[seq] = true

		if seq < newest:
			inversions += 1
		newest = maxi(newest, seq)


static func _datagram(seq: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(12)
	out.encode_u32(0, seq)
	out.encode_u64(4, Time.get_ticks_usec())
	return out


func _section_datagrams() -> void:
	_sections_started += 1
	_line("1. datagrams both ways, measured at the far end")

	var server := PacketPeerUDP.new()
	_check("a server socket binds", server.bind(0, "127.0.0.1") == OK)

	var relay := Relay.new()
	relay.seed = 11
	relay.up.configure(0.2, 50.0, 25.0, 0.05)
	relay.down.configure(0.05, 30.0, 10.0)
	var started := relay.start(0, "127.0.0.1", server.get_local_port())
	_check("the relay listens", started.ok, str(started.error))

	var client := PacketPeerUDP.new()
	client.connect_to_host("127.0.0.1", relay.port())

	var at_server := Tally.new()
	var at_client := Tally.new()
	var reply_to := ""
	var reply_port := 0

	# Twenty a frame, so consecutive datagrams are well inside the 50 ms jitter window and
	# the jitter alone has to reorder them, as it does on a real path.
	var sent := 0
	while sent < COUNT:
		for i in range(20):
			client.put_packet(_datagram(sent))
			sent += 1
		await get_tree().process_frame
		while server.get_available_packet_count() > 0:
			var bytes := server.get_packet()
			reply_to = server.get_packet_ip()
			reply_port = server.get_packet_port()
			at_server.take(bytes)

	var deadline := Time.get_ticks_msec() + 400
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		while server.get_available_packet_count() > 0:
			at_server.take(server.get_packet())

	# And back down, to whatever address the relay forwards from -- which is the only one
	# the server ever learns, exactly as a real server behind a real relay would.
	server.set_dest_address(reply_to, reply_port)
	sent = 0
	while sent < COUNT:
		for i in range(20):
			server.put_packet(_datagram(sent))
			sent += 1
		await get_tree().process_frame
		while client.get_available_packet_count() > 0:
			at_client.take(client.get_packet())

	deadline = Time.get_ticks_msec() + 300
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		while client.get_available_packet_count() > 0:
			at_client.take(client.get_packet())

	var up_arrived := float(at_server.seen.size()) / float(COUNT)
	var down_arrived := float(at_client.seen.size()) / float(COUNT)

	_line("    up:   %d of %d arrived (%.1f%%), %d copies, %d reordered, delay %.1f..%.1f ms" % [
		at_server.seen.size(), COUNT, up_arrived * 100.0, at_server.copies,
		at_server.inversions, at_server.min_ms, at_server.max_ms])
	_line("    down: %d of %d arrived (%.1f%%), %d copies, %d reordered, delay %.1f..%.1f ms" % [
		at_client.seen.size(), COUNT, down_arrived * 100.0, at_client.copies,
		at_client.inversions, at_client.min_ms, at_client.max_ms])

	_check("up: about 80% arrive at 20% loss", up_arrived > 0.76 and up_arrived < 0.84,
		"%.3f" % up_arrived)
	_check("down: about 95% arrive at 5% loss", down_arrived > 0.93 and down_arrived < 0.975,
		"%.3f" % down_arrived)
	_check("up: about 5% of survivors arrive twice",
		at_server.copies > 20 and at_server.copies < 70, "%d" % at_server.copies)
	_check("down: none arrive twice when duplication is off", at_client.copies == 0,
		"%d" % at_client.copies)
	_check("a 50 ms jitter reorders datagrams sent 20 a frame", at_server.inversions > 50,
		"%d" % at_server.inversions)
	# 25 ms is the floor of the window; the ceiling has the poll interval and a frame of
	# the reader's own latency on top of 75.
	_check("up: no datagram beats the delay window", at_server.min_ms >= 24.5,
		"%.2f ms" % at_server.min_ms)
	_check("up: none is held far past it", at_server.max_ms < 75.0 + 40.0,
		"%.2f ms" % at_server.max_ms)
	_check("down: the window is its own", at_client.min_ms >= 19.5 and at_client.max_ms < 40.0 + 40.0,
		"%.1f..%.1f ms" % [at_client.min_ms, at_client.max_ms])

	var said := relay.describe()
	_check("the relay's own count agrees with the far end's",
		int(said["up"]["delivered"]) == at_server.total
			and int(said["down"]["delivered"]) == at_client.total,
		"up %s vs %d, down %s vs %d" % [said["up"]["delivered"], at_server.total,
			said["down"]["delivered"], at_client.total])
	_check("one client is one flow", relay.flow_count() == 1, "%d" % relay.flow_count())

	relay.stop()
	client.close()
	server.close()
	_line("")
	_sections_finished += 1


# --- 2. The seed ------------------------------------------------------------------

## The sequence numbers that survive 300 datagrams through a relay seeded [param seed],
## stepped by hand so every datagram reaches it before any is judged.
func _survivors(seed: int) -> PackedInt32Array:
	var server := PacketPeerUDP.new()
	server.bind(0, "127.0.0.1")

	var relay := Relay.new()
	relay.threaded = false
	relay.seed = seed
	relay.up.configure(0.3, 0.0, 0.0)
	relay.start(0, "127.0.0.1", server.get_local_port())

	var client := PacketPeerUDP.new()
	client.connect_to_host("127.0.0.1", relay.port())

	# Forty at a time: a few hundred datagrams at once overflow a loopback socket's receive
	# buffer, which is a loss the seed does not choose.
	var out := PackedInt32Array()
	for seq in range(300):
		client.put_packet(_datagram(seq))
		if seq % 40 == 39 or seq == 299:
			OS.delay_msec(3)
			relay.poll()
			relay.poll()
			OS.delay_msec(3)
			while server.get_available_packet_count() > 0:
				out.append(server.get_packet().decode_u32(0))
	out.sort()

	relay.stop()
	client.close()
	server.close()
	return out


func _section_seed() -> void:
	_sections_started += 1
	_line("2. a seed fixes which datagrams are lost")

	var first := _survivors(7)
	var again := _survivors(7)
	var other := _survivors(8)

	_check("about 70% survive 30% loss", first.size() > 180 and first.size() < 240,
		"%d of 300" % first.size())
	_check("the same seed loses the same datagrams", first == again,
		"%d vs %d" % [first.size(), again.size()])
	_check("another seed loses others", first != other)
	_line("")
	_sections_finished += 1


# --- 3. ENet through it -------------------------------------------------------------

func _section_enet() -> void:
	_sections_started += 1
	_line("3. a real ENet pair through 20% loss each way, 30..80 ms")

	if not ClassDB.class_exists("ENetMultiplayerPeer"):
		_line("    skipped: this build has no ENet")
		for i in range(11):
			_check("(skipped)", true)
		_sections_finished += 1
		return

	# Reached through ClassDB, as dot-core's transport does: a script that names the class
	# does not compile on the web template.
	var server_peer: Object = ClassDB.instantiate("ENetMultiplayerPeer")
	var err: int = server_peer.call("create_server", 0, 4)
	if err != OK:
		# Port 0 is not every engine's "any port" for ENet; take a fixed high one instead.
		err = server_peer.call("create_server", 27391, 4)
	_check("an ENet server listens", err == OK, error_string(err))
	var server_port := 27391
	var host: Object = server_peer.call("get_host")
	if host != null and host.has_method("get_local_port"):
		server_port = int(host.call("get_local_port"))

	var relay := Relay.new()
	relay.seed = 3
	relay.up.configure(0.2, 55.0, 25.0)
	relay.down.configure(0.2, 55.0, 25.0)
	relay.start(0, "127.0.0.1", server_port)

	var client_peer: Object = ClassDB.instantiate("ENetMultiplayerPeer")
	err = client_peer.call("create_client", "127.0.0.1", relay.port())
	_check("an ENet client is pointed at the relay", err == OK, error_string(err))

	var connected := false
	var deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline:
		server_peer.call("poll")
		client_peer.call("poll")
		if int(client_peer.call("get_connection_status")) == MultiplayerPeer.CONNECTION_CONNECTED:
			connected = true
			break
		await get_tree().process_frame

	_check("and connects through the loss", connected)

	if not connected:
		for i in range(8):
			_check("(not connected)", false)
		relay.stop()
		_sections_finished += 1
		return

	# Let the server see the peer.
	var client_id := 0
	deadline = Time.get_ticks_msec() + 3000
	while client_id == 0 and Time.get_ticks_msec() < deadline:
		server_peer.call("poll")
		client_peer.call("poll")
		while int(server_peer.call("get_available_packet_count")) > 0:
			server_peer.call("get_packet")
		var peers: Variant = (server_peer.call("get_host") as Object).call("get_peers")
		if peers is Array and not (peers as Array).is_empty():
			client_id = 2
		await get_tree().process_frame

	var reliable_got: Array[int] = []
	var unreliable_got: Array[int] = []
	var sent := 0
	const SEND := 300

	while sent < SEND:
		for i in range(6):
			for reliable in [true, false]:
				var bytes := PackedByteArray([1 if reliable else 0, 0, 0, 0, 0])
				bytes.encode_u32(1, sent)
				server_peer.set("transfer_mode",
					MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable
					else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
				server_peer.call("set_target_peer", 0)
				server_peer.call("put_packet", bytes)
			sent += 1
		server_peer.call("poll")
		client_peer.call("poll")
		_drain(client_peer, reliable_got, unreliable_got)
		await get_tree().process_frame

	deadline = Time.get_ticks_msec() + 5000
	while reliable_got.size() < SEND and Time.get_ticks_msec() < deadline:
		server_peer.call("poll")
		client_peer.call("poll")
		_drain(client_peer, reliable_got, unreliable_got)
		await get_tree().process_frame

	var in_order := true
	for i in range(reliable_got.size()):
		if reliable_got[i] != i:
			in_order = false
			break

	var unreliable_inversions := 0
	var newest := -1
	var unique := {}
	for seq in unreliable_got:
		if seq < newest:
			unreliable_inversions += 1
		newest = maxi(newest, seq)
		unique[seq] = true

	var said := relay.describe()
	_line("    relay: up %s, down %s" % [said["up"]["measured_loss"], said["down"]["measured_loss"]])
	_line("    reliable %d of %d, unreliable %d of %d, %d unreliable behind a newer one" % [
		reliable_got.size(), SEND, unique.size(), SEND, unreliable_inversions])

	_check("the relay really lost about a fifth each way",
		float(said["up"]["measured_loss"]) > 0.12 and float(said["down"]["measured_loss"]) > 0.12)
	_check("every reliable packet arrived", reliable_got.size() == SEND,
		"%d of %d" % [reliable_got.size(), SEND])
	_check("exactly once, and in the order sent", in_order)
	var arrived := float(unique.size()) / float(SEND)
	_check("about 80% of the unreliable ones arrived", arrived > 0.7 and arrived < 0.9,
		"%.3f" % arrived)
	_check("no unreliable packet arrived twice", unique.size() == unreliable_got.size(),
		"%d unique of %d" % [unique.size(), unreliable_got.size()])
	_check("and some arrived behind a newer one: Godot's ENet unreliable is UNSEQUENCED",
		unreliable_inversions > 0, "%d" % unreliable_inversions)
	_check("the client is still connected",
		int(client_peer.call("get_connection_status")) == MultiplayerPeer.CONNECTION_CONNECTED)
	_check("so is the server's end of it", client_id != 0)

	client_peer.call("close")
	server_peer.call("close")
	relay.stop()
	_line("")
	_sections_finished += 1


func _drain(peer: Object, reliable: Array[int], unreliable: Array[int]) -> void:
	while int(peer.call("get_available_packet_count")) > 0:
		var bytes: PackedByteArray = peer.call("get_packet")
		if bytes.size() < 5:
			continue
		if bytes[0] == 1:
			reliable.append(bytes.decode_u32(1))
		else:
			unreliable.append(bytes.decode_u32(1))


func _check(label: String, passed: bool, detail: String = "") -> void:
	_checks += 1
	if not passed:
		_failures += 1

	var suffix := ""
	if detail != "":
		suffix = " (%s)" % detail

	_line("  %s %s%s" % [label.rpad(60), "ok" if passed else "FAILED", suffix])


func _line(text: String) -> void:
	print(text)
