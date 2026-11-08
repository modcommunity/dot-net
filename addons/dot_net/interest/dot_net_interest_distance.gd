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

## The map's potentially visible set: an entity in range is dropped when the map says nothing in the
## observer's cluster could see anything in its cluster. Null (the default) is distance only. Owned and always-relevant
## entities and [member always_tags] are never dropped. Cuts what a wall hides, which on an indoor map
## smaller than [member radius] is the only thing that cuts anything. [method invalidate]s on change.
@export var visibility: DotNetVisibility = null:
	set(value):
		visibility = value
		invalidate()

## The switch for [member visibility] without unloading it (a cvar, a mode with x-ray).
@export var visibility_enabled: bool = true:
	set(value):
		if value != visibility_enabled:
			visibility_enabled = value
			invalidate()

## Within this many metres [member visibility] is not asked: what is close behind a wall is heard,
## and is round the corner a moment later. 0 asks at every distance.
@export var visibility_audible_radius: float = 8.0

static var _native_visibility: int = -1

## Per identity, its cluster this snapshot ([method _prepare]); empty outside a snapshot.
var _clusters: Dictionary = {}


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
	var here := observer.world_position()
	var there := entity.world_position()

	if use_squared:
		var limit_squared := limit * limit
		if here.distance_squared_to(there) > limit_squared:
			return false
	elif here.distance_to(there) > limit:
		return false

	return not _visibility_on() or _sees(here, there)


## Whether [member visibility] is in force.
func _visibility_on() -> bool:
	return visibility_enabled and visibility != null and visibility.is_ready()


## [member visibility] past [member visibility_audible_radius].
func _sees(here: Vector3, there: Vector3) -> bool:
	if here.distance_squared_to(there) <= visibility_audible_radius * visibility_audible_radius:
		return true
	return visibility.visible(here, there)


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
	if _visibility_on():
		_evaluate_visible_into(out, here, owner, all)
		return
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


## Each identity's cluster, once per snapshot: a tree walk per entity rather than per pair. Not
## when the native core will answer (it walks its own); a GDScript question then walks per pair.
func _prepare(all: Array[DotNetIdentity], context: Dictionary) -> void:
	super._prepare(all, context)
	_clusters = {}
	var config := context.get("config") as DotNetConfig
	if _visibility_on() and not (config != null and config.native and config.native_interest and native_interest_ok()):
		for identity in all:
			_clusters[identity] = visibility.cluster_of(identity.world_position())


func index_snapshot(all: Array[DotNetIdentity]) -> void:
	super.index_snapshot(all)
	if all.is_empty():
		_clusters = {}


## The cluster of [param identity] at [param at]: [method _prepare]'s, or walked now outside a snapshot.
func _cluster(identity: DotNetIdentity, at: Vector3) -> int:
	var known: Variant = _clusters.get(identity)
	return int(known) if known != null else visibility.cluster_of(at)


## The loop above with [member visibility]: the observer's cluster looked up once, the bit test after
## the distance test, as the native core does it.
func _evaluate_visible_into(out: Array, here: Vector3, owner: int, all: Array[DotNetIdentity]) -> void:
	var vis := visibility
	var from_cluster := vis.cluster_of(here)
	var audible_squared := visibility_audible_radius * visibility_audible_radius
	for identity in all:
		if identity.always_relevant or identity.owner_peer_id == owner:
			out.append(identity)
			continue
		var limit := radius
		for tag in identity.interest_tags:
			if radius_by_tag.has(tag):
				limit = float(radius_by_tag[tag])
				break
		var there := identity.world_position()
		var d2 := here.distance_squared_to(there)
		if d2 <= limit * limit and (d2 <= audible_squared or vis.cluster_sees(from_cluster, _cluster(identity, there))):
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
## With [member visibility] on, only a core that has it ([code]DotNetNativeCore.visibility_supported[/code]);
## an older binary leaves interest to GDScript rather than ignoring the walls.
func native_interest_ok() -> bool:
	if not (_exact() and use_squared and always_tags.is_empty()):
		return false
	if _visibility_on():
		if _native_visibility < 0:
			_native_visibility = 1 if ClassDB.class_exists(&"DotNetNativeCore") \
				and ClassDB.class_has_method(&"DotNetNativeCore", &"visibility_supported") else 0
		return _native_visibility == 1
	return true


func native_config(config: DotNetConfig) -> Dictionary:
	return {
		"on": true, "radius": radius, "radius_by_tag": radius_by_tag,
		"interval": evaluation_interval_sec, "far_every": far_every, "far_distance": far_distance,
		"far_by_tag": far_distance_by_tag, "far_coherent": far_coherent, "far_tiers": far_tiers,
		"ticks_per_snapshot": config.ticks_per_snapshot(), "cap": config.entity_cap(),
		"send_budget": config.peer_send_budget, "invalidation": invalidation_serial,
		"vis": visibility.native_dict() if _visibility_on() else {},
		"vis_audible": visibility_audible_radius,
	}


func _exact() -> bool:
	return (get_script() as Script).get_global_name() == &"DotNetInterestDistance"


func describe() -> Dictionary:
	var d := super.describe()
	d["radius"] = radius
	d["tag_radii"] = radius_by_tag
	d["visibility"] = visibility.describe() if _visibility_on() else "off"
	return d


## Thread-safe as itself, not as a subclass: see [method DotNetInterest.is_thread_safe].
## Reads only frozen positions, the identities' fields and its own exports.
func is_thread_safe() -> bool:
	return (get_script() as Script).get_global_name() == &"DotNetInterestDistance"
