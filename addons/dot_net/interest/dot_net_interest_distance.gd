@tool
class_name DotNetInterestDistance
extends DotNetInterest

## Replicates entities within a radius of the observer.
##
## The simplest useful strategy, and enough for most games. Costs one distance check
## per entity per observer, which is fine into the low thousands of entities and
## becomes the bottleneck above that — [DotNetInterestGrid] exists for that case.
##
## [b]Per-tag radii are the useful part.[/b] A player needs to know about other
## players much further away than about dropped items or decorative props, and one
## radius for everything is either too small for players or too large for props.

## Default radius in metres.
@export var radius: float = 200.0

## Per-tag overrides, as [code]tag -> radius[/code].
##
## The first matching tag on an entity wins, so order the entity's tags by
## specificity.
@export var radius_by_tag: Dictionary = {}

## Entities with any of these tags are always replicated.
##
## For categories rather than individuals — [member DotNetIdentity.always_relevant]
## covers a single entity, this covers "every objective".
@export var always_tags: PackedStringArray = PackedStringArray()

## Use squared distance and skip the square root.
##
## Free correctness-preserving speedup; off only if a subclass overrides the
## comparison in a way that needs real distances.
@export var use_squared: bool = true


func _init() -> void:
	strategy_name = "distance"


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

	var limit := _radius_for(entity)

	if use_squared:
		var limit_squared := limit * limit
		return observer.world_position().distance_squared_to(
			entity.world_position()
		) <= limit_squared

	return observer.world_position().distance_to(entity.world_position()) <= limit


func _radius_for(entity: DotNetIdentity) -> float:
	for tag in entity.interest_tags:
		if radius_by_tag.has(tag):
			return float(radius_by_tag[tag])
	return radius


func _score(
	observer: DotNetIdentity,
	entity: DotNetIdentity,
	_context: Dictionary
) -> float:
	if observer == null:
		return entity.priority

	# Normalised by the entity's own radius, so a prop at the edge of its short
	# radius and a player at the edge of its long one are equally unimportant.
	var limit := maxf(1.0, _radius_for(entity))
	var distance := observer.world_position().distance_to(entity.world_position())

	return entity.priority * (1.0 - clampf(distance / limit, 0.0, 1.0))


func describe() -> Dictionary:
	var d := super.describe()
	d["radius"] = radius
	d["tag_radii"] = radius_by_tag
	return d
