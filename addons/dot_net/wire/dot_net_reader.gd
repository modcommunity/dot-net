class_name DotNetReader
extends RefCounted

## Reads what [DotNetWriter] wrote. Every method mirrors one there.
##
## [b]Reading is the untrusted side.[/b] Every buffer this touches came off the
## network, so it must survive being truncated, padded, or filled with noise without
## crashing or looping. It does that by never trusting a length it read: reads past
## the end return zero and set [member exhausted], and length-prefixed reads are
## bounded before they allocate.
##
## Callers check [member exhausted] once after decoding a message rather than after
## every field. A message that ran off the end is malformed as a whole, and there is
## nothing useful to salvage from its first half.

var _bytes: PackedByteArray
var _bit_pos: int = 0

## Set when a read ran past the end of the buffer.
##
## Sticky: once true it stays true, so a single check after decoding covers every
## field.
var exhausted: bool = false

## Where reading stops, in bits. The whole buffer unless [method limit_bits] set less.
var _end_bits: int = -1


func _init(data: PackedByteArray) -> void:
	_bytes = data


## Stops reading at [param bits], however much more the buffer holds.
##
## [b]A message body is framed in BITS, not bytes, and this is why.[/b] A body a newer
## sender wrote can end mid-byte, and the padding to the byte boundary is zeroes that look
## exactly like a one-bit field set to false. Bounding the reader at the body's exact bit
## length is what lets [method has_more] say "the writer sent nothing further" and mean
## it -- which is the whole of the append-only rule [DotNetMessage] documents.
func limit_bits(bits: int) -> void:
	_end_bits = clampi(bits, 0, _bytes.size() << 3)


func _end() -> int:
	return (_bytes.size() << 3) if _end_bits < 0 else _end_bits


# --- Raw bits --------------------------------------------------------------

## Reads [param bits] bits. Returns 0 and sets [member exhausted] past the end.
func read_bits(bits: int) -> int:
	if bits <= 0 or bits > 64:
		push_error("DotNetReader.read_bits: bits must be 1..64, got %d" % bits)
		return 0

	# Once exhausted, every subsequent read returns zero rather than resuming from
	# whatever bits happen to remain. A decoder that skips the ok() check would
	# otherwise get a plausible-looking value for the field *after* the one that
	# ran off the end, which is far harder to diagnose than a run of zeroes.
	if exhausted:
		return 0

	if _bit_pos + bits > _end():
		exhausted = true
		return 0

	var result := 0
	var written := 0
	var remaining := bits

	while remaining > 0:
		var byte_index := _bit_pos >> 3
		var bit_offset := _bit_pos & 7
		var take := mini(8 - bit_offset, remaining)

		var chunk := (_bytes[byte_index] >> bit_offset) & DotNetWriter._mask(take)
		result |= chunk << written

		written += take
		_bit_pos += take
		remaining -= take

	return result


func read_bool() -> bool:
	return read_bits(1) == 1


func read_uint(bits: int = 32) -> int:
	return read_bits(bits)


## Reads a signed integer, sign-extending from [param bits].
func read_int(bits: int = 32) -> int:
	var raw := read_bits(bits)
	if bits >= 64:
		return raw

	# Sign-extend: if the top bit of the field is set, the value is negative.
	var sign_bit := 1 << (bits - 1)
	if raw & sign_bit:
		return raw - (1 << bits)
	return raw


# --- Variable-length integers ---------------------------------------------

## Reads a varint.
##
## Bounded at ten groups — enough for any 64-bit value — so a buffer of 0xFF bytes
## cannot spin this forever.
func read_varint() -> int:
	var result := 0
	var shift := 0

	for _i in range(10):
		var group := read_bits(8)
		if exhausted:
			return 0

		result |= (group & 0x7F) << shift

		if (group & 0x80) == 0:
			return result

		shift += 7

	# Ten continuation bytes means the encoding is malformed.
	exhausted = true
	return 0


func read_svarint() -> int:
	var raw := read_varint()
	return (raw >> 1) ^ -(raw & 1)


# --- Quantised reals -------------------------------------------------------

func read_float_range(min_value: float, max_value: float, bits: int) -> float:
	if max_value <= min_value:
		push_error("DotNetReader.read_float_range: max must exceed min")
		return min_value

	var quantised := read_bits(bits)
	var normalised := float(quantised) / float(DotNetWriter._mask(bits))
	return min_value + normalised * (max_value - min_value)


func read_float_step(
	min_value: float,
	max_value: float,
	step: float
) -> float:
	return read_float_range(
		min_value,
		max_value,
		DotNetWriter.bits_for_step(min_value, max_value, step)
	)


func read_angle(bits: int = 9) -> float:
	var quantised := read_bits(bits)
	return float(quantised) / float((1 << bits) - 1) * 360.0


func read_float32() -> float:
	var buffer := PackedByteArray()
	buffer.resize(4)
	for i in range(4):
		buffer[i] = read_bits(8)
	if exhausted:
		return 0.0
	return buffer.decode_float(0)


# --- Vectors and rotations -------------------------------------------------

func read_vector2_range(
	min_value: float,
	max_value: float,
	bits: int
) -> Vector2:
	var x := read_float_range(min_value, max_value, bits)
	var y := read_float_range(min_value, max_value, bits)
	return Vector2(x, y)


func read_vector3_range(
	min_value: float,
	max_value: float,
	bits: int
) -> Vector3:
	var x := read_float_range(min_value, max_value, bits)
	var y := read_float_range(min_value, max_value, bits)
	var z := read_float_range(min_value, max_value, bits)
	return Vector3(x, y, z)


func read_vector3_step(
	min_value: float,
	max_value: float,
	step: float
) -> Vector3:
	var bits := DotNetWriter.bits_for_step(min_value, max_value, step)
	return read_vector3_range(min_value, max_value, bits)


func read_direction(bits: int = 12) -> Vector3:
	var polar := read_float_range(0.0, PI, bits)
	var azimuth := read_float_range(-PI, PI, bits)

	var sin_polar := sin(polar)
	return Vector3(
		sin_polar * cos(azimuth),
		cos(polar),
		sin_polar * sin(azimuth)
	)


## Reads a smallest-three quaternion.
##
## The dropped component is recovered from the unit-length constraint. The
## [method maxf] guard matters: quantisation can push the sum of squares slightly
## past 1, and [method sqrt] of a small negative is NaN — which then propagates into
## every transform derived from it.
func read_quaternion(bits: int = 9) -> Quaternion:
	var largest := read_bits(2)

	const LIMIT := 0.7071067811865476

	var values := [0.0, 0.0, 0.0, 0.0]
	var sum_squares := 0.0

	for i in range(4):
		if i == largest:
			continue
		var value := read_float_range(-LIMIT, LIMIT, bits)
		values[i] = value
		sum_squares += value * value

	values[largest] = sqrt(maxf(0.0, 1.0 - sum_squares))

	var q := Quaternion(values[0], values[1], values[2], values[3])

	# A quaternion that arrived as noise can still be zero-length; normalizing that
	# is NaN, so fall back to identity rather than poisoning the scene.
	if not q.is_finite() or q.length_squared() < 0.0001:
		return Quaternion.IDENTITY

	return q.normalized()


func read_transform(
	min_value: float,
	max_value: float,
	position_bits: int = 16,
	rotation_bits: int = 9
) -> Transform3D:
	var origin := read_vector3_range(min_value, max_value, position_bits)
	var rotation := read_quaternion(rotation_bits)
	return Transform3D(Basis(rotation), origin)


# --- Bytes and strings -----------------------------------------------------

## Reads a length-prefixed byte array.
##
## [param max_bytes] is checked against the prefix [b]before[/b] allocating. A
## hostile sender writing a varint of 4 billion must not cause an allocation
## attempt — that is a one-packet denial of service.
func read_bytes(max_bytes: int = 1 << 20) -> PackedByteArray:
	var length := read_varint()

	if exhausted:
		return PackedByteArray()

	if length < 0 or length > max_bytes:
		exhausted = true
		return PackedByteArray()

	align()

	var start := _bit_pos >> 3
	if (start + length) << 3 > _end():
		exhausted = true
		return PackedByteArray()

	var out := _bytes.slice(start, start + length)
	_bit_pos = (start + length) << 3
	return out


func read_string(max_bytes: int = 1024) -> String:
	var raw := read_bytes(max_bytes)
	if exhausted:
		return ""
	return raw.get_string_from_utf8()


# --- Framing ---------------------------------------------------------------

func align() -> void:
	var remainder := _bit_pos & 7
	if remainder != 0:
		_bit_pos += 8 - remainder


func bit_position() -> int:
	return _bit_pos


func bits_remaining() -> int:
	return maxi(0, _end() - _bit_pos)


func bytes_remaining() -> int:
	return bits_remaining() >> 3


## A reader over the next [param bits] bits, byte-aligned first, and this one moved past
## them. Null, with [member exhausted] set, when fewer are there.
##
## How a framed message body is read: the returned reader ends where the body ends, so a
## message cannot read into the next one, and the next one starts where it should whatever
## the message read.
func take_bits(bits: int) -> DotNetReader:
	align()
	if exhausted or bits < 0 or bits > bits_remaining():
		exhausted = true
		return null
	var start := _bit_pos >> 3
	var count := (bits + 7) >> 3
	var sub := DotNetReader.new(_bytes.slice(start, start + count))
	sub.limit_bits(bits)
	_bit_pos = (start + count) << 3
	return sub


## Whether the writer sent anything past this point.
##
## The guard for a field appended to a message after it first shipped: read it only
## `if reader.has_more()`, and a message from a sender that predates the field keeps the
## field's declared default instead of reading zero. On a reader bounded by
## [method limit_bits] -- which every message body is -- this is exact to the bit.
func has_more() -> bool:
	return bits_remaining() > 0


func at_end() -> bool:
	# Trailing padding to the byte boundary is normal, so fewer than 8 bits left
	# counts as the end rather than as a truncated field.
	return bits_remaining() < 8


func seek_bits(position: int) -> void:
	_bit_pos = clampi(position, 0, _end())


func reset() -> void:
	_bit_pos = 0
	exhausted = false


## True when the buffer decoded without running off the end.
##
## The single check a message decoder makes before trusting anything it read.
func ok() -> bool:
	return not exhausted
