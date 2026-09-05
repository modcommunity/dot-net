class_name DotNetSnapshot
extends RefCounted

## One tick's worth of world state.
##
## Used in three places, which is why it is a value object rather than a message:
## the server keeps recent ones as delta baselines, the client buffers them for
## interpolation, and lag compensation searches them to rewind.
##
## [b]On delta compression.[/b] A snapshot is normally sent as a difference against
## the last one the client [i]acknowledged[/i] — not against the last one sent. The
## distinction matters: an unreliable snapshot may be lost, and a delta against
## something the client never received is undecodable. So the server keeps a window
## of sent snapshots, the client acks the newest tick it has, and the server deltas
## against that. When the ack is too old the server sends a full state instead.

## Tick this state belongs to.
var tick: int = 0

## Local time it was created or received, in milliseconds.
##
## Interpolation works in wall time rather than tick numbers, because a client's tick
## estimate drifts and the arrival spacing is what actually needs smoothing.
var received_at_ms: int = 0

## net_id -> {property: value}
var entities: Dictionary = {}

## Ids that despawned as of this tick.
var despawned: PackedInt64Array = PackedInt64Array()

## Ids that spawned as of this tick, with their prefab and owner.
var spawned: Array[Dictionary] = []

## Tick this snapshot was encoded against, or 0 for a full state.
var baseline_tick: int = 0


func _init(p_tick: int = 0) -> void:
	tick = p_tick
	received_at_ms = Time.get_ticks_msec()


func is_full_state() -> bool:
	return baseline_tick == 0


func has(net_id: int) -> bool:
	return entities.has(net_id)


func values_for(net_id: int) -> Dictionary:
	return entities.get(net_id, {})


func set_values(net_id: int, values: Dictionary) -> void:
	entities[net_id] = values


func entity_count() -> int:
	return entities.size()


## The ids in this snapshot, ascending.
##
## Sorted, not in insertion order. This is the public way to iterate a
## snapshot's entities, and "iteration over an unordered collection whose order
## differs" is on this addon's own list of things that break reconciliation —
## two peers that inserted the same ids in a different order would walk them in
## a different order and diverge, for no reason a reader could see. It also
## keeps [method describe] stable between runs, which is what makes two bug
## reports comparable.
func net_ids() -> PackedInt64Array:
	var out := PackedInt64Array()
	for net_id in entities:
		out.append(net_id)
	out.sort()
	return out


## Properties in [param newer] that differ from this snapshot.
##
## The server's delta step. Only changed properties travel, which for a world where
## most entities are still is most of the saving there is.
func delta_to(newer: DotNetSnapshot) -> Dictionary:
	var out := {}

	for net_id in newer.entities:
		var new_values: Dictionary = newer.entities[net_id]

		if not entities.has(net_id):
			# Not in the baseline: the receiver has nothing to apply a delta to, so
			# everything must go.
			out[net_id] = new_values.duplicate()
			continue

		var old_values: Dictionary = entities[net_id]
		var changed := {}

		for property in new_values:
			if not old_values.has(property) \
				or not _same(old_values[property], new_values[property]):
				changed[property] = new_values[property]

		if not changed.is_empty():
			out[net_id] = changed

	return out


## Applies a delta on top of this snapshot, producing a new one.
func apply_delta(delta: Dictionary, new_tick: int) -> DotNetSnapshot:
	var result := DotNetSnapshot.new(new_tick)
	result.baseline_tick = tick

	# Carry every entity forward first: an entity absent from the delta is unchanged,
	# not gone. Removal is explicit, through `despawned`.
	for net_id in entities:
		result.entities[net_id] = (entities[net_id] as Dictionary).duplicate()

	for net_id in delta:
		if not result.entities.has(net_id):
			result.entities[net_id] = {}

		var target: Dictionary = result.entities[net_id]
		for property in (delta[net_id] as Dictionary):
			target[property] = (delta[net_id] as Dictionary)[property]

	return result


static func _same(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	return a == b


## A copy that shares nothing with the original.
##
## Snapshots kept as baselines outlive the objects they were built from, so a shallow
## copy would let a later tick mutate a baseline the server is still deltaing against.
func duplicate_deep() -> DotNetSnapshot:
	var copy := DotNetSnapshot.new(tick)
	copy.received_at_ms = received_at_ms
	copy.baseline_tick = baseline_tick
	copy.despawned = despawned.duplicate()

	for net_id in entities:
		copy.entities[net_id] = (entities[net_id] as Dictionary).duplicate()

	for entry in spawned:
		copy.spawned.append(entry.duplicate())

	return copy


func describe() -> Dictionary:
	return {
		"tick": tick,
		"entities": entities.size(),
		"spawned": spawned.size(),
		"despawned": despawned.size(),
		"baseline": baseline_tick,
		"full": is_full_state(),
	}


func _to_string() -> String:
	return "DotNetSnapshot(tick %d, %d entities%s)" % [
		tick, entities.size(), "" if is_full_state() else ", delta"
	]
