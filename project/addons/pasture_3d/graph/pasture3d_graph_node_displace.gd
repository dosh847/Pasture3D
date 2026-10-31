# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDisplace — a FILTER grid node: read the incoming surface at a point moved by two offset
# fields, so an existing landform bends sideways.
#
# The gap it fills: Warp distorts only its OWN noise sample and adds the result to its input, so it cannot
# move a hill — the input is read at the cell it already sits in. This is Hesiod's Warp (input, dx, dy),
# World Machine's Displacement and Houdini's HeightField Distort. Wire two noise fields into `dx` and `dy`
# to push a smooth hill's contours into lobes and spurs before an erosion pass cuts its valleys.
#
# dx and dy are read as METRES on world X and Z, times `scale`. A Noise node with an amplitude of 40 wired
# straight in moves the surface up to 40 m. The kernel is src/pasture_3d_displace.cpp.
@tool
class_name Pasture3DGraphNodeDisplace
extends Pasture3DGraphNode

## Multiplies both offset fields. 1 reads them as metres; use it to turn the whole distortion up or down
## without touching the noise that drives it. Negative reverses the push.
@export_range(-10.0, 10.0, 0.01, "or_less", "or_greater") var scale: float = 1.0:
	set(v):
		scale = v
		emit_changed()

## How much of the displacement is applied, 0..1 (times the mask, if wired).
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()


func op() -> StringName:
	return &"displace"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = scale
	p[1] = amount
	return {"params": p}


## Ports 0..3 are fields and ride in0..in3; `amount` is port 4 and travels in the driven-scalar table.
func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1, -1, -1, -1, 1])


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 5


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "dx", "dy", "mask", "amount"])


func aux_grid_port() -> int:
	return 3 # "mask"


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.SIGNED, PortType.SIGNED, PortType.MASK, PortType.FLOAT])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		3: return 1.0
		4: return amount
		_: return 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		return Pasture3DGraphOps.zeros(n)
	var dx_g := _field(p_inputs, 1, n)
	var dy_g := _field(p_inputs, 2, n)
	var mask := _field(p_inputs, 3, n)
	var amt: float = float(p_inputs[4][0]) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array and p_inputs[4].size() > 0) else amount

	if not ClassDB.class_has_method("Pasture3DUtil", "displace_grid"):
		push_error("[Pasture3D] Pasture3DUtil.displace_grid is not bound. Rebuild GDExtension.")
		return in_grid.duplicate()

	var res: PackedFloat32Array = Pasture3DUtil.displace_grid(in_grid, dx_g, dy_g, mask, p_gw, p_gh, p_rect,
			scale, amt)
	if res.size() != n:
		push_error("[Pasture3D] Displace returned an invalid grid size.")
		return in_grid.duplicate()
	return res


func _field(p_inputs: Array, p_port: int, p_n: int) -> PackedFloat32Array:
	if p_inputs.size() > p_port and p_inputs[p_port] is PackedFloat32Array \
			and (p_inputs[p_port] as PackedFloat32Array).size() == p_n:
		return p_inputs[p_port]
	return PackedFloat32Array()


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amount) or is_zero_approx(scale):
		w.append("%s: Amount or Scale is 0, so it passes the input through unchanged." % display_name())
	return w
