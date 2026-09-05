@tool
class_name DotNetInterest
extends Resource

## Decides which entities a client is told about. Subclass to define your own rule.
##
## [b]The single biggest lever on server bandwidth.[/b] Sending every entity to every
## client is quadratic: 100 players each hearing about 100 entities is 10,000 updates
## a tick. Sending only what a client can perceive turns that into a constant per
## client, and it is the difference between 20 players and 200 on the same hardware.
##
## It is also an anti-cheat measure, and the only one that actually works. A client
## that is never told where an enemy is cannot draw a box around them, no matter what
## it does to its own renderer. Everything else — obfuscation, client-side checks,
## detection — is a delaying action; not sending the data is not.
##
## [b]A [Resource], so a game swaps the whole strategy without touching dot-net.[/b]
## The built-ins cover the common cases; a game with rooms, teams, portals,
## line-of-sight or a fog of war writes its own and the rest of the pipeline does not
## change.
##
## [codeblock]
## class_name TeamInterest extends DotNetInterest
##
## func _is_relevant(observer, entity, ctx) -> bool:
##     # Teammates always; everyone else only within earshot.
##     if entity.has_tag("player") and _same_team(observer, entity):
##         return true
##     return observer.world_position().distance_to(entity.world_position()) < 50.0
## [/codeblock]

const CHANNEL := "net.interest"

## Human-readable name, for `net_status`.
@export var strategy_name: String = "custom"

## Consulted at most this often per observer, in seconds. 0 evaluates every snapshot.
##
## Interest rarely changes as fast as state does. Re-evaluating a grid query 20 times
## a second for 100 players is real CPU for an answer that changes a few times a
## second; a cached answer refreshed at 4 Hz is almost always identical and costs a
## twentieth as much.
@export_range(0.0, 5.0, 0.05) var evaluation_interval_sec: float = 0.25

## observer peer_id -> {at_ms, ids: Dictionary}
var _cache: Dictionary = {}

## observer peer_id -> {net_id: leave_at_ms}
##
## Entities that have left interest but are still being sent, to stop an entity on
## the boundary from flickering in and out.
var _lingering: Dictionary = {}


# --- Subclass interface ----------------------------------------------------

## Whether [param observer] should know about [param entity].
##
## [param context] carries whatever the manager knows: [code]tick[/code],
## [code]peer_id[/code], and the config. Override this and nothing else for most
## strategies.
func _is_relevant(
	_observer: DotNetIdentity,
	_entity: DotNetIdentity,
	_context: Dictionary
) -> bool:
	return true


## Optional bulk filter, when a strategy can answer faster than one at a time.
##
## A spatial index can return a candidate set directly instead of being asked about
## every entity in the world — which is the difference between O(n) and O(visible)
## per observer. Return null to fall back to [method _is_relevant] per entity.
func _candidates(
	_observer: DotNetIdentity,
	_all: Array[DotNetIdentity],
	_context: Dictionary
) -> Variant:
	return null


## Called once per snapshot before any queries, for strategies with an index to
## rebuild.
func _prepare(_all: Array[DotNetIdentity], _context: Dictionary) -> void:
	pass


## Relative importance of an entity to an observer, for prioritisation.
##
## Consulted when the bandwidth budget cannot carry everything relevant. Higher is
## sent first. The default weights by proximity, because a distant entity's staleness
## is less visible than a near one's.
func _score(
	observer: DotNetIdentity,
	entity: DotNetIdentity,
	_context: Dictionary
) -> float:
	if observer == null or entity == null:
		return 1.0

	var distance := observer.world_position().distance_to(entity.world_position())
	return entity.priority / (1.0 + distance * 0.01)


# --- Public API ------------------------------------------------------------

## The entities [param observer] should receive, with the cache and linger applied.
func relevant_for(
	observer: DotNetIdentity,
	all: Array[DotNetIdentity],
	peer_id: int,
	context: Dictionary
) -> Array[DotNetIdentity]:
	var now := Time.get_ticks_msec()

	if evaluation_interval_sec > 0.0 and _cache.has(peer_id):
		var cached: Dictionary = _cache[peer_id]
		var age := float(now - int(cached["at_ms"])) / 1000.0

		if age < evaluation_interval_sec:
			# Pinned before the cache is consulted, not after [method _evaluate] runs.
			# The cache is a cache of *which entities existed and where* at one instant,
			# and an entity spawned since is in nobody's cached set — so without this an
			# observer does not receive its own newly spawned entity until the cache
			# expires, and neither does anything marked always relevant.
			#
			# [b]That is not a small window.[/b] In a game where players respawn, split or
			# spawn projectiles, a quarter of a second of an entity that exists only by
			# prediction is a monster that pops into place on every respawn — and on a
			# host that ticks faster than the wall clock, which is every headless test,
			# the cache never expires at all and the entity is never sent even once. The
			# position still looks right the whole time, because the owning client is
			# predicting it; what does not arrive is everything it cannot predict.
			return _resolve(_pinned(cached["ids"], observer, all), all)

	var relevant := _evaluate(observer, all, context)

	var ids := {}
	for identity in relevant:
		ids[identity.net_id] = true

	# Anything that was relevant and no longer is keeps being sent for a while.
	# Without this an entity pacing across the boundary costs a full spawn and
	# despawn several times a second.
	var linger := _lingering.get(peer_id, {}) as Dictionary
	var previous: Dictionary = _cache.get(peer_id, {}).get("ids", {})

	for net_id in previous:
		if not ids.has(net_id) and not linger.has(net_id):
			linger[net_id] = now

	var still_lingering := {}
	for net_id in linger:
		if ids.has(net_id):
			continue

		var identity := _find(all, net_id)
		if identity == null:
			continue

		var elapsed := float(now - int(linger[net_id])) / 1000.0
		if elapsed < identity.interest_linger_sec:
			still_lingering[net_id] = linger[net_id]
			ids[net_id] = true
			relevant.append(identity)

	_lingering[peer_id] = still_lingering
	_cache[peer_id] = {"at_ms": now, "ids": ids}

	return relevant


## Adds what an observer must receive whatever the cache says.
##
## The same two exemptions [method _evaluate] applies, applied to a cached answer: an
## entity the observer owns, and anything marked [member DotNetIdentity.always_relevant].
## Both are guarantees rather than heuristics — a client that stopped being told about its
## own character would be unplayable, and an objective marker that popped in is a bug
## rather than an optimisation — so neither may wait for a cache to expire.
##
## Returns a new dictionary rather than mutating the cached one: mutating it would make
## the cache grow with every entity that has ever been pinned into it, and those entries
## would then survive the expiry that is supposed to re-evaluate them.
func _pinned(
	ids: Dictionary,
	observer: DotNetIdentity,
	all: Array[DotNetIdentity]
) -> Dictionary:
	var out := ids

	for identity in all:
		if ids.has(identity.net_id):
			continue

		if not identity.always_relevant and (
			observer == null or identity.owner_peer_id != observer.owner_peer_id
		):
			continue

		if out == ids:
			out = ids.duplicate()

		out[identity.net_id] = true

	return out


func _evaluate(
	observer: DotNetIdentity,
	all: Array[DotNetIdentity],
	context: Dictionary
) -> Array[DotNetIdentity]:
	var out: Array[DotNetIdentity] = []

	var candidates: Variant = _candidates(observer, all, context)
	var pool: Array[DotNetIdentity] = candidates if candidates is Array else all

	for identity in pool:
		# always_relevant bypasses the strategy entirely. For objectives, bosses and
		# anything whose absence would be a bug rather than an optimisation.
		if identity.always_relevant:
			out.append(identity)
			continue

		# An observer always receives what it owns, whatever the strategy says.
		# A client that stopped being told about its own character would be
		# unplayable, and every strategy would otherwise have to remember this.
		if observer != null and identity.owner_peer_id == observer.owner_peer_id:
			out.append(identity)
			continue

		if _is_relevant(observer, identity, context):
			out.append(identity)

	return out


## Sorts by score and truncates to the entity cap.
##
## The backstop when interest management alone is not enough — a hundred players in
## one room. Something has to be dropped, and dropping the least relevant is better
## than dropping whatever happened to be last.
func prioritise(
	observer: DotNetIdentity,
	entities: Array[DotNetIdentity],
	limit: int,
	context: Dictionary
) -> Array[DotNetIdentity]:
	if limit <= 0 or entities.size() <= limit:
		return entities

	var scored: Array = []
	for identity in entities:
		scored.append({
			"identity": identity,
			# always_relevant entities are pinned above everything else, so the cap
			# never drops the objective marker in favour of scenery.
			"score": 1e9 if identity.always_relevant else _score(observer, identity, context),
		})

	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["score"]) > float(b["score"])
	)

	var out: Array[DotNetIdentity] = []
	for i in range(limit):
		out.append(scored[i]["identity"])

	return out


static func _find(all: Array[DotNetIdentity], net_id: int) -> DotNetIdentity:
	for identity in all:
		if identity.net_id == net_id:
			return identity
	return null


func _resolve(ids: Dictionary, all: Array[DotNetIdentity]) -> Array[DotNetIdentity]:
	var out: Array[DotNetIdentity] = []
	for identity in all:
		if ids.has(identity.net_id):
			out.append(identity)
	return out


## Forgets a peer's cached set. Call on disconnect.
func forget_peer(peer_id: int) -> void:
	_cache.erase(peer_id)
	_lingering.erase(peer_id)


## Drops every cached answer, forcing re-evaluation.
##
## For a level change, a team switch, anything that invalidates the rule's inputs
## wholesale.
func invalidate() -> void:
	_cache.clear()
	_lingering.clear()


func describe() -> Dictionary:
	return {
		"strategy": strategy_name,
		"interval": evaluation_interval_sec,
		"cached_observers": _cache.size(),
	}
