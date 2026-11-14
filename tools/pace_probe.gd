extends Node

## A client clock against a server on a modelled wall clock: does the local player's jump keep wall time?
## `godot --headless res://tools/pace_probe.tscn`. Each row: client frame shape, server tick cost, the pace
## the clock settled on, client ticks per wall second, and a jump's apex and landing in wall ms (ideal shown).

const RATE := 66
const CAP := 17
const JUMP_V := 8.0
const GRAVITY := 20.0


func _ready() -> void:
	var rows := [
		["30 fps", 1.0 / 30.0, 0.0, 0.0, 0.0],
		["60 fps", 1.0 / 60.0, 0.0, 0.0, 0.0],
		["144 fps", 1.0 / 144.0, 0.0, 0.0, 0.0],
		["21 ms jitter, spikes", 0.021, 0.006, 0.0, 0.01],
		["21 ms, server 8 ms/tick", 0.021, 0.006, 0.008, 0.01],
		["21 ms, server 14 ms/tick", 0.021, 0.006, 0.014, 0.01],
		["21 ms, server 17 ms/tick", 0.021, 0.006, 0.017, 0.01],
		["21 ms, server 8 ms + 2 s/10 s at 20", 0.021, 0.006, -0.020, 0.01],
		["21 ms, server 8 ms + 1 s/5 s at 25", 0.021, 0.006, -0.025, 0.01],
	]
	for r: Array in rows:
		_run(r[0], r[1], r[2], r[3], r[4])
	get_tree().quit(0)


## [param frame] client frame seconds, [param jitter] its random spread, [param cost] server seconds a tick,
## [param spikes] the share of client frames that take 100 ms.
func _run(label: String, frame: float, jitter: float, cost: float, spikes: float) -> void:
	seed(7)
	var clock := DotNetClock.new(RATE)
	clock.follow_engine_time = false
	var wall := 0.0
	var acc := 0.0
	var steps := 0
	var frames := 0
	# The server: tick k is done at server_done[k]; ticks start on their period unless behind.
	var server_tick := 0
	var server_free := 0.0
	var in_flight: Array = []  # [arrive_wall, tick]
	var produced := 0
	var t_produced: Array[float] = []
	var synced_at := -1.0
	var seconds := 40.0
	var slow_server := 0.0
	var slow_client := 0.0
	while wall < seconds:
		var d := frame + randf_range(-jitter, jitter)
		if randf() < spikes:
			d = 0.1
		d = maxf(d, 0.001)
		wall += d
		frames += 1
		if clock.server_pace() < 1.0:
			slow_client += d
		# The server runs up to now: a tick starts at its period or when the last one ended.
		while true:
			var start := maxf(float(server_tick + 1) / RATE, server_free)
			if start > wall:
				break
			server_tick += 1
			var c := cost
			if cost < 0.0:
				# A hiccup: -cost a tick for a stretch of each period, 8 ms otherwise.
				var period := 10.0 if cost > -0.022 else 5.0
				var hiccup := 2.0 if cost > -0.022 else 1.0
				c = -cost if fmod(start, period) < hiccup else 0.008
				if c > 0.010:
					slow_server += c - 1.0 / RATE
			server_free = start + c
			in_flight.append([server_free + 0.0075 + randf() * 0.003, server_tick])
		# Godot: steps for the wall time this frame, capped.
		acc += d
		var n := mini(int(acc * RATE), CAP)
		acc -= float(n) / RATE
		if int(acc * RATE) > 0:
			acc = fmod(acc, 1.0 / RATE)
		for i in n:
			steps += 1
			if i == 0:
				clock.note_engine_frame(frames, int(wall * 1.0e6), steps, RATE, CAP)
			var ticks := clock.advance(1.0 / RATE)
			if clock.is_synced():
				for _t in ticks:
					produced += 1
					t_produced.append(wall)
		# Receive at the frame's poll.
		var keep: Array = []
		for p: Array in in_flight:
			if float(p[0]) <= wall:
				clock.sync_from_server(int(p[1]), 15.0)
				if synced_at < 0.0:
					synced_at = wall
			else:
				keep.append(p)
		in_flight = keep
	# Ticks per wall second over the last 20 s, and a jump started 25 s in, integrated per tick.
	var from := t_produced.bsearch(seconds - 20.0)
	var tps := float(t_produced.size() - from) / 20.0
	var at := t_produced.bsearch(25.0)
	var y := 0.0
	var v := JUMP_V
	var apex := -1.0
	var land := -1.0
	var i := at
	while i < t_produced.size():
		v -= GRAVITY / RATE
		y += v / RATE
		if apex < 0.0 and v <= 0.0:
			apex = t_produced[i] - t_produced[at]
		if y <= 0.0:
			land = t_produced[i] - t_produced[at]
			break
		i += 1
	print("%-26s server behind %.1f s of %d, client slowed %.1f s" % [label, slow_server, int(seconds), slow_client])
	print("%-26s pace %.3f  server %.1f ticks/s  client %.1f ticks/s  apex %d ms land %d ms (ideal %d / %d)" % [
		label, clock.server_pace(), float(server_tick) / wall, tps, int(apex * 1000.0), int(land * 1000.0),
		int(JUMP_V / GRAVITY * 1000.0), int(2.0 * JUMP_V / GRAVITY * 1000.0)])
