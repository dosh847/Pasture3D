# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadWall — one retaining wall design, reusable across road types, roads and segments. See
# PASTURE3D_ROAD_WALL_SPEC.md.
#
# The same resource serves a CUT wall (holding the hillside back above the road) and a FILL wall (holding
# the road up above the valley); which one it is depends on the slot it sits in.
@tool
class_name Pasture3DRoadWall
extends Resource

## Where the wall stands.
enum Placement {
	ROAD_SIDE,  ## At the edge of formation, `offset` metres out: a wall that holds the hill back from the road.
	BATTER_TOP, ## Where the batter has climbed `trigger_height`: the batter runs up to it and the hillside stands above.
}

## How the top of the wall runs along the road.
enum TopMode {
	FOLLOW_ROAD,   ## One height per run of wall, the tallest it needs: a level top parallel to the road.
	STEPPED,       ## Level blocks `step_length` long, each rounded up to a multiple of `step_height`.
	FOLLOW_GROUND, ## Tracks the height it needs, smoothed over `top_smoothing`.
}

## How a run of wall ends.
enum EndTreatment {
	TAPER,  ## Ramps down into the plain batter over `end_taper_length`.
	SQUARE, ## Full height to the last sample.
}

## False makes this resource mean "no wall", so an override can switch off a wall its type has.
@export var enabled: bool = true:
	set(v):
		enabled = v
		emit_changed()

@export_group("Placement")
@export var placement: Placement = Placement.ROAD_SIDE:
	set(v):
		placement = v
		emit_changed()

## A wall stands only where the plain batter would climb (cut) or fall (fill) more than this, metres.
## Lower ground just gets the batter.
@export_range(0.0, 30.0, 0.1, "or_greater", "suffix:m") var trigger_height: float = 2.0:
	set(v):
		trigger_height = maxf(v, 0.0)
		emit_changed()

## Metres from the edge of formation to the wall's inner face. On a cut wall this is the ditch in front of it.
@export_range(0.0, 10.0, 0.05, "or_greater", "suffix:m") var offset: float = 0.5:
	set(v):
		offset = maxf(v, 0.0)
		emit_changed()

@export_group("Size")
## The tallest the wall is built, metres. Where the ground needs more, the batter carries on above a cut
## wall (or below a fill wall) at `beyond_batter`.
@export_range(0.25, 60.0, 0.25, "or_greater", "suffix:m") var max_height: float = 6.0:
	set(v):
		max_height = maxf(v, 0.25)
		emit_changed()

## Metres through the wall. The terrain steps at `offset + thickness` (plus `landscape_offset` on a cut).
@export_range(0.1, 5.0, 0.05, "or_greater", "suffix:m") var thickness: float = 0.6:
	set(v):
		thickness = maxf(v, 0.05)
		emit_changed()

## CUT walls: metres the terrain's step is set back behind the wall, so a steep hillside cannot poke
## through the face. The heightfield draws the step as a ramp across a cell, and that ramp starts a cell
## BEFORE the step; set back far enough, it starts behind the face rather than in front of it. The coping
## covers the gap. Ignored on a fill wall, whose ground falls away from the shelf.
@export_range(0.0, 5.0, 0.05, "or_greater", "suffix:m") var landscape_offset: float = 0.25:
	set(v):
		landscape_offset = maxf(v, 0.0)
		emit_changed()


## Metres from the edge of formation to where the terrain steps, for a cut (`p_cut`) or a fill wall.
func step_offset(p_cut: bool) -> float:
	return offset + thickness + (landscape_offset if p_cut else 0.0)

## Slope of the batter above a cut wall or below a fill wall, rise/run. 0 uses the road type's batter.
@export_range(0.0, 10.0, 0.05, "or_greater") var beyond_batter: float = 0.0:
	set(v):
		beyond_batter = maxf(v, 0.0)
		emit_changed()

## Metres the face is sunk below the ground in front of it, so a later bake never shows a gap under the wall.
@export_range(0.0, 5.0, 0.05, "or_greater", "suffix:m") var embed_depth: float = 0.5:
	set(v):
		embed_depth = maxf(v, 0.0)
		emit_changed()

## Face batter, run/rise: 0.1 leans the face back 10 cm for every metre it rises. Mesh only.
@export_range(0.0, 1.0, 0.01) var lean: float = 0.0:
	set(v):
		lean = clampf(v, 0.0, 1.0)
		emit_changed()

@export_group("Top")
@export var top_mode: TopMode = TopMode.FOLLOW_ROAD:
	set(v):
		top_mode = v
		emit_changed()

## STEPPED: length of each level block along the road, metres.
@export_range(1.0, 100.0, 0.5, "or_greater", "suffix:m") var step_length: float = 10.0:
	set(v):
		step_length = maxf(v, 0.5)
		emit_changed()

## STEPPED: every block's height is rounded up to a multiple of this, metres.
@export_range(0.1, 5.0, 0.05, "or_greater", "suffix:m") var step_height: float = 0.5:
	set(v):
		step_height = maxf(v, 0.05)
		emit_changed()

## FOLLOW_GROUND: the window the height is averaged over along the road, metres.
@export_range(0.0, 100.0, 0.5, "or_greater", "suffix:m") var top_smoothing: float = 8.0:
	set(v):
		top_smoothing = maxf(v, 0.0)
		emit_changed()

@export_group("Runs")
## A run of wall shorter than this is not built, metres.
@export_range(0.0, 100.0, 0.5, "or_greater", "suffix:m") var min_length: float = 6.0:
	set(v):
		min_length = maxf(v, 0.0)
		emit_changed()

## A gap between two runs shorter than this is walled over, metres. Never across a bridge or a junction.
@export_range(0.0, 100.0, 0.5, "or_greater", "suffix:m") var gap_bridge: float = 4.0:
	set(v):
		gap_bridge = maxf(v, 0.0)
		emit_changed()

@export var end_treatment: EndTreatment = EndTreatment.TAPER:
	set(v):
		end_treatment = v
		emit_changed()

## TAPER: metres over which the wall ramps from nothing to full height at each end of a run.
@export_range(0.5, 50.0, 0.5, "or_greater", "suffix:m") var end_taper_length: float = 4.0:
	set(v):
		end_taper_length = maxf(v, 0.5)
		emit_changed()

@export_group("Finish")
## Height of the cap course on top of the wall, metres. Mesh only.
@export_range(0.0, 2.0, 0.01, "or_greater", "suffix:m") var coping_height: float = 0.1:
	set(v):
		coping_height = maxf(v, 0.0)
		emit_changed()

## How far the cap course overhangs the face, metres. Mesh only.
@export_range(0.0, 1.0, 0.01, "or_greater", "suffix:m") var coping_overhang: float = 0.05:
	set(v):
		coping_overhang = maxf(v, 0.0)
		emit_changed()

## Empty uses a plain concrete grey.
@export var material: Material = null:
	set(v):
		material = v
		emit_changed()

## Metres per texture repeat, along the road and up the face.
@export_range(0.1, 20.0, 0.1, "or_greater", "suffix:m") var uv_scale_m: float = 2.0:
	set(v):
		uv_scale_m = maxf(v, 0.01)
		emit_changed()

## Build a StaticBody3D for the wall.
@export var collision: bool = true:
	set(v):
		collision = v
		emit_changed()

@export_flags_3d_physics var collision_layer: int = 1:
	set(v):
		collision_layer = v
		emit_changed()


## The fields that move the GROUND. The finish, `embed_depth` and `lean` are absent: they shape the
## mesh only, and a stamp key that saw them would re-rasterise a road for a change of material.
func terrain_signature() -> Array:
	return [enabled, placement, trigger_height, offset, max_height, thickness, landscape_offset, beyond_batter,
			top_mode, step_length, step_height, top_smoothing, min_length, gap_bridge, end_treatment, end_taper_length]


## The fields the mesh reads on top of the terrain ones.
func mesh_signature() -> Array:
	return [terrain_signature(), embed_depth, lean, coping_height, coping_overhang,
			material.get_instance_id() if material != null else 0, uv_scale_m, collision, collision_layer]


## True when this resource asks for a wall at all.
static func active(p_wall: Pasture3DRoadWall) -> bool:
	return p_wall != null and p_wall.enabled
