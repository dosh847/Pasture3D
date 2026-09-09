# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevPathWidth — the ORACLE for Path Width. Pure GDScript, hidden.
#
# See PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md §1 & §3.2.
# The production node calls Pasture3DUtil.path_width_solve and fails fast without it.
@tool
class_name Pasture3DGraphNodeDevPathWidth
extends Pasture3DGraphNodePathShape

enum Mode { SET, SCALE }

@export var mode: Mode = Mode.SET:
	set(v):
		mode = v
		emit_changed()

@export_range(0.0, 200.0, 0.01, "or_greater") var half_width: float = 5.0:
	set(v):
		half_width = maxf(v, 0.0)
		emit_changed()

@export var along: Curve:
	set(v):
		if along != null and along.changed.is_connected(emit_changed):
			along.changed.disconnect(emit_changed)
		along = v
		if along != null and not along.changed.is_connected(emit_changed):
			along.changed.connect(emit_changed)
		emit_changed()

@export_range(0.001, 50.0, 0.001, "or_greater", "suffix:m") var min_half_width: float = 0.1:
	set(v):
		min_half_width = maxf(v, 0.001)
		emit_changed()


func op() -> StringName:
	return &"dev_path_width"


func moves_the_line() -> bool:
	return false


func reshape(p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	var n := p_src.points.size()
	var cum := arc_lengths(p_src.points)
	var total: float = cum[n - 1]
	var was := p_src.half_widths
	var hw := PackedFloat32Array()
	hw.resize(n)

	for i in n:
		var w: float = half_width
		if mode == Mode.SCALE:
			var prev: float = was[i] if (i < was.size()) else 1.0
			w = prev * half_width
		if along != null and total > 0.0:
			var u := clampf(cum[i] / total, 0.0, 1.0)
			w *= along.sample_baked(u)
		hw[i] = maxf(w, min_half_width)

	p_out.half_widths = hw
