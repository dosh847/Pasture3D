# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeFloatToMask — a FILTER grid node: a field in its own units (metres of erosion, of
# deposition, of height) to a 0..1 MASK.
#
# ---- WHY IT EXISTS ----
#
# Solvers publish what they measured, in metres. Turning that into a mask is a CHOICE — which depth reads as
# "fully eroded" — and it used to be made inside the solver, hidden, as a fraction of the relief. That
# saturated most of a mountain and meant a pin's meaning changed with the footprint. Now the solver outputs
# metres and this node makes the choice where it can be seen.
#
# ---- RANGE ----
#
# FIXED (the default): the window is metres you type. The same metres give the same mask on every bake.
# AUTO: the window is the field's own low/high percentile. It adapts, but a rect bake over a different
# extent measures a different field, so the mask can shift between bakes with nothing edited. Use it for
# exploring; pin FIXED for anything painted.
#
# Post-processing runs in order: invert, gamma, smoothstep, blur. The kernel is C++
# (Pasture3DUtil.float_to_mask_grid, native op 66); the [Dev/GD] Float to Mask is its GDScript oracle.
@tool
class_name Pasture3DGraphNodeFloatToMask
extends Pasture3DGraphNode

## Values are serialised — append, never reorder.
enum RangeMode { FIXED, AUTO }

@export_group("Range")
## FIXED: the window below, in the input's units. AUTO: the input's own percentiles, re-measured per bake.
@export var range_mode: RangeMode = RangeMode.FIXED:
	set(v):
		range_mode = v
		notify_property_list_changed()
		emit_changed()

## Input value that maps to 0 (FIXED).
@export var in_min: float = 0.0:
	set(v):
		in_min = v
		emit_changed()

## Input value that maps to 1 (FIXED).
@export var in_max: float = 5.0:
	set(v):
		in_max = v
		emit_changed()

## Percentile that maps to 0 (AUTO). Clipping a few percent keeps outliers from flattening the rest.
@export_range(0.0, 100.0, 0.1, "suffix:%") var low_percentile: float = 2.0:
	set(v):
		low_percentile = clampf(v, 0.0, 100.0)
		emit_changed()

## Percentile that maps to 1 (AUTO).
@export_range(0.0, 100.0, 0.1, "suffix:%") var high_percentile: float = 98.0:
	set(v):
		high_percentile = clampf(v, 0.0, 100.0)
		emit_changed()

@export_group("Post-Processing")
## 1 - mask.
@export var invert: bool = false:
	set(v):
		invert = v
		emit_changed()

## pow(mask, gamma). Above 1 tightens the mask onto the strongest values; below 1 widens it.
@export_range(0.05, 8.0, 0.01, "or_greater") var gamma: float = 1.0:
	set(v):
		gamma = maxf(v, 0.01)
		emit_changed()

## Smoothstep the mask, softening both ends.
@export var smooth_edges: bool = false:
	set(v):
		smooth_edges = v
		emit_changed()

## Blur passes (the Smooth node's kernel) applied last.
@export_range(0, 32, 1, "or_greater") var blur_passes: int = 0:
	set(v):
		blur_passes = maxi(v, 0)
		emit_changed()


func _validate_property(p_property: Dictionary) -> void:
	var fixed_only := ["in_min", "in_max"]
	var auto_only := ["low_percentile", "high_percentile"]
	if (range_mode == RangeMode.AUTO and p_property.name in fixed_only) \
			or (range_mode == RangeMode.FIXED and p_property.name in auto_only):
		p_property.usage &= ~PROPERTY_USAGE_EDITOR


func op() -> StringName:
	return &"float_to_mask"


func role() -> Role:
	return Role.FILTER


## AUTO measures the whole field, and blur reads neighbours.
func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["in"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.FIELD])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.MASK])


## The kernel's parameter block, in float_to_mask_grid's order.
func mask_params() -> PackedFloat32Array:
	return PackedFloat32Array([float(range_mode), in_min, in_max, low_percentile, high_percentile,
			1.0 if invert else 0.0, gamma, 1.0 if smooth_edges else 0.0, float(blur_passes)])


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	var m := mask_params()
	for i in m.size():
		p[i] = m[i]
	return {"params": p}


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var h: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and p_inputs[0].size() == n) else Pasture3DGraphOps.zeros(n)
	return Pasture3DUtil.float_to_mask_grid(h, p_gw, p_gh, mask_params())


func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return 0.0 # needs_grid(): never evaluated per cell


## The window this bake uses, [lo, hi], by the kernel's rule. GDScript so the oracle and the gate can read it.
func resolve_window(p_in: PackedFloat32Array) -> Vector2:
	if range_mode == RangeMode.FIXED:
		return Vector2(in_min, in_max)
	var fin: Array[float] = []
	for v in p_in:
		if is_finite(v):
			fin.append(v)
	if fin.is_empty():
		return Vector2.ZERO
	fin.sort()
	var m := fin.size()
	return Vector2(fin[_rank(low_percentile, m)], fin[_rank(high_percentile, m)])


static func _rank(p_pct: float, p_m: int) -> int:
	return clampi(int(floor(clampf(p_pct, 0.0, 100.0) / 100.0 * float(p_m - 1) + 0.5)), 0, p_m - 1)


## The kernel in GDScript: the body [Dev/GD] Float to Mask runs.
func _eval_gd(p_in: PackedFloat32Array, p_gw: int, p_gh: int) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var win := resolve_window(p_in)
	var span: float = win.y - win.x
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var x: float = p_in[i] if i < p_in.size() else NAN
		var t := 0.0
		if is_finite(x):
			t = (x - win.x) / span if span > 1.0e-12 else (1.0 if x >= win.y else 0.0)
			t = clampf(t, 0.0, 1.0)
		if invert:
			t = 1.0 - t
		if gamma != 1.0:
			t = pow(t, gamma)
		if smooth_edges:
			t = t * t * (3.0 - 2.0 * t)
		out[i] = t
	return Pasture3DGraphOps.blur_nan(out, p_gw, p_gh, blur_passes)
