# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DTrough — spline-as-channel river / canyon / road-cut brush. Pasture3D's analogue of UE5's
# Landmass CustomBrush_LandmassRiver. Carves a channel UNDER and along each (usually open) spline: an
# optionally flat bed flanked by banks that rise back to the surrounding terrain. The bed follows the
# spline's own Y, so drawing the spline downhill produces a channel that descends (water flow).
# Defaults to MIN (carve-only) so banks never bulge above the ground.
#
# See PASTURE3D_LANDSCAPE_TOOLS_SPEC.md §6. Paints non-destructively into a reserved layer via the
# Pasture3DTerrainBrush base.
@tool
class_name Pasture3DTrough
extends Pasture3DTerrainBrush

enum BlendMode { REPLACE, ADD, MAX, MIN }

@export_group("Channel")
## How far below the bed reference the channel floor sits.
@export var depth: float = 8.0
## Half-width of the (flat) channel floor, centred on the spline.
@export var bed_half_width: float = 4.0
## true = flat floor of bed_half_width + bank ramp; false = a single smooth V/U basin across the
## whole half-width (bed_half_width + bank_width), deepest at the centreline.
@export var flat_bed: bool = true
## MIN = carve-only (default, never raises); REPLACE/ADD available for special cases.
@export var blend_mode: BlendMode = BlendMode.MIN:
	set(v):
		blend_mode = v
		_schedule_refresh() # re-bake so the new blend takes effect immediately (and undo-coherently)

@export_group("Banks")
## Lateral run from the bed edge up to terrain level (the bank slope length).
@export var bank_width: float = 10.0
## Bank shape: bed edge (0, deep) → bank top (1, terrain). Default = smoothstep.
@export var bank_profile: Curve
## Extra feather beyond the bank top into the surrounding terrain.
@export var falloff: float = 6.0

@export_group("Bed line")
## Bed reference = the spline's own Y (true; author flow by drawing downhill) or the per-pixel
## terrain height (false; a uniform-depth ditch that hugs the ground).
@export var follow_spline_height: bool = true
## Metres at each end over which the depth eases to 0 (mouth / source blend).
@export var taper_ends: float = 0.0

@export_group("Noise")
@export var noise: FastNoiseLite
## Jitter on the banks for a natural edge (never lifts the bed above terrain).
@export var noise_strength: float = 0.0

## Clamp each spline's points so its Y never rises along the path — guarantees a downhill channel.
@export_tool_button("Make Descend") var _descend_btn = make_descend


func _init() -> void:
	if target_layer_name == "":
		target_layer_name = "Troughs"


func _get_blend_mode() -> int:
	return int(blend_mode)


func _spline_basename() -> String:
	return "Channel"


func _padding() -> float:
	return bed_half_width + bank_width + falloff + 2.0


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

	# One O(cells) polyline feature field replaces the per-pixel O(segments) closest-point scan: each
	# cell gets its lateral distance, the bed-reference Y at the nearest point, and the arc length.
	var fld := _polyline_field(pts, min_x, min_z, vs, gw, gh)
	var lat_arr: PackedFloat32Array = fld[0]
	var by_arr: PackedFloat32Array = fld[1]
	var al_arr: PackedFloat32Array = fld[2]
	var total: float = fld[3]
	var reach := bed_half_width + bank_width + falloff
	var span := bed_half_width + bank_width

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
			var top_y: float = by_arr[i] if follow_spline_height else terrain.data.get_height(pos)
			var e := _end_taper(al_arr[i], total)
			var bed_y := top_y - depth * e
			var h: float
			if flat_bed:
				if lat <= bed_half_width:
					h = bed_y
				elif lat <= span:
					h = lerpf(bed_y, top_y, _ramp(bank_profile, (lat - bed_half_width) / maxf(bank_width, 0.001)))
				else:
					h = top_y
			else:
				if lat <= span:
					h = lerpf(bed_y, top_y, _ramp(bank_profile, lat / maxf(span, 0.001)))
				else:
					h = top_y
			if noise and h < top_y:
				# Lift the banks a little for a natural edge, never above the surrounding terrain.
				var mask := clampf((top_y - h) / maxf(depth, 0.001), 0.0, 1.0)
				h = minf(h + noise_strength * noise.get_noise_2d(x, z) * mask, top_y)
			_paint_height(pos, h, h - top_y)


func _end_taper(along: float, total: float) -> float:
	if taper_ends <= 0.0:
		return 1.0
	var d := minf(along, total - along)
	return clampf(d / taper_ends, 0.0, 1.0)


func make_descend() -> void:
	# Gather the clamps first so we can register a single undoable action. Walk each curve carrying the
	# running (already-clamped) previous Y, so a run of rising points all collapse to the first's level.
	var old_points: Array = [] # [curve, index, original_position]
	var new_points: Array = [] # [curve, index, clamped_position]
	for s in _get_splines():
		var c: Curve3D = s.curve
		if c == null or c.point_count == 0:
			continue
		var prev_y := c.get_point_position(0).y
		for i in range(1, c.point_count):
			var p := c.get_point_position(i)
			if p.y > prev_y:
				old_points.append([c, i, p])
				new_points.append([c, i, Vector3(p.x, prev_y, p.z)])
			else:
				prev_y = p.y
	if new_points.is_empty():
		return
	var ur := _editor_undo()
	if ur:
		ur.create_action("Make %s Descend" % _spline_basename())
		ur.add_do_method(self, "_set_curve_points_and_repaint", new_points)
		ur.add_undo_method(self, "_set_curve_points_and_repaint", old_points)
		ur.commit_action() # executes the do method now (applies the clamps + repaints)
	else:
		_set_curve_points_and_repaint(new_points)
