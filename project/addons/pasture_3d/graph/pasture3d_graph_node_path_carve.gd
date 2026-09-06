# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathCarve — one cross-section, cut or raised along a PATH (§7.1, S3).
#
# ---- THE PRODUCTION NODE. THE MATHS IS IN C++ ----
#
# The algorithm and the argument for it live in Pasture3DGraphNodeDevPathCarve — the [Dev/GD] oracle this
# node is measured against by PathCarveGate — and in src/pasture_3d_path_carve.h. Read either for WHY the
# cross-section has two references rather than one. This file is the production half: it marshals the
# path and the parameters into flat arrays, calls Pasture3DUtil.path_carve_grid, and FAILS FAST if the
# kernel is not there (PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md §3.1).
#
# ---- THIS IS RIDGE AND TROUGH, WRITTEN ONCE ----
#
# Pasture3DRidge and Pasture3DTrough are the same mathematics twice, and where they differ they differ in
# ways that are parameters rather than algorithms. Trough's `flat_bed: bool` plus `bed_half_width: float`
# is one number with a redundant switch in front of it — `flat_width` here — and as a width it also gives
# a CREST a plateau, which the bool could not express: a causeway, a levee top, a mesa rim.
#
# §9 of the spec rebuilds both brushes on top of this node. Being a node rather than a stamp is what makes
# the difference visible: the carve reads a surface and returns one, so it can sit BETWEEN erosion passes
# instead of only at the end of them.
#
# ---- WHY THE PARAMETERS TRAVEL AS SIXTEEN FLOATS ----
#
# `native_lower()` writes the same sixteen-slot block the whole-graph program uses, and the binding takes
# it as one array rather than a dozen arguments. Both routes into the kernel then unpack through
# `path_carve_params_from` in C++, so the slot order is defined exactly once. A twelve-argument binding
# beside a sixteen-float program block would be two orderings of one thing, and the failure when they
# drifted would be a carve reading `falloff` as a slope angle.
@tool
class_name Pasture3DGraphNodePathCarve
extends Pasture3DGraphNode

## Which way the cross-section goes. CREST raises to a ridge line; BED carves to a channel floor.
##
## Named rather than left to a signed `offset`, because the sign also decides the sensible default blend
## (MAX for a crest, MIN for a bed) and reads correctly in a warning.
enum CrossSection { CREST, BED }

## How the flank reaches the ground.
enum FlankMode { FIXED_WIDTH, SLOPE_ANGLE }

## Where the flank's lateral reach comes from.
enum WidthSource { PATH, CONSTANT }

## How the carve composites onto the incoming surface.
##
## There is no ADD, and its absence is deliberate: the cross-section is already draped onto the incoming
## surface, so the carved height IS the surface plus the carve's delta and an ADD would be byte-for-byte
## REPLACE. MAX and MIN are not no-ops for the reason they look like they might be — with Follow Path
## Height on, a CREST whose drawn line runs BELOW the ground beside it has a negative height difference
## and would dig a trench where a ridge was asked for. MAX is what stops that.
enum Blend { REPLACE, MAX, MIN }

@export_group("Cross-section")
@export var cross_section: CrossSection = CrossSection.CREST:
	set(v):
		cross_section = v
		emit_changed()

## Metres above (CREST) or below (BED) the reference. With Follow Path Height on the path IS the
## reference and this is a bonus offset.
@export_range(0.0, 500.0, 0.1, "or_greater", "suffix:m") var offset: float = 0.0:
	set(v):
		offset = v
		emit_changed()

## Half-width of the FLAT top or floor. 0 = peaked crest / V-basin.
##
## This is where Trough's `flat_bed` bool plus `bed_half_width` float went: one number instead of a number
## with a switch in front of it. Note that at 0 the `bed` output is empty by construction — a peaked crest
## has no flat part — which the node warns about rather than leaving to be discovered.
@export_range(0.0, 200.0, 0.1, "or_greater", "suffix:m") var flat_width: float = 0.0:
	set(v):
		flat_width = maxf(v, 0.0)
		emit_changed()

## Cross-section shape across the flank: flat edge (x=0) reads 1, flank foot (x=1) reads 0. Null = a
## rounded cosine.
##
## The orientation is upside down from `raster_ramp`'s own empty-table fallback, which is a smoothstep
## that RISES. That is why this node always bakes a full table rather than letting an empty one mean
## "default" — the two look alike until you measure the flank.
@export var profile: Curve:
	set(v):
		if profile != null and profile.changed.is_connected(emit_changed):
			profile.changed.disconnect(emit_changed)
		profile = v
		if profile != null and not profile.changed.is_connected(emit_changed):
			profile.changed.connect(emit_changed)
		emit_changed()

@export_group("Flank")
@export var flank_mode: FlankMode = FlankMode.FIXED_WIDTH:
	set(v):
		flank_mode = v
		emit_changed()

## SLOPE_ANGLE only: the flank descends at this angle until it meets the terrain, capped by the reach.
@export_range(1.0, 89.0, 0.5, "suffix:°") var slope_angle: float = 30.0:
	set(v):
		slope_angle = clampf(v, 0.5, 89.5)
		emit_changed()

## Extra feather beyond the flank foot, metres.
@export_range(0.0, 200.0, 0.5, "or_greater", "suffix:m") var falloff: float = 10.0:
	set(v):
		falloff = maxf(v, 0.0)
		emit_changed()

@export_group("Width")
## PATH reads the path's own per-vertex half-widths, so a river that widens downstream does it here and
## Path Width (§7.3) is what sets it. CONSTANT ignores what the path carries.
@export var width_source: WidthSource = WidthSource.PATH:
	set(v):
		width_source = v
		emit_changed()

@export_range(0.0, 10.0, 0.05, "or_greater") var width_scale: float = 1.0:
	set(v):
		width_scale = maxf(v, 0.0)
		emit_changed()

## CONSTANT only.
@export_range(0.0, 500.0, 0.5, "or_greater", "suffix:m") var width: float = 25.0:
	set(v):
		width = maxf(v, 0.0)
		emit_changed()

@export_group("Reference")
## Take the crest/floor from the path's own drawn heights (needs a path that carries them), rather than
## from the terrain plus `offset`.
@export var follow_path_height: bool = true:
	set(v):
		follow_path_height = v
		emit_changed()

@export var blend: Blend = Blend.MAX:
	set(v):
		blend = v
		emit_changed()

var _path: Pasture3DGraphPath = null


func op() -> StringName:
	return &"path_carve"


## The sixteen-slot block. The order is `path_carve_params_from`'s in src/pasture_3d_path_carve.cpp, and
## that function is the only thing that reads it — on both routes.
func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = float(cross_section)
	p[1] = offset
	p[2] = flat_width
	p[3] = float(flank_mode)
	p[4] = slope_angle
	p[5] = float(width_source)
	p[6] = width_scale
	p[7] = width
	p[8] = 1.0 if follow_path_height else 0.0
	p[9] = float(blend)
	p[10] = falloff
	return {"params": p, "lut": bake_profile_lut()}


func native_out_count() -> int:
	return 5 # height, bed, flank, cut, fill


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
## makes `bed` wire straight into a Blend's mask input, so erosion can weather AROUND a carve rather than
## through it.
func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.MASK, PortType.MASK,
			PortType.MASK])


func reads_paths() -> bool:
	return true


func set_path_inputs(p_paths: Array) -> void:
	_path = p_paths[1] if p_paths.size() > 1 and p_paths[1] is Pasture3DGraphPath else null


## The profile as a 256-entry table, or the analytic cosine when no Curve is set.
##
## Baked HERE and identically in the oracle, rather than left for the kernel to default. A default that
## lived in two places would be two defaults, and this one is invisible: a cosine and a smoothstep look
## alike until the flank is measured.
func bake_profile_lut() -> PackedFloat32Array:
	var lut := PackedFloat32Array()
	lut.resize(256)
	for i in 256:
		var x := float(i) / 255.0
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

	if not ClassDB.class_has_method("Pasture3DUtil", "path_carve_grid"):
		push_error("[Pasture3D] Pasture3DUtil.path_carve_grid is not bound. Rebuild GDExtension.")
		return _passthrough(surface, n)

	# An empty or unresolved path is handled INSIDE the kernel, not here, so the two cannot disagree about
	# what "no spline" reads as — the one answer in this node whose wrong value flattens a terrain.
	var pts := _path.points if _path != null else PackedVector2Array()
	var widths := _path.half_widths if _path != null else PackedFloat32Array()
	var hts := _path.heights if _path != null else PackedFloat32Array()
	var is_closed := _path.closed if _path != null else false
	var res: Dictionary = Pasture3DUtil.path_carve_grid(pts, widths, hts, is_closed, surface, p_gw, p_gh,
			p_rect, bake_profile_lut(), native_lower()["params"])
	if not bool(res.get("ok", false)):
		push_error("[Pasture3D] path_carve_grid failed for a %d x %d grid." % [p_gw, p_gh])
		return _passthrough(surface, n)
	var height: PackedFloat32Array = res["height"]
	if height.size() != n:
		push_error("[Pasture3D] path_carve_grid returned %d cells for a %d cell grid."
				% [height.size(), n])
		return _passthrough(surface, n)
	return [height, res["bed"], res["flank"], res["cut"], res["fill"]]


## The safe answer when the kernel is missing or failed: the surface UNCHANGED and every mask empty.
##
## Not zeros — a fail-fast that flattened the terrain would be worse than the missing kernel it is
## reporting, and it is the one wrong answer a user could not undo by rebuilding.
func _passthrough(p_surface: PackedFloat32Array, p_n: int) -> Array:
	var empty := PackedFloat32Array()
	empty.resize(p_n)
	return [p_surface, empty, empty.duplicate(), empty.duplicate(), empty.duplicate()]


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if follow_path_height and _path != null and _path.heights.is_empty():
		out.append("Follow Path Height is on but this path carries no heights, so the carve is measured "
				+ "from the terrain instead. Turn on Carry Heights on the Pasture3DSpline, or turn this off.")
	if flat_width <= 0.0:
		out.append("Flat Width is 0, so the `bed` output is empty — a peaked crest has no flat part. "
				+ "Use `flank` or `fill` to mask the carve instead.")
	if cross_section == CrossSection.CREST and blend == Blend.MIN:
		out.append("A CREST with MIN blend can only ever lower the terrain, so it will never raise a "
				+ "ridge. MAX is the safe pairing for a crest, MIN for a bed.")
	elif cross_section == CrossSection.BED and blend == Blend.MAX:
		out.append("A BED with MAX blend can only ever raise the terrain, so it will never cut a "
				+ "channel. MIN is the safe pairing for a bed, MAX for a crest.")
	if width_source == WidthSource.PATH and _path != null and _path.half_widths.is_empty():
		out.append("Width Source is PATH but this path carries no half-widths, so the flank reaches 1 m. "
				+ "Set a Half Width on the Pasture3DSpline, or switch to CONSTANT.")
	return out
