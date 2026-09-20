# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeHydraulicParticle — a LAGRANGIAN droplet hydraulic erosion SOLVER.
# Casts thousands of virtual water droplets across the terrain that gather momentum, carve channels along
# gradients, transport sediment, and deposit alluvial fans.
#
# ---- Outputs ----
#   port 0  "height"       HEIGHT  eroded surface elevation (metres)
#   port 1  "eroded"       FIELD   metres cut from the input surface, net (max(0, input - height))
#   port 2  "deposited"    FIELD   metres laid on the input surface, net (max(0, height - input))
#   port 3  "flow"         FIELD   droplet path length per unit area at unit droplet density (metres)
#
# `eroded` and `deposited` describe the FINAL surface, not what passed through: a deposit later cut away
# shows in neither. They are metres, not 0..1 -- put a Float to Mask after them for a mask.
@tool
class_name Pasture3DGraphNodeHydraulicParticle
extends Pasture3DGraphSolverNode


enum Units { CELLS, METRIC }

@export_group("Simulation")
## CELLS: a droplet step, its slope and its lifetime are measured in grid cells, so the same terrain at
## another resolution (or with a wider brush margin) erodes differently. The original behaviour.
## METRIC: steps are Step Length metres, slopes are metres per metre, and droplets are placed per area
## (Droplet Density), so the result holds across resolutions once a cell is at most half a step.
@export var units: Units = Units.CELLS:
	set(v):
		units = v
		_param_changed()
		notify_property_list_changed()

## Total number of raindrops / particles simulated across the terrain footprint. CELLS only; METRIC uses
## Droplet Density.
@export_range(1000, 200000, 1000, "or_greater") var droplet_count: int = 25000:
	set(v):
		droplet_count = maxi(v, 1)
		_param_changed()

## Maximum lifetime / steps a single droplet can travel before terminating.
@export_range(5, 100, 1) var max_lifetime: int = 30:
	set(v):
		max_lifetime = maxi(v, 1)
		_param_changed()

## Droplet momentum weight [0.0..1.0]. Higher inertia causes droplets to overshoot turns and follow valley lines.
@export_range(0.0, 1.0, 0.01) var inertia: float = 0.05:
	set(v):
		inertia = clampf(v, 0.0, 1.0)
		_param_changed()

## Multiplier for the amount of sediment water can carry per unit of velocity and slope.
@export_range(0.1, 20.0, 0.1, "or_greater") var sediment_capacity: float = 4.0:
	set(v):
		sediment_capacity = maxf(v, 0.0)
		_param_changed()

## Rate at which soil/bedrock dissolves into the water droplet when below sediment capacity [0.0..1.0].
@export_range(0.0, 1.0, 0.01) var erosion_speed: float = 0.3:
	set(v):
		erosion_speed = clampf(v, 0.0, 1.0)
		_param_changed()

## Rate at which excess sediment is deposited onto the terrain when above capacity [0.0..1.0].
@export_range(0.0, 1.0, 0.01) var deposition_speed: float = 0.3:
	set(v):
		deposition_speed = clampf(v, 0.0, 1.0)
		_param_changed()

## Fraction of water volume that evaporates per droplet step [0.0..1.0].
@export_range(0.0, 0.5, 0.005) var evaporation_rate: float = 0.01:
	set(v):
		evaporation_rate = clampf(v, 0.0, 1.0)
		_param_changed()

## Minimum slope gradient used for sediment capacity calculation.
@export_range(0.001, 0.2, 0.005) var min_slope: float = 0.01:
	set(v):
		min_slope = maxf(v, 0.0001)
		_param_changed()

## Gravitational acceleration constant scaling downhill speed.
@export_range(0.5, 20.0, 0.5) var gravity: float = 4.0:
	set(v):
		gravity = maxf(v, 0.1)
		_param_changed()

## Absolute floor on the cut, in metres below the **input** surface: no cell may finish more than
## `bedrock_gap` below where it started. **0 disables it**, which is the default.
##
## It defaults off because it does not scale. A fixed 2 m was 5% of a 40 m mound and 0.25% of an 800 m
## one, so on anything large it stopped being a safety rail and became the shape: measured at the old
## default, 49.8% of eroding cells on a 400 m world were pinned at the cap, 80.6% at 2 km and 92.1% at
## 8 km. A solver saturated against a constant is not eroding, and it reads as resolution-invariant
## because the constant, not the physics, is setting the depth. Set it per-brush against that brush's
## relief when you actually want a floor.
@export_range(0.0, 200.0, 0.5, "or_greater") var bedrock_gap: float = 0.0:
	set(v):
		bedrock_gap = maxf(v, 0.0)
		_param_changed()

## Ridge forcing cross-gradient strength to organize droplets into dendritic tributary trees.
@export_range(0.0, 2.0, 0.05) var ridge_forcing: float = 0.0:
	set(v):
		ridge_forcing = maxf(v, 0.0)
		_param_changed()

## Erosion brush radius in metres (Beyer): the cut is spread over every cell within it, weighted toward
## the droplet, instead of the four cells around it. 0 keeps the four-corner cut, which pits. METRIC never
## uses less than one Step Length.
@export_range(0.0, 20.0, 0.1, "or_greater", "suffix:m") var radius_m: float = 0.0:
	set(v):
		radius_m = maxf(v, 0.0)
		_param_changed()

## METRIC: the length of one droplet step. Lifetime is in steps, so a droplet travels up to
## Max Lifetime x Step Length metres.
@export_range(0.1, 20.0, 0.1, "or_greater", "suffix:m") var step_length_m: float = 1.0:
	set(v):
		step_length_m = maxf(v, 0.01)
		_param_changed()

## METRIC: droplets per 100 m² of the footprint.
@export_range(0.1, 200.0, 0.1, "or_greater") var droplet_density: float = 40.0:
	set(v):
		droplet_density = maxf(v, 0.0)
		_param_changed()

## Deterministic random seed for particle distribution.
@export var seed: int = 1337:
	set(v):
		seed = v
		_param_changed()


## A droplet that dies still carrying sediment -- out of lifetime, an edge ahead, or stuck in a pit --
## drops it where it stands instead of losing it, so the solve moves no mass off the terrain (except
## where the mask scales it down). Off by default: the original solver discarded it, and turning this on
## raises the ends of channels and the floors of pits.
@export var deposit_at_death: bool = false:
	set(v):
		deposit_at_death = v
		_param_changed()


@export_group("Evaluation")

@export_tool_button("Bake Particle Erosion") var _bake_btn = clear_cache

# ---- Runtime freeze state ----


## Names this node's own Bake button, for the freeze warning.
func bake_label() -> String:
	return "Bake Particle Erosion"


func op() -> StringName:
	return &"hydraulic_particle"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = float(droplet_count)
	p[1] = float(max_lifetime)
	p[2] = inertia
	p[3] = sediment_capacity
	p[4] = erosion_speed
	p[5] = deposition_speed
	p[6] = evaporation_rate
	p[7] = min_slope
	p[8] = gravity
	# Two 16-bit halves of the seed's low 32 bits: a float32 slot is exact only to 2^24, so one slot
	# rounded large seeds and the graph solved a different seed than this node's own route.
	p[9] = float(seed & 0xFFFF)
	p[10] = bedrock_gap
	p[11] = ridge_forcing
	p[12] = float((seed >> 16) & 0xFFFF)
	p[13] = float(units)
	p[14] = radius_m
	p[15] = step_length_m
	# The 16 slots are full; droplet_density rides the LUT.
	return {"params": p, "lut": PackedFloat32Array([droplet_density, 1.0 if deposit_at_death else 0.0])}


func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1, -1, 0, 4, 5])


## The native freeze key: the surface and the mask grids (an unwired mask hashes as its 1.0 default, via
## key_defaults), plus the three drivable scalars. A mask or a wired Const moving now stales the solve.
func freeze_key_grid_ports() -> PackedInt32Array:
	return PackedInt32Array([0, 1])


func freeze_key_scalar_ports() -> PackedInt32Array:
	return PackedInt32Array([2, 3, 4])


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "Particle Hydraulic Erosion"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 5


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "mask", "droplets", "erosion_speed", "deposition_speed"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.MASK,
		PortType.INT,
		PortType.FLOAT,
		PortType.FLOAT,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return 1.0
		2: return float(droplet_count)
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


func _validate_property(p_property: Dictionary) -> void:
	var metric_only := [&"step_length_m", &"droplet_density"]
	if p_property.name in metric_only and units != Units.METRIC:
		p_property.usage = PROPERTY_USAGE_NO_EDITOR | PROPERTY_USAGE_STORAGE
	elif p_property.name == &"droplet_count" and units == Units.METRIC:
		p_property.usage = PROPERTY_USAGE_NO_EDITOR | PROPERTY_USAGE_STORAGE


func node_warnings() -> PackedStringArray:
	var w := super()
	if droplet_count <= 0 or is_zero_approx(erosion_speed):
		w.append("%s: Droplet Count or Erosion Speed is 0, so no erosion will occur." % display_name())
	return w


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var mask_in: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array) else PackedFloat32Array()
	var d_count: int = int(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else droplet_count
	var es: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else erosion_speed
	var ds: float = float(p_inputs[4][0]) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array and p_inputs[4].size() > 0) else deposition_speed

	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	return solve_cached(freeze_key(p_inputs, p_gw, p_gh), func(): return _solve_dynamic(surface, p_gw, p_gh, p_rect, d_count, es, ds, mask_in))


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


# ---- Internals -------------------------------------------------------------------------------------

func _param_changed() -> void:
	mark_dirty_since_bake()
	emit_changed()


static func _f32(p_value: float) -> float:
	return PackedFloat32Array([p_value])[0]


func _solve_dynamic(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_droplets: int, p_es: float, p_ds: float, p_mask: PackedFloat32Array) -> Array:
	var n := p_gw * p_gh
	# Every real parameter goes through float32, because that is what the graph program carries and the
	# solver now keeps doubles: without the round trip this route and the native route solve with values
	# ~1e-9 apart, and the droplets amplify that into metres.
	var params := {
		"droplet_count": p_droplets,
		"max_lifetime": max_lifetime,
		"inertia": _f32(inertia),
		"sediment_capacity": _f32(sediment_capacity),
		"erosion_speed": _f32(p_es),
		"deposition_speed": _f32(p_ds),
		"evaporation_rate": _f32(evaporation_rate),
		"min_slope": _f32(min_slope),
		"gravity": _f32(gravity),
		"bedrock_gap": _f32(bedrock_gap),
		"ridge_forcing": _f32(ridge_forcing),
		"seed": seed,
		"units": int(units),
		"radius_m": _f32(radius_m),
		"step_length_m": _f32(step_length_m),
		"deposit_at_death": deposit_at_death,
		"droplet_density": _f32(droplet_density),
		"mask": p_mask,
	}

	if not ClassDB.class_has_method("Pasture3DUtil", "hydraulic_particle_solve_grid"):
		push_error("[Pasture3D] Pasture3DUtil.hydraulic_particle_solve_grid is not bound. Rebuild GDExtension.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	var res: Dictionary = Pasture3DUtil.hydraulic_particle_solve_grid(p_surface, p_gw, p_gh, p_rect, params)
	if not bool(res.get("ok", false)):
		push_error("[Pasture3D] Hydraulic particle native solve failed.")
		return [p_surface.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	return [
		res["height"] as PackedFloat32Array,
		res["eroded"] as PackedFloat32Array,
		res["deposited"] as PackedFloat32Array,
		res["flow"] as PackedFloat32Array,
	]
