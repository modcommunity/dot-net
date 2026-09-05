@tool
class_name DotNetVar
extends Resource

## A declaration that one property is replicated, and how.
##
## [b]This is the main extension point in dot-net.[/b] A game describes what it wants
## replicated and how precisely, and the rest — dirty tracking, quantisation,
## delta compression, per-observer filtering, interpolation — follows from the
## declaration. Nothing needs to be written per property.
##
## [codeblock]
## func _register_net_vars() -> void:
##     replicate("position", DotNetVar.Type.VECTOR3_POSITION).interpolated()
##     replicate("health", DotNetVar.Type.UINT).bits(7).on_change(_on_health_changed)
##     replicate("ammo", DotNetVar.Type.UINT).bits(9).to_owner_only()
##     replicate("inventory", DotNetVar.Type.CUSTOM).codec(_write_inv, _read_inv)
## [/codeblock]
##
## [b]When the built-in types are not enough, use [constant Type.CUSTOM].[/b] Supply
## a write and a read callable and any type at all can be replicated — a dictionary,
## a resource, a bitfield of your own design. The codec sees a [DotNetWriter] and a
## [DotNetReader] and is otherwise unconstrained.

## Built-in wire representations. [constant Type.CUSTOM] escapes to your own codec.
enum Type {
	BOOL,
	## Unsigned integer. Width from [member bit_width].
	UINT,
	## Signed integer. Width from [member bit_width].
	INT,
	## Variable-length integer. Small values cost one byte.
	VARINT,
	## Full 32-bit float. Use a quantised type where the range is known.
	FLOAT,
	## Float quantised into [member min_value]..[member max_value].
	FLOAT_RANGE,
	## Vector3 on the world position grid, from the config.
	VECTOR3_POSITION,
	## Vector3 quantised as a velocity, from the config.
	VECTOR3_VELOCITY,
	## Vector3 quantised into [member min_value]..[member max_value] per axis.
	VECTOR3_RANGE,
	## Unit-length direction, as two angles.
	DIRECTION,
	## Rotation, smallest-three encoded.
	QUATERNION,
	## Angle in degrees, wrapped. Width from [member bit_width].
	ANGLE,
	## UTF-8 string, length-prefixed.
	STRING,
	## Raw bytes, length-prefixed.
	BYTES,
	## Your own codec. See [method codec].
	CUSTOM,
}

## Who receives a property.
enum Audience {
	## Everyone who can see the entity at all.
	EVERYONE,
	## Only the client that owns it.
	##
	## For state a player needs and opponents must not have: exact ammo, cooldowns,
	## whether an ability is off cooldown. Sending it to everyone is how a modified
	## client gets information the game never intended to give it.
	OWNER,
	## Everyone except the owner.
	##
	## For state the owner already predicts locally and would only be corrected by.
	OBSERVERS,
}

## The property name on the behaviour.
@export var property: StringName = &""

@export var type: Type = Type.FLOAT

@export var audience: Audience = Audience.EVERYONE

## Bit width for the integer and angle types.
@export_range(1, 64, 1) var bit_width: int = 32

## Range for the quantised types.
@export var min_value: float = -1.0
@export var max_value: float = 1.0

## Interpolate between snapshots on receiving clients.
##
## Right for anything continuous — position, rotation, a health bar that should slide.
## Wrong for anything discrete: interpolating a weapon index produces weapons that do
## not exist.
@export var interpolate: bool = false

## Send at most this many times per second. 0 uses the snapshot rate.
##
## For state that changes constantly but does not need to arrive constantly — a score,
## a stamina bar. Costs staleness, saves bandwidth.
@export_range(0.0, 240.0, 1.0) var max_rate: float = 0.0

## Send priority relative to other properties on the same entity.
##
## Consulted when a client's bandwidth budget cannot carry everything. Position
## usually outranks cosmetic state.
@export_range(0.0, 10.0, 0.1) var priority: float = 1.0

## Send once on spawn and only on change afterwards.
##
## For values that rarely change — a team, a name, a skin. The alternative is paying
## for them in every snapshot.
@export var on_spawn_only: bool = false

## Deadband: changes smaller than this are not sent.
##
## Suppresses the constant micro-updates floating-point drift produces. Only
## meaningful for numeric types.
@export var epsilon: float = 0.0

## Called on a receiving client when the value changes.
##
## Signature: [code]func(old_value: Variant, new_value: Variant) -> void[/code].
var change_handler: Callable = Callable()

## Custom encoder. Signature: [code]func(writer: DotNetWriter, value: Variant) -> void[/code].
var write_fn: Callable = Callable()

## Custom decoder. Signature: [code]func(reader: DotNetReader) -> Variant[/code].
var read_fn: Callable = Callable()

## Resolved at registration from the owning manager's config.
var _config: DotNetConfig = null


static func make(p_property: StringName, p_type: Type) -> DotNetVar:
	var v := DotNetVar.new()
	v.property = p_property
	v.type = p_type
	return v


# --- Fluent configuration --------------------------------------------------
#
# Chained rather than positional because a property declaration reads as a
# sentence, and a call with nine optional arguments does not.

func bits(count: int) -> DotNetVar:
	bit_width = clampi(count, 1, 64)
	return self


func range_of(p_min: float, p_max: float) -> DotNetVar:
	min_value = p_min
	max_value = p_max
	return self


func interpolated(enabled: bool = true) -> DotNetVar:
	interpolate = enabled
	return self


func to_owner_only() -> DotNetVar:
	audience = Audience.OWNER
	return self


func to_observers_only() -> DotNetVar:
	audience = Audience.OBSERVERS
	return self


func at_most(times_per_second: float) -> DotNetVar:
	max_rate = times_per_second
	return self


func with_priority(value: float) -> DotNetVar:
	priority = value
	return self


func once() -> DotNetVar:
	on_spawn_only = true
	return self


func with_epsilon(value: float) -> DotNetVar:
	epsilon = value
	return self


func on_change(handler: Callable) -> DotNetVar:
	change_handler = handler
	return self


## Supplies a codec for [constant Type.CUSTOM].
##
## The escape hatch that makes any type replicable. The pair must be exact inverses;
## nothing can check that for you, so round-trip them in a test.
func codec(writer_fn: Callable, reader_fn: Callable) -> DotNetVar:
	type = Type.CUSTOM
	write_fn = writer_fn
	read_fn = reader_fn
	return self


func bind_config(config: DotNetConfig) -> void:
	_config = config


# --- Serialisation ---------------------------------------------------------

## Writes a value according to this declaration.
func write(writer: DotNetWriter, value: Variant) -> void:
	match type:
		Type.BOOL:
			writer.write_bool(bool(value))

		Type.UINT:
			writer.write_uint(int(value), bit_width)

		Type.INT:
			writer.write_int(int(value), bit_width)

		Type.VARINT:
			writer.write_svarint(int(value))

		Type.FLOAT:
			writer.write_float32(float(value))

		Type.FLOAT_RANGE:
			writer.write_float_range(float(value), min_value, max_value, bit_width)

		Type.VECTOR3_POSITION:
			var extent := _extent()
			writer.write_vector3_range(
				value as Vector3, -extent, extent, _position_bits()
			)

		Type.VECTOR3_VELOCITY:
			var speed := _max_speed()
			writer.write_vector3_range(
				value as Vector3, -speed, speed, _velocity_bits()
			)

		Type.VECTOR3_RANGE:
			writer.write_vector3_range(
				value as Vector3, min_value, max_value, bit_width
			)

		Type.DIRECTION:
			writer.write_direction(value as Vector3, bit_width)

		Type.QUATERNION:
			writer.write_quaternion(value as Quaternion, _rotation_bits())

		Type.ANGLE:
			writer.write_angle(float(value), bit_width)

		Type.STRING:
			writer.write_string(str(value))

		Type.BYTES:
			writer.write_bytes(value as PackedByteArray)

		Type.CUSTOM:
			if write_fn.is_valid():
				write_fn.call(writer, value)
			else:
				push_error(
					"DotNetVar '%s' is CUSTOM but has no codec." % property
				)


## Reads a value according to this declaration.
func read(reader: DotNetReader) -> Variant:
	match type:
		Type.BOOL:
			return reader.read_bool()

		Type.UINT:
			return reader.read_uint(bit_width)

		Type.INT:
			return reader.read_int(bit_width)

		Type.VARINT:
			return reader.read_svarint()

		Type.FLOAT:
			return reader.read_float32()

		Type.FLOAT_RANGE:
			return reader.read_float_range(min_value, max_value, bit_width)

		Type.VECTOR3_POSITION:
			var extent := _extent()
			return reader.read_vector3_range(-extent, extent, _position_bits())

		Type.VECTOR3_VELOCITY:
			var speed := _max_speed()
			return reader.read_vector3_range(-speed, speed, _velocity_bits())

		Type.VECTOR3_RANGE:
			return reader.read_vector3_range(min_value, max_value, bit_width)

		Type.DIRECTION:
			return reader.read_direction(bit_width)

		Type.QUATERNION:
			return reader.read_quaternion(_rotation_bits())

		Type.ANGLE:
			return reader.read_angle(bit_width)

		Type.STRING:
			return reader.read_string()

		Type.BYTES:
			return reader.read_bytes()

		Type.CUSTOM:
			if read_fn.is_valid():
				return read_fn.call(reader)
			push_error("DotNetVar '%s' is CUSTOM but has no codec." % property)
			return null

	return null


## Whether two values differ enough to be worth sending.
##
## Applies [member epsilon] to numeric types. Without a deadband, a float that drifts
## in its last bit is dirty every tick forever, and the property costs full bandwidth
## while never visibly changing.
func differs(old_value: Variant, new_value: Variant) -> bool:
	if epsilon <= 0.0:
		return not _values_equal(old_value, new_value)

	if old_value is float and new_value is float:
		return absf(float(old_value) - float(new_value)) > epsilon

	if old_value is Vector3 and new_value is Vector3:
		return (old_value as Vector3).distance_to(new_value as Vector3) > epsilon

	if old_value is Vector2 and new_value is Vector2:
		return (old_value as Vector2).distance_to(new_value as Vector2) > epsilon

	if old_value is int and new_value is int:
		return absi(int(old_value) - int(new_value)) > int(epsilon)

	return not _values_equal(old_value, new_value)


static func _values_equal(a: Variant, b: Variant) -> bool:
	# typeof first: `==` between a null and a Vector3 is false, but between two
	# different types it can be true in ways that hide a real change.
	if typeof(a) != typeof(b):
		return false
	return a == b


## Whether [param peer_id] should receive this property.
func visible_to(peer_id: int, owner_peer_id: int) -> bool:
	match audience:
		Audience.OWNER:
			return peer_id == owner_peer_id
		Audience.OBSERVERS:
			return peer_id != owner_peer_id
		_:
			return true


# --- Config-derived widths -------------------------------------------------

func _extent() -> float:
	return _config.world_extent if _config != null else 2048.0


func _position_bits() -> int:
	return _config.position_bits() if _config != null else 19


func _max_speed() -> float:
	return _config.max_speed if _config != null else 100.0


func _velocity_bits() -> int:
	return _config.velocity_bits if _config != null else 12


func _rotation_bits() -> int:
	return _config.rotation_bits if _config != null else 9


## Approximate bits this property costs, for budgeting.
##
## Exact for fixed-width types and a guess for the variable ones — which is enough,
## because the budget only needs to know roughly what it is spending.
func estimated_bits() -> int:
	match type:
		Type.BOOL: return 1
		Type.UINT, Type.INT, Type.ANGLE, Type.FLOAT_RANGE: return bit_width
		Type.VARINT: return 16
		Type.FLOAT: return 32
		Type.VECTOR3_POSITION: return _position_bits() * 3
		Type.VECTOR3_VELOCITY: return _velocity_bits() * 3
		Type.VECTOR3_RANGE: return bit_width * 3
		Type.DIRECTION: return bit_width * 2
		Type.QUATERNION: return _rotation_bits() * 3 + 2
		Type.STRING: return 128
		Type.BYTES: return 256
		Type.CUSTOM: return 64
	return 32


func _to_string() -> String:
	return "DotNetVar(%s: %s, %d bits)" % [
		property, Type.keys()[type], estimated_bits()
	]
