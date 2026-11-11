# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeShoreCharacter — where a coast would be cliffed and where it would be a beach. Bays,
# sheltered water and low hinterland read as beach; headlands, exposed water and high ground as cliff. The
# signals, their formulas and the known limits are in src/pasture_3d_shore_character.h; the maths is C++
# only and reuses the shared box mean and fractal noise.
#
# Intended wiring: feed `height` from a Coast Profile with its cliff port unwired, and `exposure` from Wave
# Exposure on that same height. Wire `cliff` (combined with any hand-drawn beach mask) into a second Coast
# Profile's cliff port, and `erosion` into Coastal Erosion's exposure port. Port 0 is a MASK, so the
# framework adds no standard mask.
@tool
class_name Pasture3DGraphNodeShoreCharacter
extends Pasture3DGraphNode

## Height below which a cell is water, metres. Also a value port.
@export var sea_level: float = 0.0:
	set(v):
		sea_level = v
		_param_changed()
## Variation seed for the hardness noise.
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export_group("Shape")
## Window for big bays and headlands, metres.
@export_range(0.0, 3000.0, 1.0, "or_greater") var bay_radius: float = 300.0:
	set(v):
		bay_radius = maxf(v, 0.0)
		_param_changed()
## Window for small coves and points, metres.
@export_range(0.0, 1000.0, 1.0, "or_greater") var cove_radius: float = 60.0:
	set(v):
		cove_radius = maxf(v, 0.0)
		_param_changed()

@export_group("Weights")
## How much coast shape counts (headland = cliff, bay = beach).
@export_range(0.0, 4.0, 0.01, "or_greater") var shape_weight: float = 1.0:
	set(v):
		shape_weight = maxf(v, 0.0)
		_param_changed()
## How much exposure counts (exposed = cliff).
@export_range(0.0, 4.0, 0.01, "or_greater") var exposure_weight: float = 0.7:
	set(v):
		exposure_weight = maxf(v, 0.0)
		_param_changed()
## How much the hinterland's height counts (high = cliff).
@export_range(0.0, 4.0, 0.01, "or_greater") var backshore_weight: float = 0.5:
	set(v):
		backshore_weight = maxf(v, 0.0)
		_param_changed()
## Window the hinterland height is averaged over, metres.
@export_range(0.0, 1000.0, 1.0, "or_greater") var backshore_dist: float = 80.0:
	set(v):
		backshore_dist = maxf(v, 0.0)
		_param_changed()
## Mean hinterland height above sea that reads as fully cliff, metres.
@export_range(0.1, 500.0, 0.5, "or_greater") var backshore_height: float = 40.0:
	set(v):
		backshore_height = maxf(v, 0.001)
		_param_changed()
## Weighted score above which the coast turns to cliff, 0..1.
@export_range(0.0, 1.0, 0.01) var threshold: float = 0.5:
	set(v):
		threshold = clampf(v, 0.0, 1.0)
		_param_changed()
## Width of the cliff/beach transition in score units. Small = hard switch.
@export_range(0.001, 1.0, 0.01) var softness: float = 0.2:
	set(v):
		softness = maxf(v, 0.001)
		_param_changed()

@export_group("Hardness")
## Wavelength of the rock-hardness noise along the coast, metres.
@export_range(1.0, 5000.0, 1.0, "or_greater") var hardness_scale: float = 400.0:
	set(v):
		hardness_scale = maxf(v, 1.0)
		_param_changed()
## How far hardness swings from 0.5, 0..1. 0 = uniform rock.
@export_range(0.0, 1.0, 0.01) var hardness_variation: float = 0.6:
	set(v):
		hardness_variation = clampf(v, 0.0, 1.0)
		_param_changed()


func op() -> StringName:
	return &"shore_character"


## The sixteen-slot block. The order is `shore_character_params_from`'s in src/pasture_3d_shore_character.cpp.
func native_lower() -> Dictionary:
	return {"params": _params()}


func _params() -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = sea_level
	p[1] = float(seed)
	p[2] = bay_radius
	p[3] = cove_radius
	p[4] = shape_weight
	p[5] = exposure_weight
	p[6] = backshore_weight
	p[7] = backshore_dist
	p[8] = backshore_height
	p[9] = threshold
	p[10] = softness
	p[11] = hardness_scale
	p[12] = hardness_variation
	return p


func native_out_count() -> int:
	return 4 # cliff, beach, hardness, erosion


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


## The exposure is the secondary grid, on port 1. Port 2 (`sea_level`) drives slot 0.
func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"height", PortType.HEIGHT).require(),
		Pasture3DGraphPort.field(&"exposure", PortType.MASK).unwired(1.0).as_aux(),
		Pasture3DGraphPort.value(&"sea_level", PortType.FLOAT, &"sea_level", 0),
	]


## Port order is a wire format: APPEND only.
func _outputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"cliff", PortType.MASK),
		Pasture3DGraphPort.field(&"beach", PortType.MASK),
		Pasture3DGraphPort.field(&"hardness", PortType.MASK),
		Pasture3DGraphPort.field(&"erosion", PortType.MASK),
	]


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var h: PackedFloat32Array = p_inputs[0] if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array \
			and p_inputs[0].size() == n else Pasture3DGraphOps.zeros(n)
	if not ClassDB.class_has_method("Pasture3DUtil", "shore_character_grid"):
		push_error("[Pasture3D] Pasture3DUtil.shore_character_grid is not bound. Rebuild GDExtension.")
		return _fallback(n)
	var ex: PackedFloat32Array = p_inputs[1] if p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array \
			and p_inputs[1].size() == n else PackedFloat32Array()
	var prm := _params()
	# A wired sea level arrives as cell 0 of port 2 on this route, as the Leveler reads its value port.
	if p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0:
		prm[0] = float(p_inputs[2][0])
	var res: Dictionary = Pasture3DUtil.shore_character_grid(h, ex, p_gw, p_gh, p_rect, prm)
	var cl: PackedFloat32Array = res.get("cliff", PackedFloat32Array())
	if cl.size() != n:
		push_error("[Pasture3D] shore_character_grid returned %d cells for a %d cell grid." % [cl.size(), n])
		return _fallback(n)
	return [cl, res["beach"], res["hardness"], res["erosion"]]


## All cliff, no beach, mid hardness, no erosion: a failed solve leaves a Coast Profile as if unwired and
## erodes nothing.
func _fallback(p_n: int) -> Array:
	var one := PackedFloat32Array()
	one.resize(p_n)
	one.fill(1.0)
	var half := PackedFloat32Array()
	half.resize(p_n)
	half.fill(0.5)
	return [one, Pasture3DGraphOps.zeros(p_n), half, Pasture3DGraphOps.zeros(p_n)]
