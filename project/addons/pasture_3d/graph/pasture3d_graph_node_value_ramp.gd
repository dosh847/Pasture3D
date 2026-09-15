# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeValueRamp — a FILTER cell node: map the input through a Godot Gradient and read one
# channel back as a scalar (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md §6).
#
# The gradient is evaluated EXACTLY, from its stops, never from a 256-entry table: on a 100 m window a table
# smears a CONSTANT band edge by 0.4 m. The native kernel (src/pasture_3d_ramp_eval.h) is a transcription of
# the pinned engine's Gradient::get_color_at_offset, and the oracle is Gradient.sample itself.
@tool
class_name Pasture3DGraphNodeValueRamp
extends Pasture3DGraphNode

## Values are serialised. Append only.
enum OutputMode { MASK, HEIGHT }
enum Channel { AVERAGE, LUMINANCE, RED, GREEN, BLUE, ALPHA }
enum Repeat { CLAMP, REPEAT, MIRROR }

## The stops. Unassigned or empty = the normalised input passes through (and a warning).
@export var gradient: Gradient:
	set(v):
		if gradient != null and gradient.changed.is_connected(emit_changed):
			gradient.changed.disconnect(emit_changed)
		gradient = v
		if gradient != null and not gradient.changed.is_connected(emit_changed):
			gradient.changed.connect(emit_changed)
		emit_changed()

## Reduces the sampled colour to a scalar. AVERAGE is (r + g + b) / 3; read from the sRGB result.
@export var channel: Channel = Channel.AVERAGE:
	set(v):
		channel = v
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

@export_group("Output")
## MASK: the value clamped to [0, 1]. HEIGHT: lerp(height_min, height_max, value) in metres.
@export var output_mode: OutputMode = OutputMode.MASK:
	set(v):
		output_mode = v
		notify_property_list_changed()
		emit_changed()

@export var height_min: float = 0.0:
	set(v):
		height_min = v
		emit_changed()

@export var height_max: float = 100.0:
	set(v):
		height_max = v
		emit_changed()

## Blends from the normalised input (0) to the ramp value (1), before the output mapping.
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()

@export_tool_button("Auto Fit Range") var _auto_btn = auto_fit_range


func _init() -> void:
	super()


func auto_fit_range(p_min: float = 0.0, p_max: float = 1.0) -> void:
	input_min = p_min
	input_max = p_max


func op() -> StringName:
	return &"value_ramp"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return false


func input_count() -> int:
	return 6


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "in_min", "in_max", "height_min", "height_max", "amount"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.FLOAT, PortType.FLOAT, PortType.FLOAT, PortType.FLOAT,
			PortType.FLOAT])


func output_port_type() -> int:
	return PortType.HEIGHT if output_mode == OutputMode.HEIGHT else PortType.MASK


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([output_port_type()])


func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1, 4, 5, 8, 9, 10])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		1: return input_min
		2: return input_max
		3: return height_min
		4: return height_max
		5: return amount
	return 0.0


## [offset, r, g, b, a] x n in the ENGINE's sorted order. Sampling once first runs Gradient::_update_sorting,
## so the points read back are the order get_color_at_offset searches — which is what decides an
## equal-offset tie. Reading `offsets` from an unsorted resource would lower a different tie.
func stop_table() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if gradient == null or gradient.get_point_count() == 0:
		return out
	gradient.sample(0.0)
	var offs := gradient.offsets
	var cols := gradient.colors
	var n := mini(offs.size(), cols.size())
	out.resize(n * 5)
	for k in n:
		out[k * 5] = offs[k]
		out[k * 5 + 1] = cols[k].r
		out[k * 5 + 2] = cols[k].g
		out[k * 5 + 3] = cols[k].b
		out[k * 5 + 4] = cols[k].a
	return out


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	var stops := stop_table()
	p[0] = float(stops.size() / 5)
	p[1] = float(gradient.interpolation_mode) if gradient != null else 0.0
	p[2] = float(gradient.interpolation_color_space) if gradient != null else 0.0
	p[3] = float(channel)
	p[4] = input_min
	p[5] = input_max
	p[6] = float(repeat)
	p[7] = float(output_mode)
	p[8] = height_min
	p[9] = height_max
	p[10] = amount
	return {"params": p, "lut": stops}


## Colour -> scalar, as p3d_ramp_channel.
static func reduce(p_c: Color, p_channel: int) -> float:
	match p_channel:
		Channel.LUMINANCE: return 0.2126 * p_c.r + 0.7152 * p_c.g + 0.0722 * p_c.b
		Channel.RED: return p_c.r
		Channel.GREEN: return p_c.g
		Channel.BLUE: return p_c.b
		Channel.ALPHA: return p_c.a
	return (p_c.r + p_c.g + p_c.b) / 3.0


## The definition, through Gradient.sample: the engine is the reference.
func eval_cell(_p_wx: float, _p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var x := _in(p_inputs, 0, 0.0)
	if is_nan(x):
		return x
	var imin := _in(p_inputs, 1, input_min)
	var imax := _in(p_inputs, 2, input_max)
	var span := imax - imin
	var t := (x - imin) / span if absf(span) > 1.0e-9 else 0.0
	t = Pasture3DGraphDistance.repeat(repeat, t)
	var v := t
	if gradient != null and gradient.get_point_count() > 0:
		v = reduce(gradient.sample(t), channel)
	v = t + _in(p_inputs, 5, amount) * (v - t)
	if output_mode == OutputMode.HEIGHT:
		var hmin := _in(p_inputs, 3, height_min)
		return hmin + (_in(p_inputs, 4, height_max) - hmin) * v
	return clampf(v, 0.0, 1.0)


func _in(p_inputs: PackedFloat32Array, p_port: int, p_default: float) -> float:
	if p_port == 0:
		return p_inputs[0] if p_inputs.size() > 0 else 0.0
	if p_inputs.size() > p_port and not is_nan(p_inputs[p_port]):
		return p_inputs[p_port]
	return p_default


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if gradient == null or gradient.get_point_count() == 0:
		w.append("%s: no Gradient stops, so the normalised input passes through." % display_name())
	if absf(input_max - input_min) <= 1.0e-9:
		w.append("%s: the input window is empty (min == max), so every value samples offset 0." % display_name())
	if output_mode == OutputMode.HEIGHT and is_equal_approx(height_min, height_max):
		w.append("%s: Height Min equals Height Max, so the output is flat." % display_name())
	return w
