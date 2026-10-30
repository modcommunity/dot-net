class_name DotNetLatency
extends RefCounted

## Artificial latency a client adds to its own traffic, both directions, for testing lag: `cl_latency_baseline`
## (seconds) unless the server's `sv_allow_client_latency` is 0. Zero costs one float compare per packet.
## The cvar side is wired by the host (dot-net has no console): [method bind_client_cvar] on a client,
## [method bind_server_cvar] on a server, [method follow_cvars] on a client to read the server's switch.

const CHANNEL := "net"
const CVAR_BASELINE := "cl_latency_baseline"
const CVAR_ALLOW := "sv_allow_client_latency"
## Longest baseline accepted, seconds.
const MAX_SECONDS := 5.0

## Emitted when [method effective] changes.
signal changed(seconds: float)

## What the player asked for, seconds.
var requested: float = 0.0:
	set(value):
		requested = clampf(value, 0.0, MAX_SECONDS)
		_refresh()

## Whether the server lets a client add latency.
var allowed: bool = true:
	set(value):
		allowed = value
		_refresh()

var _effective: float = 0.0
var _now: float = 0.0
var _queue: Array = []


## Seconds actually added: [member requested], or 0 when the server forbids it.
func effective() -> float:
	return _effective


## True while packets should be held. The fast path every packet takes.
func delaying() -> bool:
	return _effective > 0.0


## True while anything is queued or latency is on, so a host skips [method advance] otherwise.
func busy() -> bool:
	return _effective > 0.0 or not _queue.is_empty()


## Holds [param action] for [method effective] seconds.
func hold(action: Callable) -> void:
	_queue.append([_now + _effective, action])


## Moves the clock on and runs what has come due, in order.
func advance(delta: float) -> void:
	_now += delta
	while not _queue.is_empty() and _queue[0][0] <= _now:
		var entry: Array = _queue.pop_front()
		(entry[1] as Callable).call()


## Packets still held.
func pending() -> int:
	return _queue.size()


func set_cvar(cvar_name: String, value: String) -> bool:
	if not value.is_valid_float():
		return false
	match cvar_name:
		CVAR_BASELINE:
			requested = value.to_float()
		CVAR_ALLOW:
			allowed = value.to_float() != 0.0
		_:
			return false
	return true


## Registers `cl_latency_baseline` through [param add] (`(name, default, description, flags) -> cvar`).
func bind_client_cvar(add: Callable, flags: int = 0) -> Object:
	return _bind(add, CVAR_BASELINE, "0", "Artificial latency added to this client's traffic, seconds (for testing).", flags)


## Registers `sv_allow_client_latency`; pass the replicate flag so clients hear it.
func bind_server_cvar(add: Callable, flags: int = 0) -> Object:
	return _bind(add, CVAR_ALLOW, "1", "Whether clients may add artificial latency (cl_latency_baseline).", flags)


## Follows the server's switch through a link with `replicated_cvar` / `replicated_cvar_changed`.
func follow_cvars(source: Object) -> bool:
	if source == null or not is_instance_valid(source):
		return false
	if not source.has_method(&"replicated_cvar") or not source.has_signal(&"replicated_cvar_changed"):
		return false
	var held := String(source.call(&"replicated_cvar", CVAR_ALLOW, ""))
	if held != "":
		var _applied := set_cvar(CVAR_ALLOW, held)
	if not source.is_connected(&"replicated_cvar_changed", _on_replicated):
		source.connect(&"replicated_cvar_changed", _on_replicated)
	return true


func describe() -> Dictionary:
	return {"requested": requested, "allowed": allowed, "effective": _effective, "pending": _queue.size()}


func _bind(add: Callable, cvar_name: String, default: String, text: String, flags: int) -> Object:
	var cv: Variant = add.call(cvar_name, default, text, flags)
	if not (cv is Object):
		return null
	var obj := cv as Object
	if obj.has_signal(&"changed"):
		obj.connect(&"changed", func(_old: Variant, new_value: Variant) -> void: set_cvar(cvar_name, str(new_value)))
	if obj.has_method(&"get_string"):
		var held := String(obj.call(&"get_string"))
		if held != default:
			var _applied := set_cvar(cvar_name, held)
	return obj


func _on_replicated(cvar_name: String, value: String) -> void:
	var _applied := set_cvar(cvar_name, value)


func _refresh() -> void:
	var now_effective := requested if allowed else 0.0
	if now_effective == _effective:
		return
	_effective = now_effective
	if _effective == 0.0:
		_flush()
	changed.emit(_effective)


# Order matters for reliable messages: whatever is held leaves before anything newer can overtake it.
func _flush() -> void:
	var held := _queue
	_queue = []
	for entry in held:
		(entry[1] as Callable).call()
