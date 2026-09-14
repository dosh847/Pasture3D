# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# LevelerBench — what the Leveler costs. Not a gate: it reports, it does not pass or fail (except when a
# run produced nothing, which would make its timing meaningless).
#
# Times Pasture3DUtil.leveler_grid at 1 thread and at N on three routes that exercise different passes:
#   mask/JFA + MEAN            — the raster distance route and the block-folded mean
#   exact loop + MEDIAN        — per-cell polygon queries and the histogram merge
#   loop + path width + SLOPE  — nearest-segment queries on every non-core cell
# plus the GDScript oracle at a small size, for the native/GDScript ratio.
#
# Ask before running — see the ask-before-perf-tests rule.
#   Godot_v4.7-stable_win64_console.exe --headless --path project bench/LevelerBench.tscn
extends Node

const SIZES := [1024, 2048]
const REPS := 3
const ORACLE_SIZE := 256


func _ready() -> void:
	print("=== LevelerBench (median of %d runs, ms) ===\n" % REPS)
	var empty := 0
	for gs in SIZES:
		var half := float(gs) * 0.5
		var rect := Rect2(-half, -half, float(gs), float(gs))
		var h := _surface(gs, rect)
		var mask := _mask(gs, rect, half)
		var loop := _loop(half * 0.55)
		print("grid %d x %d (%.1f M cells)" % [gs, gs, gs * gs / 1.0e6])
		for r in _routes(loop, mask):
			var p: PackedFloat32Array = r[1]
			var pts: PackedVector2Array = r[2].points if r[2] != null else PackedVector2Array()
			var wid: PackedFloat32Array = r[2].half_widths if r[2] != null else PackedFloat32Array()
			var mk: PackedFloat32Array = r[3]
			var lut := Pasture3DGraphNodeLeveler.new().falloff_lut()
			var times := []
			for threads in [1, 0]:
				Pasture3DUtil.set_max_threads(threads)
				var ms := []
				for i in REPS:
					var t0 := Time.get_ticks_usec()
					var res: Dictionary = Pasture3DUtil.leveler_grid(pts, wid, r[2] != null, h, mk, gs, gs, rect, lut, p)
					ms.append((Time.get_ticks_usec() - t0) / 1000.0)
					if not bool(res.get("ok", false)) or int(res["core_count"]) == 0:
						empty += 1
				ms.sort()
				times.append(ms[REPS / 2])
			Pasture3DUtil.set_max_threads(0)
			print("    %-28s 1 thread %8.1f   N threads %8.1f   speedup %.2fx   (%.1f ns/cell at N)" % [
				r[0], times[0], times[1], times[0] / maxf(times[1], 0.001), times[1] * 1.0e6 / float(gs * gs)])

	# Native vs GDScript oracle, same small fixture.
	var og := ORACLE_SIZE
	var ohalf := float(og) * 0.5
	var orect := Rect2(-ohalf, -ohalf, float(og), float(og))
	var oh := _surface(og, orect)
	var oloop := _loop(ohalf * 0.55)
	print("\noracle ratio at %d x %d (exact loop, MEDIAN)" % [og, og])
	var ora := Pasture3DGraphNodeDevLeveler.new()
	var nat := Pasture3DGraphNodeLeveler.new()
	for nd in [ora, nat]:
		nd.statistic = Pasture3DGraphNodeLevelerBase.Statistic.MEDIAN
		nd.set_path_inputs([null, oloop, null, null])
	var ins := [oh, PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]
	var t0 := Time.get_ticks_usec()
	ora.eval_grid_channels(ins, og, og, null, orect)
	var t_ora := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	nat.eval_grid_channels(ins, og, og, null, orect)
	var t_nat := (Time.get_ticks_usec() - t0) / 1000.0
	print("    oracle %.1f ms   native %.2f ms   ratio %.0fx" % [t_ora, t_nat, t_ora / maxf(t_nat, 0.001)])

	if empty > 0:
		print("\n!! %d runs levelled nothing — the timings above are of a pass-through" % empty)
	print("\n=== LEVELER BENCH DONE ===")
	get_tree().quit(1 if empty > 0 else 0)


func _routes(p_loop: Pasture3DGraphPath, p_mask: PackedFloat32Array) -> Array:
	return [
		["mask/JFA + MEAN", _params(0, 0, false, 0), null, p_mask],
		["exact loop + MEDIAN", _params(0, 1, false, 0), p_loop, PackedFloat32Array()],
		["loop + path width + SLOPE", _params(1, 0, true, 1), p_loop, PackedFloat32Array()],
	]


func _params(p_mode: int, p_stat: int, p_width: bool, p_shape: int) -> PackedFloat32Array:
	var n := Pasture3DGraphNodeLeveler.new()
	n.mode = p_mode
	n.statistic = p_stat
	n.target_height = 5.0
	n.feather = 24.0
	n.feather_from_path_width = p_width
	n.path_width_scale = 2.0
	n.walls_shape = p_shape
	return n.native_lower()["params"]


func _surface(p_gs: int, p_rect: Rect2) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(p_gs * p_gs)
	var d := p_rect.size.x / p_gs
	for iz in p_gs:
		var z := p_rect.position.y + (iz + 0.5) * d
		for ix in p_gs:
			var x := p_rect.position.x + (ix + 0.5) * d
			h[iz * p_gs + ix] = 10.0 + 0.05 * x + 0.03 * z + 4.0 * sin(x * 0.02) * cos(z * 0.017)
	return h


func _mask(p_gs: int, p_rect: Rect2, p_half: float) -> PackedFloat32Array:
	var m := PackedFloat32Array()
	m.resize(p_gs * p_gs)
	var d := p_rect.size.x / p_gs
	var r0 := p_half * 0.4
	var r1 := p_half * 0.6
	for iz in p_gs:
		var z := p_rect.position.y + (iz + 0.5) * d
		for ix in p_gs:
			var x := p_rect.position.x + (ix + 0.5) * d
			m[iz * p_gs + ix] = clampf((r1 - sqrt(x * x + z * z)) / (r1 - r0), 0.0, 1.0)
	return m


## A 64-vertex wobbly ring, so nearest-segment queries do real index work.
func _loop(p_r: float) -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var wid := PackedFloat32Array()
	for i in 64:
		var a := TAU * float(i) / 64.0
		var rr := p_r * (1.0 + 0.15 * sin(a * 5.0))
		pts.append(Vector2(cos(a), sin(a)) * rr)
		wid.append(6.0 + 4.0 * sin(a * 3.0))
	p.points = pts
	p.half_widths = wid
	p.closed = true
	return p
