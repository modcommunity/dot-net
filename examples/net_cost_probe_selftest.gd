extends Node

## DotNetCostProbe: silent without a profiler, forwards per message class when one records, and the manager's send and receive paths feed it.
## Run: [code]godot --headless --path . res://examples/net_cost_probe_selftest.tscn[/code]

const SECTIONS := 2
const CHECKS := 10

var _passed := 0
var _failed := 0
var _sections := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	print("dot-net cost probe self-test")
	_absent()
	_bound()
	print("%d sections, %d passed, %d failed" % [_sections, _passed, _failed])
	var bad := _sections != SECTIONS or _passed + _failed != CHECKS or _failed > 0
	if _sections != SECTIONS or _passed + _failed != CHECKS:
		print("ERROR: %d sections and %d checks ran, %d and %d expected" % [_sections, _passed + _failed, SECTIONS, CHECKS])
	get_tree().quit(1 if bad else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("   FAIL: ", what)


func _absent() -> void:
	_sections += 1
	print("-- no profiler")
	DotNetCostProbe.bind(null)
	DotNetCostProbe.note(&"x", DotNetCostProbe.OUT, 10)
	_check(not DotNetCostProbe.active(), "inactive without a profiler")
	_check(true, "note without a profiler does nothing and does not error")


func _bound() -> void:
	_sections += 1
	print("-- stand-in profiler")
	var src := GDScript.new()
	src.source_code = "extends RefCounted\nstatic var enabled := false\nstatic var log := []\nstatic func add(cls, dir, bytes):\n\tlog.append([cls, dir, bytes])\n"
	src.reload()
	DotNetCostProbe.bind(src)
	DotNetCostProbe.note(&"a", DotNetCostProbe.OUT, 5)
	_check(src.get(&"log").is_empty(), "not forwarded while the profiler is off")
	src.set(&"enabled", true)
	_check(DotNetCostProbe.active(), "active while recording")
	DotNetCostProbe.note(&"a", DotNetCostProbe.OUT, 5)
	_check(src.get(&"log") == [[&"a", 1, 5]], "forwarded with class, direction, bytes")

	var server := _manager(true, 1)
	var client := _manager(false, 2)
	var wire: Array = []
	server.send_fn = func(_peer: int, payload: PackedByteArray, _mode: int) -> void: wire.append(payload)
	var cls: Array = src.get(&"log")
	cls.clear()
	server.announce_schema(1)
	_check(cls.size() == 1 and cls[0][0] == &"schema" and cls[0][1] == DotNetCostProbe.OUT, "announce_schema reports class schema")
	client.receive(wire[0], 1)
	_check(cls.size() == 2 and cls[1][1] == DotNetCostProbe.IN, "receiving the schema reports an inbound message")
	src.set(&"enabled", false)
	DotNetCostProbe.bind(null)
	DotNetCostProbe.reset()
	_check(true, "reset looks the class up again")


func _manager(as_server: bool, peer_id: int) -> DotNetManager:
	var m := DotNetManager.new()
	m.is_server = as_server
	m.service_scope = &"server" if as_server else &"client"
	m.local_peer_id = peer_id
	m.auto_tick = false
	m.config_file = ""
	m.config = DotNetConfig.new()
	add_child(m)
	var res := m.setup()
	_check(res.ok, "manager setup")
	return m
