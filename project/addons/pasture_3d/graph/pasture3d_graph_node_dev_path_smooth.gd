# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevPathSmooth — the ORACLE for Path Smooth. Pure GDScript, hidden.
#
# See PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md §1 & §3.2.
# The production node calls Pasture3DUtil.path_smooth_solve and fails fast without it.
@tool
class_name Pasture3DGraphNodeDevPathSmooth
extends Pasture3DGraphNodePathShape

@export_range(0, 64, 1) var window: int = 3:
	set(v):
		window = maxi(v, 0)
		emit_changed()

@export_range(0.0, 1.0, 0.001) var intensity: float = 1.0:
	set(v):
		intensity = clampf(v, 0.0, 1.0)
		emit_changed()

@export_range(0.0, 0.95, 0.001) var inertia: float = 0.0:
	set(v):
		inertia = clampf(v, 0.0, 0.95)
		emit_changed()

@export var pin_ends: bool = true:
	set(v):
		pin_ends = v
		emit_changed()


func min_vertices() -> int:
	return 3


func op() -> StringName:
	return &"dev_path_smooth"


func reshape(p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	if window <= 0 or intensity <= 0.0:
		return
	var ring := ring_of(p_src)
	var n := ring.size()
	var closed := p_src.closed
	var out := PackedVector2Array()
	out.resize(n)
	var prev := ring[0]
	for i in n:
		var acc := Vector2.ZERO
		var cnt := 0
		for k in range(-window, window + 1):
			var j := i + k
			if closed:
				j = posmod(j, n - 1)
			else:
				j = clampi(j, 0, n - 1)
			acc += ring[j]
			cnt += 1
		var avg := acc / float(cnt)
		var moved := ring[i].lerp(avg, intensity)
		if inertia > 0.0 and i > 0:
			moved = moved.lerp(prev, inertia)
		if pin_ends and not closed and (i == 0 or i == n - 1):
			moved = ring[i]
		out[i] = moved
		prev = moved
	if closed:
		out[n - 1] = out[0]
	p_out.points = unring(out, closed)
	carry_values(p_src, p_out)
