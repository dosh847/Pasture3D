# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevPathCarve — the ORACLE for Path Carve (§7.1, S3). Pure GDScript, hidden.
#
# ---- WHY THIS FILE EXISTS AND WHY IT IS SLOW ON PURPOSE ----
#
# PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md §1: a node whose mathematics runs in GDScript is a
# [Dev/GD] reference node, invisible unless `pasture_3d/developer/enable_gdscript_reference_nodes` is on.
# The production node (pasture3d_graph_node_path_carve.gd) calls Pasture3DUtil.path_carve_grid and fails
# fast without it. This is the definition that kernel is measured against, by PathCarveGate.
#
# It is a port of an ALGORITHM, not of a file, and the parts that must be copied exactly are the ones
# where a reasonable person would choose differently:
#
#   * THE TWO REFERENCES. The crest sits at the path (or the ground plus `offset`); the flank descends to
#     the ACTUAL per-cell terrain. The shape — `diff` and the effective width — is anchored to a ground
#     reference interpolated from the terrain at the PATH'S OWN VERTICES, never sampled per cell. Sampling
#     per cell is the obvious implementation and it scallops the crest over rough ground.
#   * THE PROFILE'S ORIENTATION. index 0 = the flat edge = 1; the last index = the flank foot = 0. Upside
#     down from `raster_ramp`'s own empty-LUT fallback, which is why neither side is ever allowed to
#     receive an empty LUT and call it a default.
#   * THE FEATHER BEYOND THE FOOT decays from the profile's value AT the foot, not from 1 and not from 0.
#     A curve that does not reach 0 there would otherwise step, and the step is a hard line in the terrain
#     exactly where the carve was supposed to stop being visible.
#   * `cut` and `fill` split by the SIGN OF THE ACTUAL CHANGE, not by `cross_section`. A crest laid over a
#     hilltop fills at the middle and cuts at the flanks.
@tool
class_name Pasture3DGraphNodeDevPathCarve
extends Pasture3DGraphNode

enum CrossSection { CREST, BED }
enum FlankMode { FIXED_WIDTH, SLOPE_ANGLE }
enum WidthSource { PATH, CONSTANT }
enum Blend { REPLACE, MAX, MIN }

@export var cross_section: CrossSection = CrossSection.CREST:
	set(v):
		cross_section = v
		emit_changed()

@export var offset: float = 0.0:
	set(v):
		offset = v
		emit_changed()

@export_range(0.0, 200.0, 0.1, "or_greater", "suffix:m") var flat_width: float = 0.0:
	set(v):
		flat_width = maxf(v, 0.0)
		emit_changed()

@export var flank_mode: FlankMode = FlankMode.FIXED_WIDTH:
	set(v):
		flank_mode = v
		emit_changed()

@export_range(1.0, 89.0, 0.5, "suffix:°") var slope_angle: float = 30.0:
	set(v):
		slope_angle = clampf(v, 0.5, 89.5)
		emit_changed()

@export var width_source: WidthSource = WidthSource.PATH:
	set(v):
		width_source = v
		emit_changed()

@export_range(0.0, 10.0, 0.05, "or_greater") var width_scale: float = 1.0:
	set(v):
		width_scale = maxf(v, 0.0)
		emit_changed()

@export_range(0.0, 500.0, 0.5, "or_greater", "suffix:m") var width: float = 25.0:
	set(v):
		width = maxf(v, 0.0)
		emit_changed()

@export var profile: Curve:
	set(v):
		if profile != null and profile.changed.is_connected(emit_changed):
			profile.changed.disconnect(emit_changed)
		profile = v
		if profile != null and not profile.changed.is_connected(emit_changed):
			profile.changed.connect(emit_changed)
		emit_changed()

@export var follow_path_height: bool = true:
	set(v):
		follow_path_height = v
		emit_changed()

@export var blend: Blend = Blend.MAX:
	set(v):
		blend = v
		emit_changed()

@export_range(0.0, 200.0, 0.5, "or_greater", "suffix:m") var falloff: float = 10.0:
	set(v):
		falloff = maxf(v, 0.0)
		emit_changed()

var _path: Pasture3DGraphPath = null


func op() -> StringName:
	return &"dev_path_carve"


func role() -> Role:
	return Role.SOLVER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["surface", "path"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.PATH])


func output_count() -> int:
	return 5


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "bed", "flank", "cut", "fill"])


## `height` is a surface; the four channels are [0,1] coverage and are MASKs by contract — which is what
## makes `bed` wire straight into a Blend's mask input, the wiring this node exists for.
func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.MASK, PortType.MASK,
			PortType.MASK])


func reads_paths() -> bool:
	return true


func set_path_inputs(p_paths: Array) -> void:
	_path = p_paths[1] if p_paths.size() > 1 and p_paths[1] is Pasture3DGraphPath else null


func blocks_native() -> bool:
	return true


## The profile as a 256-entry table, or the analytic cosine when no Curve is set.
##
## Baked HERE rather than left for the kernel to default, and the production node bakes it identically:
## a default that lived in two places would be two defaults, and this one is invisible — a cosine and a
## smoothstep look alike until you measure the flank.
func bake_profile_lut() -> PackedFloat32Array:
	var lut := PackedFloat32Array()
	lut.resize(256)
	for i in 256:
		var x := float(i) / 255.0
		# 1 at the flat edge, 0 at the flank foot.
		lut[i] = profile.sample_baked(x) if profile != null else 0.5 * (1.0 + cos(PI * x))
	return lut


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = p_inputs[0] if p_inputs.size() > 0 else PackedFloat32Array()
	if surface.size() != n:
		surface = PackedFloat32Array()
		surface.resize(n)

	var bed := PackedFloat32Array()
	var flank := PackedFloat32Array()
	var cut := PackedFloat32Array()
	var fill := PackedFloat32Array()
	bed.resize(n)
	flank.resize(n)
	cut.resize(n)
	fill.resize(n)

	# PASS THE SURFACE THROUGH when there is nothing to carve, rather than returning zeros. An unresolved
	# Spline Source is a normal state — a graph mid-edit passes through it constantly — and a node that
	# flattened the terrain to sea level while a spline was being renamed would read as a solver bug.
	if _path == null or _path.segment_count() == 0:
		return [surface, bed, flank, cut, fill]

	var height := surface.duplicate()
	var lut := bake_profile_lut()

	# The ground reference, per PATH VERTEX. O(vertices), not O(cells) — and that is the smoothness
	# argument as much as the cost one: the crest's shape is decided by a few dozen terrain samples rather
	# than by every cell the flank happens to cross.
	var gv := PackedFloat32Array()
	gv.resize(_path.points.size())
	for v in _path.points.size():
		var pt := _path.points[v]
		gv[v] = _sample(surface, p_gw, p_gh, p_rect, pt.x, pt.y)

	var flat_hw := flat_width
	var slope_tan: float = maxf(tan(deg_to_rad(clampf(slope_angle, 0.5, 89.5))), 1.0e-4)
	var falloff_d: float = maxf(falloff, 1.0e-3)
	var edge_val := _ramp(lut, 1.0)
	var signed_offset := -offset if cross_section == CrossSection.BED else offset

	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	var min_x := p_rect.position.x + 0.5 * dx
	var min_z := p_rect.position.y + 0.5 * dz

	for iz in range(p_gh):
		var row := iz * p_gw
		var wz: float = min_z + float(iz) * dz
		for ix in range(p_gw):
			var i := row + ix
			var ground: float = surface[i]
			# NAN is "no data" in a HEIGHT grid, and a carve is not entitled to invent ground.
			if not is_finite(ground):
				continue
			var q := _path.nearest(Vector2(min_x + float(ix) * dx, wz))
			var lat: float = q["distance"]
			var s: float = q["s"]

			var reach: float = (maxf(_path.half_width_at(s) * width_scale, 0.0)
					if width_source == WidthSource.PATH else maxf(width, 0.0))
			var span := flat_hw + reach
			if lat > span + falloff:
				continue

			var gs := _path.lerp_vertex(gv, s)
			var ground_ref: float = gs if is_finite(gs) else ground
			var top := ground_ref
			if follow_path_height:
				var py := _path.height_at(s)
				if is_finite(py):
					top = py
			top += signed_offset
			var diff := top - ground_ref

			var w_eff := span
			if flank_mode == FlankMode.SLOPE_ANGLE:
				w_eff = clampf(flat_hw + absf(diff) / slope_tan, flat_hw, span)
			if lat > w_eff + falloff:
				continue

			var p: float
			if lat <= flat_hw:
				p = 1.0
			elif lat <= w_eff:
				p = _ramp(lut, (lat - flat_hw) / maxf(w_eff - flat_hw, 1.0e-3))
			else:
				p = edge_val * (1.0 - clampf((lat - w_eff) / falloff_d, 0.0, 1.0))
			if p <= 0.0:
				continue

			# `ground`, not `ground_ref`: the flank meets the terrain WHERE IT ACTUALLY IS, while only the
			# shape is anchored to the vertex reference. That split is the two-reference rule in one line.
			var carved := ground + diff * p
			var result := carved
			if blend == Blend.MAX:
				result = maxf(carved, ground)
			elif blend == Blend.MIN:
				result = minf(carved, ground)

			height[i] = result
			if lat <= flat_hw:
				bed[i] = 1.0
			elif lat <= w_eff:
				flank[i] = p
			var delta := result - ground
			if delta < 0.0:
				cut[i] = p
			elif delta > 0.0:
				fill[i] = p
	return [height, bed, flank, cut, fill]


## Linear lookup into a 0..1 ramp table. Mirrors `raster_ramp` in src/pasture_3d_brush_raster.cpp — with
## no empty-table fallback, because the table is never empty here and the C++ fallback is a smoothstep
## that RISES, which is this convention upside down.
func _ramp(p_lut: PackedFloat32Array, p_x: float) -> float:
	var x := clampf(p_x, 0.0, 1.0)
	var m := p_lut.size()
	if m == 0:
		return 0.0
	if m == 1:
		return p_lut[0]
	var f := x * float(m - 1)
	var i0 := int(f)
	if i0 >= m - 1:
		return p_lut[m - 1]
	return lerpf(p_lut[i0], p_lut[i0 + 1], f - float(i0))


## Bilinear sample of the surface at a world XZ, on the CELL-CENTRE convention. Edge-CLAMPED rather than
## refused: a path vertex a little outside the evaluated rect is completely normal — the rect is a brush's
## extent and the spline is longer than it — and answering NAN there would step the crest at the boundary.
## NaN-aware, so one missing corner cannot notch the reference.
func _sample(p_surf: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_x: float,
		p_z: float) -> float:
	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	if dx <= 0.0 or dz <= 0.0:
		return NAN
	var fx := ((p_x - p_rect.position.x) / dx) - 0.5
	var fz := ((p_z - p_rect.position.y) / dz) - 0.5
	var x0 := int(floor(fx))
	var z0 := int(floor(fz))
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var total := 0.0
	var wt := 0.0
	for k in 4:
		var ox := x0 + (k & 1)
		var oz := z0 + (k >> 1)
		var w: float = (tx if (k & 1) == 1 else 1.0 - tx) * (tz if (k >> 1) == 1 else 1.0 - tz)
		var v: float = p_surf[clampi(oz, 0, p_gh - 1) * p_gw + clampi(ox, 0, p_gw - 1)]
		if is_finite(v):
			total += v * w
			wt += w
	return total / wt if wt > 0.0 else NAN


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if follow_path_height and _path != null and _path.heights.is_empty():
		out.append("Follow Path Height is on but this path carries no heights, so the carve is measured "
				+ "from the terrain instead. Turn on Carry Heights on the Pasture3DSpline, or turn this off.")
	if flat_width <= 0.0:
		out.append("Flat Width is 0, so the `bed` output is empty — a peaked crest has no flat part.")
	return out
