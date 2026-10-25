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

## Entities past [member far_distance] are sent in one snapshot of this many, staggered by net id
## (1 is off). The observer's own are never thinned; keep it near
## [member DotNetConfig.interpolation_buffer] or far mirrors run out of samples.
@export_range(1, 16, 1) var far_every: int = 1

## Metres beyond which an entity counts as far for [member far_every]. 0 is never far.
@export var far_distance: float = 0.0

## Per-tag [member far_distance], as [code]tag -> metres[/code]; the first matching tag wins.
@export var far_distance_by_tag: Dictionary = {}

## observer peer_id -> {at_ms, ids: Dictionary}
var _cache: Dictionary = {}

## observer peer_id -> {net_id: leave_at_ms}
##
## Entities that have left interest but are still being sent, to stop an entity on
## the boundary from flickering in and out.
var _lingering: Dictionary = {}

## observer peer_id -> {capped: bool, warned: bool, since_tick: int}
##
## Whether [method prioritise] is currently cutting this peer's relevant set, so the
## log reports the EDGES of that condition rather than every snapshot it holds.
var _cap_state: Dictionary = {}


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

## Whether [method thin_into] drops anything at all, so a caller can skip it.
func thins() -> bool:
	return far_every > 1 and (far_distance > 0.0 or not far_distance_by_tag.is_empty())


## [param relevant] without the far entities whose turn this snapshot is not (see
## [member far_every]), appended to [param out]. Reads frozen positions and fields only, so a
## worker may run it; [param out] is untyped there (see [method relevance]).
func thin_into(out: Array, observer: DotNetIdentity, relevant: Array, peer_id: int, context: Dictionary) -> void:
	if observer == null or not thins():
		out.append_array(relevant)
		return
	var config: DotNetConfig = context.get("config")
	var index := int(context.get("tick", 0)) / (config.ticks_per_snapshot() if config != null else 1)
	var here := observer.world_position()
	for identity: DotNetIdentity in relevant:
		if identity.owner_peer_id == observer.owner_peer_id \
				or (index + identity.net_id + peer_id) % far_every == 0:
			out.append(identity)
			continue
		var far := _far_distance_for(identity)
		if far <= 0.0 or here.distance_squared_to(identity.world_position()) <= far * far:
			out.append(identity)


func _far_distance_for(entity: DotNetIdentity) -> float:
	for tag in entity.interest_tags:
		if far_distance_by_tag.has(tag):
			return float(far_distance_by_tag[tag])
	return far_distance


## Whether [method relevance], [method ranked] and [method _score] may run on a worker
## thread, for several peers at once ([member DotNetConfig.snapshot_workers]). False unless a
## strategy says otherwise, and the built-in ones say so only for themselves (their own script,
## not a subclass), because a subclass is a game's code and nothing here can tell whether it
## reads a node, a physics space or a shared container. Return true from a subclass when
## [method _is_relevant], [method _candidates] and [method _score] read nothing but
## [method DotNetIdentity.world_position] (frozen for the snapshot), the identities' own fields,
## [param context] and the strategy's own exports, and write nothing at all. [method _prepare]
## runs on the main thread before the fork and may do anything.
##
## A strategy that answers false keeps every snapshot on the manager's thread: correct, and as
## fast as before the option existed.
func is_thread_safe() -> bool:
	return false


## The entities [param observer] should receive, with the cache and linger applied.
##
## The manager's own path, writing the cache as it goes. [method relevance] and
## [method commit_relevance] are the same answer split for a worker thread; kept apart
## rather than this calling them, because the split's copies and untyped lists cost every
## snapshot on this thread (see [method DotNetManager._send_to_peer]).
func relevant_for(
	observer: DotNetIdentity,
	all: Array[DotNetIdentity],
	peer_id: int,
	context: Dictionary
) -> Array[DotNetIdentity]:
	var now := int(context["now_ms"]) if context.has("now_ms") else Time.get_ticks_msec()

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

		var identity := _find_in(all, net_id)
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


## [method relevant_for] without its writes: [code][relevant, cache entry, lingering][/code],
## the last two null when the cached answer was used, for [method commit_relevance] to store.
## What a snapshot built on a worker thread asks, since the cache is shared by every peer.
##
## [b]The list is an untyped [Array][/b], here and in [method ranked] and [method _evaluate].
## Appending a node to an [code]Array[DotNetIdentity][/code] checks its script through
## [method Node.get_script], which refuses a worker thread for a node in the tree: the append
## fails with "The caller thread can't call the function get_script()" and the entity is
## silently missing from the snapshot. A main-thread caller wanting the typed list
## [method Array.assign]s it, as [method relevant_for] does.
##
## The time is [code]context["now_ms"][/code] when the caller gives one, which the manager
## does once per snapshot: read here per peer, two peers a millisecond apart on either side of
## the evaluation interval could get a cached and a fresh answer in one snapshot, and the same
## snapshot built twice could differ.
func relevance(
	observer: DotNetIdentity,
	all: Array[DotNetIdentity],
	peer_id: int,
	context: Dictionary
) -> Array:
	var now := int(context["now_ms"]) if context.has("now_ms") else Time.get_ticks_msec()

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
			var resolved: Array = []
			_resolve_into(resolved, _pinned(cached["ids"], observer, all), all)
			return [resolved, null, null]

	var relevant: Array = []
	_evaluate_into(relevant, observer, all, context)

	var ids := {}
	for identity: DotNetIdentity in relevant:
		ids[identity.net_id] = true

	# Anything that was relevant and no longer is keeps being sent for a while.
	# Without this an entity pacing across the boundary costs a full spawn and
	# despawn several times a second.
	# A copy: the stored one is written to below, and this must not write.
	var linger := (_lingering.get(peer_id, {}) as Dictionary).duplicate()
	var previous: Dictionary = _cache.get(peer_id, {}).get("ids", {})

	for net_id in previous:
		if not ids.has(net_id) and not linger.has(net_id):
			linger[net_id] = now

	var still_lingering := {}
	for net_id in linger:
		if ids.has(net_id):
			continue

		var identity := _find_in(all, net_id)
		if identity == null:
			continue

		var elapsed := float(now - int(linger[net_id])) / 1000.0
		if elapsed < identity.interest_linger_sec:
			still_lingering[net_id] = linger[net_id]
			ids[net_id] = true
			relevant.append(identity)

	return [relevant, {"at_ms": now, "ids": ids}, still_lingering]


## Stores what [method relevance] worked out for [param peer_id]. Main thread.
func commit_relevance(peer_id: int, answer: Array) -> void:
	if answer[1] == null:
		return
	_lingering[peer_id] = answer[2]
	_cache[peer_id] = answer[1]


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
	_evaluate_into(out, observer, all, context)
	return out


## [method _evaluate] into [param out]: typed on the manager's thread, untyped on a worker
## (see [method relevance]).
func _evaluate_into(
	out: Array,
	observer: DotNetIdentity,
	all: Array[DotNetIdentity],
	context: Dictionary
) -> void:
	var candidates: Variant = _candidates(observer, all, context)
	var pool: Array = candidates if candidates is Array else all

	for identity: DotNetIdentity in pool:
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


## Sorts by score and truncates to the entity cap.
##
## The backstop when interest management alone is not enough — a hundred players in
## one room. Something has to be dropped, and dropping the least relevant is better
## than dropping whatever happened to be last.
## [param scores] is [method scores_for]'s answer when the caller has it, so nothing is
## scored twice.
func prioritise(
	observer: DotNetIdentity,
	entities: Array[DotNetIdentity],
	limit: int,
	context: Dictionary,
	peer_id: int = 0,
	scores: Dictionary = {}
) -> Array[DotNetIdentity]:
	_note_cap(peer_id, entities.size(), limit, context)

	if limit <= 0 or entities.size() <= limit:
		return entities

	var out: Array[DotNetIdentity] = []
	_rank_into(out, observer, entities, limit, context, scores)
	return out


## [method prioritise] without its bookkeeping (the cap's log lines, see [method note_cap]),
## into an untyped list: the part a worker thread may run.
func ranked(
	observer: DotNetIdentity,
	entities: Array,
	limit: int,
	context: Dictionary,
	scores: Dictionary = {}
) -> Array:
	if limit <= 0 or entities.size() <= limit:
		return entities

	var out: Array = []
	_rank_into(out, observer, entities, limit, context, scores)
	return out


## Every entity's [method _score] for [param observer], by net id: what the entity cap and the
## budget both rank by, worked out once per peer. Reads what [method _score] reads, so a worker
## may run it when [method is_thread_safe] says so.
func scores_for(observer: DotNetIdentity, entities: Array, context: Dictionary) -> Dictionary:
	var out := {}
	for identity: DotNetIdentity in entities:
		out[identity.net_id] = _score(observer, identity, context)
	return out


func _rank_into(
	out: Array,
	observer: DotNetIdentity,
	entities: Array,
	limit: int,
	context: Dictionary,
	scores: Dictionary = {}
) -> void:
	# (-score, index) pairs sorted natively: a sort_custom over dictionaries was 0.7 ms a peer
	# at 250 relevant. Always-relevant entities are pinned above everything else.
	var keys: Array[Vector2] = []
	keys.resize(entities.size())
	var given := not scores.is_empty()
	for i in entities.size():
		var identity: DotNetIdentity = entities[i]
		var score: float = float(scores[identity.net_id]) if given else _score(observer, identity, context)
		keys[i] = Vector2(-1e9 if identity.always_relevant else -score, i)
	keys.sort()

	for i in range(limit):
		out.append(entities[int(keys[i].y)])


## Reports the edges of "the cap is cutting what this peer should see".
##
## [b]This is the one thing in this class an operator can act on.[/b] Everything else
## here is a per-observer per-tick decision, and a line per decision is twenty a
## second per peer that never says anything. But when the entity cap cuts a set that
## interest management already chose, the dropped entities are ones this client
## SHOULD be seeing — a player standing in plain sight who is not drawn — and the
## remedy is a setting: raise [member DotNetConfig.max_entities_per_snapshot] or
## [member DotNetConfig.max_tracked_entities], or tighten the strategy. Nothing in
## the process said so before.
##
## WARN the first time a peer is capped, because that is a configuration somebody
## should look at eventually; DEBUG for every later crossing, both ways, because a peer
## on the boundary of a crowded room crosses it repeatedly and a WARN per crossing
## would bury the one that matters. The "clear" edge wants the set back under 90% of
## the cap, for the same reason: a set hovering at the cap would otherwise flap once
## a snapshot. [param peer_id] 0 is a caller outside the snapshot loop — a test or
## a tool asking directly — and is not reported.
## The entity cap's record and log lines for one peer: [method prioritise]'s first step, for a
## caller that ranked with [method ranked] off the main thread. Main thread (it logs).
func note_cap(peer_id: int, count: int, limit: int, context: Dictionary) -> void:
	_note_cap(peer_id, count, limit, context)


func _note_cap(peer_id: int, count: int, limit: int, context: Dictionary) -> void:
	if peer_id == 0 or limit <= 0:
		return

	var state: Dictionary = _cap_state.get(peer_id, {"capped": false, "warned": false})
	var tick := int(context.get("tick", 0))

	if not state["capped"] and count > limit:
		state["capped"] = true
		state["since_tick"] = tick
		var fields := {
			"peer": peer_id, "relevant": count, "cap": limit,
			"dropped": count - limit, "strategy": strategy_name,
		}
		if state["warned"]:
			DotLog.debug(CHANNEL, "the entity cap is cutting a peer's view again", fields)
		else:
			state["warned"] = true
			DotLog.warn(CHANNEL, "the entity cap is cutting entities a peer should see", fields)
	elif state["capped"] and count * 10 <= limit * 9:
		state["capped"] = false
		DotLog.debug(CHANNEL, "a peer's view fits under the entity cap again", {
			"peer": peer_id, "relevant": count, "cap": limit,
			"ticks": tick - int(state.get("since_tick", tick)),
		})

	_cap_state[peer_id] = state


static func _find(all: Array[DotNetIdentity], net_id: int) -> DotNetIdentity:
	for identity in all:
		if identity.net_id == net_id:
			return identity
	return null


## Indexes [param all] by net id for the snapshot about to be asked about it, so a lingering
## entity is found by lookup, not by a walk of every identity per peer. Main thread, once per
## snapshot; [code]index_snapshot([])[/code] after it.
func index_snapshot(all: Array[DotNetIdentity]) -> void:
	_indexed = all
	_by_id = {}
	for identity in all:
		_by_id[identity.net_id] = identity


func _find_in(all: Array[DotNetIdentity], net_id: int) -> DotNetIdentity:
	if is_same(all, _indexed):
		return _by_id.get(net_id)
	return _find(all, net_id)


var _indexed: Array[DotNetIdentity] = []
var _by_id: Dictionary = {}


func _resolve(ids: Dictionary, all: Array[DotNetIdentity]) -> Array[DotNetIdentity]:
	var out: Array[DotNetIdentity] = []
	_resolve_into(out, ids, all)
	return out


func _resolve_into(out: Array, ids: Dictionary, all: Array[DotNetIdentity]) -> void:
	for identity in all:
		if ids.has(identity.net_id):
			out.append(identity)


## Forgets a peer's cached set. Call on disconnect.
func forget_peer(peer_id: int) -> void:
	_cache.erase(peer_id)
	_lingering.erase(peer_id)
	_cap_state.erase(peer_id)


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
		"far_every": far_every,
		"far_distance": far_distance,
		"cached_observers": _cache.size(),
		"capped_observers": _cap_state.values().filter(
			func(state: Dictionary) -> bool: return state["capped"]
		).size(),
	}
