@tool
extends "dot_net_manager_wire.gd"

## Which peers get a snapshot this tick and how it is built: inline, pooled or native.

## Builds and sends a snapshot to every peer, filtered and prioritised per peer.
## [param phase] and [param period]: only the peers whose id falls on this phase, when
## snapshots are staggered ([member DotNetConfig.stagger_snapshots]); -1 is every peer.
func _send_snapshots(
	tick: int, identities: Array[DotNetIdentity], phase: int = -1, period: int = 1
) -> void:
	# The clock read once for the whole snapshot, for interest's cache and every rate limit:
	# read per peer, two peers either side of a millisecond could be answered differently in
	# one snapshot, and a snapshot built on workers could not be compared with one built here.
	var now_ms := Time.get_ticks_msec()
	var context := {"tick": tick, "config": config, "now_ms": now_ms}
	var prep_started := Time.get_ticks_usec()

	var workers := _snapshot_workers()
	var pooled := workers > 0 and send_fn.is_valid() and not _peers.is_empty()
	var native := _native_for_snapshot()

	# Before [method DotNetInterest._prepare], which reads positions too (a grid indexes
	# them): from here to the thaw every interest question is about one instant. Inline too:
	# a transform read per entity per peer was a third of a 100-player snapshot's interest.
	for identity in identities:
		identity.freeze_position()

	interest._prepare(identities, context)
	interest.index_snapshot(identities)

	_last_snapshot_tick = tick

	# There is deliberately no world-wide baseline snapshot here any more. One was
	# built and stored every snapshot tick — a full read of every replicated property
	# of every entity — against the day whole-snapshot deltas landed, and nothing
	# ever read it. Baselines are per peer instead, and they have to be: interest
	# management means no two peers were sent the same set of entities, so a single
	# world baseline is not a baseline for anybody. See [DotNetBehaviour.PeerView].

	var sent_to := 0

	# Each property read once for this snapshot rather than once per peer; see
	# [member DotNetBehaviour._snapshot_reads]. For workers, read all of them now.
	if native == null:
		for identity in identities:
			for behaviour in identity.behaviours:
				behaviour.begin_snapshot_reads(now_ms, pooled)

	if native != null:
		_snapshot_prep_usec_total += Time.get_ticks_usec() - prep_started
		sent_to = _send_snapshots_native(native, tick, identities, phase, period, context, workers)
	elif pooled:
		_snapshot_prep_usec_total += Time.get_ticks_usec() - prep_started
		sent_to = _send_snapshots_pooled(tick, identities, phase, period, context, workers)
	else:
		for peer_id in _peers:
			if phase >= 0 and posmod(peer_id, period) != phase:
				continue

			budget.begin_tick(peer_id)

			var observer := _observer_for(peer_id)
			var relevant := interest.relevant_for(
				observer, identities, peer_id, context
			)
			if interest.thins():
				var kept: Array[DotNetIdentity] = []
				interest.thin_into(kept, observer, relevant, peer_id, context)
				relevant = kept

			var scores := interest.scores_for(observer, relevant, context)

			# Both caps at once — see [method DotNetConfig.entity_cap]. max_tracked_entities
			# was documented from the first version and enforced by nothing; it is applied
			# HERE rather than by a score sort of our own, because prioritise is what pins
			# always_relevant and a plain sort would cut the observer's own entity.
			relevant = interest.prioritise(
				observer, relevant, config.entity_cap(), context, peer_id, scores
			)
			relevant = budget.accumulate(peer_id, relevant, scores)
			if config.peer_send_budget > 0 and relevant.size() > config.peer_send_budget:
				var kept: Array[DotNetIdentity] = []
				_within_send_budget(kept, relevant, observer)
				relevant = kept

			if _send_to_peer(peer_id, tick, relevant):
				sent_to += 1

	if native == null:
		for identity in identities:
			for behaviour in identity.behaviours:
				behaviour.end_snapshot_reads()

	interest.index_snapshot([])
	for identity in identities:
		identity.thaw_position()
	if pooled or native != null:
		for identity in _late_frozen:
			if is_instance_valid(identity):
				identity.thaw_position()
		_late_frozen.clear()

	snapshot_sent.emit(tick, sent_to)


## The worker count this snapshot is built with: 0 (here, on the calling thread) unless
## [member DotNetConfig.snapshot_workers] asks for workers, [method DotParallel.available] and
## the interest strategy says [method DotNetInterest.is_thread_safe]. The reason it is 0 when
## asked for is logged once per change, and kept for [method describe_lines].
func _snapshot_workers() -> int:
	var reason := ""
	var workers := 0
	if config == null or config.snapshot_workers == 0:
		reason = "off"
	elif not DotParallel.available():
		reason = "no worker threads on this platform"
	elif interest == null or not interest.is_thread_safe():
		reason = "interest strategy %s is not thread-safe" % (
			interest.strategy_name if interest != null else "none")
	else:
		workers = DotParallel.resolve_workers(config.snapshot_workers)
	if reason != _snapshot_threads_reason:
		_snapshot_threads_reason = reason
		if reason != "off" and reason != "":
			_snapshot_threads_note = "snapshots are built inline (%s)" % reason
		elif reason == "":
			_snapshot_threads_note = (
				"snapshot workers active: %d; interest %s pooled; custom DotNetVar codecs pooled"
				% [workers, interest.strategy_name])
		if reason != "off":
			# INFO, once per change: an operator who turned this on wants to see it took or why not.
			DotLog.info(CHANNEL, _snapshot_threads_note, {
				"workers": workers, "asked": config.snapshot_workers if config != null else 0,
			})
	return workers


## The native core for this snapshot, made the first time [member DotNetConfig.native] is on,
## or null for the GDScript path. Turned off, the behaviours it held are handed back.
func _native_for_snapshot() -> Object:
	if config == null or not config.native:
		if _native != null:
			_reset_send_views()
			_native = null
			_native_tried = false
			_native_note = "off"
		return null
	if _native == null and not _native_tried:
		_native_tried = true
		var res := DotNetNative.make_core(config)
		if res.ok:
			_reset_send_views()
			_native = res.value
			_native_note = "on (%s)" % DotNetNative.describe()["from"]
			DotLog.info(CHANNEL, "snapshots are built natively", DotNetNative.describe())
		else:
			_native_note = "asked, GDScript in use: %s" % res.error.message
			DotLog.warn(CHANNEL, "native snapshots asked for but unavailable; GDScript in use",
				{"reason": res.error.message})
	return _native


## Every behaviour's send records dropped, GDScript's and the native core's hold on them: each
## path keeps its own acks, so after a switch the other's are stale and everything is resent.
func _reset_send_views() -> void:
	for identity in registry.all():
		for behaviour in identity.behaviours:
			behaviour._native_core = null
			behaviour._views.clear()


## [method _send_snapshots]'s peers built by [param core]: interest and the budget's ranking
## here (or on [param workers] as the pooled path does), every peer's parts in the core, then
## sent in peer order. The same bytes as either GDScript path.
func _send_snapshots_native(
	core: Object, tick: int, identities: Array[DotNetIdentity], phase: int, period: int,
	context: Dictionary, workers: int
) -> int:
	var oldest_pending: int = tick - config.ack_window_snapshots * config.ticks_per_snapshot()
	# Before begin_snapshot, which reads each identity's interest fields once.
	var core_interest := config.native_interest and send_fn.is_valid() and interest.native_interest_ok()
	var interest_cfg := interest.native_config(config) if core_interest else {}
	if config.native_interest and send_fn.is_valid() and not core_interest and not _interest_fallback_logged:
		_interest_fallback_logged = true
		DotLog.info(CHANNEL, "native_interest is on but this interest strategy is not portable; interest stays in GDScript")
	if core_interest:
		interest_cfg["starvation_ticks"] = budget.starvation_ticks
		interest_cfg["starvation_weight"] = budget.starvation_weight
	core.set_interest(interest_cfg)
	core.begin_snapshot(identities, PackedInt64Array([
		tick, int(context["now_ms"]), config.mtu, oldest_pending, workers,
		DotNetIdentity.Authority.SHARED,
	]))
	var jobs: Array[SnapshotJob] = []
	var interest_started := Time.get_ticks_usec()
	if core_interest:
		# The library works out each peer's candidates itself, in its build threads.
		for peer_id in _peers:
			if phase >= 0 and posmod(peer_id, period) != phase:
				continue
			budget.begin_tick(peer_id)
			var job := SnapshotJob.new()
			job.peer_id = peer_id
			job.observer = _observer_for(peer_id)
			if _input_buffers.has(peer_id):
				job.lead = (_input_buffers[peer_id] as DotNetInput.Buffer).take_lead_sample()
			job.send_lead = job.lead.x != DotNetInput.Buffer.LEAD_NONE \
				and messages.peer_supports(peer_id, DotNetMessageRegistry.FEATURE_INPUT_LEAD)
			job.compact = messages.peer_supports(peer_id, DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS)
			job.acked_tick = int(_acks.get(peer_id, 0))
			job.strict = bool(_ack_wired.get(peer_id, false))
			job.remaining_bytes = budget.remaining(peer_id)
			job.peer_budget = budget.for_peer(peer_id)
			jobs.append(job)
	elif workers > 0 and send_fn.is_valid():
		for peer_id in _peers:
			if phase >= 0 and posmod(peer_id, period) != phase:
				continue
			budget.begin_tick(peer_id)
			jobs.append(_freeze_job(peer_id, tick))
		if not jobs.is_empty():
			var chunks := mini(workers, jobs.size())
			var cap := config.entity_cap()
			var interest_task := func(chunk: int) -> Array:
				return _interest_chunk(jobs, chunk, chunks, identities, context, cap)
			DotParallel.run(interest_task, chunks, &"net.snapshot", workers)
	else:
		for peer_id in _peers:
			if phase >= 0 and posmod(peer_id, period) != phase:
				continue
			budget.begin_tick(peer_id)
			var observer := _observer_for(peer_id)
			var relevant := interest.relevant_for(observer, identities, peer_id, context)
			if interest.thins():
				var kept: Array[DotNetIdentity] = []
				interest.thin_into(kept, observer, relevant, peer_id, context)
				relevant = kept
			var scores := interest.scores_for(observer, relevant, context)
			relevant = interest.prioritise(
				observer, relevant, config.entity_cap(), context, peer_id, scores
			)
			relevant = budget.accumulate(peer_id, relevant, scores)
			if config.peer_send_budget > 0 and relevant.size() > config.peer_send_budget:
				var kept: Array[DotNetIdentity] = []
				_within_send_budget(kept, relevant, observer)
				relevant = kept
			if not send_fn.is_valid():
				continue
			var job := SnapshotJob.new()
			job.peer_id = peer_id
			if _input_buffers.has(peer_id):
				job.lead = (_input_buffers[peer_id] as DotNetInput.Buffer).take_lead_sample()
			job.send_lead = job.lead.x != DotNetInput.Buffer.LEAD_NONE \
				and messages.peer_supports(peer_id, DotNetMessageRegistry.FEATURE_INPUT_LEAD)
			job.compact = messages.peer_supports(peer_id, DotNetMessageRegistry.FEATURE_UNCHANGED_RUNS)
			job.acked_tick = int(_acks.get(peer_id, 0))
			job.strict = bool(_ack_wired.get(peer_id, false))
			job.remaining_bytes = budget.remaining(peer_id)
			job.peer_budget = budget.for_peer(peer_id)
			job.ordered = relevant
			jobs.append(job)

	var submit_started := Time.get_ticks_usec()
	_snapshot_interest_usec_total += submit_started - interest_started
	for job in jobs:
		var info := PackedInt64Array([
			job.peer_id, job.acked_tick, 1 if job.strict else 0, 1 if job.compact else 0,
			job.remaining_bytes, 1 if job.send_lead else 0, job.lead.x, job.lead.y,
		])
		if core_interest:
			core.submit_peer_interest(job.observer, info,
				job.peer_budget.accumulators, job.peer_budget.starved_ticks)
		else:
			core.submit_peer(job.ordered, info,
				job.peer_budget.accumulators, job.peer_budget.starved_ticks)
	var started := Time.get_ticks_usec()
	_snapshot_submit_usec_total += started - submit_started
	var results: Array = core.finish_snapshot()
	_snapshot_join_usec = Time.get_ticks_usec() - started
	_snapshot_join_usec_total += _snapshot_join_usec

	var applying := Time.get_ticks_usec()
	for i in results.size():
		var job := jobs[i]
		var r: Array = results[i]
		var peer_id := job.peer_id
		var peer_budget := job.peer_budget
		if core_interest:
			interest.note_cap(peer_id, int(r[11]), config.entity_cap(), context)
		elif not job.answer.is_empty():
			interest.commit_relevance(peer_id, job.answer)
			interest.note_cap(peer_id, job.cap_count, config.entity_cap(), context)
		peer_budget.starved_this_tick += int(r[3])
		peer_budget.total_starved += int(r[3])
		peer_budget.bytes_this_second += int(r[4])
		if bool(r[5]):
			snapshots_split += 1
		unchanged_listed += int(r[6])
		unchanged_bytes_saved += int(r[7])
		input_leads_sent += int(r[8])
		if not _warned_oversize and int(r[9]) >= 0:
			_warned_oversize = true
			var big := registry.get_identity(int(r[9]))
			DotLog.warn(CHANNEL, "an entity's state alone is bigger than the snapshot MTU; it is sent oversized", {
				"net_id": int(r[9]), "prefab": str(big.prefab_id) if big != null else "",
				"bytes": int(r[10]), "mtu": config.mtu,
			})
		var payloads: Array = r[1]
		var counts: PackedInt32Array = r[2]
		for index in payloads.size():
			var payload: PackedByteArray = payloads[index]
			send_fn.call(peer_id, payload, DotNetMessage.Delivery.UNRELIABLE)
			largest_part_bytes = maxi(largest_part_bytes, payload.size())
			budget.note_packet(peer_id, payload.size())
			stats.note_sent(payload.size(), counts[index])
	_snapshot_apply_usec_total += Time.get_ticks_usec() - applying
	return results.size()


## Snapshots for every peer on this phase, built on [param workers] worker threads and sent
## from here in peer order. Returns how many peers were sent one.
##
## [b]Each task writes its own peers' records in place.[/b] A peer's [DotNetBehaviour.PeerView]s
## and its budget record are touched by the one task that owns the peer, so they need no copy;
## what is made here first is every record a build would otherwise insert into a table the
## tasks share (a view for each behaviour and peer, the peer's budget record). An earlier
## version built into copies of the views and installed them afterwards, so that a build could
## be run twice and compared ([member DotParallel.verify]); the copies made each build dearer
## than the inline one and the install cost 4 ms at 32 players and 15 at 64, more than the
## workers saved. The tasks are not pure, so no [code]compare[/code] is given and verify never
## re-runs them: netcode_demo's [snapshot threads] compares a whole game built on workers with
## the same game built inline instead.
##
## [b]One task per worker, never one per peer.[/b] A group task is handed only an item index,
## not which worker runs it, so a per-worker cache cannot be picked by worker; one task owning
## a contiguous run of peers creates its own [DotNetBehaviour.EncodeCache]s and shares each
## entity's encoding among its own peers, which is most of what the cache saved on one thread.
func _send_snapshots_pooled(
	tick: int, identities: Array[DotNetIdentity], phase: int, period: int,
	context: Dictionary, workers: int
) -> int:
	var prep_started := Time.get_ticks_usec()
	var jobs: Array[SnapshotJob] = []
	for peer_id in _peers:
		if phase >= 0 and posmod(peer_id, period) != phase:
			continue
		budget.begin_tick(peer_id)
		jobs.append(_freeze_job(peer_id, tick))

	if jobs.is_empty():
		return 0

	var chunks := mini(workers, jobs.size())
	var cap := config.entity_cap()

	# Interest first, on the workers, so a view is made only for what a peer is sent (as the
	# inline path does) and not for every entity of every peer.
	var interest_task := func(chunk: int) -> Array:
		return _interest_chunk(jobs, chunk, chunks, identities, context, cap)
	DotParallel.run(interest_task, chunks, &"net.snapshot", workers)
	for job in jobs:
		for identity: DotNetIdentity in job.ordered:
			for behaviour in identity.behaviours:
				var _view := behaviour.view_for(job.peer_id)

	var task := func(chunk: int) -> Array:
		return _build_chunk(jobs, chunk, chunks, tick)

	var started := Time.get_ticks_usec()
	_snapshot_prep_usec_total += started - prep_started
	var results := DotParallel.run(task, chunks, &"net.snapshot", workers)
	_snapshot_join_usec = Time.get_ticks_usec() - started
	_snapshot_join_usec_total += _snapshot_join_usec
	_snapshot_pooled += 1
	_snapshot_pooled_peers = jobs.size()
	_snapshot_pooled_workers = chunks

	var sent_to := 0
	var applying := Time.get_ticks_usec()
	for builds: Array in results:
		for build: SnapshotBuild in builds:
			_apply_build(build, context)
			sent_to += 1
	_snapshot_apply_usec_total += Time.get_ticks_usec() - applying
	return sent_to


## Relevance, ranking and the budget's accumulation for peers [code][chunk * n / chunks,
## (chunk + 1) * n / chunks)[/code] of [param jobs], stored on each job. Runs on a worker:
## reads the frozen world and writes only the job and its peer's budget record.
func _interest_chunk(
	jobs: Array[SnapshotJob], chunk: int, chunks: int, identities: Array[DotNetIdentity],
	context: Dictionary, cap: int
) -> Array:
	var from := chunk * jobs.size() / chunks
	var to := (chunk + 1) * jobs.size() / chunks
	for j in range(from, to):
		var job := jobs[j]
		var answer := interest.relevance(job.observer, identities, job.peer_id, context)
		var relevant: Array = answer[0]
		if interest.thins():
			var kept: Array = []
			interest.thin_into(kept, job.observer, relevant, job.peer_id, context)
			relevant = kept

		var scores := interest.scores_for(job.observer, relevant, context)

		job.cap_count = relevant.size()
		relevant = interest.ranked(job.observer, relevant, cap, context, scores)
		if _test_skew_pooled:
			job.acked_tick = 0
		job.ordered = budget.accumulate_record(job.peer_budget, relevant, scores)
		if config.peer_send_budget > 0 and job.ordered.size() > config.peer_send_budget:
			var kept: Array = []
			_within_send_budget(kept, job.ordered, job.observer)
			job.ordered = kept
		job.answer = answer
	return []


## The first [member DotNetConfig.peer_send_budget] of [param ordered] (accumulator order) into
## [param out], and every later one [param observer]'s owner owns. Those left out keep their
## accumulated priority and lead a later snapshot. Reads fields only, so a worker may run it.
func _within_send_budget(out: Array, ordered: Array, observer: DotNetIdentity) -> void:
	var limit := config.peer_send_budget
	var owner := observer.owner_peer_id if observer != null else -1
	for i in ordered.size():
		var identity: DotNetIdentity = ordered[i]
		if i < limit or (owner > 0 and identity.owner_peer_id == owner):
			out.append(identity)


## Builds the snapshots of peers [code][chunk * n / chunks, (chunk + 1) * n / chunks)[/code]
## of [param jobs] from what [method _interest_chunk] stored. Runs on a worker: reads the
## frozen world, and writes only what it creates and its own peers' records.
func _build_chunk(jobs: Array[SnapshotJob], chunk: int, chunks: int, tick: int) -> Array:
	var out: Array = []
	var from := chunk * jobs.size() / chunks
	var to := (chunk + 1) * jobs.size() / chunks
	var caches := {}
	for j in range(from, to):
		var job := jobs[j]
		var build := _build_peer(job, tick, job.ordered, caches)
		build.relevance = job.answer
		build.cap_count = job.cap_count
		out.append(build)
	return out
