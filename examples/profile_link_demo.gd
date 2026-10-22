extends Node

## Exercises [DotNetProfileLink]: a server and two clients, one process, payloads pumped by hand.
##
## [codeblock]
## godot --headless --path . res://examples/profile_link_demo.tscn
## [/codeblock]

const SECTIONS := 6
const CHECKS := 39
const BASE := "user://profile_link_demo"

var _passed := 0
var _failed := 0
var _sections := 0
var _queue: Array = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	print("dot-net profile link demo")
	_wipe()
	_test_command_route()
	_test_refused()
	_test_broadcast()
	_test_late_joiner()
	_test_bad_requests()
	_test_off_by_default()
	_wipe()
	_current = {}
	for world: Dictionary in _open:
		world["link"].release()
		for c: Dictionary in world["clients"].values():
			if c["link"] != null:
				c["link"].release()
	_open.clear()
	for child in get_children():
		child.free()
	print("\n%d sections, %d passed, %d failed" % [_sections, _passed, _failed])
	if _sections != SECTIONS or _passed + _failed != CHECKS:
		print("ERROR: %d sections, %d checks ran; expected %d and %d." % [_sections, _passed + _failed, SECTIONS, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _mk_set() -> DotProfileSet:
	var s := DotProfileSet.create("dot-npc", "mygame", "npc", [
		DotProfileSet.field("health", "int", 100, {"min": 1, "max": 1000}),
		DotProfileSet.field("speed", "float", 3.0, {"min": 0.0, "max": 50.0}),
	])
	s.roots = PackedStringArray([BASE])
	return s


func _wipe() -> void:
	for f in ["addons/dot-npc/npc/zombie.yml"]:
		DirAccess.remove_absolute(BASE + "/" + f)


## A server whose peers 11 (admin) and 12 (player) are connected, and `clients` clients.
func _world(clients: Array = [11, 12]) -> Dictionary:
	_wipe()
	DirAccess.make_dir_recursive_absolute(BASE + "/addons/dot-npc/npc")
	var f := FileAccess.open(BASE + "/addons/dot-npc/npc/zombie.yml", FileAccess.WRITE)
	f.store_string("health: 50\n")
	f.close()
	_queue.clear()
	var w := {"clients": {}}
	_current = w
	_open.append(w)
	var srv := _manager(true, 1, "s%d" % Time.get_ticks_usec())
	var rt := DotProfileRuntime.new()
	rt.add_set(_mk_set())
	rt.save_root = BASE
	rt.permit = func(actor: Variant, _flag: String) -> bool: return actor == "uid-admin"
	var link := DotNetProfileLink.attach(srv, rt)
	link.actor_of = func(peer: int) -> Variant: return "uid-admin" if peer == 11 else "uid-%d" % peer
	srv.send_fn = func(peer: int, payload: PackedByteArray, _d: int) -> void:
		for c in _clients_of(w):
			if peer == 0 or peer == c:
				_queue.append([c, 1, payload])
	w["server"] = srv
	w["rt"] = rt
	w["link"] = link
	srv.start()
	for id in clients:
		_join(w, id)
	_pump()
	return w


func _clients_of(w: Dictionary) -> Array:
	return (w["clients"] as Dictionary).keys()


func _manager(is_server: bool, id: int, scope: String) -> DotNetManager:
	var m := DotNetManager.new()
	m.is_server = is_server
	m.local_peer_id = id
	m.auto_tick = false
	m.config_file = ""
	m.service_scope = StringName(scope)
	add_child(m)
	m.setup()
	return m


func _join(w: Dictionary, id: int, attach: bool = true) -> Dictionary:
	var m := _manager(false, id, "c%d_%d" % [id, Time.get_ticks_usec()])
	var rt := DotProfileRuntime.new()
	rt.add_set(_mk_set())
	var link: DotNetProfileLink = DotNetProfileLink.attach(m, rt) if attach else null
	var replies: Array = []
	if link != null:
		link.reply.connect(func(ok: bool, text: String) -> void: replies.append([ok, text]))
	m.send_fn = func(_peer: int, payload: PackedByteArray, _d: int) -> void:
		_queue.append([1, id, payload])
	m.start()
	var entry := {"m": m, "rt": rt, "link": link, "replies": replies}
	(w["clients"] as Dictionary)[id] = entry
	var srv: DotNetManager = w["server"]
	srv.add_peer(id)
	if link != null:
		(w["link"] as DotNetProfileLink).peer_joined(id)
	return entry


func _pump() -> void:
	var guard := 0
	while not _queue.is_empty() and guard < 1000:
		guard += 1
		var item: Array = _queue.pop_front()
		var to: int = item[0]
		var w: Dictionary = _current
		if to == 1:
			(w["server"] as DotNetManager).receive(item[2], item[1])
		elif (w["clients"] as Dictionary).has(to):
			((w["clients"] as Dictionary)[to]["m"] as DotNetManager).receive(item[2], 1)


var _current: Dictionary = {}
var _open: Array = []


func _begin(title: String, clients: Array = [11, 12]) -> Dictionary:
	_section(title)
	return _world(clients)


func _req(op: String, key: String = "", value: Variant = null) -> Dictionary:
	return DotProfileRuntime.make_request(op, "npc", "zombie", key, value)


func _health(rt: DotProfileRuntime) -> Variant:
	var res := (rt.get("_sets") as Dictionary)["npc"].load_profile("zombie") as DotResult
	return res.value.get_value("health")


func _test_command_route() -> void:
	var w := _begin("an admin's request reaches the server and is answered")
	var admin: Dictionary = w["clients"][11]
	var res: DotResult = admin["link"].submit(_req("set", "health", 400))
	_check(res.ok, "the request was sent")
	_check(_health(w["rt"]) == 50, "nothing is applied before the server has read it")
	_pump()
	_check(_health(w["rt"]) == 400, "the server applied it")
	_check(w["rt"].revision("npc", "zombie") == 1, "revision 1")
	_check(admin["replies"].size() == 1 and admin["replies"][0][0] == true, "the requester was told it worked")
	var local: DotResult = w["link"].submit(_req("set", "speed", 7))
	_check(not local.ok and local.error.code == DotError.CODE_FORBIDDEN, "the server's own console is refused as a non-admin actor")
	_check(w["rt"].revision("npc", "zombie") == 1, "and changed nothing")
	w["link"].local_actor = "uid-admin"
	_check(w["link"].submit(_req("set", "speed", 7)).ok and w["rt"].revision("npc", "zombie") == 2, "and as an admin it applies")


func _test_refused() -> void:
	var w := _begin("a non-admin is refused and told so")
	var player: Dictionary = w["clients"][12]
	player["link"].submit(_req("set", "health", 999))
	_pump()
	_check(_health(w["rt"]) == 50 and w["rt"].revision("npc", "zombie") == 0, "nothing changed")
	_check(player["replies"].size() == 1 and player["replies"][0][0] == false, "the player got a refusal")
	_check((w["clients"][11]["replies"] as Array).is_empty(), "the admin was not told")
	_check(_health(w["clients"][11]["rt"]) == 50, "no client saw a row")


func _test_broadcast() -> void:
	var w := _begin("an edit reaches a second client")
	w["clients"][11]["link"].submit(_req("set", "health", 321))
	_pump()
	var other: Dictionary = w["clients"][12]
	_check(_health(other["rt"]) == 321, "the other client has the value")
	_check(_health(w["clients"][11]["rt"]) == 321, "and so does the requester")
	_check(other["rt"].revision("npc", "zombie") == 1, "at the server's revision")
	var seen: Array = []
	other["rt"].profile_changed.connect(func(k: String, i: String, r: int) -> void: seen.append([k, i, r]))
	w["clients"][11]["link"].submit(_req("set", "speed", 9.5))
	_pump()
	_check(seen == [["npc", "zombie", 2]], "profile_changed fired on the client")
	_check(is_equal_approx(float(other["rt"].get("_sets")["npc"].load_profile("zombie").value.get_value("speed")), 9.5), "a float stayed a float")
	w["clients"][11]["link"].submit(_req("reset"))
	_pump()
	_check(_health(other["rt"]) == 50, "a reset reaches the client too")


func _test_late_joiner() -> void:
	var w := _begin("a late joiner gets a snapshot", [11])
	w["clients"][11]["link"].submit(_req("set", "health", 640))
	_pump()
	var late := _join(w, 13)
	_check(_health(late["rt"]) == 50, "before the pump it has nothing")
	_pump()
	_check(_health(late["rt"]) == 640, "after it holds the current value")
	_check(late["rt"].revision("npc", "zombie") == 1, "at the current revision")
	var quiet := _join(w, 14)
	late["rt"].begin_sync()
	_check(_health(late["rt"]) == 50 and late["rt"].revision("npc", "zombie") == 0, "begin_sync forgets before a reconnect")
	_check(_health(quiet["rt"]) == 50, "a client joining after pumping nothing is unchanged until pumped")


func _test_bad_requests() -> void:
	var w := _begin("bad requests return errors and never crash", [11])
	var link: DotNetProfileLink = w["link"]
	var cases := {
		"not json": "{{{", "a list": "[1,2]", "empty": "", "a number": "5",
		"unknown op": DotNetProfileLink.encode_body(_req("explode")),
		"bad value": DotNetProfileLink.encode_body(_req("set", "health", "lots")),
		"out of range": DotNetProfileLink.encode_body(_req("set", "health", 99999)),
		"unknown key": DotNetProfileLink.encode_body(_req("set", "wings", 2)),
		"object smuggled": '{"type":"Dictionary","args":[["op","value"],["set",{"type":"Object","class":"Node","props":{}}]]}',
	}
	for name in cases:
		var res := link.handle_from_peer(11, cases[name])
		_check(not res.ok, "%s is a DotResult error" % name)
	_pump()
	_check(w["clients"][11]["replies"].size() == cases.size(), "every one was answered")
	_check(_health(w["rt"]) == 50, "nothing was applied")
	var tiny := link.handle_from_peer(11, DotNetProfileLink.encode_body({}))
	_check(not tiny.ok, "an empty request is refused")


func _test_off_by_default() -> void:
	var w := _begin("a peer without the link plays on", [11])
	var bare := _join(w, 15, false)
	_pump()
	w["clients"][11]["link"].submit(_req("set", "health", 77))
	_pump()
	_check(_health(w["rt"]) == 77, "the server still applies edits")
	_check(_health(bare["rt"]) == 50, "a client that did not attach just does not see them")
	_check(bare["link"] == null, "attach is the only switch")
	var sealed := DotNetManager.new()
	sealed.config_file = ""
	add_child(sealed)
	sealed.setup()
	sealed.messages.seal()
	_check(DotNetProfileLink.attach(sealed, DotProfileRuntime.new()) == null, "attaching after the schema sealed returns null")


func _section(title: String) -> void:
	_sections += 1
	print("\n-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
