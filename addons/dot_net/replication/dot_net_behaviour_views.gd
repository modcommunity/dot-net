@tool
extends "dot_net_behaviour_state.gd"

## The per-peer half of [DotNetBehaviour]: what each peer is believed to hold, acked, trimmed and forgotten.

## The manager's native snapshot core ([DotNetNative]) once it holds this behaviour's send
## records, so that the record methods answer from it. Set by the core.
var _native_core: Object = null


## Resolves this peer's unconfirmed sends against the tick it has acknowledged. Called by
## [DotNetManager] just before [method collect_dirty], not pushed to every behaviour on each ack (a
## full registry sweep per ack).
func sync_peer_acks(peer_id: int, acked_tick: int, strict: bool) -> void:
	var view := _view_for(peer_id)

	if strict:
		view.strict = true

	if acked_tick <= view.last_ack:
		return

	_sync_view(view, acked_tick)


## [method sync_peer_acks] past its early-outs: [param acked_tick] is newer than the view's.
func _sync_view(view: PeerView, acked_tick: int) -> void:
	view.last_ack = acked_tick

	if view.pending.is_empty():
		return

	# The resolved entries are a prefix (pending is in tick order), so they come off the
	# front; see [method trim_pending] for why not a rebuilt list.
	var resolved := 0
	var count := view.pending.size()
	var dropped := false

	while resolved < count:
		var entry: Dictionary = view.pending[resolved]
		var entry_tick := int(entry["tick"])

		if entry_tick > acked_tick:
			break

		resolved += 1

		if entry_tick == acked_tick or not view.strict:
			view.acked.merge(entry["values"], true)
		else:
			# Sent before a snapshot the peer already applied, still unconfirmed: dropped without promotion so
			# it goes out again, and stays owed (`relost`) since it can be lost again. Erased from `acked` too:
			# only the ack may have been lost, so "equals the acked value" no longer proves the peer holds it.
			dropped = true
			for property: StringName in entry["values"]:
				view.relost[property] = true
				view.acked.erase(property)

	if resolved == 0:
		return

	if resolved == count:
		view.pending.clear()
	else:
		for i in resolved:
			view.pending.pop_front()
	# Only a DROP changes what the peer is believed to hold: promoting the oldest entries moves
	# their values from the front of the overlay into `acked`, which is the same dictionary
	# afterwards. Rebuilding anyway was a third of a 32-player snapshot's cost.
	if dropped:
		_rebuild_believed(view)


## Drops unconfirmed sends older than [param oldest_tick].
##
## Bounds what one peer can accumulate when it stops acknowledging. With acks an aged-out entry is a loss and re-sends; without them it is assumed delivered.
func trim_pending(peer_id: int, oldest_tick: int) -> void:
	var view: PeerView = _views.get(peer_id)

	if view == null or view.pending.is_empty():
		return

	# The oldest entry first, and nearly always that is the whole answer: pending is in tick
	# order, so if the oldest is inside the window every entry is.
	if int(view.pending[0]["tick"]) >= oldest_tick:
		return

	_trim_view(view, oldest_tick)


## [method trim_pending] past its early-out: the oldest pending entry is older than
## [param oldest_tick].
func _trim_view(view: PeerView, oldest_tick: int) -> void:

	# The aged-out entries are a prefix (pending is in tick order): they come off the front and
	# nothing else is touched.
	var aged := 0
	var count := view.pending.size()

	while aged < count:
		var entry: Dictionary = view.pending[aged]
		if int(entry["tick"]) >= oldest_tick:
			break

		if not view.strict:
			view.acked.merge(entry["values"], true)
		else:
			for property: StringName in entry["values"]:
				view.relost[property] = true
				view.acked.erase(property)

		aged += 1

	if aged == count:
		view.pending.clear()
	else:
		for i in aged:
			view.pending.pop_front()

	# Promoted (not strict) leaves `believed` as it was; see [method sync_peer_acks].
	if view.strict:
		_rebuild_believed(view)


## Forgets everything recorded for one peer.
##
## Called on disconnect; otherwise every behaviour keeps the [PeerView] for the entity's lifetime, a leak proportional to everyone who ever connected.
func forget_peer(peer_id: int) -> void:
	_views.erase(peer_id)
	if _native_core != null:
		_native_core.forget_view(self, peer_id)


func _view_for(peer_id: int) -> PeerView:
	var view: PeerView = _views.get(peer_id)

	if view == null:
		view = PeerView.new()
		_views[peer_id] = view

	return view


## Rebuilds what a peer is believed to have from what it has confirmed.
##
## Confirmed state first, then every unconfirmed send in tick order: a property sent twice is believed at its newest value, and one whose only send was dropped falls back to confirmed, or to absent (dirty, re-sent).
func _rebuild_believed(view: PeerView) -> void:
	view.synced_serial = -1
	view.believed = view.acked.duplicate()

	for entry in view.pending:
		view.believed.merge(entry["values"], true)


## What is known about one peer. For diagnostics and tests.
func peer_view_state(peer_id: int) -> Dictionary:
	if _native_core != null:
		return _native_core.view_state(self, peer_id)
	var view: PeerView = _views.get(peer_id)

	if view == null:
		return {}

	return {
		"acked": view.acked.size(),
		"believed": view.believed.size(),
		"pending": view.pending.size(),
		"last_ack": view.last_ack,
		"strict": view.strict,
	}


## Forgets what a peer is known to have, so the next collection sends everything.
##
## For a re-established connection: a delta against its old record would be meaningless. With no argument it forgets every peer and the receive-side record too.
func reset_baseline(peer_id: int = -1) -> void:
	if _native_core != null:
		_native_core.forget_view(self, peer_id)
	if peer_id < 0:
		_baseline.clear()
		_read_now.clear()
		_views.clear()
		return

	_views.erase(peer_id)


## The live view for [param peer_id], made when there is none. Manager's thread only: it
## writes [member _views].
func view_for(peer_id: int) -> PeerView:
	var view: PeerView = _views.get(peer_id)
	if view == null:
		view = PeerView.new()
		_views[peer_id] = view
	return view


## The live view's [method PeerView.snapshot], or an empty dictionary. For tests. A fresh view reads as none.
func peer_view_snapshot(peer_id: int) -> Dictionary:
	if _native_core != null:
		return _native_core.view_snapshot(self, peer_id)
	var view: PeerView = _views.get(peer_id)
	return view.snapshot() if view != null and not view.is_fresh() else {}
