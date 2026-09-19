# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeHydraulicSaleve — Salève Structural Large-Scale Hydraulic Erosion SOLVER.
# Implements large-scale dendritic drainage routing with noise perturbation, secondary micro-rill flow,
# mountain shape preservation, and transverse channel bank diffusion.
#
# The drainage network is solved on jittered control points (Delaunay-triangulated) and reconstructed onto
# the grid, as Hesiod does; see PASTURE3D_SALEVE_STRATA_FIDELITY_SPEC.md phases S1-S2.
#
# ---- Inputs ----
#   port 1/2 "dx"/"dy"  SIGNED  reconstruction warp in METRES (added to Default Warp's fBm, if on)
#   port 3   "mask"     MASK    blend of the eroded result over the input
#
# ---- Outputs ----
#   port 0  "height"       HEIGHT  eroded surface elevation (metres)
#   port 1  "eroded_rock"  MASK    cumulative bedrock incision intensity
#   port 2  "sediment"     MASK    alluvial sediment deposition thickness
@tool
class_name Pasture3DGraphNodeHydraulicSaleve
extends Pasture3DGraphSolverNode


@export_group("Simulation")
## Upper bound on drainage passes. The solve stops as soon as it converges below Tolerance, so this is a
## ceiling, not a cost.
@export_range(1, 1000, 1, "or_greater") var iterations: int = 200:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

## Convergence threshold: mean height change per pass, as a fraction of the current relief.
@export_range(0.0, 0.01, 0.0001) var tolerance: float = 1.0e-3:
	set(v):
		tolerance = maxf(v, 0.0)
		_param_changed()

## Large-scale drainage erosion strength.
@export_range(0.0, 1.0, 0.01) var erosion_strength: float = 0.7:
	set(v):
		erosion_strength = clampf(v, 0.0, 1.0)
		_param_changed()

## Catchment drainage exponent for stream power scaling.
@export_range(0.01, 0.8, 0.01) var drainage_exponent: float = 0.15:
	set(v):
		drainage_exponent = clampf(v, 0.01, 0.8)
		_param_changed()

## Coherent noise strength perturbing drainage flow routing to create natural dendritic branching.
@export_range(0.0, 1.0, 0.01) var drainage_noise: float = 0.15:
	set(v):
		drainage_noise = maxf(v, 0.0)
		_param_changed()

## Mountain shape preservation strength; preserves macroscopic mountain silhouette.
@export_range(0.05, 4.0, 0.05) var shape_preservation: float = 2.0:
	set(v):
		shape_preservation = clampf(v, 0.05, 4.0)
		_param_changed()

## The vertical scale, in metres, every length in the solver is measured against — set it and the drainage
## network becomes a property of the TERRAIN rather than of the grid it is solved on. 0 takes it from the
## input's own relief, which moves whenever the solved extent does: a brush's Modifier Margin brings the
## surrounding ground into range without moving one vertex of the shape, and the pattern rescales. Pin it
## to roughly the relief you are eroding (a 90 m mound → 90) to hold a shape steady across margins,
## footprint edits and re-bakes.
@export_range(0.0, 500.0, 1.0, "or_greater", "suffix:m") var reference_relief: float = 0.0:
	set(v):
		reference_relief = maxf(v, 0.0)
		_param_changed()

## Transverse river channel bank smoothing rate [0.0..0.5].
@export_range(0.0, 0.5, 0.01) var bank_smoothing: float = 0.0:
	set(v):
		bank_smoothing = clampf(v, 0.0, 0.5)
		_param_changed()

## Steepest slope (m/m) the drainage solve allows at the centre of the domain. It falls along a smooth
## radial pulse to Max Slope Border at a distance of the smaller domain side.
@export_range(0.0, 20.0, 0.1, "or_greater") var max_slope_center: float = 6.0:
	set(v):
		max_slope_center = maxf(v, 0.0)
		_param_changed()

## Steepest slope (m/m) allowed toward the domain border.
@export_range(0.0, 20.0, 0.1, "or_greater") var max_slope_border: float = 0.0:
	set(v):
		max_slope_border = maxf(v, 0.0)
		_param_changed()

## Use Max Slope Center everywhere, with no radial falloff.
@export var uniform_slope: bool = false:
	set(v):
		uniform_slope = v
		_param_changed()

## Noise seed for drainage branch perturbation.
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export_group("Control Points")
## How many control points the drainage network is solved on. Channels are about one point apart, so
## more points give finer valleys. Ignored when Point Spacing is set.
@export_range(500, 100000, 100, "or_greater") var control_points: int = 15000:
	set(v):
		control_points = clampi(v, 16, 1000000)
		_param_changed()

## Distance between control points, in metres. 0 derives it from Control Points over the solved area,
## which moves when the area does (a Modifier Margin). Set it to hold the network steady across margins:
## the point lattice is anchored to the world, so a wider area adds points without moving any.
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

@export_group("Sediment Deposition (Stage 2)")
## Alluvial depression hole filling radius, in METRES. It was a fraction of the grid's smaller dimension,
## so the flats grew whenever the solved extent did; it is now a size on the ground.
@export_range(0.0, 200.0, 0.5, "or_greater", "suffix:m") var deposition_radius: float = 25.0:
	set(v):
		deposition_radius = maxf(v, 0.0)
		_param_changed()

## Alluvial sediment deposition strength.
@export_range(0.0, 1.0, 0.01) var deposition_strength: float = 0.5:
	set(v):
		deposition_strength = clampf(v, 0.0, 1.0)
		_param_changed()

@export_group("Fine River Incision (Stage 3)")
## Secondary fine dendritic rill erosion strength.
@export_range(0.0, 1.0, 0.005) var stream_strength: float = 0.02:
	set(v):
		stream_strength = clampf(v, 0.0, 1.0)
		_param_changed()

## Secondary stream influence exponent.
@export_range(0.01, 1.0, 0.01) var stream_exp: float = 0.8:
	set(v):
		stream_exp = clampf(v, 0.01, 1.0)
		_param_changed()

@export_group("Post-Processing (Stage 4)")
## Enable spatial post-smoothing.
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
			1.0 if default_warp else 0.0, warp_amount, warp_size])
	return {"params": p, "lut": ext}


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "Salève Hydraulic Erosion"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "dx", "dy", "mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		# SIGNED, not FLOAT. `dx`/`dy` are read as GRIDS — `p_inputs[1] as PackedFloat32Array` in
		# `eval_grid` below, handed straight to the solver as displacement fields — so declaring them
		# FLOAT described them as one value per port when they are one value per CELL. The consequence
		# was not cosmetic: a FLOAT port connects to nothing but another FLOAT, so these two could not be
		# wired at all, and being fields they have no inline property either. They were inert sockets.
		# SIGNED because a displacement is signed and zero is meaningful.
		PortType.SIGNED,
		PortType.SIGNED,
		PortType.MASK,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return 0.0
		2: return 0.0
		3: return 1.0
		_: return 0.0


func output_count() -> int:
	return 3


## The channels the NATIVE op writes, which is now every channel this node offers.
##
## It used to answer 1, and the compiler then refused to lower any graph that read a channel above 0 --
## correctly, since serving zeros for a field nobody computed is the impostor of spec section 4.4. But the
## refusal is graph-wide: reading `eroded_rock` off this node dropped the whole graph, erosion and all, onto
## the GDScript evaluator. The solver had already computed the field and the op was discarding it.
func native_out_count() -> int:
	return 3 # height, eroded_rock, sediment


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "eroded_rock", "sediment"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.FIELD, PortType.FIELD])


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
	var mask_in: PackedFloat32Array = (p_inputs[3] as PackedFloat32Array) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array) else PackedFloat32Array()

	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	return solve_cached(solver_cache_key(p_gw, p_gh, [surface, dx_in, dy_in, mask_in]), func(): return _solve_dynamic(surface, p_gw, p_gh, p_rect, dx_in, dy_in, mask_in))


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


# ---- Internals -------------------------------------------------------------------------------------

func _param_changed() -> void:
	mark_dirty_since_bake()
	emit_changed()


func _solve_dynamic(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_dx: PackedFloat32Array, p_dy: PackedFloat32Array, p_mask: PackedFloat32Array) -> Array:
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
