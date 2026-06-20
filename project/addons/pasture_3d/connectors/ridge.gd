# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRidge — spline-as-crest hill / mountain / ridge brush. Raises the terrain under and along
# each (usually open) spline, the spline acting as the ridge crest, with a cross-section shaped by a
# profile Curve. Pasture3D's raise-side analogue of UE5's Landmass river brush. To CARVE a channel /
# river along a spline use Pasture3DTrough instead — it adds a flat bed, bank run and carve defaults.
#
# See PASTURE3D_LANDSCAPE_TOOLS_SPEC.md §5. Paints non-destructively into a reserved layer via the
# Pasture3DTerrainBrush base.
@tool
class_name Pasture3DRidge
extends Pasture3DTerrainBrush

enum BlendMode { REPLACE, ADD, MAX, MIN }

@export_group("Shape")
## Height of the crest above the base reference.
@export var crest_height: float = 30.0
## Half-width: lateral distance from the centreline to the skirt edge.
@export var width: float = 25.0
## MAX = mountain ridge (raise-only, default); ADD = additive; MIN/REPLACE for special cases.
@export var blend_mode: BlendMode = BlendMode.MAX:
	set(v):
		blend_mode = v
		_schedule_refresh() # re-bake so the new blend takes effect immediately (and undo-coherently)
## Flip the sign (lower instead of raise).
@export var invert: bool = false
## Cross-section: centre (t=0) = 1 → skirt edge (t=1) = 0. Default = rounded cosine.
@export var profile: Curve

@export_group("Crest line")
## Crest follows the spline's own Y (true) or the terrain height + crest_height (false).
@export var follow_spline_height: bool = true
## Metres at each end over which the crest eases to 0 (blends into the ground).
@export var taper_ends: float = 0.0

@export_group("Noise")
@export var noise: FastNoiseLite
## Vertical jitter along the ridgeline (mountain-range feel), masked by the cross-section.
@export var noise_strength: float = 0.0

@export_group("Falloff")
## Extra skirt beyond `width` that feathers a non-zero profile edge into the terrain.
@export var falloff: float = 10.0


func _default_layer_name() -> String:
	return "Ridges"


func _get_blend_mode() -> int:
	return int(blend_mode)


func _spline_basename() -> String:
	return "Ridge"


func _padding() -> float:
	return width + falloff + 2.0


## Starter shape: a straight line in local space.
func _make_starter_curve() -> Curve3D:
	var c := Curve3D.new()
	c.add_point(Vector3(0.0, 0.0, -20.0))
	c.add_point(Vector3(0.0, 0.0, 20.0))
	return c


func _paint_spline(path: Path3D) -> void:
	var pts := _baked_world_points(path)
	if pts.size() < 2:
		return
	var vs: float = terrain.vertex_spacing
	var b := _snapped_bounds(_spline_footprint_aabb(path), vs)
	var min_x: float = b[0]
	var min_z: float = b[2]
	var gw := int(round((b[1] - b[0]) / vs)) + 1
	var gh := int(round((b[3] - b[2]) / vs)) + 1
	if gw < 1 or gh < 1:
		return

	# Native rasteriser (Round 2): same polyline field + per-cell crest math in C++. GDScript reference
	# below for builds without it (and the A/B oracle via force_gdscript_raster).
	if _native_raster("stamp_ridge_line"):
		var params := {
			"min_x": min_x, "min_z": min_z, "vs": vs, "gw": gw, "gh": gh,
			"crest_height": crest_height, "width": width, "falloff": falloff,
			"invert": invert, "follow_spline_height": follow_spline_height,
			"taper_ends": taper_ends, "blend": _blend, "composite": not _defer_composite,
			"noise": noise, "noise_strength": noise_strength,
		}
		terrain.data.stamp_ridge_line(_layer_id, pts, _clip_aabb, params, _ridge_cross_lut(profile))
		return

	# One O(cells) polyline feature field replaces the per-pixel O(segments) closest-point scan: each
	# cell gets its lateral distance, the crest Y at the nearest point, and the arc length (for taper).
	var fld := _polyline_field(pts, min_x, min_z, vs, gw, gh)
	var lat_arr: PackedFloat32Array = fld[0]
	var by_arr: PackedFloat32Array = fld[1]
	var al_arr: PackedFloat32Array = fld[2]
	var total: float = fld[3]
	var sign := -1.0 if invert else 1.0
	var reach := width + falloff
	var edge_val := _ridge_cross(profile, 1.0) # profile value at the skirt edge, feathered out over `falloff`

	for iz in range(gh):
		var z := min_z + iz * vs
		var row := iz * gw
		for ix in range(gw):
			var i := row + ix
			var lat := lat_arr[i]
			if lat > reach:
				continue
			var x := min_x + ix * vs
			var pos := Vector3(x, 0.0, z)
			var base_y: float = by_arr[i] if follow_spline_height else terrain.data.get_height(pos)
			var e := _end_taper(al_arr[i], total)
			var p: float
			if lat <= width:
				p = _ridge_cross(profile, lat / maxf(width, 0.001))
			else:
				p = edge_val * (1.0 - clampf((lat - width) / maxf(falloff, 0.001), 0.0, 1.0))
			if p > 0.0:
				var amp := sign * crest_height * p * e
				if noise:
					amp += noise_strength * noise.get_noise_2d(x, z) * p
				_paint_height(pos, base_y + amp, amp)


func _end_taper(along: float, total: float) -> float:
	if taper_ends <= 0.0:
		return 1.0
	var d := minf(along, total - along)
	return clampf(d / taper_ends, 0.0, 1.0)
