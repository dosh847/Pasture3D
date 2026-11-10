# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeCurve — a FILTER cell node: remap the INPUT field through a transfer Curve. One input,
# one output; it reshapes what is wired into it and generates nothing. Use it to flatten valleys, exaggerate
# peaks, clip a side, or apply any custom height response.
#
# METRIC domain and range (matching the Terrace node's height-domain model): the input window
# [input_min, input_max] metres maps onto the curve's X in [0, 1], the curve's Y in [0, 1] maps back onto
# [output_min, output_max] metres, and `amount` cross-fades input against the remap. Values outside the
# input window clamp to the window edges.
#
# Output Range SAME_AS_INPUT maps curve Y back onto the input window itself, so the curve reshapes the
# distribution of heights and keeps their scale. It follows the RESOLVED window: a wired in_min/in_max
# (a Measure's min/max, say) moves the output with it.
@tool
class_name Pasture3DGraphNodeCurve
extends Pasture3DGraphNode

## Values are serialised. Append only.
enum OutputRange { CUSTOM, SAME_AS_INPUT }

## The transfer function. X and Y are both read over [0, 1]. Unassigned = a pass-through (and a warning).
@export var curve: Curve:
	set(v):
		if curve != null and curve.changed.is_connected(emit_changed):
			curve.changed.disconnect(emit_changed)
		curve = v
		if curve != null and not curve.changed.is_connected(emit_changed):
			curve.changed.connect(emit_changed)
		emit_changed()

@export_group("Input window (metres → curve X)")
## Input height mapped to the curve's left edge (X = 0).
@export var input_min: float = 0.0:
	set(v):
		input_min = v
		emit_changed()

var in_min: float:
	get: return input_min
	set(v): input_min = v

## Input height mapped to the curve's right edge (X = 1).
@export var input_max: float = 100.0:
	set(v):
		input_max = v
		emit_changed()

var in_max: float:
	get: return input_max
	set(v): input_max = v

@export_group("Output range (curve Y → metres)")
## CUSTOM: curve Y spans Output Min..Max below. SAME_AS_INPUT: it spans the input window, so the scale is
## kept and only the distribution inside it changes. The out_min/out_max ports are ignored then.
@export var output_range: OutputRange = OutputRange.CUSTOM:
	set(v):
		output_range = v
		notify_property_list_changed()
		emit_changed()

## Height the curve's Y = 0 maps to.
@export var output_min: float = 0.0:
	set(v):
		output_min = v
		emit_changed()

var out_min: float:
	get: return output_min
	set(v): output_min = v

## Height the curve's Y = 1 maps to.
@export var output_max: float = 100.0:
	set(v):
		output_max = v
		emit_changed()

var out_max: float:
	get: return output_max
	set(v): output_max = v

## Cross-fade between the input (0) and the remapped field (1).
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()

## Fits the input window to the upstream field's min/max. Measured by the graph editor, which is the only
## thing that can evaluate this node's upstream; with no graph editor open it does nothing.
@export_tool_button("Auto Fit Range") var _auto_btn = _request_auto_fit


func _request_auto_fit() -> void:
	editor_action_requested.emit(&"auto_fit")


func auto_fit_range(p_min: float = 0.0, p_max: float = 100.0) -> void:
	input_min = p_min
	input_max = p_max
	emit_changed()


func _validate_property(p_property: Dictionary) -> void:
	if output_range == OutputRange.SAME_AS_INPUT and p_property.name in ["output_min", "output_max"]:
		p_property.usage &= ~PROPERTY_USAGE_EDITOR


func op() -> StringName:
	return &"curve"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	var lut := PackedFloat32Array()
	# Every name here was wrong: the node's are input_min/input_max/output_min/output_max/amount.
	# `clamp_output` does not exist at all, and `bool(null)` THREW — so compiling any graph
	# containing a Curve node raised "Nonexistent 'bool' constructor" rather than merely
	# producing a wrong surface. The fifth argument of curve_grid() is the blend amount.
	p[0] = input_min
	p[1] = input_max
	p[2] = output_min
	p[3] = output_max
	p[4] = amount
	p[5] = 1.0 if output_range == OutputRange.SAME_AS_INPUT else 0.0
	var c: Curve = curve
	if c != null:
		lut.resize(256)
		for li in range(256):
			lut[li] = c.sample_baked(float(li) / 255.0)
	return {"params": p, "lut": lut}


func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"in", PortType.HEIGHT).require(),
		Pasture3DGraphPort.value(&"in_min", PortType.FLOAT, &"input_min", 0),
		Pasture3DGraphPort.value(&"in_max", PortType.FLOAT, &"input_max", 1),
		Pasture3DGraphPort.value(&"out_min", PortType.FLOAT, &"output_min", 2),
		Pasture3DGraphPort.value(&"out_max", PortType.FLOAT, &"output_max", 3),
		Pasture3DGraphPort.value(&"amount", PortType.FLOAT, &"amount", 4),
	]


func role() -> Role:
	return Role.FILTER


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> PackedFloat32Array:
	var s: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(p_gw * p_gh)
	var imin: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else input_min
	var imax: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else input_max
	var omin: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else output_min
	var omax: float = float(p_inputs[4][0]) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array and p_inputs[4].size() > 0) else output_max
	var amt: float = float(p_inputs[5][0]) if (p_inputs.size() > 5 and p_inputs[5] is PackedFloat32Array and p_inputs[5].size() > 0) else amount
	if output_range == OutputRange.SAME_AS_INPUT:
		omin = imin
		omax = imax

	if curve == null:
		return s
	var lut_floats := PackedFloat32Array()
	lut_floats.resize(256)
	for i in range(256):
		lut_floats[i] = curve.sample_baked(float(i) / 255.0)
	return Pasture3DUtil.curve_grid(s, lut_floats, imin, imax, omin, omax, amt)


func eval_cell(_p_wx: float, _p_wz: float, p_inputs: PackedFloat32Array) -> float:
	# NaN passes through, as curve_grid does: a NaN is outside the footprint, not a height of 0. This used to
	# map it to 0 here, so the is_nan() check below could never fire and the script route painted curve(0)
	# where the native route left the footprint's hole.
	var x: float = p_inputs[0] if p_inputs.size() > 0 else 0.0
	var imin: float = p_inputs[1] if (p_inputs.size() > 1 and not is_nan(p_inputs[1])) else input_min
	var imax: float = p_inputs[2] if (p_inputs.size() > 2 and not is_nan(p_inputs[2])) else input_max
	var omin: float = p_inputs[3] if (p_inputs.size() > 3 and not is_nan(p_inputs[3])) else output_min
	var omax: float = p_inputs[4] if (p_inputs.size() > 4 and not is_nan(p_inputs[4])) else output_max
	var amt: float = p_inputs[5] if (p_inputs.size() > 5 and not is_nan(p_inputs[5])) else amount
	if output_range == OutputRange.SAME_AS_INPUT:
		omin = imin
		omax = imax

	if curve == null or is_nan(x):
		return x
	var span := imax - imin
	var tx := clampf((x - imin) / span, 0.0, 1.0) if absf(span) > 1.0e-9 else 0.0
	var y := curve.sample_baked(tx)
	var remapped := lerpf(omin, omax, y)
	return lerpf(x, remapped, amt)


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if curve == null:
		w.append("%s: no Curve assigned, so it passes the input through unchanged." % display_name())
	elif is_zero_approx(amount):
		w.append("%s: Amount is 0, so it passes the input through unchanged." % display_name())
	elif absf(input_max - input_min) <= 1.0e-9:
		w.append("%s: the input window is empty (min == max) — every value maps to curve X = 0." % display_name())
	return w
