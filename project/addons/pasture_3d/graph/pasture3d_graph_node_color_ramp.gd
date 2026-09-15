# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeColorRamp — a scalar field through a Godot Gradient, as a per-cell COLOR
# (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md §7).
#
# A colour node, like Color Blend: it never lowers, has no op id, and so cannot cost a graph its native
# route. Its `in` field is tapped by the colour resolver through `color_field_port()`, and the per-cell
# mapping runs natively in `Pasture3DUtil.color_ramp_cells` over the same evaluator as the Value Ramp
# (src/pasture_3d_ramp_eval.h). The [Dev/GD] Color Ramp maps through Gradient.sample instead, as the oracle.
#
# There are no driven window ports: a sideband node is resolved outside the program, so a driven param would
# need a tap of its own and would behave unlike every other node's ports.
@tool
class_name Pasture3DGraphNodeColorRamp
extends Pasture3DGraphNode

enum Repeat { CLAMP, REPEAT, MIRROR }

## The stops. Unassigned or empty = grey t (and a warning).
@export var gradient: Gradient:
	set(v):
		if gradient != null and gradient.changed.is_connected(emit_changed):
			gradient.changed.disconnect(emit_changed)
		gradient = v
		if gradient != null and not gradient.changed.is_connected(emit_changed):
			gradient.changed.connect(emit_changed)
		emit_changed()

@export_group("Input window")
## Input value mapped to offset 0.
@export var input_min: float = 0.0:
	set(v):
		input_min = v
		emit_changed()

## Input value mapped to offset 1.
@export var input_max: float = 1.0:
	set(v):
		input_max = v
		emit_changed()

## Applied to the normalised input before the gradient is sampled.
@export var repeat: Repeat = Repeat.CLAMP:
	set(v):
		repeat = v
		emit_changed()

@export_group("")
## Scales output alpha, which is the colour overlay's coverage. 0 paints nothing.
@export_range(0.0, 1.0, 0.01) var strength: float = 1.0:
	set(v):
		strength = clampf(v, 0.0, 1.0)
		emit_changed()


func _init() -> void:
	super()


func op() -> StringName:
	return &"color_ramp"


func role() -> Role:
	return Role.COMBINER


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["in"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.COLOR])


func color_field_port() -> int:
	return 0


func _grey(p_t: float) -> Color:
	return Color(p_t, p_t, p_t, 1.0)


func _has_stops() -> bool:
	return gradient != null and gradient.get_point_count() > 0


func _strength(p_c: Color) -> Color:
	return Color(p_c.r, p_c.g, p_c.b, p_c.a * strength)


## The uniform answer when `in` is unwired or cannot be tapped: the colour at offset 0.
func graph_color(_p_upstream: Dictionary = {}) -> Color:
	return _strength(gradient.sample(0.0) if _has_stops() else _grey(0.0))


## One Color per cell, mapped natively.
func graph_color_cells(_p_upstream: Dictionary, p_field: PackedFloat32Array, p_n: int) -> PackedColorArray:
	var mode := gradient.interpolation_mode if gradient != null else 0
	var space := gradient.interpolation_color_space if gradient != null else 0
	var out: PackedColorArray = Pasture3DUtil.color_ramp_cells(p_field, Pasture3DGraphNodeValueRamp.stops_of(gradient),
			p_n, mode, space, input_min, input_max, repeat)
	if strength < 1.0:
		for i in out.size():
			out[i].a *= strength
	return out


## The definition of one cell, through Gradient.sample. The Dev node maps with this.
func color_at_value(p_x: float) -> Color:
	var t := 0.0
	if is_finite(p_x):
		var span := input_max - input_min
		t = (p_x - input_min) / span if absf(span) > 1.0e-9 else 0.0
		t = Pasture3DGraphDistance.repeat(repeat, t)
	return gradient.sample(t) if _has_stops() else _grey(t)


## A COLOR is not a field; nothing evaluates this node in the program.
func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return 0.0


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if not _has_stops():
		w.append("%s: no Gradient stops, so the output is grey t." % display_name())
	if absf(input_max - input_min) <= 1.0e-9:
		w.append("%s: the input window is empty (min == max), so every value samples offset 0." % display_name())
	if strength <= 0.0:
		w.append("%s: Strength is 0, so a Color Sink paints nothing." % display_name())
	return w
