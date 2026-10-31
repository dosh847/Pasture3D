# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevRecastCanyon — the GDScript oracle twin for Recast Canyon. The formula is written out
# again from src/pasture_3d_recast_canyon.h rather than shared, so a slip in either one shows as a parity gap.
@tool
class_name Pasture3DGraphNodeDevRecastCanyon
extends Pasture3DGraphNode

@export var cut_height: float = 100.0:
	set(v):
		cut_height = v
		_param_changed()

@export var floor_height: float = 0.0:
	set(v):
		floor_height = v
		_param_changed()

@export var gamma: float = 0.5:
	set(v):
		gamma = v
		_param_changed()

@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = v
		_param_changed()


func op() -> StringName:
	return &"dev_recast_canyon"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 3


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "noise", "mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.SIGNED, PortType.MASK])


func input_unwired_default(p_port: int) -> float:
	return 1.0 if p_port == 2 else 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	if p_inputs.is_empty() or not (p_inputs[0] is PackedFloat32Array) or p_inputs[0].size() != n:
		return Pasture3DGraphOps.zeros(n)
	var f := func(p: int) -> PackedFloat32Array:
		return p_inputs[p] if (p_inputs.size() > p and p_inputs[p] is PackedFloat32Array and p_inputs[p].size() == n) else PackedFloat32Array()
	return solve(p_inputs[0], f.call(1), f.call(2))


func solve(p_in: PackedFloat32Array, p_noise: PackedFloat32Array, p_mask: PackedFloat32Array) -> PackedFloat32Array:
	var n := p_in.size()
	if amount <= 0.0 or gamma <= 0.0:
		return p_in.duplicate()
	var amt := minf(amount, 1.0)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var z := p_in[i]
		if is_nan(z) or is_inf(z):
			out[i] = z
			continue
		var cut := cut_height
		if p_noise.size() == n and not (is_nan(p_noise[i]) or is_inf(p_noise[i])):
			cut += p_noise[i]
		var span := cut - floor_height
		if span <= 1.0e-6 or z >= cut or z <= floor_height:
			out[i] = z
			continue
		var w := amt
		if p_mask.size() == n:
			var m := p_mask[i]
			w *= clampf(m, 0.0, 1.0) if not (is_nan(m) or is_inf(m)) else 0.0
		if w <= 0.0:
			out[i] = z
			continue
		var t := (z - floor_height) / span
		var recast := floor_height + span * pow(t, gamma)
		out[i] = z + (recast - z) * w
	return out
