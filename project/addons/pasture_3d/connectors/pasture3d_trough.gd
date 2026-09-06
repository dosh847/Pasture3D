# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DTrough — a river, canyon or road cut, as a Plow that arrives already wired.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §9. Pasture3DRidge's header carries the argument for the rebuild;
# this is the same node with a BED where that one has a CREST, and MIN where it has MAX. That the two
# differ only in those numbers is the claim the rebuild makes, and it is why they are one class with a
# preset rather than two rasterisers.
#
# ---- ADD WATER STILL BUILDS A RIVER ----
#
# The one thing this rebuild breaks and has to fix by hand. `_build_pool_for` decides lake-versus-river
# from the CURVE — closed fills as a Pool, open becomes a Stream — and after S6 a Trough's own spline is
# always a closed loop. So Add Water would build a moat, on the one brush whose documented relationship
# with Pasture3DStream is "press Add Water on it".
#
# `Pasture3DSplinePreset._water_source_splines` is the fix (§12.2 option a): Add Water follows the
# preset's CHILD line, not the brush's loop. The closed/open rule is untouched — a Trough whose bed line
# is a ring still gets a Pool, and it should.
@tool
@icon("res://addons/pasture_3d/icons/brush_trough.svg")
class_name Pasture3DTrough
extends Pasture3DSplinePreset


func _default_layer_name() -> String:
	return "Troughs"


func _spline_basename() -> String:
	return "Area"


func _preset_spline_name() -> String:
	return "Bed"


## Cool blue-green, against the Ridge's warm orange: the pair is the one that most needs telling apart
## in a scene, because they are the same shape from above.
func _gizmo_color() -> Color:
	return Color(0.28, 0.78, 0.82)


## Narrower than a Ridge's: a channel's half-width is its bank run, and 8 m is a stream rather than a
## gorge. The flat floor is `Path Carve.flat_width`, which is a different number.
func _preset_half_width() -> float:
	return 8.0


## BED and MIN, with a flat floor. MIN is what makes it carve-only: banks never bulge above the ground,
## whatever the terrain does under them, which is the property that lets a channel cross a slope.
func _configure_carve(p_carve: Pasture3DGraphNodePathCarve) -> void:
	p_carve.cross_section = Pasture3DGraphNodePathCarve.CrossSection.BED
	p_carve.blend = Pasture3DGraphNodePathCarve.Blend.MIN
	# Negative, for the same reason the Ridge's is positive and not zero: a channel arrives cut.
	p_carve.offset = -6.0
	p_carve.flat_width = 4.0
	p_carve.follow_path_height = true
	p_carve.width_source = Pasture3DGraphNodePathCarve.WidthSource.PATH


## Clamp each bed line's points so its Y never rises along the path — a channel that flows.
##
## Kept, and moved onto the CHILD spline: the line that has to descend is the bed, and the brush's own
## spline is now a loop, which cannot meaningfully descend at all.
@export_tool_button("Make Descend") var _descend_btn = make_bed_descend


func make_bed_descend() -> void:
	var sp := _preset_spline()
	if sp == null:
		push_warning("[Pasture3D] %s: no bed spline to make descend." % name)
		return
	sp.make_descend()


## §9.5's table. Same shapes as the Ridge's; `depth` and `bank_width` are where the two differ.
func _migration_map() -> Dictionary:
	return {
		"depth": &"offset",
		"bank_width": ["spline", "half_width"],
		"width_curve": ["spline", "width_along"],
		"flank_mode": &"flank_mode",
		"slope_angle": &"slope_angle",
		"bank_profile": &"profile",
		"falloff": &"falloff",
		"follow_spline_height": &"follow_path_height",
		"blend_mode": Callable(self, "_migrate_blend"),
		"closed": Callable(self, "_migrate_closed"),
		# The floor is TWO old properties and one new one, so it cannot be a rename either way round.
		"bed_half_width": Callable(self, "_migrate_bed"),
		"flat_bed": Callable(self, "_migrate_flat_bed"),
		# Nodes, not parameters. See Pasture3DSplinePreset._apply_migration.
		"noise": null,
		"noise_strength": null,
	}


## The old REPLACE/ADD/MAX/MIN onto Path Carve's three. See Pasture3DRidge._migrate_blend for why ADD
## has nowhere to go and does not need one.
func _migrate_blend(p_value, p_carve: Pasture3DGraphNodePathCarve, _p_spline) -> void:
	match int(p_value):
		2: p_carve.blend = Pasture3DGraphNodePathCarve.Blend.MAX
		3: p_carve.blend = Pasture3DGraphNodePathCarve.Blend.MIN
		_: p_carve.blend = Pasture3DGraphNodePathCarve.Blend.REPLACE


## `bed_half_width` becomes `flat_width`, which is a FULL width and not a half one.
##
## Doubling here rather than at the read is the whole of the mapping, and getting it wrong halves every
## migrated channel's floor while leaving the banks where they were — a shape that still looks like a
## channel, which is why the gate measures the floor's width rather than eyeballing the section.
func _migrate_bed(p_value, p_carve: Pasture3DGraphNodePathCarve, _p_spline) -> void:
	p_carve.flat_width = maxf(float(p_value), 0.0) * 2.0
	_migrated_bed_half = maxf(float(p_value), 0.0)


## `flat_bed` off means a single smooth basin across the whole half-width: no flat floor at all. It is a
## zero, not a mode — Path Carve's BED with `flat_width = 0` IS the V/U basin the old brush drew.
func _migrate_flat_bed(p_value, p_carve: Pasture3DGraphNodePathCarve, _p_spline) -> void:
	if not bool(p_value):
		p_carve.flat_width = 0.0
	elif _migrated_bed_half > 0.0:
		p_carve.flat_width = _migrated_bed_half * 2.0


func _migrate_closed(p_value, _p_carve, p_spline: Pasture3DSpline) -> void:
	p_spline.closed = bool(p_value)
	for path in p_spline._get_splines():
		if path.curve != null:
			path.curve.closed = bool(p_value)


## `bed_half_width` remembered across the two setters above, because the dictionary that drives them has
## no order and either may run first.
var _migrated_bed_half: float = 0.0
