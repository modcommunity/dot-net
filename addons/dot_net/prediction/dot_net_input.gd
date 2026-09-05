@tool
class_name DotNetInput
extends RefCounted

## One tick's input from one player. Subclass it for your game's controls.
##
## [b]Inputs, not state.[/b] A client sends what the player did — "move forward, look
## here, fire" — never where it ended up. A client that sent positions could send any
## position. The server applies the same input through the same simulation and
## arrives at the authoritative answer; the client predicts the same thing locally so
## it does not have to wait for it.
##
## [codeblock]
## class_name MyInput extends DotNetInput
##
## var move: Vector2
## var look_yaw: float
## var jump: bool
## var fire: bool
##
## func _write(w: DotNetWriter) -> void:
##     w.write_float_range(move.x, -1.0, 1.0, 8)
##     w.write_float_range(move.y, -1.0, 1.0, 8)
##     w.write_angle(look_yaw, 12)
##     w.write_bool(jump)
##     w.write_bool(fire)
##
## func _read(r: DotNetReader) -> void:
##     move = Vector2(
##         r.read_float_range(-1.0, 1.0, 8), r.read_float_range(-1.0, 1.0, 8))
##     look_yaw = r.read_angle(12)
##     jump = r.read_bool()
##     fire = r.read_bool()
##
## func _sanitise() -> void:
##     move = move.limit_length(1.0)
## [/codeblock]
##
## [b][method _sanitise] is not optional.[/b] Everything on this object came from a
## client and can be anything the wire format permits. A move vector of length 40 is
## representable and would make a player 40 times faster; clamping it on the server is
## the only thing that stops that. Quantisation bounds the range but not the
## relationships between fields.

## Tick this input applies to.
var tick: int = 0

## Seconds this input covers. Usually one tick.
##
## Sent so the server can reject a client claiming an oversized step, which would
## otherwise be a way to move further per tick than everyone else.
var delta: float = 0.0


# --- Subclass interface ----------------------------------------------------

func _write(_writer: DotNetWriter) -> void:
	push_error("DotNetInput._write() was not overridden.")


func _read(_reader: DotNetReader) -> void:
	push_error("DotNetInput._read() was not overridden.")


## Clamps fields into legal ranges. Called on the server after decoding.
##
## Override for anything a client could exaggerate. Quantisation already bounds each
## field; this is for the relationships between them.
func _sanitise() -> void:
	pass


## Whether two inputs are identical, for redundancy suppression.
##
## Override when your input has fields worth comparing. Returning false is always
## correct, just less efficient — a held-still player then costs full input bandwidth.
func _equals(_other: DotNetInput) -> bool:
	return false


# --- Public API ------------------------------------------------------------

func write(writer: DotNetWriter) -> void:
	writer.write_uint(tick, 32)
	# Quantised: a delta outside this range is not a real frame time, and accepting
	# one lets a client claim a 10-second step and move accordingly.
	writer.write_float_range(delta, 0.0, 0.5, 12)
	_write(writer)


func read(reader: DotNetReader) -> void:
	tick = reader.read_uint(32)
	delta = reader.read_float_range(0.0, 0.5, 12)
	_read(reader)


## Clamps the base fields, then the subclass's.
func sanitise(tick_rate: int) -> void:
	# A client's delta must be close to one tick. Larger means it is claiming more
	# simulation than time has passed; smaller is harmless but pointless.
	var nominal := 1.0 / float(maxi(1, tick_rate))
	delta = clampf(delta, 0.0, nominal * 2.0)
	_sanitise()


func equals(other: DotNetInput) -> bool:
	if other == null:
		return false
	return _equals(other)


func _to_string() -> String:
	return "DotNetInput(tick %d)" % tick


# --- Buffer ----------------------------------------------------------------

## A client's queue of inputs, on both sides of the connection.
##
## On the client it is the replay history for reconciliation. On the server it is the
## jitter buffer: inputs arrive in bursts and gaps, and the simulation needs exactly
## one per tick.
class Buffer extends RefCounted:
	## Inputs held, oldest first.
	var _inputs: Array[DotNetInput] = []

	## Most inputs kept.
	var capacity: int = 120

	## Last tick handed to the simulation.
	var _last_consumed_tick: int = -1

	## Inputs the server had to invent because none arrived.
	var starved_count: int = 0

	## Inputs discarded for arriving after their tick had passed.
	var late_count: int = 0

	## Inputs discarded for duplicating one already held.
	var duplicate_count: int = 0

	func _init(p_capacity: int = 120) -> void:
		capacity = p_capacity

	## Adds an input, keeping the buffer ordered and bounded.
	func push(input: DotNetInput) -> DotResult:
		if input.tick <= _last_consumed_tick:
			# The tick it applies to is already simulated. Applying it now would
			# rewrite history the server has already sent to everyone.
			late_count += 1
			return DotResult.fail(
				DotError.CODE_STATE,
				"Input arrived too late.",
				"tick %d, already at %d" % [input.tick, _last_consumed_tick]
			)

		var index := _inputs.size()
		while index > 0 and _inputs[index - 1].tick > input.tick:
			index -= 1

		if index > 0 and _inputs[index - 1].tick == input.tick:
			# Clients resend recent inputs so a dropped packet does not cost a tick;
			# duplicates are expected and cheap to ignore.
			duplicate_count += 1
			return DotResult.success(false)

		_inputs.insert(index, input)

		while _inputs.size() > capacity:
			_inputs.pop_front()

		return DotResult.success(true)

	## Takes the input for a tick, or null.
	func take(tick: int) -> DotNetInput:
		for i in range(_inputs.size()):
			if _inputs[i].tick == tick:
				var input := _inputs[i]
				_inputs.remove_at(i)
				_last_consumed_tick = maxi(_last_consumed_tick, tick)
				return input
			if _inputs[i].tick > tick:
				break

		_last_consumed_tick = maxi(_last_consumed_tick, tick)
		return null

	## The input for a tick without removing it. For client-side replay.
	func peek(tick: int) -> DotNetInput:
		for input in _inputs:
			if input.tick == tick:
				return input
		return null

	## Inputs from [param from_tick] onward, in order. The replay set.
	func since(from_tick: int) -> Array[DotNetInput]:
		var out: Array[DotNetInput] = []
		for input in _inputs:
			if input.tick >= from_tick:
				out.append(input)
		return out

	## Drops inputs the server has confirmed. Client-side.
	##
	## Anything at or before the acknowledged tick has been applied authoritatively
	## and will never be replayed again.
	func acknowledge(tick: int) -> int:
		var removed := 0
		while not _inputs.is_empty() and _inputs[0].tick <= tick:
			_inputs.pop_front()
			removed += 1
		return removed

	## Records that a tick had no input available.
	##
	## The server repeats the last input rather than simulating nothing: a player
	## whose packet was lost should keep moving in a straight line for a tick, not
	## stop dead and then jerk forward.
	func note_starved() -> void:
		starved_count += 1

	func newest() -> DotNetInput:
		return _inputs[_inputs.size() - 1] if not _inputs.is_empty() else null

	func oldest() -> DotNetInput:
		return _inputs[0] if not _inputs.is_empty() else null

	func size() -> int:
		return _inputs.size()

	func is_empty() -> bool:
		return _inputs.is_empty()

	func clear() -> void:
		_inputs.clear()
		_last_consumed_tick = -1

	## How many ticks of input are queued ahead of the simulation.
	##
	## The number to watch on a server: consistently zero means clients are running
	## too close and their inputs arrive late; consistently large means they are too
	## far ahead and paying unnecessary input latency.
	func depth(current_tick: int) -> int:
		var count := 0
		for input in _inputs:
			if input.tick >= current_tick:
				count += 1
		return count

	func describe() -> Dictionary:
		return {
			"queued": _inputs.size(),
			"last_consumed": _last_consumed_tick,
			"starved": starved_count,
			"late": late_count,
			"duplicates": duplicate_count,
		}
