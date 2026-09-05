extends Node

## Exercises [DotNetStats] and [DotNetSnapshot] directly — the two classes in
## this addon that no example named.
##
## Both are driven indirectly by [code]netcode_demo[/code], which asserts that a
## couple of counters moved. That is weaker than it looks: it only ever walks the
## healthy path, so every branch that exists to describe an *unhealthy* one — loss,
## reordering, a stalled peer, a delta against a baseline the client never got —
## was reached by nothing. Netcode fails quietly, and these are the classes whose
## whole job is to say what went wrong; a wrong answer here sends someone to fix
## the wrong subsystem.
##
## No sockets, no manager, no ticking: values in, numbers out.
##
## [codeblock]
## godot --headless --path . res://examples/diagnostics_demo.tscn
## [/codeblock]

var _failures: int = 0
var _checks: int = 0
var _sections_started: int = 0
var _sections_finished: int = 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.INFO)
	await _run()


func _run() -> void:
	_line("[b]dot-net diagnostics[/b]")
	_line("")

	_section_counters()
	_section_loss()
	await _section_rates()
	_section_rtt()
	_section_snapshot_basics()
	_section_snapshot_delta()
	_section_snapshot_isolation()

	_line("")
	_check(
		"every section ran",
		_sections_finished == _sections_started,
		"%d/%d" % [_sections_finished, _sections_started]
	)
	_line("")
	_line("[b]%d checks, %d failed[/b]" % [_checks, _failures])
	_finish(1 if _failures > 0 else 0)


# --- 1. Counters ------------------------------------------------------------

func _section_counters() -> void:
	_sections_started += 1
	_line("[b]1. counters[/b]")

	var s := DotNetStats.new()

	s.note_sent(100, 3)
	s.note_sent(200, 1)
	s.note_received(50, 2)

	_check("bytes_sent", s.bytes_sent == 300, "%d" % s.bytes_sent)
	_check("packets_sent", s.packets_sent == 2, "%d" % s.packets_sent)
	_check("messages_sent", s.messages_sent == 4, "%d" % s.messages_sent)
	_check("bytes_received", s.bytes_received == 50, "%d" % s.bytes_received)
	_check("messages_received", s.messages_received == 2, "%d" % s.messages_received)

	# The number that says whether batching works. netcode_demo asserts it is
	# small; nothing asserted it is computed from the right two counters.
	_check("average_packet_bytes", is_equal_approx(s.average_packet_bytes(), 150.0),
		"%.1f" % s.average_packet_bytes())

	var empty := DotNetStats.new()
	_check("average over no packets is 0, not a division by zero",
		empty.average_packet_bytes() == 0.0)
	_check("loss over no snapshots is 0", empty.loss_rate() == 0.0)
	_check("rtt over no samples is 0", empty.rtt_percentile(0.5) == 0.0)

	s.note_decode_failure()
	s.note_direction_violation()
	s.note_rate_limited()
	_check("failure counters", s.decode_failures == 1
		and s.direction_violations == 1 and s.rate_limited == 1)

	# describe_lines calls these two out specifically, because they are always a
	# bug rather than a condition. A reader scanning a bug report needs the
	# sentence, not the number.
	var lines := "\n".join(Array(s.describe_lines()))
	_check("describe_lines explains decode failures",
		lines.contains("message schemas differ"))
	_check("describe_lines explains direction violations",
		lines.contains("may not send"))

	s.reset()
	_check("reset clears everything",
		s.bytes_sent == 0 and s.packets_sent == 0 and s.decode_failures == 0
		and s.snapshots_lost == 0 and s.snapshots_received == 0
		and s.rtt_percentile(0.5) == 0.0)

	_line("")
	_sections_finished += 1


# --- 2. Loss, which is inferred and therefore easy to get wrong -------------

func _section_loss() -> void:
	_sections_started += 1
	_line("[b]2. inferred loss and reordering[/b]")

	var s := DotNetStats.new()
	for tick in [10, 11, 12, 13]:
		s.note_snapshot(tick)
	_check("a clean run loses nothing", s.snapshots_lost == 0, "%d" % s.snapshots_lost)
	_check("and counts arrivals", s.snapshots_received == 4, "%d" % s.snapshots_received)
	_check("loss_rate is 0", s.loss_rate() == 0.0, "%.3f" % s.loss_rate())

	# A gap is the only evidence available: an unreliable channel gives no
	# delivery report.
	var gap := DotNetStats.new()
	gap.note_snapshot(1)
	gap.note_snapshot(5)
	_check("a gap of 4 counts 3 lost", gap.snapshots_lost == 3, "%d" % gap.snapshots_lost)
	_check("loss_rate is lost/(lost+arrived)",
		is_equal_approx(gap.loss_rate(), 3.0 / 5.0), "%.3f" % gap.loss_rate())

	# The denominator has to be snapshots, not packets. A client sends inputs
	# every tick and receives snapshots at a lower rate; counting its *packets*
	# received as the denominator made the loss rate move whenever unrelated
	# traffic did, and a server — which receives no snapshots at all — always
	# reported 0.0 no matter what it had recorded.
	var diluted := DotNetStats.new()
	diluted.note_snapshot(1)
	diluted.note_snapshot(5)
	for _i in range(50):
		diluted.note_received(64)
	_check("unrelated traffic does not dilute the loss rate",
		is_equal_approx(diluted.loss_rate(), 3.0 / 5.0), "%.3f" % diluted.loss_rate())

	# Reordering is not loss. The late packet was counted as lost when the gap
	# it left was measured, and it then arrived.
	var reorder := DotNetStats.new()
	reorder.note_snapshot(1)
	reorder.note_snapshot(3)
	_check("tick 2 provisionally counted lost", reorder.snapshots_lost == 1)
	reorder.note_snapshot(2)
	_check("...and uncounted when it turns up", reorder.snapshots_lost == 0,
		"%d" % reorder.snapshots_lost)
	_check("but still recorded as out of order", reorder.out_of_order == 1)
	_check("a fully reordered run reports no loss", reorder.loss_rate() == 0.0,
		"%.3f" % reorder.loss_rate())

	# A duplicate of the newest tick is not a recovered loss, and must not
	# credit one that never happened.
	var dup := DotNetStats.new()
	dup.note_snapshot(1)
	dup.note_snapshot(4)
	dup.note_snapshot(4)
	_check("a duplicate does not cancel a real loss", dup.snapshots_lost == 2,
		"%d" % dup.snapshots_lost)
	_check("and is counted out of order", dup.out_of_order == 1)

	# Loss cannot go negative, however badly a peer misbehaves.
	var evil := DotNetStats.new()
	evil.note_snapshot(100)
	for tick in [50, 51, 52, 53]:
		evil.note_snapshot(tick)
	_check("loss never goes negative", evil.snapshots_lost >= 0, "%d" % evil.snapshots_lost)
	_check("loss_rate stays in 0..1",
		evil.loss_rate() >= 0.0 and evil.loss_rate() <= 1.0, "%.3f" % evil.loss_rate())

	_line("")
	_sections_finished += 1


# --- 3. Rates, which have to go stale ---------------------------------------

func _section_rates() -> void:
	_sections_started += 1
	_line("[b]3. rolling rates on a connection that stops[/b]")

	var s := DotNetStats.new()
	_check("rates start at zero", s.bytes_sent_per_sec == 0.0)

	for _i in range(20):
		s.note_sent(1000)

	# The window is a full second; nothing has rolled yet.
	_check("rates are still zero inside the window", s.bytes_sent_per_sec == 0.0,
		"%.1f" % s.bytes_sent_per_sec)

	await _wait(1.1)
	s.note_sent(1000)
	_check("traffic closes the window", s.bytes_sent_per_sec > 0.0,
		"%.0f B/s" % s.bytes_sent_per_sec)

	# ...and then the peer goes quiet. The rate has to decay on its own, because
	# a stalled connection reporting the throughput it had when it stalled is
	# wrong at exactly the moment someone is reading it to find out why. Rolling
	# only from note_sent/note_received meant nothing ever closed that window.
	var was := s.bytes_sent_per_sec
	await _wait(1.1)
	s.roll()
	_check("silence rolls the rate down", s.bytes_sent_per_sec < was,
		"%.0f -> %.0f B/s" % [was, s.bytes_sent_per_sec])
	await _wait(1.1)
	s.roll()
	_check("and to zero", s.bytes_sent_per_sec == 0.0, "%.1f" % s.bytes_sent_per_sec)

	# Totals are not rates and must survive the window closing.
	_check("totals are untouched by rolling", s.bytes_sent == 21000, "%d" % s.bytes_sent)

	_line("")
	_sections_finished += 1


# --- 4. RTT percentiles -----------------------------------------------------

func _section_rtt() -> void:
	_sections_started += 1
	_line("[b]4. rtt percentiles[/b]")

	var s := DotNetStats.new()
	for i in range(1, 101):
		s.note_rtt(float(i))

	# The 95th is the point of this class: a connection with a 40 ms mean and a
	# 300 ms tail feels far worse than a steady 80 ms one, and the mean cannot
	# tell them apart.
	var p50 := s.rtt_percentile(0.5)
	var p95 := s.rtt_percentile(0.95)
	_check("p50 is mid-range", p50 > 30.0 and p50 < 75.0, "%.0f" % p50)
	_check("p95 is above p50", p95 > p50, "p50=%.0f p95=%.0f" % [p50, p95])
	_check("p100 is the maximum", s.rtt_percentile(1.0) == 100.0,
		"%.0f" % s.rtt_percentile(1.0))
	_check("p0 is the minimum", s.rtt_percentile(0.0) > 0.0)
	_check("a percentile outside 0..1 is clamped, not an index error",
		s.rtt_percentile(5.0) == 100.0 and s.rtt_percentile(-1.0) > 0.0)

	# A zero or negative sample is not a measurement; letting one in would drag
	# every percentile down and make a bad connection look fine.
	var before := s.rtt_percentile(0.5)
	s.note_rtt(0.0)
	s.note_rtt(-50.0)
	_check("non-positive rtt samples are ignored", s.rtt_percentile(0.5) == before)

	# The sample buffer is bounded, and must keep the newest rather than the
	# first 128 the connection ever saw.
	var many := DotNetStats.new()
	for _i in range(DotNetStats.SAMPLE_CAPACITY * 2):
		many.note_rtt(10.0)
	for _i in range(DotNetStats.SAMPLE_CAPACITY):
		many.note_rtt(500.0)
	_check("the sample window keeps the newest",
		many.rtt_percentile(0.5) == 500.0, "%.0f" % many.rtt_percentile(0.5))

	_line("")
	_sections_finished += 1


# --- 5. Snapshots -----------------------------------------------------------

func _section_snapshot_basics() -> void:
	_sections_started += 1
	_line("[b]5. snapshot basics[/b]")

	var snap := DotNetSnapshot.new(42)
	_check("tick", snap.tick == 42)
	_check("a snapshot with no baseline is a full state", snap.is_full_state())
	_check("empty", snap.entity_count() == 0)
	_check("has() on an absent id is false", not snap.has(7))
	_check("values_for an absent id is empty, not null",
		snap.values_for(7) is Dictionary and (snap.values_for(7) as Dictionary).is_empty())

	snap.set_values(7, {"x": 1.0, "hp": 100})
	snap.set_values(3, {"x": 5.0})
	_check("entity_count", snap.entity_count() == 2)
	_check("has()", snap.has(7) and snap.has(3))
	_check("values round-trip", float(snap.values_for(7)["x"]) == 1.0)

	# Sorted, because these ids index a wire format and a describe() that a
	# human diffs between two runs.
	var ids := snap.net_ids()
	_check("net_ids is sorted", Array(ids) == [3, 7], str(ids))

	snap.baseline_tick = 40
	_check("a snapshot with a baseline is not a full state", not snap.is_full_state())

	_check("describe reports the tick and count",
		int(snap.describe()["tick"]) == 42 and int(snap.describe()["entities"]) == 2)

	_line("")
	_sections_finished += 1


func _section_snapshot_delta() -> void:
	_sections_started += 1
	_line("[b]6. delta and apply[/b]")

	var base := DotNetSnapshot.new(10)
	base.set_values(1, {"x": 0.0, "y": 0.0, "hp": 100})
	base.set_values(2, {"x": 9.0})

	var newer := DotNetSnapshot.new(11)
	newer.set_values(1, {"x": 5.0, "y": 0.0, "hp": 100})
	newer.set_values(2, {"x": 9.0})
	newer.set_values(3, {"x": 1.0})

	var delta := base.delta_to(newer)

	# The whole saving is here: a world where most entities are still should put
	# almost nothing on the wire. An unchanged entity must not appear at all,
	# and an entity that moved must contribute only the property that moved.
	_check("an unchanged entity is absent from the delta", not delta.has(2), str(delta))
	_check("a changed entity is present", delta.has(1))
	if delta.has(1):
		var d1: Dictionary = delta[1]
		_check("only the changed property travels", d1.size() == 1 and d1.has("x"), str(d1))
	_check("a new entity is present whole", delta.has(3))

	# Applying it must reconstruct the newer snapshot exactly, or the client and
	# server have quietly diverged — the failure this format exists to avoid.
	var rebuilt := base.apply_delta(delta, 11)
	_check("apply_delta restores the tick", rebuilt.tick == 11)
	_check("restores the changed value", float(rebuilt.values_for(1)["x"]) == 5.0)
	_check("keeps properties the delta did not mention",
		int(rebuilt.values_for(1)["hp"]) == 100)
	_check("keeps entities the delta did not mention",
		rebuilt.has(2) and float(rebuilt.values_for(2)["x"]) == 9.0)
	_check("adds the new entity", rebuilt.has(3))
	_check("rebuilt matches the original", rebuilt.entity_count() == newer.entity_count())

	# A delta against itself is empty, which is what a still world costs.
	_check("no change means no delta", base.delta_to(base).is_empty())

	_line("")
	_sections_finished += 1


func _section_snapshot_isolation() -> void:
	_sections_started += 1
	_line("[b]7. baselines outlive what built them[/b]")

	var base := DotNetSnapshot.new(1)
	base.set_values(1, {"x": 0.0})

	# The server keeps sent snapshots as delta baselines. A shallow copy lets a
	# later tick mutate a baseline the server is still deltaing against, and the
	# symptom is a client decoding a delta against bytes it never had — which
	# looks like corruption, several layers away from the cause.
	var copy := base.duplicate_deep()
	copy.set_values(1, {"x": 99.0})
	_check("mutating the copy leaves the original alone",
		float(base.values_for(1)["x"]) == 0.0, "%.1f" % float(base.values_for(1)["x"]))

	# The same hazard one level down: the per-entity dictionary.
	var copy2 := base.duplicate_deep()
	var vals: Dictionary = copy2.values_for(1)
	vals["x"] = 77.0
	_check("and the nested dictionaries are copies too",
		float(base.values_for(1)["x"]) == 0.0, "%.1f" % float(base.values_for(1)["x"]))

	# apply_delta produces a new snapshot; the baseline it was applied to must
	# survive intact, because the server may still delta another client against it.
	var applied := base.apply_delta({1: {"x": 42.0}}, 2)
	_check("apply_delta does not mutate its baseline",
		float(base.values_for(1)["x"]) == 0.0, "%.1f" % float(base.values_for(1)["x"]))
	_check("and the result has the new value",
		float(applied.values_for(1)["x"]) == 42.0)

	_line("")
	_sections_finished += 1


# --- Helpers ----------------------------------------------------------------

func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _finish(code: int = 0) -> void:
	if DotPlatform.is_headless():
		await get_tree().process_frame
		get_tree().quit(code)


func _check(label: String, passed: bool, detail: String = "") -> void:
	_checks += 1
	if not passed:
		_failures += 1

	var suffix := ""
	if detail != "":
		suffix = " (%s)" % detail

	_line("  %s %s%s" % [label.rpad(52), "ok" if passed else "FAILED", suffix])


func _line(text: String) -> void:
	print(text.replace("[b]", "").replace("[/b]", ""))
