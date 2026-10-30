extends "netcode_sections_7.gd"


## A client's artificial latency pair: a server and a client over a hand-pumped link.
func _latency_pair() -> Dictionary:
	var host := _parts_manager("LatencyServer", true, 1200)
	var guest := _parts_manager("LatencyClient", false, 1200)
	var got := {"up": [], "down": []}
	for m in [host, guest]:
		var manager := m as DotNetManager
		manager.messages.register(&"demo.chat", ChatMessage)
		manager.messages.register(
			&"demo.notice", ServerNotice, DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT
		)
	host.messages.on(&"demo.chat", func(_m: DotNetMessage) -> void: (got["up"] as Array).append(got["t"]))
	guest.messages.on(&"demo.notice", func(_m: DotNetMessage) -> void: (got["down"] as Array).append(got["t"]))
	got["t"] = 0.0
	host.send_fn = func(_peer: int, payload: PackedByteArray, _d: int) -> void:
		var _r := guest.receive(payload, 1)
	guest.send_fn = func(_peer: int, payload: PackedByteArray, _d: int) -> void:
		var _r := host.receive(payload, 2)
	return {"host": host, "guest": guest, "got": got}


## Sends one message each way and steps the client for [param seconds]; returns the first delivery time each way, or -1.
func _latency_run(pair: Dictionary, seconds: float) -> Array[float]:
	var host := pair["host"] as DotNetManager
	var guest := pair["guest"] as DotNetManager
	var got := pair["got"] as Dictionary
	(got["up"] as Array).clear()
	(got["down"] as Array).clear()
	got["t"] = 0.0
	var chat := ChatMessage.new()
	chat.text = "hi"
	var notice := ServerNotice.new()
	notice.notice = "hi"
	var _a := guest.send(chat)
	var _b := host.send(notice, 2)
	var steps := int(seconds / 0.01)
	for i in steps:
		got["t"] = float(i + 1) * 0.01
		guest.step(0.01)
	var up: Array = got["up"]
	var down: Array = got["down"]
	return [-1.0 if up.is_empty() else float(up[0]), -1.0 if down.is_empty() else float(down[0])]


## [b]`cl_latency_baseline`[/b]: 0 adds nothing, 0.2 s delays a client's traffic both ways by about that, and the server's `sv_allow_client_latency` 0 forces it back to 0.
func _test_latency_baseline() -> void:
	_sections_entered += 1
	print("")
	print("[client latency baseline]")

	var pair := _latency_pair()
	var guest := pair["guest"] as DotNetManager
	var latency := guest.latency
	guest.start()
	(pair["host"] as DotNetManager).start()

	_check("idle by default: not delaying, not busy", not latency.delaying() and not latency.busy())
	var base := _latency_run(pair, 0.5)
	_check("baseline 0 delivers at once both ways (%s)" % [base], base[0] == 0.0 and base[1] == 0.0)
	_check("and queues nothing", latency.pending() == 0)

	latency.requested = 0.2
	var lagged := _latency_run(pair, 0.5)
	_check("baseline 0.2 delays outgoing by ~0.2 s (%.2f)" % lagged[0], absf(lagged[0] - 0.2) <= 0.02)
	_check("and incoming by ~0.2 s (%.2f)" % lagged[1], absf(lagged[1] - 0.2) <= 0.02)
	_check("and the queue drains", latency.pending() == 0)

	guest.send_fn = guest.send_fn
	_check("assigning send_fn back while delaying keeps the real one", guest.send_fn.is_valid())

	_check("the server's switch 0 is accepted", latency.set_cvar("sv_allow_client_latency", "0"))
	_check("which forces the effective baseline to 0 (%.2f)" % latency.effective(), latency.effective() == 0.0)
	var forced := _latency_run(pair, 0.5)
	_check("traffic is immediate again (%s)" % [forced], forced[0] == 0.0 and forced[1] == 0.0)
	_check("the client's own request is kept (%.2f)" % latency.requested, latency.requested == 0.2)

	latency.set_cvar("sv_allow_client_latency", "1")
	_check("switching it back on restores 0.2", latency.effective() == 0.2)
	var chat := ChatMessage.new()
	chat.text = "held"
	var _s := guest.send(chat)
	_check("a packet is held", latency.pending() == 1)
	latency.allowed = false
	_check("forbidding releases what was held, in order", latency.pending() == 0)

	_check("a bad cvar value is refused", not latency.set_cvar("cl_latency_baseline", "fast"))
	_check("an unknown cvar is refused", not latency.set_cvar("sv_other", "1"))
	_sections_completed += 1
