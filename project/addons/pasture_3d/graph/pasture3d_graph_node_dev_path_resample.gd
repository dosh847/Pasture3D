# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevPathResample — the ORACLE for Path Resample. Pure GDScript, hidden.
#
# See PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md §1 & §3.2.
# The production node calls Pasture3DUtil.path_resample_solve and fails fast without it.
@tool
class_name Pasture3DGraphNodeDevPathResample
extends Pasture3DGraphNodePathShape

enum Method { LINEAR, CUBIC, CATMULL_ROM, BEZIER }

@export var method: Method = Method.LINEAR:
	set(v):
		method = v
		emit_changed()

@export_range(0.25, 200.0, 0.05, "or_greater", "suffix:m") var step: float = 4.0:
	set(v):
		step = maxf(v, 0.05)
		emit_changed()

@export var close: bool = false:
	set(v):
		close = v
		emit_changed()

const MAX_POINTS: int = 200000


func op() -> StringName:
	return &"dev_path_resample"


func reshape(p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	if close:
		p_out.closed = true
	var ring := ring_of(p_out)
	if ring.size() < 2:
		return
	var cum := arc_lengths(ring)
	var total: float = cum[cum.size() - 1]
	if total <= 0.0:
		return
	var count := int(floor(total / step)) + 1
	if count < 2 or count > MAX_POINTS:
		return

	var pts := PackedVector2Array()
	pts.resize(count)
	for i in count:
		pts[i] = _at(ring, cum, minf(float(i) * step, total))
	if pts[count - 1].distance_to(ring[ring.size() - 1]) > step * 0.5:
		pts.append(ring[ring.size() - 1])

	p_out.points = unring(pts, p_out.closed)
	carry_values(p_src, p_out)


func _at(p_ring: PackedVector2Array, p_cum: PackedFloat32Array, p_s: float) -> Vector2:
	var n := p_ring.size()
	var i := 1
	while i < n - 1 and p_cum[i] < p_s:
		i += 1
	var s0: float = p_cum[i - 1]
	var s1: float = p_cum[i]
	var t: float = 0.0 if s1 <= s0 else clampf((p_s - s0) / (s1 - s0), 0.0, 1.0)
	if method == Method.LINEAR:
		return p_ring[i - 1].lerp(p_ring[i], t)
	var p0 := p_ring[maxi(i - 2, 0)]
	var p1 := p_ring[i - 1]
	var p2 := p_ring[i]
	var p3 := p_ring[mini(i + 1, n - 1)]
	if method == Method.BEZIER:
		var c1 := p1 + (p2 - p0) / 6.0
		var c2 := p2 - (p3 - p1) / 6.0
		var u := 1.0 - t
		return (p1 * (u * u * u) + c1 * (3.0 * u * u * t) + c2 * (3.0 * u * t * t)
				+ p2 * (t * t * t))
	if method == Method.CUBIC:
		return p1.cubic_interpolate(p2, p0, p3, t)
	return _catmull_rom(p0, p1, p2, p3, t)


static func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((p1 * 2.0) + (-p0 + p2) * t + (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2
			+ (-p0 + p1 * 3.0 - p2 * 3.0 + p3) * t3)
