# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeSlope — slope of a heightfield in degrees, a band mask over it, and the compass direction
# the ground faces. PASTURE3D_RANGES_SPEC.md step 2; the maths is C++ only (slope_grid in
# src/pasture_3d_terrain_metrics.cpp), on the same metric gradient Recast Cliff uses.
#
# `degrees` and `aspect` are raw measurements (degrees, compass bearing). `mask` is the band selector itself:
# 1 between Min and Max Angle, easing to 0 over Falloff degrees outside it. `scale` box-means the surface
# first, so the slope reads at the scale of a hillside rather than of one cell.
@tool
class_name Pasture3DGraphNodeSlope
extends Pasture3DGraphNode

## Lower edge of the band, degrees. Also a value port.
@export_range(0.0, 90.0, 0.1) var min_angle: float = 30.0:
	set(v):
		min_angle = clampf(v, 0.0, 90.0)
		_param_changed()
## Upper edge of the band, degrees. Also a value port.
@export_range(0.0, 90.0, 0.1) var max_angle: float = 90.0:
	set(v):
		max_angle = clampf(v, 0.0, 90.0)
		_param_changed()
## Degrees over which the mask eases to 0 outside the band. 0 = a hard edge.
@export_range(0.0, 45.0, 0.1, "or_greater") var falloff: float = 5.0:
	set(v):
		falloff = maxf(v, 0.0)
		_param_changed()
## Smooth the surface over this radius first, metres. 0 = the slope of each cell.
@export_range(0.0, 1000.0, 1.0, "or_greater") var scale: float = 0.0:
	set(v):
		scale = maxf(v, 0.0)
		_param_changed()


func op() -> StringName:
	return &"slope"


## The sixteen-slot block. The order is `slope_grid`'s in src/pasture_3d_terrain_metrics.cpp.
func native_lower() -> Dictionary:
	return {"params": _params()}


func _params() -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = min_angle
	p[1] = max_angle
	p[2] = falloff
	p[3] = scale
	return p


func native_out_count() -> int:
	return 3 # degrees, mask, aspect


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


## Ports 1 and 2 drive slots 0 and 1.
func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"height", PortType.HEIGHT).require(),
		Pasture3DGraphPort.value(&"min_angle", PortType.FLOAT, &"min_angle", 0),
		Pasture3DGraphPort.value(&"max_angle", PortType.FLOAT, &"max_angle", 1),
	]


## Port order is a wire format: APPEND only.
func _outputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"degrees", PortType.FIELD),
		Pasture3DGraphPort.field(&"mask", PortType.MASK),
		Pasture3DGraphPort.field(&"aspect", PortType.FIELD),
	]


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var h: PackedFloat32Array = p_inputs[0] if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array \
			and p_inputs[0].size() == n else Pasture3DGraphOps.zeros(n)
	if not ClassDB.class_has_method("Pasture3DUtil", "slope_grid"):
		push_error("[Pasture3D] Pasture3DUtil.slope_grid is not bound. Rebuild GDExtension.")
		return _fallback(n)
	var prm := _params()
	# Wired value ports arrive as cell 0 of their grid on this route, as the Leveler reads its value port.
	for k in 2:
		if p_inputs.size() > k + 1 and p_inputs[k + 1] is PackedFloat32Array and p_inputs[k + 1].size() > 0:
			prm[k] = float(p_inputs[k + 1][0])
	var res: Dictionary = Pasture3DUtil.slope_grid(h, p_gw, p_gh, p_rect, prm)
	var d: PackedFloat32Array = res.get("degrees", PackedFloat32Array())
	if d.size() != n:
		push_error("[Pasture3D] slope_grid returned %d cells for a %d cell grid." % [d.size(), n])
		return _fallback(n)
	return [d, res["mask"], res["aspect"]]


## Flat, unselected: a failed solve selects nothing.
func _fallback(p_n: int) -> Array:
	return [Pasture3DGraphOps.zeros(p_n), Pasture3DGraphOps.zeros(p_n), Pasture3DGraphOps.zeros(p_n)]
