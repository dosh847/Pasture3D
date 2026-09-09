# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevPathMeanderize — the ORACLE for Path Meanderize. Pure GDScript, hidden.
#
# See PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md §1 & §3.2.
# The production node calls Pasture3DUtil.path_meanderize_solve and fails fast without it.
@tool
class_name Pasture3DGraphNodeDevPathMeanderize
extends Pasture3DGraphNodePathShape

@export_range(10.0, 2000.0, 1.0, "or_greater", "suffix:m") var wavelength: float = 150.0:
	set(v):
		wavelength = maxf(v, 1.0)
		_param_changed()

@export_range(0.0, 500.0, 0.5, "or_greater", "suffix:m") var amplitude: float = 25.0:
	set(v):
		amplitude = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 2.0, 0.001) var ratio: float = 0.4:
	set(v):
		ratio = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 1.0, 0.001) var noise_ratio: float = 0.1:
	set(v):
		noise_ratio = maxf(v, 0.0)
		_param_changed()

@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export_range(1, 10, 1) var iterations: int = 4:
	set(v):
		iterations = clampi(v, 1, 10)
		_param_changed()

@export_range(1.0, 100.0, 0.5, "or_greater", "suffix:m") var min_segment_length: float = 5.0:
	set(v):
		min_segment_length = maxf(v, 0.1)
		_param_changed()

@export_range(1, 8, 1) var edge_divisions: int = 1:
	set(v):
		edge_divisions = clampi(v, 1, 8)
		_param_changed()

@export var remove_loops: bool = true:
	set(v):
		remove_loops = v
		_param_changed()

@export var pin_ends: bool = true:
	set(v):
		pin_ends = v
		_param_changed()

const MAX_POINTS: int = 200000


func op() -> StringName:
	return &"dev_path_meanderize"


func reshape(p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	if (ratio <= 0.0 and noise_ratio <= 0.0) or iterations <= 0 or p_src.points.size() < 2:
		return

	var pts := ring_of(p_src)
	var cur_seed := seed

	var eff_amp := amplitude * (ratio + noise_ratio)
	if eff_amp > 0.0:
		var max_seg_len := maxf(wavelength / 4.0, min_segment_length)
		pts = _subdivide_long_edges(pts, max_seg_len, p_src.closed)
		var n := pts.size()
		var s_arr := arc_lengths(pts, p_src.closed)
		var total_len := s_arr[s_arr.size() - 1]

		if total_len > 1.0e-4 and n >= 2:
			var wl := wavelength
			if p_src.closed:
				var m := maxi(1, int(roundf(total_len / wl)))
				wl = total_len / float(m)

			var phi_0 := float(posmod(seed * 2654435761, 628318)) / 100000.0
			var new_pts := pts.duplicate()

			for i in range(n):
				var is_end := (i == 0 or i == n - 1)
				if is_end and not p_src.closed and pin_ends:
					continue

				var s := s_arr[i]
				var u := (TAU * s) / wl
				var swing := sin(u + phi_0)
				var harmonic := 0.3 * sin(2.0 * u + phi_0 * 1.7)
				var noise_val := _noise1d(s / (wl * 0.5), seed + 101)
				var disp := eff_amp * (swing + harmonic + noise_ratio * noise_val)

				if not p_src.closed and pin_ends:
					var taper_len := minf(wl * 0.75, total_len * 0.35)
					if taper_len > 0.0:
						var d0 := clampf(s / taper_len, 0.0, 1.0)
						var d1 := clampf((total_len - s) / taper_len, 0.0, 1.0)
						var env := (d0 * d0 * (3.0 - 2.0 * d0)) * (d1 * d1 * (3.0 - 2.0 * d1))
						disp *= env

				var prev_pt := pts[posmod(i - 1, n - 1) if p_src.closed else maxi(i - 1, 0)]
				var next_pt := pts[posmod(i + 1, n - 1) if p_src.closed else mini(i + 1, n - 1)]
				var seg := next_pt - prev_pt
				var seg_len := seg.length()
				if seg_len > 0.0:
					var nrm := Vector2(seg.y, -seg.x) / seg_len
					new_pts[i] = pts[i] + nrm * disp

			if p_src.closed and n >= 2:
				new_pts[n - 1] = new_pts[0]
			pts = new_pts

	for it in iterations:
		var n := pts.size()
		if n < 2 or n > MAX_POINTS:
			break
		var disp_pts := pts.duplicate()

		for i in n:
			var is_end := (i == 0 or i == n - 1)
			if is_end and not p_src.closed and pin_ends:
				continue

			var prev_i := posmod(i - 1, n - 1) if p_src.closed else maxi(i - 1, 0)
			var next_i := posmod(i + 1, n - 1) if p_src.closed else mini(i + 1, n - 1)
			var p0 := pts[prev_i]
			var p1 := pts[i]
			var p2 := pts[next_i]

			var chord_v := p2 - p0
			var chord := chord_v.length()
			if chord <= 1e-4:
				if is_end and not p_src.closed and not pin_ends:
					var adj_i := 1 if i == 0 else n - 2
					var edge := pts[adj_i] - pts[i]
					var elen := edge.length()
					if elen > 1e-4:
						var enrm := Vector2(edge.y, -edge.x) / elen
						var j: float = _hash1d(i * 31 + it * 7, cur_seed)
						disp_pts[i] = pts[i] + enrm * elen * noise_ratio * j
				continue

			var nrm := Vector2(chord_v.y, -chord_v.x) / chord
			var v_in := p1 - p0
			var v_out := p2 - p1
			var l_in := v_in.length()
			var l_out := v_out.length()
			var turn: float = (v_in.cross(v_out) / (l_in * l_out)) if (l_in > 1e-4 and l_out > 1e-4) else 0.0
			var jitter: float = _hash1d(i * 31 + it * 7, cur_seed)

			var disp: float = chord * (ratio * turn + noise_ratio * jitter)
			disp_pts[i] = p1 + nrm * disp

		if p_src.closed and n >= 2:
			disp_pts[n - 1] = disp_pts[0]

		if edge_divisions > 1:
			var div_pts := PackedVector2Array()
			for i in n - 1:
				var a := disp_pts[i]
				var b := disp_pts[i + 1]
				div_pts.append(a)
				var d := (b - a).length()
				if d > min_segment_length:
					for k in range(1, edge_divisions):
						div_pts.append(a.lerp(b, float(k) / float(edge_divisions)))
			div_pts.append(disp_pts[n - 1])
			if p_src.closed and div_pts.size() >= 2:
				div_pts[div_pts.size() - 1] = div_pts[0]
			disp_pts = div_pts

		if remove_loops:
			disp_pts = _cut_loops(disp_pts, p_src.closed)
		pts = disp_pts
		cur_seed += 1013

	p_out.points = unring(pts, p_src.closed)
	carry_values(p_src, p_out)


static func _seg_intersect(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> Variant:
	var d1 := p2 - p1
	var d2 := p4 - p3
	var cross := d1.cross(d2)
	if absf(cross) < 1e-6:
		return null
	var d := p3 - p1
	var t1 := d.cross(d2) / cross
	var t2 := d.cross(d1) / cross
	if t1 > 0.001 and t1 < 0.999 and t2 > 0.001 and t2 < 0.999:
		return p1 + d1 * t1
	return null


static func _cut_loops(p_pts: PackedVector2Array, p_closed: bool) -> PackedVector2Array:
	var pts := p_pts
	var changed := true
	var passes := 0
	const MAX_PASSES := 32

	while changed and passes < MAX_PASSES:
		changed = false
		passes += 1
		var n := pts.size()
		var segs := (n - 1) if not p_closed else (n - 1 if n >= 2 else 0)
		if segs < 3:
			break

		for i in segs:
			var a := pts[i]
			var b := pts[(i + 1) % n]
			for j in range(i + 2, segs):
				if p_closed and i == 0 and j == segs - 1:
					continue
				var c := pts[j]
				var d := pts[(j + 1) % n]
				var x = _seg_intersect(a, b, c, d)
				if x != null:
					var cut := PackedVector2Array()
					if p_closed:
						var loop_forward := j - i
						var loop_wrap := segs - loop_forward
						if loop_forward <= loop_wrap:
							for k in range(0, i + 1):
								cut.append(pts[k])
							cut.append(x)
							for k in range(j + 1, n):
								cut.append(pts[k])
						else:
							cut.append(x)
							for k in range(i + 1, j + 1):
								cut.append(pts[k])
							cut.append(x)
					else:
						for k in range(0, i + 1):
							cut.append(pts[k])
						cut.append(x)
						for k in range(j + 1, n):
							cut.append(pts[k])
					pts = cut
					changed = true
					break
			if changed:
				break
	return pts


func _subdivide_long_edges(p_pts: PackedVector2Array, p_max_len: float, p_closed: bool) -> PackedVector2Array:
	var n := p_pts.size()
	if n < 2 or p_max_len <= 0.0:
		return p_pts
	var out := PackedVector2Array()
	for i in range(n - 1):
		var a := p_pts[i]
		var b := p_pts[i + 1]
		var d := (b - a).length()
		out.append(a)
		if d > p_max_len:
			var steps := clampi(int(ceilf(d / p_max_len)), 1, 32)
			for k in range(1, steps):
				out.append(a.lerp(b, float(k) / float(steps)))
	out.append(p_pts[n - 1])
	if p_closed and out.size() >= 2:
		out[out.size() - 1] = out[0]
	return out


static func _noise1d(t: float, p_seed: int, p_closed_period: int = -1) -> float:
	var i := floori(t)
	var f := t - float(i)
	var u := f * f * (3.0 - 2.0 * f)
	var i0 := i
	var i1 := i + 1
	if p_closed_period > 0:
		i0 = posmod(i0, p_closed_period)
		i1 = posmod(i1, p_closed_period)
	var v0 := _hash1d(i0, p_seed)
	var v1 := _hash1d(i1, p_seed)
	return lerpf(v0, v1, u)


static func _hash1d(k: int, p_seed: int) -> float:
	var x := (k * 73856093) ^ (p_seed * 19349663) ^ 0x9e3779b9
	x = ((x >> 16) ^ x) * 0x45d9f3b
	x = ((x >> 16) ^ x) * 0x45d9f3b
	x = (x >> 16) ^ x
	return float((x & 0x7fffffff) % 2001 - 1000) / 1000.0

