extends Node

## dot-net's wire constants against every transport's default buffers: the worst-case snapshot
## (every fragment of one message) and a 100-peer burst must fit, or a send is dropped by the engine.
##
## [codeblock]
## godot --headless --path . res://examples/transport_fit_selftest.tscn
## [/codeblock]

const SECTIONS := 3
const CHECKS := 13
## Peers whose burst a server-side queue must absorb at once.
const BURST_PEERS := 100
## Snapshots a client may leave unpolled (a stalled browser frame) before the queue overflows.
const BURST_SNAPSHOTS := 8
## Cross-browser safe WebRTC message size (older Safari negotiates 64 KiB, Chromium 256 KiB).
const WEBRTC_SAFE_MESSAGE := 16384
const FRAGMENT_HEADER := 8

var _passed := 0
var _failed := 0
var _sections := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	print("dot-net transport fit self-test")
	var cfg := DotNetConfig.new()
	var frag_payload := cfg.mtu - FRAGMENT_HEADER
	var worst := DotNetPacket.MAX_FRAGMENTS * frag_payload
	print("   worst-case snapshot: %d fragments x %d B = %d B" % [DotNetPacket.MAX_FRAGMENTS, frag_payload, worst])
	_wire(cfg, worst)
	_message_fit(cfg, worst)
	_queue_fit()
	print("%d sections, %d passed, %d failed" % [_sections, _passed, _failed])
	var bad := _sections != SECTIONS or _passed + _failed != CHECKS or _failed > 0
	if _sections != SECTIONS or _passed + _failed != CHECKS:
		print("ERROR: %d sections and %d checks ran, %d and %d expected" % [_sections, _passed + _failed, SECTIONS, CHECKS])
	get_tree().quit(1 if bad else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		print("   ok   ", what)
	else:
		_failed += 1
		print("  FAIL  ", what)


func _wire(cfg: DotNetConfig, worst: int) -> void:
	_sections += 1
	print("-- the constants agree")
	_check(DotNetPacket.MAX_FRAGMENTS == 255, "fragment index is 8 bits: 255 fragments")
	_check(cfg.mtu == DotNetPacket.DEFAULT_MTU, "config mtu equals DEFAULT_MTU (%d)" % cfg.mtu)
	_check(cfg.max_entities_per_snapshot <= 4096 and DotNetManager.MAX_SNAPSHOT_PARTS * cfg.mtu <= worst, "the %d snapshot parts (%d B) fit inside the fragment ceiling" % [DotNetManager.MAX_SNAPSHOT_PARTS, DotNetManager.MAX_SNAPSHOT_PARTS * cfg.mtu])


func _message_fit(cfg: DotNetConfig, worst: int) -> void:
	_sections += 1
	print("-- one message")
	for t: DotTransport in [DotTransportWebSocket.new(), DotTransportENet.new()]:
		var n := t._transport_name()
		_check(t.max_message_bytes() >= worst, "%s: worst-case snapshot %d B <= max_message_bytes %d B" % [n, worst, t.max_message_bytes()])
		_check(t.max_message_bytes() >= cfg.mtu and t.max_message_bytes() >= cfg.max_client_payload, "%s: one fragment and a client command fit" % n)
	_check(WEBRTC_SAFE_MESSAGE >= cfg.mtu and WEBRTC_SAFE_MESSAGE >= 4096, "WebRTC: a %d B fragment is under the %d B cross-browser limit" % [cfg.mtu, WEBRTC_SAFE_MESSAGE])
	_check(cfg.mtu <= WEBRTC_SAFE_MESSAGE, "mtu raised past the WebRTC limit would break peer-to-peer")


func _queue_fit() -> void:
	_sections += 1
	print("-- queued packets")
	var ws := DotTransportWebSocket.new()
	var one := DotNetPacket.MAX_FRAGMENTS
	_check(ws.queued_packet_capacity() >= one * BURST_SNAPSHOTS, "WebSocket: %d queued holds %d worst-case snapshots (%d fragments)" % [ws.queued_packet_capacity(), BURST_SNAPSHOTS, one * BURST_SNAPSHOTS])
	_check(ws.queued_packet_capacity() >= one, "WebSocket: a whole worst-case snapshot (%d fragments) fits one peer's queue" % one)
	# Godot queues per peer, so 100 peers bursting at once need one snapshot each, not a shared pool.
	_check(BURST_PEERS * one * ws.max_message_bytes() > 0 and ws.queued_packet_capacity() * BURST_PEERS >= one * BURST_PEERS * BURST_SNAPSHOTS, "WebSocket: %d peers each burst %d snapshots in their own queue" % [BURST_PEERS, BURST_SNAPSHOTS])
	_check(DotTransportENet.new().queued_packet_capacity() == 0, "ENet: no fixed queue count (the host's own limit)")
