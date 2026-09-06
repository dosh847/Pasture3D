# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRidge — a hill, mountain or ridge, as a Plow that arrives already wired.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §9. The brush is a CLOSED LOOP; the crest is a child
# Pasture3DSpline the loop contains. Drawing the crest and bounding the area are two different jobs and
# this is the node that stopped pretending they were one.
#
# ---- WHAT CHANGED, AND WHY IT IS NOT A COSMETIC REFACTOR ----
#
# The old Ridge derived its footprint from the crest polyline plus its reach, so every edit re-rasterised
# a corridor whose extent MOVED with the line — and a graph modifier's frozen cache is keyed on
# `ox,oz,gw,gh`, so a moving extent cannot hit it at all. A closed loop is a stable extent. That is the
# performance fix, and everything else here follows from it:
#
# * the crest is not owned. It is a `Pasture3DSpline` child, found by the Spline Source's empty-key host
#   fallback (§5.1). Reparent it out and the Ridge stops carving; name it by key from another brush's
#   graph and two brushes carve one line. Neither is a special case that needed writing.
# * the maths is `Path Carve`, a graph node with a C++ kernel, a GPU mode and its own gate. The old
#   `stamp_ridge_line` rasteriser and its GDScript twin are deleted rather than kept behind a flag
#   (`pre-stack-code-gets-deleted`): two implementations of a ridge is the state this work exists to
#   end, and the kept one is the one that gets fixed instead.
# * everything the old brush did with a fixed parameter is now a node somebody can move. `noise` was a
#   per-cell term inside the crest maths; it is a Noise node before the carve. `smooth_passes` needed no
#   move at all: Pasture3DPlow already has one, doing the same blur after the same rasterisation.
#
# Scenes referencing Pasture3DRidge keep loading: the class name is the same and `_set` migrates the old
# properties onto the preset. §9.5 says what will differ and why, and it is a behaviour change rather
# than a port.
@tool
@icon("res://addons/pasture_3d/icons/brush_ridge.svg")
class_name Pasture3DRidge
extends Pasture3DSplinePreset


func _default_layer_name() -> String:
	return "Ridges"


func _spline_basename() -> String:
	return "Area"


func _preset_spline_name() -> String:
	return "Crest"


## Warm orange, against the Plow's neon purple: a scene with both wants them told apart at a glance.
func _gizmo_color() -> Color:
	return Color(1.0, 0.62, 0.24)


## A crest is drawn to a width; 12 m of half-width is a hill rather than a hedgerow, and it is the
## number `Path Carve.width_source = PATH` then reads per vertex.
func _preset_half_width() -> float:
	return 12.0


## CREST and MAX: a ridge raises, and MAX is what makes it a ridge rather than a bulge — it never digs,
## whatever the ground under it does.
func _configure_carve(p_carve: Pasture3DGraphNodePathCarve) -> void:
	p_carve.cross_section = Pasture3DGraphNodePathCarve.CrossSection.CREST
	p_carve.blend = Pasture3DGraphNodePathCarve.Blend.MAX
	# Path Carve's own default is 0, which for a CREST means a crest level with the line that draws it —
	# a preset that visibly does nothing. A preset exists to arrive doing something, and 20 m is a hill.
	p_carve.offset = 20.0
	p_carve.follow_path_height = true
	p_carve.width_source = Pasture3DGraphNodePathCarve.WidthSource.PATH


## §9.5's table. A bare StringName goes to the carve; `["spline", name]` to the child spline; a Callable
## takes the ones that are not a rename.
func _migration_map() -> Dictionary:
	return {
		"crest_height": &"offset",
		"width": ["spline", "half_width"],
		"width_curve": ["spline", "width_along"],
		"flank_mode": &"flank_mode",
		"slope_angle": &"slope_angle",
		"profile": &"profile",
		"falloff": &"falloff",
		"follow_spline_height": &"follow_path_height",
		"blend_mode": Callable(self, "_migrate_blend"),
		"invert": Callable(self, "_migrate_invert"),
		"closed": Callable(self, "_migrate_closed"),
		# Parked but not mapped: these two become a NODE rather than parameters, and the node is built
		# from both at once. The base does it after the mapped loop -- see
		# Pasture3DSplinePreset._apply_migration.
		"noise": null,
		"noise_strength": null,
	}


## The old REPLACE/ADD/MAX/MIN onto Path Carve's REPLACE/MAX/MIN.
##
## ADD has nowhere to go and does not need one: Path Carve's cross-section is already draped onto the
## incoming surface, so `ground + (carved - ground)` is byte for byte REPLACE — the argument §7.6 makes
## for why the node offers three blends and not four. An old Ridge set to ADD therefore migrates to
## REPLACE and produces the same surface it did before.
func _migrate_blend(p_value, p_carve: Pasture3DGraphNodePathCarve, _p_spline) -> void:
	match int(p_value):
		2: p_carve.blend = Pasture3DGraphNodePathCarve.Blend.MAX
		3: p_carve.blend = Pasture3DGraphNodePathCarve.Blend.MIN
		_: p_carve.blend = Pasture3DGraphNodePathCarve.Blend.REPLACE


## An inverted crest IS a bed. Not a sign flip on the offset: the cross-section is a different shape,
## and inverting a crest profile numerically would give a V where the old brush gave the mirror of a
## rounded hill.
func _migrate_invert(p_value, p_carve: Pasture3DGraphNodePathCarve, _p_spline) -> void:
	if bool(p_value):
		p_carve.cross_section = Pasture3DGraphNodePathCarve.CrossSection.BED


## `closed` moves and stops meaning what it meant. It used to decide whether the BRUSH's own spline was
## a ring; the brush's own spline is now always the loop. It migrates onto the child spline, where it
## decides whether the carved crest is a ring — the same reading of the same question, carried by a
## different property on a different node.
func _migrate_closed(p_value, _p_carve, p_spline: Pasture3DSpline) -> void:
	p_spline.closed = bool(p_value)
	for path in p_spline._get_splines():
		if path.curve != null:
			path.curve.closed = bool(p_value)
