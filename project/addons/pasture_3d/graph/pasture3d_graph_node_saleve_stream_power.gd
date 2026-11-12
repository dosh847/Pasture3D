# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeSaleveStreamPower — Salève Hydraulic Erosion: uplift and stream-power incision over the
# drainage network, integrated through time (PASTURE3D_SALEVE_STRATA_FIDELITY_SPEC.md, "Salève Hydraulic Erosion").
#
# The input is the initial surface. Every time step the ground rises by Uplift Rate x the `uplift` field, water is
# routed down the current surface (lakes spill at their lowest pass), and every vertex is cut toward its receiver
# by the stream-power law dz/dt = U - K A^m S^n, solved implicitly from the outlets upstream. Max Slope is the
# threshold hillslope. Outlets (the grid border and the low ground under Outlet Level) are base level and keep the
# input's height. Run long enough, the landscape reaches the steady state where every channel stands at
#     S = u^(1/n) x Uplift Gradient x (Channel Area / A)^(m/n),
# which is how K is set: Uplift Gradient is the slope a channel draining Channel Area keeps at full uplift.
#
# Salève Hydraulic Erosion Smooth (hydraulic_saleve) is the other Salève node: it incises the input in place,
# so the input stays the shape. This one lets the drainage network build its own relief.
#
# The solve is native (src/pasture_3d_hydraulic_saleve.cpp, saleve_stream_power_solve); the GDScript
# specification is the [Dev/GD] node, pasture3d_graph_node_dev_saleve_stream_power.gd.
#
# ---- Inputs ----
#   port 0   "in"       HEIGHT  initial surface (metres)
#   port 1/2 "dx"/"dy"  SIGNED  reconstruction warp in METRES (added to Default Warp's fBm, if on)
#   port 3   "uplift"   MASK    where, and how hard, ground rises (unwired = everywhere)
#   port 4   "mask"     MASK    scales the change cell by cell (rides the native in_aux grid)
#
# ---- Outputs ----
#   port 0  "height"         HEIGHT  the eroded surface (metres)
#   port 1  "eroded_rock"    FIELD   rock removed over the run, in metres (Float to Mask makes it a 0..1 mask)
#   port 2  "drainage_area"  FIELD   the area draining through each point of the final surface, in m²
@tool
class_name Pasture3DGraphNodeSaleveStreamPower
extends Pasture3DGraphSolverNode


@export_group("Uplift")
## How fast fully uplifted ground rises, in millimetres per year (times the `uplift` field, if wired).
@export_range(0.0, 20.0, 0.01, "or_greater", "suffix:mm/yr") var uplift_rate: float = 1.0:
	set(v):
		uplift_rate = maxf(v, 0.0)
		_param_changed()

## How long the landscape evolves, in thousands of years. 0 returns the input unchanged. Long enough, and
## the result stops depending on it: the steady state, where incision keeps pace with uplift everywhere.
@export_range(0.0, 10000.0, 1.0, "or_greater", "suffix:kyr") var duration: float = 500.0:
	set(v):
		duration = maxf(v, 0.0)
		_param_changed()

## Steps the duration is integrated in. Each step reroutes the water on the new surface, so more steps let the
## network reorganise more finely; every step is implicit, so few steps stay stable.
@export_range(1, 1000, 1, "or_greater") var time_steps: int = 100:
	set(v):
		time_steps = maxi(v, 1)
		_param_changed()

@export_group("Stream Power")
## The slope, in metres per kilometre, a fully uplifted channel draining Channel Area stands at once it reaches
## the steady state. Larger catchments stand gentler, by (Channel Area / area)^(m/n). It sets the erodibility,
## so it is a slope, not a height: a bigger area grows taller ranges, not a rescaled copy.
@export_range(0.0, 2000.0, 1.0, "or_greater", "suffix:m/km") var uplift_gradient: float = 300.0:
	set(v):
		uplift_gradient = maxf(v, 0.0)
		_param_changed()

## The drainage area Uplift Gradient is measured at, in square metres.
@export_range(1.0, 1000000.0, 1.0, "or_greater", "suffix:m²") var channel_area: float = 10000.0:
	set(v):
		channel_area = maxf(v, 1.0)
		_param_changed()

## The stream-power area exponent m in K A^m S^n. Channel slopes fall with area^(m/n) downstream, so higher
## values give gentler trunk valleys under steeper headwaters.
@export_range(0.05, 2.0, 0.01) var drainage_exponent: float = 0.5:
	set(v):
		drainage_exponent = clampf(v, 0.05, 2.0)
		_param_changed()

## The stream-power slope exponent n. Relief goes as uplift^(1/n): higher n evens the slopes out between
## channels and divides.
@export_range(0.5, 4.0, 0.05) var slope_exponent: float = 1.0:
	set(v):
		slope_exponent = clampf(v, 0.5, 4.0)
		_param_changed()

## The threshold hillslope, in metres per metre: no edge of the network stands steeper. Ground lowered to it
## counts as eroded rock. 0 flattens everything that is not draining.
@export_range(0.0, 20.0, 0.05, "or_greater", "suffix:m/m") var max_slope: float = 1.0:
	set(v):
		max_slope = maxf(v, 0.0)
		_param_changed()

## How much seeded noise bends the flow routing, 0..1, so valleys branch dendritically instead of following the
## steepest edge.
@export_range(0.0, 1.0, 0.01) var drainage_noise: float = 0.15:
	set(v):
		drainage_noise = clampf(v, 0.0, 1.0)
		_param_changed()

## Where the water leaves: every point within this fraction of the input's relief above its lowest point is an
## outlet, as well as the grid border. Outlets are base level: they never rise or erode, so this ground keeps
## the input's height exactly. 0 = the grid border only.
@export_range(0.0, 0.5, 0.005) var outlet_level: float = 0.1:
	set(v):
		outlet_level = clampf(v, 0.0, 0.5)
		_param_changed()

## How much of the change is applied, 0..1 (times the mask, if wired).
@export_range(0.0, 1.0, 0.01) var strength: float = 1.0:
	set(v):
		strength = clampf(v, 0.0, 1.0)
		_param_changed()

## Keeps the result at or above the input: the node only adds rock, never cuts below the ground it was given.
## Use it to raise a ridge over existing hills without carving valleys into them. eroded_rock still reports the
## rock the run removed from the uplifted ground.
@export var never_below_input: bool = false:
	set(v):
		never_below_input = v
		_param_changed()

## Seed for the drainage noise, the flat-breaking noise, the control-point jitter and the default warp.
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export_group("Control Points")
## How many control points the network is solved on. Ignored when Point Spacing is set. At most 100000.
@export_range(500, 100000, 100) var control_points: int = 15000:
	set(v):
		control_points = clampi(v, 16, 100000)
		_param_changed()

## Distance between control points, in metres. 0 derives it from Control Points over the solved area. The point
## lattice is anchored to the world, so a pinned spacing holds the network steady when the area grows. Past
## 100000 points the spacing widens to fit, with a warning.
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m") var point_spacing: float = 0.0:
	set(v):
		point_spacing = maxf(v, 0.0)
		_param_changed()

enum Reconstruction { LINEAR, GRADIENT }
## How the solved points become the grid. Gradient blends each point's tangent plane for smooth valley walls;
## Linear is flat within each triangle.
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

@export_group("Evaluation")

@export_tool_button("Bake Salève Erosion") var _bake_btn = clear_cache


func _init() -> void:
	super()


## Names this node's own Bake button, for the freeze warning.
func bake_label() -> String:
	return "Bake Salève Erosion"


func op() -> StringName:
	return &"saleve_stream_power"


## Slot layout, read by SaleveStreamPowerParams::from_slots: the 16 params, then [warp_amount, warp_size,
## never_below_input] on the LUT.
func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = float(time_steps)
	p[1] = strength
	p[2] = drainage_exponent
	p[3] = drainage_noise
	p[4] = uplift_rate
	p[5] = duration
	p[6] = uplift_gradient
	p[7] = slope_exponent
	p[8] = channel_area
	p[9] = max_slope
	p[10] = float(seed)
	p[11] = outlet_level
	p[12] = float(control_points)
	p[13] = point_spacing
	p[14] = float(reconstruction)
	p[15] = 1.0 if default_warp else 0.0
	return {"params": p, "lut": PackedFloat32Array([warp_amount, warp_size, 1.0 if never_below_input else 0.0])}


## The native freeze key: every grid the solve reads (surface, dx, dy, uplift, mask).
func freeze_key_grid_ports() -> PackedInt32Array:
	return PackedInt32Array([0, 1, 2, 3, 4])


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "Salève Hydraulic Erosion"


func needs_grid() -> bool:
	return true


## The mask scales what the node does, cell by cell, inside the kernel (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md
## §9.3.1).
func mask_mode() -> MaskMode:
	return MaskMode.OWN


func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"in", PortType.HEIGHT).require(),
		Pasture3DGraphPort.field(&"dx", PortType.SIGNED),
		Pasture3DGraphPort.field(&"dy", PortType.SIGNED),
		# Before the mask, so the mask (appended by the framework) lands on port 4 and rides in_aux.
		Pasture3DGraphPort.field(&"uplift", PortType.MASK).unwired(1.0),
	]


func _outputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"height", PortType.HEIGHT),
		Pasture3DGraphPort.field(&"eroded_rock", PortType.FIELD),
		Pasture3DGraphPort.field(&"drainage_area", PortType.FIELD),
	]


func native_out_count() -> int:
	return 3 # height, eroded_rock, drainage_area


func node_warnings() -> PackedStringArray:
	var w := super()
	if is_zero_approx(strength):
		w.append("%s: Strength is 0, so the input passes through unchanged." % display_name())
	if is_zero_approx(duration) or is_zero_approx(uplift_rate):
		w.append("%s: Duration or Uplift Rate is 0, so the input passes through unchanged." % display_name())
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
	# Keyed through freeze_key, the recipe the native evaluator rebuilds, so a solve on either route is a hit on the
	# other.
	return solve_cached(freeze_key(p_inputs, p_gw, p_gh), func(): return _solve(surface, p_gw, p_gh, p_rect, dx_in, dy_in, uplift_in, mask_in))


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


# ---- Internals -------------------------------------------------------------------------------------

func _param_changed() -> void:
	mark_dirty_since_bake()
	emit_changed()


func _solve(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_dx: PackedFloat32Array,
		p_dy: PackedFloat32Array, p_uplift: PackedFloat32Array, p_mask: PackedFloat32Array) -> Array:
	var n := p_gw * p_gh
	var params := {
		"uplift_rate": uplift_rate,
		"duration": duration,
		"time_steps": time_steps,
		"uplift_gradient": uplift_gradient,
		"channel_area": channel_area,
		"drainage_exponent": drainage_exponent,
		"slope_exponent": slope_exponent,
		"max_slope": max_slope,
		"drainage_noise": drainage_noise,
		"outlet_level": outlet_level,
		"strength": strength,
		"never_below_input": never_below_input,
		"seed": seed,
		"control_points": control_points,
		"point_spacing": point_spacing,
		"reconstruction": int(reconstruction),
		"default_warp": default_warp,
		"warp_amount": warp_amount,
		"warp_size": warp_size,
		"dx": p_dx,
		"dy": p_dy,
		"uplift": p_uplift,
		"mask": p_mask,
	}
	if not ClassDB.class_has_method("Pasture3DUtil", "saleve_stream_power_solve_grid"):
		push_error("[Pasture3D] Pasture3DUtil.saleve_stream_power_solve_grid is not bound. Rebuild GDExtension.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]
	var res: Dictionary = Pasture3DUtil.saleve_stream_power_solve_grid(p_surface, p_gw, p_gh, p_rect, params)
	if not bool(res.get("ok", false)):
		push_error("[Pasture3D] Salève Hydraulic Erosion native solve failed.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]
	return [
		res["height"] as PackedFloat32Array,
		res["eroded_rock"] as PackedFloat32Array,
		res["drainage_area"] as PackedFloat32Array,
	]
