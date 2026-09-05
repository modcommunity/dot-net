@tool
class_name DotNetIdentity
extends Node

## Makes the node it is attached to a networked entity.
##
## Add one as a child of anything that needs to exist on more than one machine. It
## carries the network id, who owns it, who has authority over what, and which
## [DotNetBehaviour]s under it replicate state.
##
## [b]Attach it to a child, not the root.[/b] A component rather than a base class,
## so a networked entity can extend whatever your game needs —
## [CharacterBody3D], [RigidBody3D], your own class — instead of inheriting from
## something dot-net chose. The entity itself is [member entity], resolved through a
## [DotNodeRef] so it can be the parent, an ancestor, or a node somewhere else
## entirely.
##
## [codeblock]
## Player (CharacterBody3D)
##  ├── NetIdentity (DotNetIdentity)      entity_ref -> parent
##  ├── Movement    (DotNetBehaviour)     replicates position, velocity
##  └── Health      (DotNetBehaviour)     replicates health, alive
## [/codeblock]

const CHANNEL := "net.identity"

## Who may change what.
enum Authority {
	## The server decides everything. Clients predict and are corrected.
	##
	## The default, and the only model that is safe against a modified client.
	SERVER,
	## The owning client decides its own transform; the server relays it.
	##
	## Cheaper and smoother for the owner, and it trusts the client completely — a
	## modified one can teleport. Reasonable for cosmetic entities and co-op; never
	## for anything competitive.
	CLIENT,
	## The owning client predicts and the server validates and corrects.
	##
	## The usual choice for a player character: responsive locally, authoritative
	## where it matters.
	SHARED,
}

## Emitted on every peer once the entity is registered and its id is known.
signal net_spawned(net_id: int)

## Emitted just before the entity is removed.
signal net_despawned(net_id: int)

## Emitted when ownership changes, on every peer that can see it.
signal owner_changed(old_peer_id: int, new_peer_id: int)

## Emitted on the owning client only, once it learns it owns this.
signal became_owner()

@export_group("Identity")

## Network id. Assigned by the server; 0 until spawned.
##
## Never set this by hand — the registry allocates it, and a duplicate means two
## entities receiving each other's state.
@export var net_id: int = 0

## Peer that owns this entity. 0 means the server owns it.
##
## Ownership decides who may send input for it, which properties they receive, and
## whether the local machine predicts it.
@export var owner_peer_id: int = 0

## Prefab id used to recreate this on clients. See [DotNetSpawner].
@export var prefab_id: StringName = &""

@export var authority: Authority = Authority.SERVER

@export_group("Wiring")

## The node this identity represents. Defaults to the parent.
##
## Behaviours read and write properties on it, and interest management reads its
## position from it.
@export var entity_ref: DotNodeRef = null

@export_group("Replication")

## Replicate to every observer regardless of interest management.
##
## For entities that must never pop in — an objective marker, a boss, the level
## geometry's moving parts. Costs bandwidth from every client, so use it sparingly.
@export var always_relevant: bool = false

## Interest tags, for strategies that filter by category.
##
## A [DotNetInterest] implementation can use these to answer questions distance
## cannot: "replicate entities on my team wherever they are", "never replicate props
## to spectators".
@export var interest_tags: PackedStringArray = PackedStringArray()

## Relative priority when bandwidth is short. Higher is sent first.
@export_range(0.0, 100.0, 0.5) var priority: float = 1.0

## Keep replicating for this long after leaving interest, in seconds.
##
## Stops an entity on the edge of the radius from flickering in and out as it moves
## back and forth across the boundary — which costs a full spawn each time.
@export_range(0.0, 30.0, 0.5) var interest_linger_sec: float = 2.0

## The resolved entity node.
var entity: Node = null

## Behaviours found under this identity.
var behaviours: Array[DotNetBehaviour] = []

## Whether this process has authority over this entity.
##
## Set by the manager at registration. Behaviours read it to decide whether to
## simulate or to apply received state.
var is_authoritative: bool = false

## Whether the local peer owns this.
var is_owner: bool = false

## Tick this entity was spawned on.
var spawn_tick: int = 0

var _registered: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if entity_ref == null:
		entity_ref = DotNodeRef.new()
		entity_ref.mode = DotNodeRef.Mode.PARENT

	var resolved := entity_ref.resolve(self)
	if resolved.ok:
		entity = resolved.value
	else:
		DotLog.warn(
			CHANNEL,
			"could not resolve the entity node; falling back to the parent",
			{"ref": entity_ref.describe()}
		)
		entity = get_parent()

	_collect_behaviours()


## Finds the behaviours this identity replicates.
##
## Searched from [member entity] rather than from this node, so behaviours can be
## siblings of the identity — which is the natural layout when the identity is a
## child of the entity.
func _collect_behaviours() -> void:
	behaviours.clear()

	var root := entity if entity != null else self
	_collect_from(root)

	for behaviour in behaviours:
		behaviour.identity = self


## Walks the subtree, stopping at nested identities.
##
## A child entity with its own [DotNetIdentity] owns its own behaviours; claiming
## them here would replicate them twice and under the wrong id.
func _collect_from(node: Node) -> void:
	for child in node.get_children():
		if child is DotNetIdentity and child != self:
			continue

		if child is DotNetBehaviour:
			behaviours.append(child as DotNetBehaviour)

		_collect_from(child)


# --- Registration ----------------------------------------------------------

## Called by the manager once an id is assigned.
func _on_registered(assigned_id: int, tick: int, authoritative: bool, local_peer: int) -> void:
	net_id = assigned_id
	spawn_tick = tick
	is_authoritative = authoritative
	is_owner = owner_peer_id == local_peer
	_registered = true

	for behaviour in behaviours:
		behaviour._net_ready()

	net_spawned.emit(net_id)

	if is_owner:
		became_owner.emit()

	DotLog.debug(
		CHANNEL,
		"entity registered",
		{
			"net_id": net_id,
			"prefab": String(prefab_id),
			"owner": owner_peer_id,
			"authority": Authority.keys()[authority],
		}
	)


func _on_unregistered() -> void:
	if not _registered:
		return

	net_despawned.emit(net_id)

	for behaviour in behaviours:
		behaviour._net_removed()

	_registered = false


func is_registered() -> bool:
	return _registered


## Changes the owner, notifying both sides.
##
## Used for pickups, vehicles, possession — anything where control transfers. The
## previous owner stops predicting it and the new one starts, which is why both
## learn about it rather than only the new owner.
func set_owner_peer(new_peer_id: int, local_peer: int) -> void:
	if owner_peer_id == new_peer_id:
		return

	var previous := owner_peer_id
	owner_peer_id = new_peer_id
	is_owner = new_peer_id == local_peer

	owner_changed.emit(previous, new_peer_id)

	if is_owner:
		became_owner.emit()

	DotLog.debug(
		CHANNEL,
		"ownership changed",
		{"net_id": net_id, "from": previous, "to": new_peer_id}
	)


# --- Authority queries -----------------------------------------------------

## Whether this process may simulate the entity's own movement.
func can_simulate() -> bool:
	match authority:
		Authority.SERVER:
			return is_authoritative
		Authority.CLIENT:
			return is_owner
		Authority.SHARED:
			# Both: the owner predicts, the server is authoritative and corrects.
			return is_authoritative or is_owner
	return false


## Whether this process's state should be sent rather than received.
func should_send() -> bool:
	match authority:
		Authority.SERVER:
			return is_authoritative
		Authority.CLIENT:
			return is_owner
		Authority.SHARED:
			return is_authoritative
	return false


## Whether the local peer predicts this entity.
##
## True for a shared-authority entity the local peer owns — the case prediction and
## reconciliation exist for.
func is_predicted() -> bool:
	return authority == Authority.SHARED and is_owner and not is_authoritative


## World position, for interest management and lag compensation.
##
## Reads whichever transform the entity actually has, so a 2D game works without a
## separate code path.
func world_position() -> Vector3:
	if entity == null:
		return Vector3.ZERO

	if entity is Node3D:
		return (entity as Node3D).global_position

	if entity is Node2D:
		var p := (entity as Node2D).global_position
		return Vector3(p.x, p.y, 0.0)

	return Vector3.ZERO


func has_tag(tag: String) -> bool:
	return interest_tags.has(tag)


func describe() -> Dictionary:
	return {
		"net_id": net_id,
		"prefab": String(prefab_id),
		"owner": owner_peer_id,
		"authority": Authority.keys()[authority],
		"authoritative": is_authoritative,
		"is_owner": is_owner,
		"behaviours": behaviours.size(),
		"always_relevant": always_relevant,
		"tags": Array(interest_tags),
	}


func _to_string() -> String:
	return "DotNetIdentity(#%d %s)" % [net_id, prefab_id]
