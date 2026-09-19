# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeErosionHydraulic — a GRID hydraulic erosion SOLVER/filter, in two models.
# Both simulate continuous rainfall, slope-limited sediment capacity, erosion pickup, transport, deposition
# and evaporation over an elevation heightfield. They differ in how the water moves:
#
#   MUSGRAVE  each pass shares a cell's water and load among its lower 4-neighbours in proportion to the
#             drop. Cheap, and the only model the GPU runs. Its behaviour depends on the grid: the same
#             world at another resolution erodes differently.
#   PIPE      a virtual-pipe shallow-water model (Mei, Decaudin & Hu 2007) with momentum and substepping,
#             in metres and seconds, so it holds across resolutions. CPU only; its sediment capacity is on
#             a different scale to MUSGRAVE's, so a Kc tuned for one is wrong for the other.
#
# ---- Outputs ----
#   port 0  "height"     HEIGHT  eroded surface elevation (metres)
#   port 1  "eroded"     FIELD   metres cut from the input surface, net (max(0, input - height))
#   port 2  "deposited"  FIELD   metres laid on the input surface, net (max(0, height - input))
#   port 3  "flow"       FIELD   MUSGRAVE: contributing area (m^2). PIPE: mean discharge (m^3/s).
#
# `eroded` and `deposited` describe the FINAL surface, not the suspended load: a deposit later cut away
# shows in neither. Nothing here is normalised -- put a Float to Mask after it for a mask.
@tool
class_name Pasture3DGraphNodeErosionHydraulic
extends Pasture3DGraphSolverNode


@export_group("Simulation")
## Number of simulation passes. More iterations deepen channels and carve drainage networks.
@export_range(1, 100, 1, "or_greater") var iterations: int = 25:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

## Amount of rain water added per cell on each iteration pass. Higher rain rate produces stronger flow accumulation.
@export_range(0.001, 0.5, 0.005, "or_greater") var rain_rate: float = 0.05:
	set(v):
		rain_rate = maxf(v, 0.0)
		_param_changed()

## Fraction of water that evaporates per pass [0.0..1.0].
@export_range(0.0, 1.0, 0.005) var evaporation_rate: float = 0.02:
	set(v):
		evaporation_rate = clampf(v, 0.0, 1.0)
		_param_changed()

## Maximum sediment that water can carry per unit of flow velocity and slope.
@export_range(0.1, 50.0, 0.5, "or_greater") var sediment_capacity: float = 8.0:
	set(v):
		sediment_capacity = maxf(v, 0.0)
		_param_changed()

## Rate at which soil/rock is dissolved into flowing water when sediment is below capacity [0.0..1.0].
@export_range(0.0, 1.0, 0.01) var erosion_speed: float = 0.5:
	set(v):
		erosion_speed = clampf(v, 0.0, 1.0)
		_param_changed()

## Rate at which excess sediment drops out of water and settles when above capacity [0.0..1.0].
@export_range(0.0, 1.0, 0.01) var deposition_speed: float = 0.4:
	set(v):
		deposition_speed = clampf(v, 0.0, 1.0)
		_param_changed()

## Minimum slope gradient used for sediment capacity to maintain transport across shallow beds.
@export_range(0.0, 0.5, 0.005) var min_slope: float = 0.01:
	set(v):
		min_slope = maxf(v, 0.0)
		_param_changed()


## WALLS: the grid edge and no-data cells hold water in, so it ponds and drops its sediment along them.
## The original behaviour. OUTLETS: water reaching them drains away, as into terrain beyond the grid that
## sits Outlet Level below the rim. Only the rim changes: the interior is identical to WALLS until the
## drainage it feeds reaches it, one cell per iteration.
@export_enum("Walls", "Outlets") var edge_mode: int = 0:
	set(v):
		edge_mode = clampi(v, 0, 1)
		_param_changed()

## OUTLETS: the base level, in metres below the rim cell's INPUT ground. Water drains to it and the rim can
## erode down to it, no further. 0 lets water spill off at the rim's own level.
@export_range(0.0, 10.0, 0.05, "or_greater", "suffix:m") var outlet_level: float = 0.0:
	set(v):
		outlet_level = maxf(v, 0.0)
		_param_changed()

## MUSGRAVE: the original model -- each pass routes water one cell downhill, in grid steps, so the same
## world at another resolution erodes differently. PIPE: Mei et al. 2007's virtual-pipe shallow water, in
## metres and seconds, which converges as the resolution rises. Under PIPE each iteration simulates Time
## Step seconds, Erosion and Deposition Speed are per second, and Sediment Capacity is far smaller (try
## 0.05-0.5): it scales tilt x speed x depth rather than the Musgrave capacity term.
@export_enum("Musgrave", "Pipe") var model: int = 0:
	set(v):
		model = clampi(v, 0, 1)
		_param_changed()
		notify_property_list_changed()

## PIPE: seconds of simulated time per iteration. Substepped internally for stability, so a large value is
## safe, only slower.
@export_range(0.01, 5.0, 0.01, "or_greater", "suffix:s") var time_step: float = 0.5:
	set(v):
		time_step = maxf(v, 1e-3)
		_param_changed()


## Lay whatever sediment is still suspended when the last pass ends onto the ground, instead of deleting
## it, so the solve moves no material off the terrain. Off by default: the original solver dropped it, and
## settling raises channel floors and the basins where water pooled.
@export var settle_at_end: bool = false:
	set(v):
		settle_at_end = v
		_param_changed()


@export_group("Evaluation")

@export_tool_button("Bake Hydraulic Erosion") var _bake_btn = clear_cache

# ---- Runtime freeze state ----


## Names this node's own Bake button, for the freeze warning.
func bake_label() -> String:
	return "Bake Hydraulic Erosion"


func op() -> StringName:
	return &"erosion_hydraulic"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = float(iterations)
	p[1] = rain_rate
	p[2] = evaporation_rate
	p[3] = sediment_capacity
	p[4] = erosion_speed
	p[5] = deposition_speed
	p[6] = min_slope
	p[7] = float(edge_mode)
	p[8] = outlet_level
	p[9] = float(model)
	p[10] = time_step
	p[11] = 1.0 if settle_at_end else 0.0
	return {"params": p}


func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1, 0, 1, 4, 5])


func freeze_key_grid_ports() -> PackedInt32Array:
	return PackedInt32Array([0])


func freeze_key_scalar_ports() -> PackedInt32Array:
	return PackedInt32Array([1, 2, 3, 4])


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 5


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "iterations", "rain_rate", "erosion_speed", "deposition_speed"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.INT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.FLOAT,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return float(iterations)
		2: return rain_rate
		3: return erosion_speed
		4: return deposition_speed
		_: return 0.0


func output_count() -> int:
	return 4


## The channels the NATIVE op writes, which is now every channel this node offers.
##
## It used to answer 1, and the compiler then refused to lower any graph that read a channel above 0 --
## correctly, since serving zeros for a field nobody computed is the impostor of spec section 4.4. But the
## refusal is graph-wide: reading `sediment` off this node dropped the whole graph, erosion and all, onto
## the GDScript evaluator. The solver had already computed the field and the op was discarding it.
func native_out_count() -> int:
	return 4 # height, eroded, deposited, flow


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "eroded", "deposited", "flow"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.FIELD, PortType.FIELD, PortType.FIELD])


func node_warnings() -> PackedStringArray:
	var w := super()
	if is_zero_approx(rain_rate) or is_zero_approx(erosion_speed):
		w.append("%s: Rain Rate or Erosion Speed is 0, so no erosion will occur." % display_name())
	return w


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var iters: int = int(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else iterations
	var rr: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else rain_rate
	var es: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else erosion_speed
	var ds: float = float(p_inputs[4][0]) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array and p_inputs[4].size() > 0) else deposition_speed

	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	return solve_cached(freeze_key(p_inputs, p_gw, p_gh), func(): return _solve_dynamic(surface, p_gw, p_gh, p_rect, iters, rr, es, ds))


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


# ---- Internals -------------------------------------------------------------------------------------

func _validate_property(p_property: Dictionary) -> void:
	if p_property.name == "time_step" and model != 1:
		p_property.usage = PROPERTY_USAGE_NO_EDITOR


func _param_changed() -> void:
	mark_dirty_since_bake()
	emit_changed()


static func _f32(p_value: float) -> float:
	return PackedFloat32Array([p_value])[0]


func _solve_dynamic(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_iters: int, p_rr: float, p_es: float, p_ds: float) -> Array:
	var n := p_gw * p_gh
	# Every real parameter goes through float32, as the graph program carries it, so this route and the
	# native route solve the same numbers. Before this they were ~1e-9 apart and the solver's
	# erode-or-deposit branch made that 0.06 m by 25 iterations (GraphAuxChannelGate's measured gap).
	var params := {
		"iterations": p_iters,
		"rain_rate": _f32(p_rr),
		"evaporation_rate": _f32(evaporation_rate),
		"sediment_capacity": _f32(sediment_capacity),
		"erosion_speed": _f32(p_es),
		"deposition_speed": _f32(p_ds),
		"min_slope": _f32(min_slope),
		"edge_mode": edge_mode,
		"outlet_level": _f32(outlet_level),
		"model": model,
		"time_step": _f32(time_step),
		"settle_at_end": settle_at_end,
	}
	if not ClassDB.class_has_method("Pasture3DUtil", "erosion_hydraulic_solve_grid_best"):
		push_error("[Pasture3D] Pasture3DUtil.erosion_hydraulic_solve_grid_best is not bound. Rebuild GDExtension.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	var res: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid_best(p_surface, p_gw, p_gh, p_rect, params)
	if not bool(res.get("ok", false)):
		push_error("[Pasture3D] Hydraulic erosion native solve failed.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	return [res["height"], res["eroded"], res["deposited"], res["flow"]]
