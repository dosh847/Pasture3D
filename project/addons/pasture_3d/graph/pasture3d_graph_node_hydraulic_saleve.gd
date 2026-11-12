# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeHydraulicSaleve — Salève Hydraulic Erosion Smooth, the large-scale hydraulic erosion SOLVER that
# incises the input in place. The op id stays `hydraulic_saleve` so saved graphs load unchanged. Its sibling,
# Salève Hydraulic Erosion (saleve_stream_power), is uplift and stream-power incision through time.
#
# Four stages (PASTURE3D_SALEVE_STRATA_FIDELITY_SPEC.md, S1-S3):
#   1  incision of the input over a drainage network: one tree per border outlet, lakes spilling at their
#      lowest point, iterated to convergence. Channels lose height as water collects and the ground beside
#      them climbs back to the input, so the input stays the shape. Solved on jittered control points
#      (Delaunay-triangulated), every edge held to Max Slope; the cut is reconstructed onto the grid, smoothed,
#      and taken off the input
#   2  deposition: pits filled and concave valley floors raised toward a blur, on flat ground only
#   3  fine incision: the Stream Log solver itself, run on the result
#   4  optional smoothing, then composite over the input by Erosion Strength x mask
#
# Stage 1 Mode UPLIFT (PASTURE3D_RANGES_SPEC.md step 4) swaps stage 1's incision for the stream-power steady
# state grown from the `uplift` field: same routing, outlets and drainage area (the input still decides what
# is downhill and where the sea is), but each vertex rises from its receiver by the steady-state slope, held
# to Max Slope. A whole area comes out as dendritic valleys and interfluves that drain to the sea. The maths
# is in src/pasture_3d_hydraulic_saleve.h (stage1_mode).
#
# ---- Inputs ----
#   port 1/2 "dx"/"dy"  SIGNED  reconstruction warp in METRES (added to Default Warp's fBm, if on)
#   port 3   "uplift"   MASK    UPLIFT only: where, and how hard, ground rises (unwired = everywhere)
#   port 4   "mask"     MASK    blend of the eroded result over the input (rides the native in_aux grid)
#
# ---- Outputs ----
#   port 0  "height"       HEIGHT  eroded surface elevation (metres)
#   port 1  "eroded_rock"  FIELD   net lowering, in metres (Float to Mask makes it a 0..1 mask)
#   port 2  "sediment"     FIELD   Stage 2 deposition, in metres
@tool
class_name Pasture3DGraphNodeHydraulicSaleve
extends Pasture3DGraphSolverNode


enum Stage1Mode { INPUT, UPLIFT }

## INPUT incises the wired height (the classic Salève). UPLIFT grows a drained ridge-and-valley landscape
## from the Uplift port instead, on top of the input: the input sets the sea and the outlets.
@export var stage1_mode: Stage1Mode = Stage1Mode.INPUT:
	set(v):
		stage1_mode = v
		_param_changed()
		notify_property_list_changed()
@export_group("Uplift")
## The slope a fully uplifted channel head stands at, in metres per kilometre of channel. Slopes fall
## downstream as water collects (by Drainage Exponent / Uplift N), so ranges rise with their distance from
## the sea. A gradient, not a height: a bigger area grows taller ranges, not a rescaled copy.
@export_range(0.0, 2000.0, 1.0, "or_greater", "suffix:m/km") var uplift_gradient: float = 300.0:
	set(v):
		uplift_gradient = maxf(v, 0.0)
		_param_changed()
## The stream-power slope exponent n: relief goes as Uplift Gradient^(1/n), and higher n evens the
## slopes out between channels and divides.
@export_range(0.25, 4.0, 0.05) var uplift_n: float = 1.0:
	set(v):
		uplift_n = clampf(v, 0.25, 4.0)
		_param_changed()

@export_group("Erosion")
## How much of the eroded result replaces the input, 0..1 (times the mask, if wired). Every output is under
## the same weight.
@export_range(0.0, 1.0, 0.01) var erosion_strength: float = 0.7:
	set(v):
		erosion_strength = clampf(v, 0.0, 1.0)
		_param_changed()

## How fast a channel loses the input's slope as water collects: its slope falls with (Channel Area / area)^m.
## Higher values cut every valley deeper, the big trunk valleys most of all.
@export_range(0.01, 0.8, 0.01) var drainage_exponent: float = 0.2:
	set(v):
		drainage_exponent = clampf(v, 0.01, 0.8)
		_param_changed()

## How much ground must drain through a point before it starts to cut, in square metres. Smaller gives more
## and finer valleys, and this has a strong effect: doubling it can halve the erosion. 0 is auto: (relief / 8)²,
## so 560 m² on 190 m of relief, and at least the area of two control points.
@export_range(0.0, 100000.0, 1.0, "or_greater", "suffix:m²") var channel_area: float = 0.0:
	set(v):
		channel_area = maxf(v, 0.0)
		_param_changed()

## How much seeded noise bends the flow routing, 0..1, so valleys branch dendritically instead of running
## straight downhill. The noise is fixed across passes, so the network still converges.
@export_range(0.0, 1.0, 0.01) var drainage_noise: float = 0.15:
	set(v):
		drainage_noise = clampf(v, 0.0, 1.0)
		_param_changed()

## How strongly high ground resists erosion (an exponent on the height below Reference Relief). Higher
## keeps the summit silhouette; lower lets the valleys cut all the way up.
@export_range(0.05, 4.0, 0.05) var shape_preservation: float = 1.5:
	set(v):
		shape_preservation = clampf(v, 0.05, 4.0)
		_param_changed()

## The height, in metres, Shape Preservation measures high ground against, and the scale drainage lengths are
## taken in. It does not scale the output. 0 takes it from the input's own relief, which moves whenever the
## solved extent does: a brush's Modifier Margin brings the surrounding ground into range without moving one
## vertex of the shape, and the pattern shifts. Pin it to roughly the relief you are eroding (a 90 m mound
## → 90) to hold a shape steady across margins, footprint edits and re-bakes.
@export_range(0.0, 500.0, 1.0, "or_greater", "suffix:m") var reference_relief: float = 0.0:
	set(v):
		reference_relief = maxf(v, 0.0)
		_param_changed()

## Seed for the drainage noise, the flat-breaking noise, the control-point jitter and the default warp.
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export_group("Slope Limit")
## The steepest the eroded ground may stand, in metres per metre. Slopes the input already has are kept. Valley
## walls climb at this slope, so lower gives wider valleys that remove more, and higher gives narrow slots that
## remove less. Used everywhere while Uniform Slope is on; otherwise it applies at the centre of the solved area
## and falls along a smooth radial pulse to Max Slope Border at a distance of the smaller side.
@export_range(0.0, 20.0, 0.1, "or_greater", "suffix:m/m") var max_slope_center: float = 1.5:
	set(v):
		max_slope_center = maxf(v, 0.0)
		_param_changed()

## The steepest the eroded ground may stand toward the border of the solved area, in metres per metre. Only used
## when Uniform Slope is off. The limit between neighbouring points never falls below a fifth of Max Slope Center.
@export_range(0.0, 20.0, 0.1, "or_greater", "suffix:m/m") var max_slope_border: float = 1.5:
	set(v):
		max_slope_border = maxf(v, 0.0)
		_param_changed()

## Use Max Slope Center everywhere, with no radial falloff. Off, the same mountain erodes differently depending on
## where it sits in the solved area.
@export var uniform_slope: bool = true:
	set(v):
		uniform_slope = v
		_param_changed()

## How wide the cut is smoothed before it comes off the input, in metres. Walls from neighbouring channels meet in
## knife crests, and this rounds them; the input's own detail is untouched and the amount removed stays about the
## same. 0 = auto: 1.5 x the distance between control points. Well below auto the fins start to come back.
@export_range(0.0, 100.0, 0.5, "or_greater", "suffix:m") var valley_smoothing: float = 0.0:
	set(v):
		valley_smoothing = maxf(v, 0.0)
		_param_changed()

@export_group("Convergence")
## Upper bound on drainage passes. The solve stops as soon as it converges below Tolerance, so this is a
## ceiling, not a cost.
@export_range(1, 1000, 1, "or_greater") var iterations: int = 200:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

## Convergence threshold: mean height change per pass, as a fraction of the current relief.
@export_range(0.0, 0.01, 0.0001) var tolerance: float = 1.0e-3:
	set(v):
		tolerance = clampf(v, 0.0, 0.01)
		_param_changed()

@export_group("Control Points")
## How many control points the drainage network is solved on. Channels are a few points apart, so more points
## give finer valleys. Ignored when Point Spacing is set. At most 100000.
@export_range(500, 100000, 100) var control_points: int = 15000:
	set(v):
		control_points = clampi(v, 16, 100000)
		_param_changed()

## Distance between control points, in metres. 0 derives it from Control Points over the solved area,
## which moves when the area does (a Modifier Margin). Set it to hold the network steady across margins:
## the point lattice is anchored to the world, so a wider area adds points without moving any. This sets the
## point count: 1 m over a 1 x 1 km area asks for a million. Past 100000 points the spacing widens to fit, with a
## warning, and stops holding steady across margins.
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m") var point_spacing: float = 0.0:
	set(v):
		point_spacing = maxf(v, 0.0)
		_param_changed()

enum Reconstruction { LINEAR, GRADIENT }
## How the solved points become the grid. Gradient blends each point's tangent plane for smooth valley
## walls; Linear is flat within each triangle.
@export var reconstruction: Reconstruction = Reconstruction.GRADIENT:
	set(v):
		reconstruction = v
		_param_changed()

@export_group("Warp")
## Adds seeded fBm to the dx/dy warp, so valleys meander instead of following triangle edges.
@export var default_warp: bool = true:
	set(v):
		default_warp = v
		_param_changed()

## Warp distance in metres. 0 = 2% of the smaller side of the solved area.
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m") var warp_amount: float = 0.0:
	set(v):
		warp_amount = maxf(v, 0.0)
		_param_changed()

## Warp feature size in metres. 0 = a quarter of the smaller side of the solved area.
@export_range(0.0, 1000.0, 1.0, "or_greater", "suffix:m") var warp_size: float = 0.0:
	set(v):
		warp_size = maxf(v, 0.0)
		_param_changed()

@export_group("Deposition")
## Blur radius, in METRES, of the alluvial flats: pits are filled and concave ground (valley floors) is
## raised toward a blur of itself this wide. 0 = 10% of the smaller side of the solved extent. Deposition
## only raises, never touches ridges, and is zero on a plane whatever this is.
@export_range(0.0, 200.0, 0.5, "or_greater", "suffix:m") var deposition_radius: float = 0.0:
	set(v):
		deposition_radius = maxf(v, 0.0)
		_param_changed()

## How far each depression is filled toward its flat, 0..1. Weighted down on ground steeper than 0.5 m/m.
@export_range(0.0, 1.0, 0.01) var deposition_strength: float = 0.5:
	set(v):
		deposition_strength = clampf(v, 0.0, 1.0)
		_param_changed()

@export_group("Fine Incision")
## Fine incision is the Stream Log solver run on the result: this is its incision_rate. 0 skips it.
@export_range(0.0, 1.0, 0.005) var stream_strength: float = 0.02:
	set(v):
		stream_strength = clampf(v, 0.0, 1.0)
		_param_changed()

## The Stream Log solver's area_exponent (m in A^m S^n).
@export_range(0.01, 1.0, 0.01) var stream_exp: float = 0.8:
	set(v):
		stream_exp = clampf(v, 0.01, 1.0)
		_param_changed()

@export_group("Rim")
## Band, in metres from the grid edge, over which the result is eased down to the input height so it meets
## the surrounding ground. Beyond it the solve is free. 0 = 10% of the shorter side.
@export_range(0.0, 500.0, 0.5, "or_greater", "suffix:m") var rim_width: float = 0.0:
	set(v):
		rim_width = maxf(v, 0.0)
		_param_changed()

## Where Stage 1's water leaves: every cell within this fraction of the grid's relief above its lowest
## point is an outlet, as well as the grid border. Outlets are never cut, so this ground keeps the input's
## height exactly. 0 = the grid border only.
@export_range(0.0, 0.5, 0.005) var outlet_level: float = 0.1:
	set(v):
		outlet_level = clampf(v, 0.0, 0.5)
		_param_changed()

@export_group("Post-Processing")
## Channel bank smoothing, 0..0.5: a 4-neighbour blend at 0.4x this rate, once. Ignored when Post
## Smoothing is on.
@export_range(0.0, 0.5, 0.01) var bank_smoothing: float = 0.0:
	set(v):
		bank_smoothing = clampf(v, 0.0, 0.5)
		_param_changed()

## One fixed 4-neighbour smoothing pass at a 0.3 blend.
@export var enable_post_smoothing: bool = false:
	set(v):
		enable_post_smoothing = v
		_param_changed()


@export_group("Evaluation")

@export_tool_button("Bake Salève Erosion") var _bake_btn = clear_cache

# ---- Runtime freeze state ----


## Names this node's own Bake button, for the freeze warning.
func bake_label() -> String:
	return "Bake Salève Erosion"


func op() -> StringName:
	return &"hydraulic_saleve"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = float(iterations)
	p[1] = erosion_strength
	p[2] = drainage_exponent
	p[3] = drainage_noise
	p[4] = shape_preservation
	p[5] = bank_smoothing
	p[6] = deposition_radius
	p[7] = deposition_strength
	p[8] = stream_strength
	p[9] = stream_exp
	p[10] = tolerance
	p[11] = max_slope_center
	p[12] = max_slope_center if uniform_slope else max_slope_border
	p[13] = float(seed)
	p[14] = 1.0 if bool(enable_post_smoothing) else 0.0
	p[15] = reference_relief
	# The 16 slots are full; the S2 settings ride the LUT (read by the native op in this order).
	var ext := PackedFloat32Array([float(control_points), point_spacing, float(reconstruction),
			1.0 if default_warp else 0.0, warp_amount, warp_size, rim_width, outlet_level, channel_area, valley_smoothing,
			float(stage1_mode), uplift_gradient, uplift_n])
	return {"params": p, "lut": ext}


## The native freeze key: every grid the solve reads (surface, dx, dy, uplift, mask). No scalar port drives Salève,
## so there are no key scalars; a property edit is caught by the dirty-since-bake flag, as for every solver.
func freeze_key_grid_ports() -> PackedInt32Array:
	return PackedInt32Array([0, 1, 2, 3, 4])


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "Salève Hydraulic Erosion Smooth"


func needs_grid() -> bool:
	return true


# SIGNED, not FLOAT. `dx`/`dy` are read as GRIDS — `p_inputs[1] as PackedFloat32Array` in
# `eval_grid` below, handed straight to the solver as displacement fields — so declaring them
# FLOAT described them as one value per port when they are one value per CELL. The consequence
# was not cosmetic: a FLOAT port connects to nothing but another FLOAT, so these two could not be
# wired at all, and being fields they have no inline property either. They were inert sockets.
# SIGNED because a displacement is signed and zero is meaningful.
## The mask scales what the node does, cell by cell, inside the kernel; it is not a blend of the finished
## result over the input (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §9.3.1).
func mask_mode() -> MaskMode:
	return MaskMode.OWN


func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"in", PortType.HEIGHT).require(),
		Pasture3DGraphPort.field(&"dx", PortType.SIGNED),
		Pasture3DGraphPort.field(&"dy", PortType.SIGNED),
		# Before the mask, so the mask (appended by the framework) lands on port 4 and rides in_aux. Wires are
		# stored by port id, so a saved mask wire still finds it.
		Pasture3DGraphPort.field(&"uplift", PortType.MASK).unwired(1.0),
	]


func _outputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"height", PortType.HEIGHT),
		Pasture3DGraphPort.field(&"eroded_rock", PortType.FIELD),
		Pasture3DGraphPort.field(&"sediment", PortType.FIELD),
	]


## The channels the NATIVE op writes, which is now every channel this node offers.
##
## It used to answer 1, and the compiler then refused to lower any graph that read a channel above 0 --
## correctly, since serving zeros for a field nobody computed is the impostor of spec section 4.4. But the
## refusal is graph-wide: reading `eroded_rock` off this node dropped the whole graph, erosion and all, onto
## the GDScript evaluator. The solver had already computed the field and the op was discarding it.
func native_out_count() -> int:
	return 3 # height, eroded_rock, sediment


func _validate_property(p_property: Dictionary) -> void:
	if p_property.name in ["uplift_gradient", "uplift_n"] and stage1_mode != Stage1Mode.UPLIFT:
		p_property.usage = PROPERTY_USAGE_NO_EDITOR | PROPERTY_USAGE_STORAGE


func node_warnings() -> PackedStringArray:
	var w := super()
	if is_zero_approx(erosion_strength):
		w.append("%s: Erosion Strength is 0, so no erosion will occur." % display_name())
	return w


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var dx_in: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array) else PackedFloat32Array()
	var dy_in: PackedFloat32Array = (p_inputs[2] as PackedFloat32Array) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array) else PackedFloat32Array()
	var uplift_in: PackedFloat32Array = (p_inputs[3] as PackedFloat32Array) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array) else PackedFloat32Array()
	var mask_in: PackedFloat32Array = (p_inputs[4] as PackedFloat32Array) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array) else PackedFloat32Array()

	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	# Keyed through freeze_key, the recipe the native evaluator rebuilds, so a solve on either route is a hit
	# on the other. An unwired port is zeros in both keys.
	return solve_cached(freeze_key(p_inputs, p_gw, p_gh), func(): return _solve_dynamic(surface, p_gw, p_gh, p_rect, dx_in, dy_in, mask_in, uplift_in))


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


# ---- Internals -------------------------------------------------------------------------------------

func _param_changed() -> void:
	mark_dirty_since_bake()
	emit_changed()


func _solve_dynamic(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_dx: PackedFloat32Array, p_dy: PackedFloat32Array, p_mask: PackedFloat32Array, p_uplift := PackedFloat32Array()) -> Array:
	var n := p_gw * p_gh
	var params := {
		"iterations": iterations,
		"erosion_strength": erosion_strength,
		"drainage_exponent": drainage_exponent,
		"drainage_noise": drainage_noise,
		"shape_preservation": shape_preservation,
		"reference_relief": reference_relief,
		"bank_smoothing": bank_smoothing,
		"seed": seed,
		"control_points": control_points,
		"point_spacing": point_spacing,
		"reconstruction": int(reconstruction),
		"default_warp": default_warp,
		"warp_amount": warp_amount,
		"warp_size": warp_size,
		"dx": p_dx,
		"dy": p_dy,
		"mask": p_mask,
		"deposition_radius": deposition_radius,
		"deposition_strength": deposition_strength,
		"stream_strength": stream_strength,
		"stream_exp": stream_exp,
		"enable_post_smoothing": enable_post_smoothing,
		"tolerance": tolerance,
		"max_slope_center": max_slope_center,
		"max_slope_border": max_slope_center if uniform_slope else max_slope_border,
		"rim_width": rim_width,
		"outlet_level": outlet_level,
		"channel_area": channel_area,
		"valley_smoothing": valley_smoothing,
		"stage1_mode": int(stage1_mode),
		"uplift_gradient": uplift_gradient,
		"uplift_n": uplift_n,
		"uplift": p_uplift,
	}

	if not ClassDB.class_has_method("Pasture3DUtil", "hydraulic_saleve_solve_grid"):
		push_error("[Pasture3D] Pasture3DUtil.hydraulic_saleve_solve_grid is not bound. Rebuild GDExtension.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	var res: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(p_surface, p_gw, p_gh, p_rect, params)
	if not bool(res.get("ok", false)):
		push_error("[Pasture3D] Salève hydraulic native solve failed.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	return [
		res["height"] as PackedFloat32Array,
		res["eroded_rock"] as PackedFloat32Array,
		res["sediment"] as PackedFloat32Array,
	]
