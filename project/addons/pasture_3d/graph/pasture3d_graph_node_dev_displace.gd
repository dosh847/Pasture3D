# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevDisplace — the GDScript oracle twin for Displace.
#
# Deliberately slow and literal. The sampler is Warp Downslope's oracle sampler, which is the rule of
# transform_sample_bilinear: bilinear, CLAMP edges, NaN taps dropped.
@tool
class_name Pasture3DGraphNodeDevDisplace
extends Pasture3DGraphNode

@export var scale: float = 1.0:
	set(v):
		scale = v
		_param_changed()

@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = v
		_param_changed()


func op() -> StringName:
	return &"dev_displace"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "dx", "dy", "mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.SIGNED, PortType.SIGNED, PortType.MASK])


func input_unwired_default(p_port: int) -> float:
	return 1.0 if p_port == 3 else 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	if p_inputs.is_empty() or not (p_inputs[0] is PackedFloat32Array) or p_inputs[0].size() != n:
		return Pasture3DGraphOps.zeros(n)
	var f := func(p: int) -> PackedFloat32Array:
		return p_inputs[p] if (p_inputs.size() > p and p_inputs[p] is PackedFloat32Array and p_inputs[p].size() == n) else PackedFloat32Array()
	return solve(p_inputs[0], f.call(1), f.call(2), f.call(3), p_gw, p_gh, p_rect)


func solve(p_in: PackedFloat32Array, p_dx: PackedFloat32Array, p_dy: PackedFloat32Array,
		p_mask: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var have_dx := p_dx.size() == n
	var have_dy := p_dy.size() == n
	var amt := minf(amount, 1.0)
	if amt <= 0.0 or scale == 0.0 or (not have_dx and not have_dy):
		return p_in.duplicate()
	var cdx := p_rect.size.x / float(p_gw)
	var cdz := p_rect.size.y / float(p_gh)
	var sampler := Pasture3DGraphNodeDevWarpDownslope.new()
	var out := PackedFloat32Array()
	out.resize(n)
	for iz in p_gh:
		for ix in p_gw:
			var i := iz * p_gw + ix
			var z := p_in[i]
			if is_nan(z) or is_inf(z):
				out[i] = z
				continue
			var w := amt
			if p_mask.size() == n:
				var m := p_mask[i]
				w *= clampf(m, 0.0, 1.0) if not (is_nan(m) or is_inf(m)) else 0.0
			var ux := p_dx[i] if have_dx else 0.0
			var uz := p_dy[i] if have_dy else 0.0
			if w <= 0.0 or is_nan(ux) or is_nan(uz) or is_inf(ux) or is_inf(uz):
				out[i] = z
				continue
			out[i] = sampler._sample(p_in, float(ix) + ux * scale * w / cdx, float(iz) + uz * scale * w / cdz,
					p_gw, p_gh)
	return out
