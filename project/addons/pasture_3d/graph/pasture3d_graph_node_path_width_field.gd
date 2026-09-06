# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathWidthField — a path's widths, read off a field.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §7.5, §8.4. The second of the three GRID → PATH nodes. The field in
# practice is `Erosion.flow`, and the result is the thing a hand-authored width cannot be: a river that
# is narrow at its head and wide at its mouth because the water says so.
#
# ---- WHY THIS IS A SEPARATE NODE AND NOT A MODE ON Path Width ----
#
# §8.4 drafts it as "`Path Width` field mode", and a mode would work. It is a separate node because
# `blocks_native()` and S7b's cut are NODE-level facts. A Path Width that blocked the whole graph in one
# of its three modes and not the others would be a node whose cost is invisible in its title and whose
# staged-compile cut depends on a parameter rather than on a type — and the parameter is on a resource
# somebody can change without recompiling anything. Two nodes, two honest answers. Recorded as a
# departure in §7.8.
#
# What IS shared is the arithmetic: the taper curve, the SET/SCALE reading and the `min_half_width`
# floor mean the same here as they do there, and the floor is load-bearing for the same reason — `t` is
# an across-distance divided by the half-width, so a zero is a division by zero at every cell near that
# vertex, and a flow field is zero across most of its domain.
#
# ---- THE REMAP IS EXPLICIT, BECAUSE FLOW HAS NO UNITS A WIDTH COULD USE ----
#
# Accumulation is a count of upstream cells; its range depends on the grid, the solver and the rainfall.
# So the node does not scale it — it takes `field_min` and `field_max` and maps that window onto
# `half_width_min` and `half_width_max`, clamped at both ends. A user reads the range off the flow
# preview and types it in. The alternative, normalising by the field's own maximum, would make a river's
# width depend on the largest flow anywhere in the brush — so extending the terrain northwards would
# narrow a river in the south, from a change that touched nothing near it.
@tool
class_name Pasture3DGraphNodePathWidthField
extends Pasture3DGraphNodePathDerive

## Field value mapped to `half_width_min`. Values below it clamp there.
@export_range(0.0, 10000.0, 0.01, "or_greater") var field_min: float = 0.0:
	set(v):
		field_min = v
		emit_changed()

## Field value mapped to `half_width_max`. Values above it clamp there.
@export_range(0.0, 10000.0, 0.01, "or_greater") var field_max: float = 1.0:
	set(v):
		field_max = v
		emit_changed()

## Half-width in metres at `field_min`.
##
## HALF-width, matching `Pasture3DGraphPath.half_widths`, `Pasture3DSpline.half_width` and Path Width's
## own parameter. A second unit for the same quantity one hop away is how a river ends up twice the size
## it was asked for (§8.5 departure 4).
@export_range(0.0, 200.0, 0.01, "or_greater", "suffix:m") var half_width_min: float = 2.0:
	set(v):
		half_width_min = maxf(v, 0.0)
		emit_changed()

## Half-width in metres at `field_max`.
@export_range(0.0, 200.0, 0.01, "or_greater", "suffix:m") var half_width_max: float = 20.0:
	set(v):
		half_width_max = maxf(v, 0.0)
		emit_changed()

## Shapes the [0,1] remap between the two widths. Null = linear.
##
## Worth having rather than left to a curve node upstream, because flow accumulation is roughly
## exponential in catchment area: linear on the raw value gives a river that is hairline for nine tenths
## of its length and then abruptly a lake. A curve is the shortest way to say that.
@export var response: Curve:
	set(v):
		if response != null and response.changed.is_connected(emit_changed):
			response.changed.disconnect(emit_changed)
		response = v
		if response != null and not response.changed.is_connected(emit_changed):
			response.changed.connect(emit_changed)
		emit_changed()

## Multiply the mapped width by the path's existing one instead of replacing it, so a drawn taper
## survives. An empty `half_widths` reads as 1.0 everywhere (the path resource says so), which makes
## SCALE over a widthless path give the same answer SET does — the only reading of "scale nothing" that
## is not a surprise.
@export var scale_existing: bool = false:
	set(v):
		scale_existing = v
		emit_changed()

## The floor every result is clamped to. See the header: a flow field is zero over most of its domain,
## so this is the ordinary case here rather than the edge one.
@export_range(0.001, 50.0, 0.001, "or_greater", "suffix:m") var min_half_width: float = 0.5:
	set(v):
		min_half_width = maxf(v, 0.001)
		emit_changed()


func op() -> StringName:
	return &"path_width_field"


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["path", "field"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.PATH, PortType.MASK])


func input_unwired_default(p_port: int) -> float:
	return NAN if p_port == 1 else 0.0


func derive(_p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	if port_unwired(1):
		# The path keeps the widths it arrived with, which is the pre-node answer rather than a guess.
		return
	var field: PackedFloat32Array = _grids[1]
	var pts := p_out.points
	var n := pts.size()
	var span: float = field_max - field_min
	var was := p_out.half_widths
	var hw := PackedFloat32Array()
	hw.resize(n)
	for i in n:
		var f: float = sample_grid(field, pts[i].x, pts[i].y)
		# Off the domain the field says nothing, and the narrow end is the safe reading: a river that
		# thins where the data runs out is wrong in a way that looks like the map edge, and one that
		# widens there floods a corner of the terrain for no visible reason.
		var u: float = 0.0 if not is_finite(f) else (0.0 if span <= 0.0 else clampf((f - field_min) / span, 0.0, 1.0))
		if response != null:
			u = clampf(response.sample_baked(u), 0.0, 1.0)
		var w: float = lerpf(half_width_min, half_width_max, u)
		if scale_existing:
			var prev: float = 1.0
			if was.size() > 0:
				prev = was[mini(i, was.size() - 1)]
			w *= prev
		hw[i] = maxf(w, min_half_width)
	p_out.half_widths = hw


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if _gw > 0 and port_unwired(1):
		out.append("Path Width from Field has no field wired, so the path keeps the widths it arrived "
				+ "with. Wire a flow or wetness channel into `field`.")
	if field_max <= field_min:
		out.append("Field Max is not above Field Min, so every vertex maps to the minimum width and the "
				+ "node produces a constant. Use Path Width if a constant is what you want.")
	return out
