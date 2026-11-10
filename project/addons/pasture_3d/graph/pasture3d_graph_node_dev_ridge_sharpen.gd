# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevRidgeSharpen — the GDScript oracle twin of RidgeSharpen. The definition written out
# longhand, so the threaded native kernel has something slow and obvious to agree with. Keep it slow.
@tool
class_name Pasture3DGraphNodeDevRidgeSharpen
extends Pasture3DGraphNode

## Metres.
@export var radius: float = 30.0:
	set(v):
		radius = v
		emit_changed()

@export var amount: float = 1.0:
	set(v):
		amount = v
		emit_changed()


func op() -> StringName:
	return &"dev_ridge_sharpen"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func blocks_native() -> bool:
	return true


func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"in", PortType.HEIGHT).require(),
		Pasture3DGraphPort.value(&"radius", PortType.FLOAT, &"radius"),
		Pasture3DGraphPort.value(&"amount", PortType.FLOAT, &"amount"),
	]


func _weights(p_spacing: float, p_radius: float) -> PackedFloat64Array:
	var w := PackedFloat64Array()
	if p_spacing <= 0.0 or p_radius <= 0.0:
		w.append(1.0)
		return w
	var sigma := p_radius * 0.5
	for k in range(int(floor(p_radius / p_spacing)) + 1):
		var d := k * p_spacing / sigma
		w.append(exp(-0.5 * d * d))
	return w


func _pass(p_src: PackedFloat64Array, p_w: PackedFloat64Array, p_gw: int, p_gh: int, p_horizontal: bool) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(p_src.size())
	var r := p_w.size() - 1
	for iz in range(p_gh):
		for ix in range(p_gw):
			var sum := 0.0
			var weight := 0.0
			for k in range(-r, r + 1):
				var x := ix + k if p_horizontal else ix
				var z := iz if p_horizontal else iz + k
				if x < 0 or x >= p_gw or z < 0 or z >= p_gh:
					continue
				var v := p_src[z * p_gw + x]
				if is_nan(v):
					continue
				sum += p_w[absi(k)] * v
				weight += p_w[absi(k)]
			out[iz * p_gw + ix] = sum / weight if weight > 0.0 else NAN
	return out


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	if not (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n):
		return Pasture3DGraphOps.zeros(n)
	var src: PackedFloat32Array = p_inputs[0]
	var rad: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else radius
	var amt: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else amount
	var wide := PackedFloat64Array()
	wide.resize(n)
	for i in range(n):
		wide[i] = src[i]
	var blur := _pass(wide, _weights(p_rect.size.x / p_gw, rad), p_gw, p_gh, true)
	blur = _pass(blur, _weights(p_rect.size.y / p_gh, rad), p_gw, p_gh, false)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		out[i] = src[i]
		if is_nan(src[i]) or is_nan(blur[i]):
			continue
		var lift: float = float(src[i]) - blur[i]
		if lift <= 0.0:
			continue
		out[i] = float(src[i]) + amt * lift
	return out
