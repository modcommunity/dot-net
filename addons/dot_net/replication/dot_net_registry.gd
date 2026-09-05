class_name DotNetRegistry
extends RefCounted

## The net-id table: which entities exist, and how to find one.
##
## Ids are allocated by the authority and never reused within a session. **Reuse is
## the trap here** — an id freed and immediately handed to a new entity means a
## snapshot still in flight for the old one is applied to the new one, which presents
## as an entity that briefly wears another's state. So allocation is monotonic, and
## the id space is wide enough that a session cannot exhaust it: at 20 spawns a
## second, 24 bits lasts nine days.

const CHANNEL := "net.registry"

## Ids fit this many bits on the wire.
const ID_BITS := 24
const MAX_ID := (1 << ID_BITS) - 1

## Emitted when an entity joins the table, on every peer.
signal registered(identity: DotNetIdentity)

## Emitted when one leaves.
signal unregistered(net_id: int, identity: DotNetIdentity)

## net_id -> DotNetIdentity
var _by_id: Dictionary = {}

## peer_id -> Array[int] of net_ids they own.
var _by_owner: Dictionary = {}

var _next_id: int = 1
var _is_authority: bool = false
var _local_peer_id: int = 0

## Ids seen despawned, so a late snapshot for one is dropped quietly rather than
## logged as unknown every tick.
var _recently_removed: Dictionary = {}
const REMOVED_MEMORY := 256


func _init(p_is_authority: bool, p_local_peer_id: int) -> void:
	_is_authority = p_is_authority
	_local_peer_id = p_local_peer_id


func set_local_peer(peer_id: int) -> void:
	_local_peer_id = peer_id


func local_peer_id() -> int:
	return _local_peer_id


func is_authority() -> bool:
	return _is_authority


# --- Allocation ------------------------------------------------------------

## Allocates the next id. Authority only.
func allocate_id() -> DotResult:
	if not _is_authority:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"Only the authority allocates network ids.",
			"a client that allocates its own would collide with the server's"
		)

	if _next_id > MAX_ID:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The network id space is exhausted.",
			"%d ids allocated this session; restart or widen ID_BITS" % _next_id
		)

	var id := _next_id
	_next_id += 1
	return DotResult.success(id)


# --- Registration ----------------------------------------------------------

## Adds an entity to the table.
##
## [param net_id] of 0 allocates one, which is what the authority does. A client
## passes the id the server sent.
func register(
	identity: DotNetIdentity,
	net_id: int,
	tick: int,
	config: DotNetConfig
) -> DotResult:
	if identity == null:
		return DotResult.fail(DotError.CODE_INVALID, "Null identity.")

	var assigned := net_id

	if assigned == 0:
		var allocated := allocate_id()
		if not allocated.ok:
			return allocated
		assigned = allocated.value

	if _by_id.has(assigned):
		var existing: DotNetIdentity = _by_id[assigned]
		if existing == identity:
			return DotResult.success(assigned)

		return DotResult.fail(
			DotError.CODE_STATE,
			"Network id %d is already in use." % assigned,
			"held by %s" % existing
		)

	# A client is told about ids the server allocated, so its own counter must stay
	# ahead of anything it has seen — otherwise a locally-spawned predicted entity
	# could take an id the server is about to use.
	if assigned >= _next_id:
		_next_id = assigned + 1

	_by_id[assigned] = identity

	if not _by_owner.has(identity.owner_peer_id):
		_by_owner[identity.owner_peer_id] = []
	(_by_owner[identity.owner_peer_id] as Array).append(assigned)

	for behaviour in identity.behaviours:
		behaviour._bind(config)

	identity._on_registered(
		assigned, tick, _is_authority, _local_peer_id
	)

	registered.emit(identity)
	return DotResult.success(assigned)


## Removes an entity from the table. Does not free the node.
##
## Freeing is the caller's decision: a despawn may mean "destroyed" or "left my
## interest set", and only the caller knows which.
func unregister(net_id: int) -> DotResult:
	if not _by_id.has(net_id):
		return DotResult.fail(
			DotError.CODE_INVALID, "No entity with id %d." % net_id
		)

	var identity: DotNetIdentity = _by_id[net_id]

	_by_id.erase(net_id)

	if _by_owner.has(identity.owner_peer_id):
		(_by_owner[identity.owner_peer_id] as Array).erase(net_id)

	_remember_removed(net_id)

	identity._on_unregistered()
	unregistered.emit(net_id, identity)

	return DotResult.success(identity)


func _remember_removed(net_id: int) -> void:
	_recently_removed[net_id] = Time.get_ticks_msec()

	if _recently_removed.size() > REMOVED_MEMORY:
		# Drop the oldest. An exact LRU is not worth it — this only suppresses log
		# spam, and being wrong means one extra warning.
		var oldest := -1
		var oldest_at := 0x7FFFFFFF
		for id in _recently_removed:
			if int(_recently_removed[id]) < oldest_at:
				oldest_at = int(_recently_removed[id])
				oldest = id
		if oldest >= 0:
			_recently_removed.erase(oldest)


## Whether an id was recently removed.
##
## Lets a receiver drop a late update for a despawned entity without logging it as
## unknown — which would otherwise fire every tick until the sender notices.
func was_recently_removed(net_id: int) -> bool:
	return _recently_removed.has(net_id)


## Re-parents ownership of an entity.
func change_owner(net_id: int, new_peer_id: int) -> DotResult:
	if not _by_id.has(net_id):
		return DotResult.fail(
			DotError.CODE_INVALID, "No entity with id %d." % net_id
		)

	var identity: DotNetIdentity = _by_id[net_id]
	var previous := identity.owner_peer_id

	if _by_owner.has(previous):
		(_by_owner[previous] as Array).erase(net_id)

	if not _by_owner.has(new_peer_id):
		_by_owner[new_peer_id] = []
	(_by_owner[new_peer_id] as Array).append(net_id)

	identity.set_owner_peer(new_peer_id, _local_peer_id)

	return DotResult.success(identity)


# --- Lookup ----------------------------------------------------------------

func get_identity(net_id: int) -> DotNetIdentity:
	var identity: DotNetIdentity = _by_id.get(net_id)
	# An identity whose node was freed without unregistering would be a dangling
	# reference. Cleaning up here keeps a missed despawn from becoming a crash.
	if identity != null and not is_instance_valid(identity):
		_by_id.erase(net_id)
		return null
	return identity


func has(net_id: int) -> bool:
	return get_identity(net_id) != null


func all() -> Array[DotNetIdentity]:
	var out: Array[DotNetIdentity] = []
	for net_id in _by_id:
		var identity: DotNetIdentity = _by_id[net_id]
		if is_instance_valid(identity):
			out.append(identity)
	return out


func ids() -> PackedInt64Array:
	var out := PackedInt64Array()
	for net_id in _by_id:
		out.append(net_id)
	out.sort()
	return out


## Entities owned by a peer.
func owned_by(peer_id: int) -> Array[DotNetIdentity]:
	var out: Array[DotNetIdentity] = []

	for net_id in _by_owner.get(peer_id, []):
		var identity := get_identity(net_id)
		if identity != null:
			out.append(identity)

	return out


## Entities carrying an interest tag.
func with_tag(tag: String) -> Array[DotNetIdentity]:
	var out: Array[DotNetIdentity] = []
	for identity in all():
		if identity.has_tag(tag):
			out.append(identity)
	return out


## Entities the local peer predicts.
func predicted() -> Array[DotNetIdentity]:
	var out: Array[DotNetIdentity] = []
	for identity in all():
		if identity.is_predicted():
			out.append(identity)
	return out


## Removes and returns every entity a peer owned.
##
## What a disconnect calls. Returned rather than freed so the caller decides whether
## a disconnecting player's body vanishes or stays as a ragdoll.
func take_owned_by(peer_id: int) -> Array[DotNetIdentity]:
	var taken := owned_by(peer_id)

	for identity in taken:
		unregister(identity.net_id)

	_by_owner.erase(peer_id)

	if not taken.is_empty():
		DotLog.debug(
			CHANNEL,
			"released entities owned by a departing peer",
			{"peer": peer_id, "count": taken.size()}
		)

	return taken


func count() -> int:
	return _by_id.size()


func clear() -> void:
	for net_id in _by_id.keys():
		unregister(net_id)
	_by_id.clear()
	_by_owner.clear()
	_recently_removed.clear()


func describe() -> Dictionary:
	var owners := {}
	for peer_id in _by_owner:
		owners[peer_id] = (_by_owner[peer_id] as Array).size()

	return {
		"entities": _by_id.size(),
		"next_id": _next_id,
		"authority": _is_authority,
		"local_peer": _local_peer_id,
		"by_owner": owners,
	}
