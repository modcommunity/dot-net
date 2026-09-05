@tool
extends EditorPlugin

## Editor entry point for dot-net. Registers inspector types only.
##
## No autoloads: a project may run a server and a client in one process, and a
## singleton would make that impossible — which is exactly the configuration the
## netcode demo uses to test itself.

const _ICON := "res://addons/dot_net/icon_placeholder.svg"

const _TYPES := [
	["DotNetManager", "Node", "res://addons/dot_net/dot_net_manager.gd"],
	["DotNetIdentity", "Node", "res://addons/dot_net/replication/dot_net_identity.gd"],
	["DotNetBehaviour", "Node", "res://addons/dot_net/replication/dot_net_behaviour.gd"],
	["DotNetSpawner", "Node", "res://addons/dot_net/replication/dot_net_spawner.gd"],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
