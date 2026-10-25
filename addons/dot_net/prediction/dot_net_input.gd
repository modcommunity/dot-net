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


## Clears whatever this input would make happen and keeps where it looks: the input a
## silent player is given ([member DotNetConfig.starved_input_hold_sec]).
##
## The default calls [code]neutralise()[/code] on every member that has one (a
## [code]DotFpsCommand[/code] zeroes its move and buttons and keeps its view angles), so a
## game whose input is made of such commands needs no override. Override for plain fields
## (a held-action bitmask, a slot), calling [code]super()[/code] first.
func _neutralise() -> void:
	for prop in get_property_list():
		if not (int(prop["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var member: Variant = get(prop["name"])
		if member is Object and (member as Object).has_method(&"neutralise"):
			(member as Object).call(&"neutralise")


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


## Rounds this input in place to exactly what the server will decode: written and read
## back through the wire format.
##
## [b]A client predicts on what it sends, not on what it sampled.[/b] A view angle goes
## out in 12 bits and a move axis in 10, so the server simulates on the rounded command,
## and a client that simulated on the raw one walks a slightly different line every tick
## that the view turns. A replay does not hide it, because the replay runs on the same raw
## command. Each tick is a fraction of a millimetre, but nothing resynchronises a skipped
## replay ([member DotNetConfig.skip_matching_replays]), so it adds up past what
## [method DotNetVar.matches] allows and the skip stops working while the player is
## turning, which is always.
func round_trip() -> void:
	var writer := DotNetWriter.new(32)
	write(writer)
	read(DotNetReader.new(writer.to_bytes()))


## A copy of this input with [method _neutralise] applied, for [param p_tick].
func neutralised(p_tick: int) -> DotNetInput:
	var copy: DotNetInput = (get_script() as Script).new()
	var writer := DotNetWriter.new(32)
	write(writer)
	copy.read(DotNetReader.new(writer.to_bytes()))
	copy.tick = p_tick
	copy._neutralise()
	return copy


func equals(other: DotNetInput) -> bool:
	if other == null:
		return false
	return _equals(other)


func _to_string() -> String:
	return "DotNetInput(tick %d)" % tick


# --- Batches: the last few inputs in every packet ---------------------------

## Most inputs one batch carries. Four bits of count.
const BATCH_MAX := 15

## Writes [param inputs] (oldest first, ticks ascending) as one batch: a count, the first
## tick in full and each later one as the step from the one before, then each input's
## delta and fields.
##
## [b]Why a client sends its last few inputs every tick rather than one.[/b] Inputs are
## unreliable, and a lost one is a tick the server simulates on the previous command,
## which the client predicted on the real one -- a correction for every lost packet that
## changed anything, and with the view angle changing every tick that is every lost
## packet. Measured through a real UDP relay in front of an ENet server (game-arena's
## `headless_lossy`): at 20% loss each way a fifth of a moving player's ticks were
## simulated on a guess, and 9% of snapshots corrected his prediction. Resending is what the input buffer already expected -- its duplicate
## counter says "clients resend recent inputs" -- and nothing in the family did. Three
## copies turn one loss in five into one tick in a hundred and twenty-five for about
## twelve extra bytes a packet; the copies after the first cost a varint for the tick
## instead of 32 bits.
static func write_batch(writer: DotNetWriter, inputs: Array) -> void:
	var count := mini(inputs.size(), BATCH_MAX)
	var first := inputs.size() - count
	writer.write_uint(count, 4)

	var previous := -1
	for i in range(first, inputs.size()):
		var input: DotNetInput = inputs[i]
		if previous < 0:
			writer.write_uint(input.tick, 32)
		else:
			writer.write_varint(maxi(1, input.tick - previous))
		previous = input.tick
		writer.write_float_range(input.delta, 0.0, 0.5, 12)
		input._write(writer)


## Reads what [method write_batch] wrote, building each input with [param make] (a
## [Callable] returning a new instance of the game's subclass). Oldest first.
##
## Untrusted: the count is four bits, a tick step is at least one, and a batch that runs
## out part-way returns what was read whole before it.
static func read_batch(reader: DotNetReader, make: Callable) -> Array[DotNetInput]:
	var out: Array[DotNetInput] = []
	var count := reader.read_uint(4)
	var tick := -1

	for i in range(count):
		if tick < 0:
			tick = reader.read_uint(32)
		else:
			tick += maxi(1, reader.read_varint())

		var input: DotNetInput = make.call()
		input.tick = tick
		input.delta = reader.read_float_range(0.0, 0.5, 12)
		input._read(reader)

		if not reader.ok():
			break

		out.append(input)

	return out


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

	## Server side: the newest input tick ever offered to [method push], late ones included.
	var _newest_tick: int = -1

	## Server side: the least [i]arrival lead[/i] seen since [method take_lead_sample] last
	## took it, and the input tick it was measured on. The arrival lead is how many ticks
	## before it was needed an input newer than any before it arrived: its tick less the next
	## tick to simulate, so 0 is just in time and below 0 is late. What the server tells the
	## client in its snapshots, so the client's clock can keep its commands a little early
	## whatever the link does (docs/timelines.md#the-input-lead-the-server-reports).
	var _lead_min: int = LEAD_NONE
	var _lead_input_tick: int = -1

	## No arrival measured since the last sample was taken.
	const LEAD_NONE := 1 << 30

	func _init(p_capacity: int = 120) -> void:
		capacity = p_capacity

	## Adds an input, keeping the buffer ordered and bounded.
	func push(input: DotNetInput) -> DotResult:
		# Measured on arrival, and only for an input newer than any before it: a resent copy
		# says nothing about when its tick was needed, and the newest input in a packet is
		# the one that came as late as the packet did. Not until the first tick has been
		# simulated, before which "the next tick to simulate" means nothing.
		if input.tick > _newest_tick:
			_newest_tick = input.tick
			if _last_consumed_tick >= 0:
				var lead := input.tick - (_last_consumed_tick + 1)
				if lead < _lead_min:
					_lead_min = lead
					_lead_input_tick = input.tick

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

	## The newest tick handed to the simulation, or -1. A server reading a batch of
	## resent inputs skips the copies at or before it rather than counting each as late.
	func last_consumed_tick() -> int:
		return _last_consumed_tick

	## Up to [param count] inputs at or before [param upto_tick], oldest first: what a
	## client resends with every packet. See [method DotNetInput.write_batch].
	func recent(count: int, upto_tick: int) -> Array[DotNetInput]:
		var out: Array[DotNetInput] = []
		var i := _inputs.size() - 1
		while i >= 0 and out.size() < count:
			if _inputs[i].tick <= upto_tick:
				out.push_front(_inputs[i])
			i -= 1
		return out

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

	## The newest input for a tick before [param tick], or null when there is none.
	func latest_before(tick: int) -> DotNetInput:
		var out: DotNetInput = null
		for input in _inputs:
			if input.tick >= tick:
				break
			out = input
		return out

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
		_newest_tick = -1
		_lead_min = LEAD_NONE
		_lead_input_tick = -1

	## The least arrival lead since the last call, as [code]Vector2i(lead, input_tick)[/code],
	## and starts the next measurement; [code]Vector2i(LEAD_NONE, -1)[/code] when no new input
	## has arrived since. Server side; [DotNetManager] sends it to a client that reads it.
	func take_lead_sample() -> Vector2i:
		var out := Vector2i(_lead_min, _lead_input_tick)
		_lead_min = LEAD_NONE
		_lead_input_tick = -1
		return out

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
