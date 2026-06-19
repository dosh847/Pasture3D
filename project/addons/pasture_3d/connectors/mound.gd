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
class_name Pasture3DMound
extends Pasture3DTerrainBrush

enum BlendMode { REPLACE, ADD, MAX, MIN }

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
## Metres from the loop edge inward over which a CAPPED plateau ramps up to full height.
@export var falloff_width: float = 15.0
## Optional 0→1 slope shape for the ramp / dome (default = smoothstep).
@export var falloff_curve: Curve
## Expand (+) or contract (−) the effective boundary off the spline, in metres.
@export var edge_offset: float = 0.0

@export_group("Noise")
## Optional vertical jitter to break up the silhouette (UE curl-noise analogue).
@export var noise: FastNoiseLite
## Metres of jitter, masked by the interior profile so the rim stays clean.
@export var noise_strength: float = 0.0


func _init() -> void:
	if target_layer_name == "":
		target_layer_name = "Mounds"


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


func _polygon_xz(path: Path3D) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in _baked_world_points(path):
		out.append(Vector2(p.x, p.z))
	return out


func _paint_spline(path: Path3D) -> void:
	var poly := _polygon_xz(path)
	if poly.size() < 3:
		return
	var vs: float = terrain.vertex_spacing
	var b := _snapped_bounds(_spline_footprint_aabb(path), vs)
	var sign := -1.0 if invert else 1.0

	# Uncapped domes ramp over the whole interior, so we need the deepest interior point.
	var max_d := 1.0
	if not capped:
		max_d = _max_interior_distance(poly, b, vs)

	var x: float = b[0]
	while x <= b[1]:
		var z: float = b[2]
		while z <= b[3]:
			var pt := Vector2(x, z)
			var inside := Geometry2D.is_point_in_polygon(pt, poly)
			var dist_b := _distance_to_polygon_boundary_2d(pt, poly)
			var signed_d := (dist_b if inside else -dist_b) + edge_offset
			if signed_d > 0.0:
				var profile: float
				if capped:
					profile = _ramp(falloff_curve, signed_d / maxf(falloff_width, 0.001))
				else:
					profile = _ramp(falloff_curve, signed_d / max_d)
				if profile > 0.0:
					var pos := Vector3(x, 0.0, z)
					var base_y := terrain.data.get_height(pos) if relative_to_terrain else global_position.y
					var amp := sign * height * profile
					if noise:
						amp += noise_strength * noise.get_noise_2d(x, z) * profile
					_paint_height(pos, base_y + amp, amp)
			z += vs
		x += vs


## Largest distance-to-boundary over the loop interior — normalises the dome so its centre hits `height`.
func _max_interior_distance(poly: PackedVector2Array, b: Array, vs: float) -> float:
	var md := 0.0
	var x: float = b[0]
	while x <= b[1]:
		var z: float = b[2]
		while z <= b[3]:
			var pt := Vector2(x, z)
			if Geometry2D.is_point_in_polygon(pt, poly):
				var d := _distance_to_polygon_boundary_2d(pt, poly) + edge_offset
				md = maxf(md, d)
			z += vs
		x += vs
	return md if md > 0.0 else 1.0
