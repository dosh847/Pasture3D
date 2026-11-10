# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeRidgeSharpen — a FILTER grid node: an unsharp mask that only ever lifts.
#
#     output = input + amount * max(0, input - blur(input, radius))
#
# Ground standing above its surroundings rises by how far it stands above them, so a crest gains height and
# its flanks steepen. Ground below its surroundings is untouched to the bit, which is what separates this
# from a plain unsharp mask: that also digs a trench beside every ridge. Contrast cannot do this job at all,
# because its window pins the highest point and it never reads a neighbour.
#
# The blur is a Gaussian (sigma = radius / 2) truncated at Radius, in metres, one horizontal pass then one
# vertical. NaN cells stay NaN and do not contribute. Pasture3DGraphNodeDevRidgeSharpen is the oracle.
@tool
class_name Pasture3DGraphNodeRidgeSharpen
extends Pasture3DGraphNode

## How wide a feature counts as a ridge, in metres. Use about the width of the ridges you want to sharpen:
## features much wider than this barely stand out from the blur and barely change.
@export_range(0.0, 500.0, 0.5, "or_greater") var radius: float = 30.0:
	set(v):
		radius = maxf(v, 0.0)
		emit_changed()

## Multiplies the lift. 1.0 adds the crest's height above its surroundings once; 0 is the identity.
@export_range(0.0, 8.0, 0.01, "or_greater") var amount: float = 1.0:
	set(v):
		amount = maxf(v, 0.0)
		emit_changed()


func op() -> StringName:
	return &"ridge_sharpen"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = radius
	p[1] = amount
	return {"params": p}


func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"in", PortType.HEIGHT).require(),
		Pasture3DGraphPort.value(&"radius", PortType.FLOAT, &"radius", 0),
		Pasture3DGraphPort.value(&"amount", PortType.FLOAT, &"amount", 1),
	]


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	if not (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n):
		return Pasture3DGraphOps.zeros(n)
	var p: PackedFloat32Array = native_lower()["params"]
	var rad: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else p[0]
	var amt: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else p[1]
	return Pasture3DUtil.ridge_sharpen_grid(p_inputs[0], p_gw, p_gh, p_rect, rad, amt)


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amount):
		w.append("%s: Amount is 0, so it passes the input through unchanged." % display_name())
	elif is_zero_approx(radius):
		w.append("%s: Radius is 0, so there is nothing to compare a cell against and it changes nothing." % display_name())
	return w
