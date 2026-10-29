class_name DotNetWriter
extends RefCounted

## Bit-level writer with quantisation. The bottom of the wire format. [b]Why bits rather than
## bytes.[/b] A player's state at 30 Hz for 64 players is roughly 2000 messages a second.

## Ceiling on a single buffer, as a guard against a runaway loop producing a
## multi-gigabyte allocation before anything notices.
const MAX_BYTES := 1 << 22

var _bytes: PackedByteArray = PackedByteArray()
var _bit_pos: int = 0

## Set when a write was refused. Checked once at the end rather than per call, so
## the common path stays branch-free at the call site.
var overflowed: bool = false


func _init(reserve_bytes: int = 256) -> void:
	# Reserving avoids repeated reallocation as the buffer grows; PackedByteArray
	# has no capacity concept, so this is a resize-then-track-length approach in
	# spirit, done by simply letting append grow it from a sensible start.
	if reserve_bytes > 0:
		_bytes.resize(0)


## Writes the low [param bits] bits of [param value]. Bits go least-significant-first into each byte,
## and bytes fill in order.
func write_bits(value: int, bits: int) -> void:
	if bits <= 0 or bits > 64:
		push_error("DotNetWriter.write_bits: bits must be 1..64, got %d" % bits)
		return

	var remaining := bits
	# Masking first means a caller passing a value wider than `bits` truncates
	# rather than corrupting the following fields.
	var v := value if bits >= 64 else value & ((1 << bits) - 1)

	while remaining > 0:
		var byte_index := _bit_pos >> 3
		var bit_offset := _bit_pos & 7
		var take := mini(8 - bit_offset, remaining)

		if byte_index >= _bytes.size():
			if _bytes.size() >= MAX_BYTES:
				overflowed = true
				return
			_bytes.append(0)

		# The masks written out rather than through `_mask`: `take` is at most 8, and a
		# static call per byte was most of what writing an entity's header cost.
		_bytes[byte_index] |= (v & ((1 << take) - 1)) << bit_offset

		v >>= take
		_bit_pos += take
		remaining -= take


static func _mask(bits: int) -> int:
	if bits >= 64:
		return -1
	return (1 << bits) - 1


func write_bool(value: bool) -> void:
	write_bits(1 if value else 0, 1)


## Writes an unsigned integer in a fixed width.
func write_uint(value: int, bits: int = 32) -> void:
	write_bits(value, bits)


## Writes a signed integer in a fixed width, two's complement.
func write_int(value: int, bits: int = 32) -> void:
	write_bits(value & _mask(bits), bits)


## Writes an unsigned integer in 7-bit groups with a continuation bit. Small values cost one byte,
## which is what makes it worth using for anything whose range is large but whose typical value is
## small — entity counts, string lengths, tick deltas.
func write_varint(value: int) -> void:
	var v := value
	if v < 0:
		push_error("DotNetWriter.write_varint: negative value; use write_svarint")
		v = 0

	while true:
		var group := v & 0x7F
		v >>= 7
		if v == 0:
			write_bits(group, 8)
			return
		write_bits(group | 0x80, 8)


## Writes a signed integer as a zigzag-encoded varint. Zigzag maps small negatives to small positives
## (-1 → 1, 1 → 2, -2 → 3), so a value near zero costs one byte regardless of sign.
func write_svarint(value: int) -> void:
	write_varint((value << 1) ^ (value >> 63))


## Writes a float mapped onto [param bits] steps across a known range. The workhorse.
## Out-of-range values clamp, not wrap: a clamped position looks wrong at the edge, a wrapped one
## teleports.
func write_float_range(value: float, min_value: float, max_value: float, bits: int) -> void:
	if max_value <= min_value:
		push_error("DotNetWriter.write_float_range: max must exceed min")
		write_bits(0, bits)
		return

	var span := max_value - min_value
	var normalised := clampf((value - min_value) / span, 0.0, 1.0)
	write_bits(int(roundf(normalised * float(_mask(bits)))), bits)


## Writes a float on a fixed grid, choosing the bit width from the range. Often what you actually want:
## "positions to the centimetre over this world" is a clearer statement of intent than "17 bits".
func write_float_step(
	value: float,
	min_value: float,
	max_value: float,
	step: float
) -> void:
	write_float_range(
		value, min_value, max_value, bits_for_step(min_value, max_value, step)
	)


## Bit width needed to represent [param min_value]..[param max_value] at [param step].
static func bits_for_step(min_value: float, max_value: float, step: float) -> int:
	if step <= 0.0 or max_value <= min_value:
		return 32
	var steps := int(ceilf((max_value - min_value) / step)) + 1
	return clampi(_bits_for_count(steps), 1, 32)


static func _bits_for_count(count: int) -> int:
	var bits := 1
	while (1 << bits) < count and bits < 63:
		bits += 1
	return bits


## Writes an angle in degrees, wrapped to 0–360. Wrapped rather than clamped, because angles are
## cyclic: 370° and 10° are the same heading and clamping would turn a rotating object into one that
## sticks at 360.
func write_angle(degrees: float, bits: int = 9) -> void:
	var wrapped := fposmod(degrees, 360.0)
	write_bits(
		int(roundf(wrapped / 360.0 * float((1 << bits) - 1))) & _mask(bits), bits
	)


## Writes a full 32-bit float with no quantisation. For values with no meaningful range — a timestamp,
## a damage number that could be anything.
func write_float32(value: float) -> void:
	var buffer := PackedByteArray()
	buffer.resize(4)
	buffer.encode_float(0, value)
	for i in range(4):
		write_bits(buffer[i], 8)


func write_vector2_range(
	value: Vector2,
	min_value: float,
	max_value: float,
	bits: int
) -> void:
	write_float_range(value.x, min_value, max_value, bits)
	write_float_range(value.y, min_value, max_value, bits)


func write_vector3_range(
	value: Vector3,
	min_value: float,
	max_value: float,
	bits: int
) -> void:
	write_float_range(value.x, min_value, max_value, bits)
	write_float_range(value.y, min_value, max_value, bits)
	write_float_range(value.z, min_value, max_value, bits)


func write_vector3_step(
	value: Vector3,
	min_value: float,
	max_value: float,
	step: float
) -> void:
	var bits := bits_for_step(min_value, max_value, step)
	write_vector3_range(value, min_value, max_value, bits)


## Writes a unit-length direction using two angles. A normalised vector has two degrees of freedom, not
## three, so sending three components wastes a third of the bits and still permits a denormalised
## result.
func write_direction(direction: Vector3, bits: int = 12) -> void:
	var d := direction.normalized()
	if not d.is_finite() or d.length_squared() < 0.5:
		# A zero or invalid direction has no angles. Encoded as straight up, which
		# is at least deterministic — the alternative is NaN on the far side.
		d = Vector3.UP

	write_float_range(acos(clampf(d.y, -1.0, 1.0)), 0.0, PI, bits)
	write_float_range(atan2(d.z, d.x), -PI, PI, bits)


## Writes a rotation using the smallest-three method. A unit quaternion has three degrees of freedom,
## and the largest component can be reconstructed from the other three because the length is 1.
func write_quaternion(rotation: Quaternion, bits: int = 9) -> void:
	var q := rotation.normalized()

	var components := [q.x, q.y, q.z, q.w]
	var largest := 0
	var largest_value := absf(q.x)

	for i in range(1, 4):
		var magnitude := absf(components[i])
		if magnitude > largest_value:
			largest_value = magnitude
			largest = i

	# The sign of the dropped component is not sent: q and -q are the same rotation,
	# so flipping the whole quaternion to make the largest component positive costs
	# nothing and saves a bit.
	var sign_flip := -1.0 if components[largest] < 0.0 else 1.0

	write_bits(largest, 2)

	const LIMIT := 0.7071067811865476  # 1/sqrt(2)

	for i in range(4):
		if i == largest:
			continue
		write_float_range(
			clampf(components[i] * sign_flip, -LIMIT, LIMIT), -LIMIT, LIMIT, bits
		)


## Writes a transform's position and rotation, quantised.
func write_transform(
	transform: Transform3D,
	min_value: float,
	max_value: float,
	position_bits: int = 16,
	rotation_bits: int = 9
) -> void:
	write_vector3_range(transform.origin, min_value, max_value, position_bits)
	write_quaternion(transform.basis.get_rotation_quaternion(), rotation_bits)


## Writes raw bytes with a length prefix. Byte-aligns first, so the copy is a straight append rather
## than a per-bit shift.
func write_bytes(data: PackedByteArray) -> void:
	write_varint(data.size())
	align()

	if _bytes.size() + data.size() > MAX_BYTES:
		overflowed = true
		return

	_bytes.append_array(data)
	_bit_pos = _bytes.size() << 3


## Appends bytes with NO length prefix, byte-aligned first. For framing that carries its own length
## elsewhere -- a message body, whose length is written in bits before it -- so the reader can bound
## itself exactly.
func write_aligned_bytes(data: PackedByteArray) -> void:
	align()

	if _bytes.size() + data.size() > MAX_BYTES:
		overflowed = true
		return

	_bytes.append_array(data)
	_bit_pos = _bytes.size() << 3


## Appends what another writer wrote from bit [param from_bit] to bit [param to_bit].
func write_bit_run(data: PackedByteArray, from_bit: int, to_bit: int) -> void:
	var bits := to_bit - from_bit

	if bits <= 0:
		return

	if (from_bit & 7) != (_bit_pos & 7):
		push_error("DotNetWriter.write_bit_run: source at bit %d of its byte, this writer at %d"
			% [from_bit & 7, _bit_pos & 7])
		return

	var last := (to_bit + 7) >> 3

	if data.size() < last:
		push_error("DotNetWriter.write_bit_run: bits to %d from %d bytes" % [to_bit, data.size()])
		return

	var end_bit := _bit_pos + bits

	if ((end_bit + 7) >> 3) > MAX_BYTES:
		overflowed = true
		return

	var first := from_bit >> 3

	if (_bit_pos & 7) != 0:
		# The byte in progress: its written low bits and the source's zero low bits share it.
		_bytes[_bytes.size() - 1] |= data[first]
		first += 1

	if first < last:
		_bytes.append_array(data.slice(first, last))

	_bit_pos = end_bit
	_bytes.resize((_bit_pos + 7) >> 3)


## Appends [param bits] bits another writer wrote from its bit 0, at whatever bit this one
## is at, shifting every byte. Only for bits with nothing byte-aligned in them -- see
## [method write_bit_run] for why that matters and for the run that has.
func write_shifted_run(data: PackedByteArray, bits: int) -> void:
	if bits <= 0:
		return

	var needed := (bits + 7) >> 3

	if data.size() < needed:
		push_error("DotNetWriter.write_shifted_run: %d bits from %d bytes" % [bits, data.size()])
		return

	var end_bit := _bit_pos + bits

	if ((end_bit + 7) >> 3) > MAX_BYTES:
		overflowed = true
		return

	var offset := _bit_pos & 7

	if offset == 0:
		_bytes.append_array(data.slice(0, needed))
	else:
		# Each source byte straddles two of ours: its low bits complete the byte in
		# progress, its high bits start the next one.
		var back := 8 - offset
		var index := _bytes.size() - 1
		for i in range(needed):
			var b := data[i]
			_bytes[index] |= (b << offset) & 0xFF
			_bytes.append(b >> back)
			index += 1

	_bit_pos = end_bit
	_bytes.resize((_bit_pos + 7) >> 3)


## Writes a UTF-8 string with a length prefix. [param max_bytes] truncates rather than refusing, and
## truncation happens on the encoded bytes with a character-boundary check — cutting UTF-8 mid-sequence
## produces a string the reader cannot decode.
func write_string(value: String, max_bytes: int = 1024) -> void:
	var encoded := value.to_utf8_buffer()

	if encoded.size() > max_bytes:
		encoded = encoded.slice(0, max_bytes)
		# Back off to a character boundary: continuation bytes are 10xxxxxx.
		while encoded.size() > 0 and (encoded[encoded.size() - 1] & 0xC0) == 0x80:
			encoded.resize(encoded.size() - 1)

	write_bytes(encoded)


## Pads to the next byte boundary.
func align() -> void:
	var remainder := _bit_pos & 7
	if remainder != 0:
		write_bits(0, 8 - remainder)


func bit_length() -> int:
	return _bit_pos


func byte_length() -> int:
	return (_bit_pos + 7) >> 3


## The written bytes, padded to a whole byte.
func to_bytes() -> PackedByteArray:
	return _bytes.duplicate()


func reset() -> void:
	_bytes = PackedByteArray()
	_bit_pos = 0
	overflowed = false


## A reader positioned at the start of what was written. For round-trip tests.
func to_reader() -> DotNetReader:
	return DotNetReader.new(to_bytes())
