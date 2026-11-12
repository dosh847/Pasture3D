# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeMaskFeather — Path Mask's soft edge, for any MASK.
#
# Path Mask feathers by DISTANCE: a flat 1 inside the shape, falling linearly to 0 over Feather metres
# beyond its edge. This node gives the same edge to a mask that came from anywhere else — Float to Mask,
# Slope's band, a Salève or Water mask, a painted layer. It thresholds the mask, takes the signed distance
# transform (the shared JFA kernel, metres from the rect) and windows the distance from the contour.
#
# Not a blur. A blur drops a thin mask's peak below 1 and rounds its corners inward; a distance feather keeps
# the shape at full strength and only adds the ramp. For a blur, Float to Mask's Blur or Smooth remain.
#
# The maths is C++ (Pasture3DUtil.mask_feather_grid, native op 79, src/pasture_3d_mask_feather.cpp); the
# [Dev/GD] Mask Feather is its GDScript oracle.
@tool
class_name Pasture3DGraphNodeMaskFeather
extends Pasture3DGraphNode

## Values are serialised — append, never reorder. Sync with MaskFeatherSide in pasture_3d_mask_feather.h.
enum FeatherSide { OUTWARD = 0, INWARD = 1, CENTRED = 2 }
## Sync with MaskFeatherFalloff.
enum EdgeFalloff { LINEAR = 0, SMOOTH = 1 }

## Metres over which the edge ramps between 1 and 0. 0 is a hard edge. Also a value port.
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m") var feather: float = 2.0:
	set(v):
		feather = maxf(v, 0.0)
		_param_changed()

## Where the ramp sits. OUTWARD (Path Mask's rule): 1 inside, fading to 0 Feather metres beyond the edge,
## so the mask grows. INWARD: 0 outside, reaching 1 Feather metres inside, so the mask never spreads past
## its edge. CENTRED: 0.5 on the edge, the ramp straddling it.
@export var side: FeatherSide = FeatherSide.OUTWARD:
	set(v):
		side = v
		_param_changed()

## LINEAR matches Path Mask. SMOOTH eases both ends of the ramp.
@export var falloff: EdgeFalloff = EdgeFalloff.LINEAR:
	set(v):
		falloff = v
		_param_changed()

## Input values above this are inside the shape. 0.5 finds the middle of a soft mask's edge.
@export_range(0.0, 1.0, 0.01) var threshold: float = 0.5:
	set(v):
		threshold = v
		_param_changed()

## 1 - result: the feathered mask of everywhere the shape is NOT.
@export var invert: bool = false:
	set(v):
		invert = v
		_param_changed()


func op() -> StringName:
	return &"mask_feather"


## The sixteen-slot block. The order is mask_feather_params_from's in src/pasture_3d_mask_feather.cpp.
func native_lower() -> Dictionary:
	return {"params": _params()}


func _params() -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = feather
	p[1] = float(side)
	p[2] = float(falloff)
	p[3] = threshold
	p[4] = 1.0 if invert else 0.0
	return p


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


## Port 1 drives slot 0 (feather).
func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"in", PortType.MASK).require(),
		Pasture3DGraphPort.value(&"feather", PortType.FLOAT, &"feather", 0),
	]


func _outputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"out", PortType.MASK),
	]


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var m: PackedFloat32Array = p_inputs[0] if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array \
			and p_inputs[0].size() == n else Pasture3DGraphOps.zeros(n)
	if not ClassDB.class_has_method("Pasture3DUtil", "mask_feather_grid"):
		push_error("[Pasture3D] Pasture3DUtil.mask_feather_grid is not bound. Rebuild GDExtension.")
		return Pasture3DGraphOps.zeros(n)
	var prm := _params()
	# A wired value port arrives as cell 0 of its grid on this route.
	if p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0:
		prm[0] = float(p_inputs[1][0])
	var res: PackedFloat32Array = Pasture3DUtil.mask_feather_grid(m, p_gw, p_gh, p_rect, prm)
	if res.size() != n:
		push_error("[Pasture3D] mask_feather_grid returned %d cells for a %d cell grid." % [res.size(), n])
		return Pasture3DGraphOps.zeros(n)
	return res


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(feather):
		w.append("%s: Feather is 0, so the edge is hard — the input thresholded at %.2f." % [display_name(), threshold])
	return w
