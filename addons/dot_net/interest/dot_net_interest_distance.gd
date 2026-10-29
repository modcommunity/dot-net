@tool
class_name DotNetInterestDistance
extends DotNetInterest

## Replicates entities within a radius of the observer. The simplest useful strategy, and enough for
## most games.

## Default radius in metres.
@export var radius: float = 200.0

## Per-tag overrides, as [code]tag -> radius[/code].
@export var radius_by_tag: Dictionary = {}

## Entities with any of these tags are always replicated. For categories rather than individuals —
## [member DotNetIdentity.always_relevant] covers a single entity, this covers "every objective".
@export var always_tags: PackedStringArray = PackedStringArray()

## Use squared distance and skip the square root. Free correctness-preserving speedup; off only if a
## subclass overrides the comparison in a way that needs real distances.
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


## The base loop with [method _is_relevant] inlined for this class's plain case (no tags, squared
## distances): one observer position per peer and no call per entity, which was most of a
## 100-player snapshot's interest time. A subclass, or any tag in play, takes the base loop.
func _evaluate_into(
	out: Array,
	observer: DotNetIdentity,
	all: Array[DotNetIdentity],
	context: Dictionary
) -> void:
	if observer == null or not use_squared or not always_tags.is_empty() or not _exact():
		super._evaluate_into(out, observer, all, context)
		return
	var here := observer.world_position()
	var owner := observer.owner_peer_id
	var limit_squared := radius * radius
	for identity in all:
		if identity.always_relevant or identity.owner_peer_id == owner:
			out.append(identity)
		elif identity.interest_tags.is_empty():
			if here.distance_squared_to(identity.world_position()) <= limit_squared:
				out.append(identity)
		else:
			var limit := radius
			for tag in identity.interest_tags:
				if radius_by_tag.has(tag):
					limit = float(radius_by_tag[tag])
					break
			if here.distance_squared_to(identity.world_position()) <= limit * limit:
				out.append(identity)


## [method DotNetInterest.scores_for] with [method _score] inlined, as above.
func scores_for(observer: DotNetIdentity, entities: Array, context: Dictionary) -> Dictionary:
	if observer == null or not _exact():
		return super.scores_for(observer, entities, context)
	var out := {}
	var here := observer.world_position()
	var plain := maxf(1.0, radius)
	var by_tag := radius_by_tag
	for identity: DotNetIdentity in entities:
		var limit := plain
		for tag in identity.interest_tags:
			if by_tag.has(tag):
				limit = maxf(1.0, float(by_tag[tag]))
				break
		var distance := here.distance_to(identity.world_position())
		out[identity.net_id] = identity.priority * (1.0 - clampf(distance / limit, 0.0, 1.0))
	return out


## Only this class itself with plain squared distances and no always-on tags: the cases the native
## core ports line for line.
func native_interest_ok() -> bool:
	return _exact() and use_squared and always_tags.is_empty()


func native_config(config: DotNetConfig) -> Dictionary:
	return {
		"on": true, "radius": radius, "radius_by_tag": radius_by_tag,
		"interval": evaluation_interval_sec, "far_every": far_every, "far_distance": far_distance,
		"far_by_tag": far_distance_by_tag, "far_coherent": far_coherent, "far_tiers": far_tiers,
		"ticks_per_snapshot": config.ticks_per_snapshot(), "cap": config.entity_cap(),
		"send_budget": config.peer_send_budget, "invalidation": invalidation_serial,
	}


func _exact() -> bool:
	return (get_script() as Script).get_global_name() == &"DotNetInterestDistance"


func describe() -> Dictionary:
	var d := super.describe()
	d["radius"] = radius
	d["tag_radii"] = radius_by_tag
	return d


## Thread-safe as itself, not as a subclass: see [method DotNetInterest.is_thread_safe].
## Reads only frozen positions, the identities' fields and its own exports.
func is_thread_safe() -> bool:
	return (get_script() as Script).get_global_name() == &"DotNetInterestDistance"
