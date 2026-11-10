# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeRecastCanyon — a FILTER node: reshape the ground between a floor and a cut height with
# a power curve, so valley walls steepen at the bottom or at the rim.
#
# After Hesiod/HighMap's Recast Canyon, which writes z < vcut as vcut * (z / vcut)^gamma on a [0,1] map.
# Here the curve runs between `floor_height` and `cut_height` in world metres, because sea level is not the
# bottom of anything (src/pasture_3d_recast_canyon.h has the formula). Ground outside that band passes
# through, and the curve meets both ends, so there is no step.
#
#   gamma > 1   flat floors under steep rims — the canyon/mesa profile.
#   gamma < 1   walls steepest AT THE FLOOR — the inner gorge of a valley cutting down faster than its
#               sides can follow.
#
# Wire a valley mask (Curvature, or an erosion node's flow through Float to Mask) into `mask` to confine it
# to the valleys, and a noise into `noise` so the rim is not a contour line.
@tool
class_name Pasture3DGraphNodeRecastCanyon
extends Pasture3DGraphNode

## The top of the band, in WORLD METRES. Ground at or above it is untouched.
@export_range(-500.0, 2000.0, 0.5, "or_less", "or_greater", "suffix:m") var cut_height: float = 100.0:
	set(v):
		cut_height = v
		emit_changed()

## The bottom of the band, in WORLD METRES. Ground at or below it is untouched. Set it to the valley floor
## you want the curve to end at.
@export_range(-500.0, 2000.0, 0.5, "or_less", "or_greater", "suffix:m") var floor_height: float = 0.0:
	set(v):
		floor_height = v
		emit_changed()

## The curve's power. Above 1 flattens the floor under a steep rim; below 1 makes the walls steepest at the
## floor. 1 is a pass-through.
@export_range(0.05, 8.0, 0.01, "or_greater") var gamma: float = 0.5:
	set(v):
		gamma = maxf(v, 0.01)
		emit_changed()

## How much of the recast is applied, 0..1.
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()


func op() -> StringName:
	return &"recast_canyon"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = cut_height
	p[1] = floor_height
	p[2] = gamma
	p[3] = amount
	return {"params": p}


## Ports 0 and 1 are fields (in0, in1); `gamma` and `amount` are driven scalars.
func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"in", PortType.HEIGHT).require(),
		Pasture3DGraphPort.field(&"noise", PortType.SIGNED),
		Pasture3DGraphPort.value(&"gamma", PortType.FLOAT, &"gamma", 2),
		Pasture3DGraphPort.value(&"amount", PortType.FLOAT, &"amount", 3),
	]


func role() -> Role:
	return Role.FILTER


## Pointwise, but its optional noise is a field, which the cell fold cannot carry as "unwired".
func needs_grid() -> bool:
	return true


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		return Pasture3DGraphOps.zeros(n)
	var noise := _field(p_inputs, 1, n)
	var gam: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else gamma
	var amt: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else amount

	if not ClassDB.class_has_method("Pasture3DUtil", "recast_canyon_grid"):
		push_error("[Pasture3D] Pasture3DUtil.recast_canyon_grid is not bound. Rebuild GDExtension.")
		return in_grid.duplicate()

	var res: PackedFloat32Array = Pasture3DUtil.recast_canyon_grid(in_grid, noise, p_gw, p_gh,
			cut_height, floor_height, gam, amt)
	if res.size() != n:
		push_error("[Pasture3D] Recast Canyon returned an invalid grid size.")
		return in_grid.duplicate()
	return res


func _field(p_inputs: Array, p_port: int, p_n: int) -> PackedFloat32Array:
	if p_inputs.size() > p_port and p_inputs[p_port] is PackedFloat32Array \
			and (p_inputs[p_port] as PackedFloat32Array).size() == p_n:
		return p_inputs[p_port]
	return PackedFloat32Array()


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if cut_height <= floor_height:
		w.append("%s: Cut Height is not above Floor Height, so the band is empty and nothing changes." % display_name())
	if is_equal_approx(gamma, 1.0):
		w.append("%s: Gamma is 1, so the curve is a straight line and nothing changes." % display_name())
	if is_zero_approx(amount):
		w.append("%s: Amount is 0, so it passes the input through unchanged." % display_name())
	return w
