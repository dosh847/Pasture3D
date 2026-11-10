# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeSmoothFill — a FILTER grid node: raise concave ground toward a blurred reference,
# leaving convex ridges alone.
#
# Raw fBm reads as noise rather than terrain because its valleys are exactly as sharp as its ridges. Real
# ground is asymmetric: material collects in the low places. This is the cheap, non-simulated way to get
# that asymmetry, and it composes with the erosion solvers instead of competing with them — run it before
# erosion to give the water somewhere to work, or after to settle the result.
#
# The asymmetry is the entire point. A node that moved ridges as much as valleys would be a blur.
@tool
class_name Pasture3DGraphNodeSmoothFill
extends Pasture3DGraphNode

enum Mode {
	FILL_VALLEYS, ## Raise all concave ground toward the blurred reference.
	FILL_HOLES, ## Only fill pits — ground concave along BOTH axes. Leaves valleys running.
	SMEAR_PEAKS, ## The mirror: pull convex ground down. Rounds off summits.
}

@export var mode: Mode = Mode.FILL_VALLEYS:
	set(v):
		mode = v
		emit_changed()

## The scale of the reference blur, in WORLD METRES. Sets how large a hollow counts as "low ground".
@export_range(1.0, 1000.0, 1.0, "or_greater") var radius: float = 50.0:
	set(v):
		radius = maxf(v, 0.0)
		emit_changed()

## Softness of the fill, in metres. As this approaches 0 the fill becomes a hard max against the blurred
## reference, which leaves a visible crease where the two surfaces meet. Raise it to round that crease.
@export_range(0.0, 50.0, 0.01, "or_greater") var k: float = 0.1:
	set(v):
		k = maxf(v, 0.0)
		emit_changed()

@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()

## The divisor the last bake used to normalise the deposition channel. Read-only, and part of the
## interface: the channel is a 0..1 field and means nothing without the metres it was divided by.
var last_deposition_divisor: float = 1.0


func op() -> StringName:
	return &"smooth_fill"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = float(mode)
	p[1] = radius
	p[2] = k
	p[3] = amount
	return {"params": p}


## The mask scales what the node does, cell by cell, inside the kernel; it is not a blend of the finished
## result over the input (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §9.3.1).
func mask_mode() -> MaskMode:
	return MaskMode.OWN


func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"in", PortType.HEIGHT).require(),
		Pasture3DGraphPort.value(&"radius", PortType.FLOAT, &"radius", 1),
		Pasture3DGraphPort.value(&"k", PortType.FLOAT, &"k", 2),
	]


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func _outputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"height", PortType.HEIGHT),
		Pasture3DGraphPort.field(&"deposition", PortType.MASK),
	]


## The channels the NATIVE op writes, which is now every channel this node offers.
##
## It used to answer 1, and the compiler then refused to lower any graph that read a channel above 0 --
## correctly, since serving zeros for a field nobody computed is the impostor of spec section 4.4. But the
## refusal is graph-wide: reading `deposition` off this node dropped the whole graph, erosion and all, onto
## the GDScript evaluator. The solver had already computed the field and the op was discarding it.
func native_out_count() -> int:
	return 2 # height, deposition


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var channels := eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)
	return channels[0]


## Two channels: [0] the filled height, [1] deposition — where and how much material was added,
## normalised by `last_deposition_divisor`.
func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		return [Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	var rad: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else radius
	var kk: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else k
	var mask: PackedFloat32Array = (p_inputs[3] as PackedFloat32Array) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and (p_inputs[3] as PackedFloat32Array).size() == n) else PackedFloat32Array()

	if is_zero_approx(amount) or rad <= 0.0:
		return [in_grid.duplicate(), Pasture3DGraphOps.zeros(n)]

	if not ClassDB.class_has_method("Pasture3DUtil", "smooth_fill_grid"):
		push_error("[Pasture3D] Pasture3DUtil.smooth_fill_grid is not bound. Rebuild GDExtension.")
		return [in_grid.duplicate(), Pasture3DGraphOps.zeros(n)]

	var res: Dictionary = Pasture3DUtil.smooth_fill_grid(in_grid, mask, p_gw, p_gh, p_rect, int(mode),
			rad, kk, amount)
	var height: PackedFloat32Array = res.get("height", PackedFloat32Array())
	var dep: PackedFloat32Array = res.get("deposition", PackedFloat32Array())
	if height.size() != n:
		push_error("[Pasture3D] Smooth fill returned an invalid grid size.")
		return [in_grid.duplicate(), Pasture3DGraphOps.zeros(n)]

	last_deposition_divisor = float(res.get("divisor", 1.0))
	if dep.size() != n:
		dep = Pasture3DGraphOps.zeros(n)
	return [height, dep]


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amount):
		w.append("%s: Amount is 0, so it passes the input through unchanged." % display_name())
	elif radius <= 0.0:
		w.append("%s: Radius is 0, so the reference blur is the input itself and nothing is filled." % display_name())
	if k <= 0.0:
		w.append("%s: K is 0, so the fill is a hard max against the blurred reference and leaves a crease where the two surfaces meet." % display_name())
	# Same rule as DistanceTransform: a normalised channel whose divisor is only printed is not an
	# interface. The divisor here is unavoidable — it depends on the terrain — so it is reported rather
	# than made settable, but only once a bake has actually produced one. A warning that is always on is
	# noise, and noise is how real warnings get ignored.
	if not is_equal_approx(last_deposition_divisor, 1.0):
		w.append("%s: the Deposition output is normalised; the last bake divided by %.4f m. Rescale it with a Remap if you need metres." % [display_name(), last_deposition_divisor])
	return w
