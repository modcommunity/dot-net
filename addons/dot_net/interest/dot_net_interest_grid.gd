@tool
class_name DotNetInterestGrid
extends DotNetInterest

## Spatial-hash interest, for worlds with too many entities to scan per observer.
##
## [DotNetInterestDistance] is O(observers × entities). At 100 players and 5000
## entities that is half a million distance checks per evaluation. This bins entities
## into cells once per snapshot and each observer only visits the cells its radius
## touches — O(entities + observers × cells).
##
## [b]Cell size is the whole tuning story.[/b] Too small and an observer visits many
## cells and the rebuild dominates; too large and each cell returns far more entities
## than are actually in range. A cell roughly equal to the radius means an observer
## touches nine cells in 2D or so, which is the sweet spot.
##
## [b]Rebuilt every evaluation, not maintained incrementally.[/b] Entities move every
## tick, so an incremental index would be updating most of itself anyway, and a full
## rebuild is a linear pass with no bookkeeping to get wrong.

## Cell edge length in metres.
@export var cell_size: float = 128.0

## Radius in metres.
@export var radius: float = 200.0

## Entities with any of these tags are always replicated.
@export var always_tags: PackedStringArray = PackedStringArray()

## Bin on the horizontal plane only.
##
## Right for almost every game: worlds are much wider than they are tall, and a third
## axis multiplies the cell count for a dimension that rarely separates anything.
@export var ignore_vertical: bool = true

## cell key -> Array[DotNetIdentity]
var _cells: Dictionary = {}
var _indexed_count: int = 0


func _init() -> void:
	strategy_name = "grid"


## Rebuilds the index.
func _prepare(all: Array[DotNetIdentity], _context: Dictionary) -> void:
	_cells.clear()
	_indexed_count = 0

	for identity in all:
		if identity.always_relevant:
			# Never queried spatially, so keeping it out of the index keeps the
			# cells smaller.
			continue

		var key := _cell_key(identity.world_position())

		if not _cells.has(key):
			_cells[key] = []

		(_cells[key] as Array).append(identity)
		_indexed_count += 1


## Returns only entities in the cells the observer's radius touches.
func _candidates(
	observer: DotNetIdentity,
	all: Array[DotNetIdentity],
	_context: Dictionary
) -> Variant:
	if observer == null or _cells.is_empty():
		return null

	var centre := observer.world_position()
	var reach := int(ceilf(radius / maxf(1.0, cell_size)))

	var out: Array[DotNetIdentity] = []

	var cx := int(floorf(centre.x / cell_size))
	var cy := 0 if ignore_vertical else int(floorf(centre.y / cell_size))
	var cz := int(floorf(centre.z / cell_size))

	var y_range := [0] if ignore_vertical else range(-reach, reach + 1)

	for dx in range(-reach, reach + 1):
		for dy in y_range:
			for dz in range(-reach, reach + 1):
				var key := _key(cx + dx, cy + int(dy), cz + dz)
				if _cells.has(key):
					out.append_array(_cells[key])

	# always_relevant entities are not in the index, so they are added back here or
	# they would never be replicated under this strategy.
	for identity in all:
		if identity.always_relevant:
			out.append(identity)

	return out


func _is_relevant(
	observer: DotNetIdentity,
	entity: DotNetIdentity,
	_context: Dictionary
) -> bool:
	if observer == null:
		return true

	for tag in always_tags:
		if entity.has_tag(tag):
			return true

	# The cell query is a coarse filter — a cell that overlaps the radius contains
	# entities outside it — so the exact check still runs, on a much smaller set.
	return observer.world_position().distance_squared_to(
		entity.world_position()
	) <= radius * radius


func _score(
	observer: DotNetIdentity,
	entity: DotNetIdentity,
	_context: Dictionary
) -> float:
	if observer == null:
		return entity.priority

	var distance := observer.world_position().distance_to(entity.world_position())
	return entity.priority * (1.0 - clampf(distance / maxf(1.0, radius), 0.0, 1.0))


func _cell_key(position: Vector3) -> int:
	return _key(
		int(floorf(position.x / cell_size)),
		0 if ignore_vertical else int(floorf(position.y / cell_size)),
		int(floorf(position.z / cell_size))
	)


## Packs three cell coordinates into one integer key.
##
## Dictionary lookups on an int are much cheaper than on a Vector3i or a string, and
## this runs once per entity per rebuild. 21 bits per axis covers ±1,048,576 cells,
## which at a 128 m cell is a world far larger than anything that would fit in memory.
static func _key(x: int, y: int, z: int) -> int:
	return ((x & 0x1FFFFF) << 42) | ((y & 0x1FFFFF) << 21) | (z & 0x1FFFFF)


func describe() -> Dictionary:
	var d := super.describe()
	d["cell_size"] = cell_size
	d["radius"] = radius
	d["cells"] = _cells.size()
	d["indexed"] = _indexed_count
	return d
