# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DMound — closed-loop spline hill / plateau / valley brush. Pasture3D's analogue of UE5's
# Landmass CustomBrush_Landmass. Each child Path3D is treated as a closed loop; the interior is
# filled with a hill (uncapped dome) or plateau (capped flat-top), falling off to the surrounding
# terrain at the loop boundary. Set invert / blend_mode = MIN to carve a basin instead.
#
# See PASTURE3D_LANDSCAPE_TOOLS_SPEC.md §4. Paints non-destructively into a reserved layer via the
# Pasture3DTerrainBrush base.
@tool
@icon("res://addons/pasture_3d/icons/brush_mound.svg")
class_name Pasture3DMound
extends Pasture3DTerrainBrush

enum BlendMode { REPLACE, ADD, MAX, MIN }
## How the height ramps in from the loop edge: FIXED_WIDTH ramps over `falloff_width`; SLOPE_ANGLE
## ramps at `slope_angle` (run = height / tan(angle)) so the flank meets the edge at a chosen grade.
enum FlankMode { FIXED_WIDTH, SLOPE_ANGLE }

@export_group("Shape")
## Peak height above the base reference. Capped → plateau-top height; uncapped → dome peak.
@export var height: float = 20.0
## Flat-topped plateau (true) vs domed peak (false).
@export var capped: bool = false
## How the loop composites with the terrain: MAX = hill (raise-only), MIN = basin (lower-only),
## ADD = additive bump, REPLACE = absolute authoring (flat plateau when combined with capped).
@export var blend_mode: BlendMode = BlendMode.MAX:
	set(v):
		blend_mode = v
		_schedule_refresh() # re-bake so the new blend takes effect immediately (and undo-coherently)
## Flip the sign so the same controls carve a depression.
@export var invert: bool = false
## true = measure height above the per-pixel terrain (hill drapes on the ground); false = above the
## node's own Y plane (flat reference — pair with capped + REPLACE for a level plateau top).
@export var relative_to_terrain: bool = true

@export_group("Falloff")
## FIXED_WIDTH = ramp over `falloff_width`; SLOPE_ANGLE = ramp at `slope_angle` (run = height / tan).
@export var flank_mode: FlankMode = FlankMode.FIXED_WIDTH:
	set(v):
		flank_mode = v
		_schedule_refresh()
		notify_property_list_changed() # show/hide falloff_width vs slope_angle
## Metres from the loop edge inward over which a CAPPED plateau ramps up to full height.
@export var falloff_width: float = 15.0
## Slope-angle mode only: degrees the flank rises from the loop edge (ramp run = height / tan(angle)).
@export_range(1.0, 89.0, 0.5) var slope_angle: float = 30.0:
	set(v):
		slope_angle = clampf(v, 1.0, 89.0)
		_schedule_refresh()
## Optional 0→1 slope shape for the ramp / dome (default = smoothstep).
@export var falloff_curve: Curve
## Expand (+) or contract (−) the effective boundary off the spline, in metres.
@export var edge_offset: float = 0.0

@export_group("Noise")
## Optional vertical jitter to break up the silhouette (UE curl-noise analogue).
@export var noise: FastNoiseLite
## Metres of jitter, masked by the interior profile so the rim stays clean.
@export var noise_strength: float = 0.0


func _validate_property(property: Dictionary) -> void:
	# Fixed-width and slope-angle drive the same ramp; only one is meaningful at a time.
	if property.name == "slope_angle" and flank_mode != FlankMode.SLOPE_ANGLE:
		property.usage &= ~PROPERTY_USAGE_EDITOR
	elif property.name == "falloff_width" and flank_mode == FlankMode.SLOPE_ANGLE:
		property.usage &= ~PROPERTY_USAGE_EDITOR


## Safety ceiling for the uncapped slope-angle cone: the region's world size (verts × spacing). A steep
## angle over a large loop would otherwise author an unbounded peak; this caps it at something sane.
func _region_safety_height() -> float:
	if terrain == null:
		return 1000.0
	return maxf(float(terrain.region_size) * terrain.vertex_spacing, 1.0)


func _default_layer_name() -> String:
	return "Mounds"


func _get_blend_mode() -> int:
	return int(blend_mode)


func _min_points() -> int:
	return 3


func _spline_basename() -> String:
	return "Loop"


func _padding() -> float:
	# Painting only reaches outside the polygon by a positive edge_offset; the dome/ramp work inward.
	return maxf(edge_offset, 0.0) + 2.0


## Starter shape: a closed square loop in local space.
func _make_starter_curve() -> Curve3D:
	var c := Curve3D.new()
	var r := 20.0
	c.add_point(Vector3(-r, 0.0, -r))
	c.add_point(Vector3(r, 0.0, -r))
	c.add_point(Vector3(r, 0.0, r))
	c.add_point(Vector3(-r, 0.0, r))
	return c


## Loop projected to world XZ and decimated to ~terrain resolution (the raw Curve3D bake is far finer
## than the grid and would make the scanline fill needlessly slow).
func _polygon_xz(path: Path3D) -> PackedVector2Array:
	var raw := PackedVector2Array()
	for p in _baked_world_points(path):
		raw.append(Vector2(p.x, p.z))
	return _decimate(raw, maxf(terrain.vertex_spacing, 0.25))


func _paint_spline(path: Path3D) -> void:
	var poly := _polygon_xz(path)
	if poly.size() < 3:
		return
	var vs: float = terrain.vertex_spacing
	var b := _snapped_bounds(_spline_footprint_aabb(path), vs)
	var min_x: float = b[0]
	var min_z: float = b[2]
	var gw := int(round((b[1] - b[0]) / vs)) + 1
	var gh := int(round((b[3] - b[2]) / vs)) + 1
	if gw < 1 or gh < 1:
		return

	# Native rasteriser (Round 2): same SDF + per-cell math in C++ (~15-40x faster than this GDScript loop
	# on large edits). The GDScript reference below runs on builds without it (and is the A/B oracle).
	if _native_raster("stamp_mound_loop"):
		var params := {
			"min_x": min_x, "min_z": min_z, "vs": vs, "gw": gw, "gh": gh,
			"height": height, "capped": capped, "invert": invert,
			"falloff_width": falloff_width, "edge_offset": edge_offset,
			"flank_mode": int(flank_mode), "slope_tan": tan(deg_to_rad(slope_angle)),
				"slope_safety": _region_safety_height(),
				"relative_to_terrain": relative_to_terrain, "plane_y": global_position.y,
			"blend": _blend, "composite": not _defer_composite,
			"noise": noise, "noise_strength": noise_strength,
		}
		if relative_to_terrain:
			params["base_below"] = _base_below_grid(min_x, min_z, vs, gw, gh)
		terrain.data.stamp_mound_loop(_layer_id, poly, _clip_aabb, params, _ramp_lut(falloff_curve))
		return

	# One O(cells) signed distance field replaces the old per-pixel O(edges) polygon distance (×2 for
	# the dome's max-interior pass). Positive inside, in metres; max_inside normalises the dome.
	var sdf := _signed_distance_field(poly, min_x, min_z, vs, gw, gh)
	var field: PackedFloat32Array = sdf[0]
	var max_inside: float = sdf[1]
	var sign := -1.0 if invert else 1.0
	var dome_denom := maxf(max_inside + edge_offset, 0.001)
	var ramp_denom := maxf(falloff_width, 0.001)
	var slope_tan := maxf(tan(deg_to_rad(slope_angle)), 0.0001)
	# Slope-angle: the grade — not a typed width — drives the ramp.
	#  - CAPPED: rise at the angle until the flank reaches `height`, then flat top. ramp run = height / tan.
	#  - UNCAPPED ("cone"): keep rising at the angle all the way in (height = tan × distance-from-edge), NOT
	#    limited by `height`. Bounded only by the interior; clamped to a region-sized safety cap so a huge
	#    loop / steep angle can't author a runaway peak.
	var use_angle := flank_mode == FlankMode.SLOPE_ANGLE
	var cone := use_angle and not capped
	var safety_max := _region_safety_height()
	if use_angle and capped:
		ramp_denom = maxf(absf(height) / slope_tan, 0.001)

	for iz in range(gh):
		var z := min_z + iz * vs
		var row := iz * gw
		for ix in range(gw):
			var signed_d := field[row + ix] + edge_offset
			if signed_d <= 0.0:
				continue
			var x := min_x + ix * vs
			var pos := Vector3(x, 0.0, z)
			var base_y := _base_height_below(pos) if relative_to_terrain else global_position.y
			var amp: float
			if cone:
				# Free-rising cone: tan × distance, capped by the region safety height. profile is the
				# 0→1 interior mask used only to keep noise off the rim.
				var profile := clampf(signed_d / dome_denom, 0.0, 1.0)
				amp = sign * minf(slope_tan * signed_d, safety_max)
				if noise:
					amp += noise_strength * noise.get_noise_2d(x, z) * profile
			else:
				var profile := _ramp(falloff_curve, signed_d / (ramp_denom if capped else dome_denom))
				if profile <= 0.0:
					continue
				amp = sign * height * profile
				if noise:
					amp += noise_strength * noise.get_noise_2d(x, z) * profile
			_paint_height(pos, base_y + amp, amp)
