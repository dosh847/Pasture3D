# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevMaskFeather — the GDScript oracle twin for Mask Feather.
#
# It reuses the distance-transform oracle (JFA, like the native kernel) rather than measuring distance its own
# way: a feather is only as trustworthy as the distance it is windowed from. Everything after the distance —
# the half-cell contour shift, the three sides, the falloff, the no-edge early out — is written here again,
# independently, which is the part the parity gate measures.
@tool
class_name Pasture3DGraphNodeDevMaskFeather
extends Pasture3DGraphNode

@export var feather: float = 2.0:
	set(v):
		feather = v
		_param_changed()

## Matches Pasture3DGraphNodeMaskFeather.FeatherSide.
@export var side: int = 0:
	set(v):
		side = v
		_param_changed()

## Matches Pasture3DGraphNodeMaskFeather.EdgeFalloff.
@export var falloff: int = 0:
	set(v):
		falloff = v
		_param_changed()

@export var threshold: float = 0.5:
	set(v):
		threshold = v
		_param_changed()

@export var invert: bool = false:
	set(v):
		invert = v
		_param_changed()


func op() -> StringName:
	return &"dev_mask_feather"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


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
	if p_inputs.is_empty() or not (p_inputs[0] is PackedFloat32Array) or p_inputs[0].size() != n:
		return Pasture3DGraphOps.zeros(n)
	var f := feather
	if p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0:
		f = float(p_inputs[1][0])
	return solve(p_inputs[0], p_gw, p_gh, p_rect, f)


func _finish(p_m: float) -> float:
	var t := clampf(p_m, 0.0, 1.0)
	var v := t * t * (3.0 - 2.0 * t) if falloff == 1 else t
	return 1.0 - v if invert else v


func solve(p_mask: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_feather: float) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var out := PackedFloat32Array()
	out.resize(n)
	var fe := maxf(p_feather, 0.0)
	var sd_side := clampi(side, 0, 2)
	# The threshold as float32, as the kernel compares it.
	var thr := PackedFloat32Array([threshold])[0]

	var any_in := false
	var any_out := false
	for i in n:
		var v := p_mask[i]
		if not is_finite(v):
			continue
		if v > thr:
			any_in = true
		else:
			any_out = true

	if not any_in or not any_out:
		var c := _finish(1.0 if any_in else 0.0)
		for i in n:
			out[i] = c if is_finite(p_mask[i]) else p_mask[i]
		return out

	var dt := Pasture3DGraphNodeDevDistanceTransform.new()
	dt.threshold = thr
	dt.direction = Pasture3DGraphNodeDistanceTransform.Direction.SIGNED
	dt.metric = Pasture3DGraphNodeDistanceTransform.Metric.EUCLIDEAN
	dt.output_units = Pasture3DGraphNodeDistanceTransform.OutputUnits.METRES
	dt.max_distance = 0.0
	var sd: PackedFloat32Array = dt.solve(p_mask, p_gw, p_gh, p_rect)
	if sd.size() != n:
		return Pasture3DGraphOps.zeros(n)

	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	var half := 0.5 * minf(dx, dz)
	for i in n:
		var v := p_mask[i]
		if not is_finite(v):
			out[i] = v
			continue
		var inside := v > thr
		# Signed distance from the contour, half a cell back from the transform's centre-to-centre distance.
		var e := minf(sd[i] + half, 0.0) if inside else maxf(sd[i] - half, 0.0)
		var m := 0.0
		match sd_side:
			1: # INWARD
				m = ((1.0 if fe <= 0.0 else -e / fe) if inside else 0.0)
			2: # CENTRED
				m = ((1.0 if inside else 0.0) if fe <= 0.0 else 0.5 - e / fe)
			_: # OUTWARD
				m = (1.0 if inside else (0.0 if fe <= 0.0 else 1.0 - e / fe))
		out[i] = _finish(m)
	return out
