# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevPathFractalize — the ORACLE for Path Fractalize. Pure GDScript, hidden.
#
# See PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md §1 & §3.2.
# The production node calls Pasture3DUtil.path_fractalize_solve and fails fast without it.
@tool
class_name Pasture3DGraphNodeDevPathFractalize
extends Pasture3DGraphNodePathShape

enum Bias { BOTH, LEFT, RIGHT }

@export var orientation: Bias = Bias.BOTH:
	set(v):
		orientation = v
		_param_changed()

@export_range(1.0, 2000.0, 0.5, "or_greater", "suffix:m") var wavelength: float = 50.0:
	set(v):
		wavelength = maxf(v, 0.1)
		_param_changed()

@export_range(1.0, 4.0, 0.01) var lacunarity: float = 2.0:
	set(v):
		lacunarity = maxf(v, 1.0)
		_param_changed()

@export_range(0, 12, 1) var iterations: int = 4:
	set(v):
		iterations = clampi(v, 0, 12)
		_param_changed()

@export_range(0.0, 200.0, 0.01, "or_greater", "suffix:m") var sigma: float = 4.0:
	set(v):
		sigma = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 2.0, 0.001) var persistence: float = 0.5:
	set(v):
		persistence = maxf(v, 0.0)
		_param_changed()

@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export var pin_ends: bool = true:
	set(v):
		pin_ends = v
		_param_changed()

const MAX_POINTS: int = 200000


func op() -> StringName:
	return &"dev_path_fractalize"


func reshape(p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	if iterations <= 0 or sigma <= 0.0:
		return
	var pts := ring_of(p_src)
	if pts.size() < 2:
		return

	var finest_wl := wavelength / pow(lacunarity, float(iterations - 1))
	var max_seg_len := clampf(finest_wl * 0.5, 2.0, 50.0)
	pts = _subdivide_long_edges(pts, max_seg_len, p_src.closed)

	var n := pts.size()
	if n < 2:
		return

	var s_arr := arc_lengths(pts, p_src.closed)
	var total_len := s_arr[s_arr.size() - 1]
	if total_len <= 1.0e-5:
		return

	var new_pts := pts.duplicate()

	for i in range(n):
		var is_end := (i == 0 or i == n - 1)
		if is_end and not p_src.closed and pin_ends:
			continue

		var s := s_arr[i]
		var disp := 0.0
		var amp := sigma

		for o in iterations:
			var wl := wavelength / pow(lacunarity, float(o))
			var period := -1
			if p_src.closed:
				var m := maxi(1, int(roundf(total_len / wl)))
				wl = total_len / float(m)
				period = m
			var octave_seed := seed + o * 1013
			disp += amp * _noise1d(s / wl, octave_seed, period)
			amp *= persistence

		match orientation:
			Bias.LEFT:
				disp = absf(disp)
			Bias.RIGHT:
				disp = -absf(disp)
			_:
				pass

		if not p_src.closed and pin_ends:
			var taper_len := minf(wavelength * 0.75, total_len * 0.25)
			if taper_len > 0.0:
				var d0 := clampf(s / taper_len, 0.0, 1.0)
				var d1 := clampf((total_len - s) / taper_len, 0.0, 1.0)
				disp *= (d0 * d0 * (3.0 - 2.0 * d0)) * (d1 * d1 * (3.0 - 2.0 * d1))

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
	p_out.points = unring(pts, p_src.closed)
	carry_values(p_src, p_out)


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
