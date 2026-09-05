@tool
class_name DotNetSpawner
extends Node

## Creates networked entities from a prefab table, on every peer.
##
## [b]The prefab table is an allow-list, and that is the point.[/b] A spawn message
## names a prefab id, never a scene path. A client that could name a path could ask
## every other client to load any scene in the build — including editor tooling and
## anything with an [code]_init[/code] that does something. Ids are looked up in a
## table the game registers at startup, and an unknown id is refused.
##
## [codeblock]
## spawner.register_prefab(&"player", preload("res://game/player.tscn"))
## spawner.register_prefab(&"rocket", preload("res://game/rocket.tscn"))
##
## # Server only:
## var res := spawner.spawn(&"player", peer_id, Transform3D(Basis(), spawn_point))
## [/codeblock]
##
## Custom construction — object pooling, per-prefab setup, entities that are not
## scenes at all — goes through [method register_factory] instead.

const CHANNEL := "net.spawn"

## Emitted after an entity is created locally, on every peer.
signal spawned(identity: DotNetIdentity)

## Emitted before one is removed.
signal despawned(net_id: int)

@export_group("Wiring")

## Where spawned entities are added. Defaults to a child of this node.
##
## Point it at the game's own container so networked entities land where the game
## expects them rather than under an addon node.
@export var container_ref: DotNodeRef = null

## Free the node when an entity despawns.
##
## Off lets a game keep the node — for a death animation, a ragdoll, a pooled
## instance. The entity leaves the network either way.
@export var free_on_despawn: bool = true

@export_group("Prefabs")

## Prefabs declared in the inspector, as [code]id -> PackedScene[/code].
##
## Equivalent to calling [method register_prefab] for each. Convenient for a fixed
## set; a game with prefabs from downloaded content registers them in code.
@export var prefabs: Dictionary = {}

var registry: DotNetRegistry = null
var config: DotNetConfig = null

## id -> PackedScene
var _prefabs: Dictionary = {}

## id -> Callable factory
var _factories: Dictionary = {}

var _container: Node = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if container_ref == null:
		container_ref = DotNodeRef.of_created(&"Entities", Node)

	_container = container_ref.resolve_or_null(self, CHANNEL)

	for id in prefabs:
		var scene: Variant = prefabs[id]
		if not (scene is PackedScene):
			DotLog.error(
				CHANNEL,
				"a declared prefab is not a scene and was not registered",
				{"id": str(id), "was": type_string(typeof(scene))}
			)
			continue

		# register_prefab's contract is that a prefab with no identity is a
		# startup error rather than a spawn that silently produces a
		# non-networked object. Discarding the result here made that guarantee
		# hold only for games that register in code: the inspector path failed
		# silently and the id was simply absent, which surfaces much later, on
		# the first spawn, as "unknown prefab".
		var registered := register_prefab(StringName(str(id)), scene as PackedScene)
		if not registered.ok:
			DotLog.error(
				CHANNEL,
				"a declared prefab was refused",
				{"id": str(id), "why": str(registered.error)}
			)


func setup(p_registry: DotNetRegistry, p_config: DotNetConfig) -> void:
	registry = p_registry
	config = p_config


# --- Prefab table ----------------------------------------------------------

## Adds a prefab.
##
## The scene must contain a [DotNetIdentity] somewhere in it; that is checked at
## registration rather than at spawn time, so a mistake is a startup error rather
## than a spawn that silently produces a non-networked object.
func register_prefab(id: StringName, scene: PackedScene) -> DotResult:
	if id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "A prefab needs an id.")

	if scene == null:
		return DotResult.fail(
			DotError.CODE_INVALID, "Prefab '%s' has no scene." % id
		)

	if _prefabs.has(id) or _factories.has(id):
		return DotResult.fail(
			DotError.CODE_STATE, "Prefab '%s' is already registered." % id
		)

	var state := scene.get_state()
	if not _state_has_identity(state):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Prefab '%s' contains no DotNetIdentity." % id,
			"add one as a child of the entity root"
		)

	_prefabs[id] = scene
	DotLog.debug(CHANNEL, "prefab registered", {"id": String(id)})

	return DotResult.success(id)


## Checks a packed scene for a [DotNetIdentity] without instantiating it.
##
## Reading the scene state rather than instantiating avoids paying for every prefab
## at startup, which matters when there are hundreds.
static func _state_has_identity(state: SceneState) -> bool:
	for i in range(state.get_node_count()):
		var type := state.get_node_type(i)
		if type == &"DotNetIdentity":
			return true

		# A scene saved with a script rather than a registered type reports its base
		# class, so the script path is the fallback check.
		for p in range(state.get_node_property_count(i)):
			if state.get_node_property_name(i, p) == &"script":
				var script: Variant = state.get_node_property_value(i, p)
				if script is Script:
					var global_name := (script as Script).get_global_name()
					if global_name == &"DotNetIdentity":
						return true

	return false


## Registers a factory instead of a scene.
##
## Signature: [code]func(context: Dictionary) -> Node[/code]. The returned node must
## contain a [DotNetIdentity]. For pooling, for procedural entities, and for anything
## whose construction needs arguments.
func register_factory(id: StringName, factory: Callable) -> DotResult:
	if _prefabs.has(id) or _factories.has(id):
		return DotResult.fail(
			DotError.CODE_STATE, "Prefab '%s' is already registered." % id
		)

	_factories[id] = factory
	DotLog.debug(CHANNEL, "factory registered", {"id": String(id)})

	return DotResult.success(id)


func has_prefab(id: StringName) -> bool:
	return _prefabs.has(id) or _factories.has(id)


func prefab_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for id in _prefabs:
		out.append(String(id))
	for id in _factories:
		out.append(String(id))
	out.sort()
	return out


# --- Spawning --------------------------------------------------------------

## Creates an entity and registers it. Authority only.
##
## [param context] is passed to a factory and is otherwise ignored, so a game can
## thread construction arguments through without a side channel.
func spawn(
	prefab_id: StringName,
	owner_peer_id: int,
	transform: Transform3D = Transform3D.IDENTITY,
	tick: int = 0,
	context: Dictionary = {}
) -> DotResult:
	if registry == null:
		return DotResult.fail(DotError.CODE_STATE, "Spawner has no registry.")

	if not registry.is_authority():
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"Only the authority may spawn.",
			"a client spawns by asking the server, not by creating an entity"
		)

	return _instantiate(prefab_id, 0, owner_peer_id, transform, tick, context)


## Creates an entity the authority told us about. Clients only.
##
## The id comes from the server and is used as given. A client that allocated its own
## would collide the moment the server spawned anything.
func spawn_remote(
	prefab_id: StringName,
	net_id: int,
	owner_peer_id: int,
	transform: Transform3D,
	tick: int,
	context: Dictionary = {}
) -> DotResult:
	if net_id <= 0:
		return DotResult.fail(
			DotError.CODE_INVALID, "A remote spawn needs a network id."
		)

	return _instantiate(
		prefab_id, net_id, owner_peer_id, transform, tick, context
	)


func _instantiate(
	prefab_id: StringName,
	net_id: int,
	owner_peer_id: int,
	transform: Transform3D,
	tick: int,
	context: Dictionary
) -> DotResult:
	if not has_prefab(prefab_id):
		# Refusing an unregistered id is the whole security property of the table.
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Unknown prefab '%s'." % prefab_id,
			"registered: %s" % ", ".join(Array(prefab_ids()))
		)

	var node: Node = null

	if _factories.has(prefab_id):
		var produced: Variant = (_factories[prefab_id] as Callable).call(context)
		if not (produced is Node):
			return DotResult.fail(
				DotError.CODE_INTERNAL,
				"The factory for '%s' did not return a Node." % prefab_id
			)
		node = produced as Node
	else:
		node = (_prefabs[prefab_id] as PackedScene).instantiate()

	if node == null:
		return DotResult.fail(
			DotError.CODE_INTERNAL, "Could not instantiate '%s'." % prefab_id
		)

	var identity := _find_identity(node)

	if identity == null:
		node.queue_free()
		return DotResult.fail(
			DotError.CODE_INVALID,
			"'%s' produced a node with no DotNetIdentity." % prefab_id
		)

	identity.prefab_id = prefab_id
	identity.owner_peer_id = owner_peer_id

	if _container == null:
		_container = container_ref.resolve_or_null(self, CHANNEL)
	if _container == null:
		node.queue_free()
		return DotResult.fail(
			DotError.CODE_STATE, "The spawner has no container node."
		)

	# A factory is allowed to hand back a node it already owns — that is what
	# pooling is, and what free_on_despawn exists to make possible. So the node
	# may arrive already parented: to the container, if the spawner parked it
	# there on the last despawn, or to the game's own pool node, which is where
	# an idle instance actually belongs.
	#
	# add_child() on a parented node does not fail the call. It pushes an engine
	# error and returns, leaving the entity registered, live, and still under the
	# pool — outside the container the spawner promises to put it in, with
	# _apply_transform below then setting a global transform through the wrong
	# parent. Nothing in the returned DotResult says any of that happened.
	var previous := node.get_parent()
	if previous == null:
		_container.add_child(node)
	elif previous != _container:
		previous.remove_child(node)
		_container.add_child(node)

	# After the node is in the container, so _ready has run and the identity has
	# resolved its entity and collected its behaviours.
	_apply_transform(identity, transform)

	var result := registry.register(identity, net_id, tick, config)

	if not result.ok:
		node.queue_free()
		return result

	DotLog.debug(
		CHANNEL,
		"spawned",
		{
			"prefab": String(prefab_id),
			"net_id": identity.net_id,
			"owner": owner_peer_id,
		}
	)

	spawned.emit(identity)
	return DotResult.success(identity)


## Removes an entity.
func despawn(net_id: int) -> DotResult:
	if registry == null:
		return DotResult.fail(DotError.CODE_STATE, "Spawner has no registry.")

	var identity := registry.get_identity(net_id)

	if identity == null:
		return DotResult.fail(
			DotError.CODE_INVALID, "No entity with id %d." % net_id
		)

	despawned.emit(net_id)

	var node := identity.entity if identity.entity != null else identity

	registry.unregister(net_id)

	if free_on_despawn and is_instance_valid(node):
		node.queue_free()

	return DotResult.success(net_id)


## Removes every entity a peer owned. Returns how many.
func despawn_owned_by(peer_id: int) -> int:
	var taken := registry.owned_by(peer_id)

	for identity in taken:
		despawn(identity.net_id)

	return taken.size()


func _find_identity(node: Node) -> DotNetIdentity:
	if node is DotNetIdentity:
		return node as DotNetIdentity

	# Breadth-first: the identity is conventionally a direct child, and stopping at
	# the first one avoids claiming a nested entity's identity for its parent.
	var queue: Array[Node] = node.get_children()

	while not queue.is_empty():
		var current: Node = queue.pop_front()
		if current is DotNetIdentity:
			return current as DotNetIdentity
		queue.append_array(current.get_children())

	return null


func _apply_transform(identity: DotNetIdentity, transform: Transform3D) -> void:
	var entity := identity.entity

	if entity is Node3D:
		(entity as Node3D).global_transform = transform
	elif entity is Node2D:
		var origin := transform.origin
		(entity as Node2D).global_position = Vector2(origin.x, origin.y)


func describe() -> Dictionary:
	return {
		"prefabs": Array(prefab_ids()),
		"scenes": _prefabs.size(),
		"factories": _factories.size(),
		"container": _container.name if _container != null else "<none>",
	}
