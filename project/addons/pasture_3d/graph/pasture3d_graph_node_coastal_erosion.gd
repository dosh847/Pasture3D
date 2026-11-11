# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeCoastalErosion — cliffs cut back where the sea is exposed, beaches built where it is
# sheltered. The model (wave-cut platform, talus-relaxed cliff face, beach profile) and its limits are in
# src/pasture_3d_coastal_erosion.h; the maths is C++ only and reuses the shared distance transform and talus
# projection kernels.
#
# Wire Wave Exposure's `exposure` into `exposure`, with its shore_reach at least twice `retreat`. Unwired,
# the whole coast reads fully exposed. The standard mask is applied by the framework.
@tool
class_name Pasture3DGraphNodeCoastalErosion
extends Pasture3DGraphNode

## Height below which a cell is water, metres. Also a value port.
@export var sea_level: float = 0.0:
	set(v):
		sea_level = v
		_param_changed()

@export_group("Cliffs")
## How far the cliff retreats at exposure 1, metres.
@export_range(0.0, 500.0, 0.5, "or_greater") var retreat: float = 30.0:
	set(v):
		retreat = maxf(v, 0.0)
		_param_changed()
## Depth of the wave-cut platform below sea level at the old shoreline, metres.
@export_range(0.0, 20.0, 0.1, "or_greater") var platform_depth: float = 1.5:
	set(v):
		platform_depth = maxf(v, 0.0)
		_param_changed()
## Steepest the new cliff face may stand, degrees.
@export_range(1.0, 89.0, 0.5) var cliff_angle: float = 70.0:
	set(v):
		cliff_angle = clampf(v, 1.0, 89.0)
		_param_changed()
## Talus relaxation passes over the cut band. 0 leaves a one-cell wall.
@export_range(0, 64, 1) var cliff_iterations: int = 8:
	set(v):
		cliff_iterations = clampi(v, 0, 256)
		_param_changed()

@export_group("Beaches")
## Height of the back of the beach above sea level, metres.
@export_range(0.0, 10.0, 0.1, "or_greater") var beach_height: float = 1.0:
	set(v):
		beach_height = v
		_param_changed()
## Width of the beach inland of the shoreline, metres. Half of it again is built below the water.
@export_range(0.0, 300.0, 0.5, "or_greater") var beach_width: float = 30.0:
	set(v):
		beach_width = maxf(v, 0.0)
		_param_changed()
## How far toward the beach profile sheltered ground is raised, 0..1, scaled by 1 - exposure.
@export_range(0.0, 1.0, 0.01) var deposit: float = 1.0:
	set(v):
		deposit = clampf(v, 0.0, 1.0)
		_param_changed()


func op() -> StringName:
	return &"coastal_erosion"


## The sixteen-slot block. The order is `coastal_erosion_params_from`'s in src/pasture_3d_coastal_erosion.cpp.
func native_lower() -> Dictionary:
	return {"params": _params()}


func _params() -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = sea_level
	p[1] = retreat
	p[2] = platform_depth
	p[3] = cliff_angle
	p[4] = float(cliff_iterations)
	p[5] = beach_height
	p[6] = beach_width
	p[7] = deposit
	return p


func native_out_count() -> int:
	return 3 # height, cut, deposit


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


## Port order is a wire format: APPEND only. `cut` and `deposit` are metres (solver outputs are metres);
## Float to Mask turns them into masks.
func _outputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"height", PortType.HEIGHT),
		Pasture3DGraphPort.field(&"cut", PortType.FIELD),
		Pasture3DGraphPort.field(&"deposit", PortType.FIELD),
	]


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var h: PackedFloat32Array = p_inputs[0] if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array \
			and p_inputs[0].size() == n else Pasture3DGraphOps.zeros(n)
	if not ClassDB.class_has_method("Pasture3DUtil", "coastal_erosion_grid"):
		push_error("[Pasture3D] Pasture3DUtil.coastal_erosion_grid is not bound. Rebuild GDExtension.")
		return _pass_through(h)
	var ex: PackedFloat32Array = p_inputs[1] if p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array \
			and p_inputs[1].size() == n else PackedFloat32Array()
	var prm := _params()
	# A wired sea level arrives as cell 0 of port 2 on this route, as the Leveler reads its value port.
	if p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0:
		prm[0] = float(p_inputs[2][0])
	var res: Dictionary = Pasture3DUtil.coastal_erosion_grid(h, ex, p_gw, p_gh, p_rect, prm)
	var out_h: PackedFloat32Array = res.get("height", PackedFloat32Array())
	if out_h.size() != n:
		push_error("[Pasture3D] coastal_erosion_grid returned %d cells for a %d cell grid." % [out_h.size(), n])
		return _pass_through(h)
	return [out_h, res["cut"], res["deposit"]]


## The surface unchanged and nothing cut or built: a failed solve must not flatten the coast.
func _pass_through(p_h: PackedFloat32Array) -> Array:
	var z := PackedFloat32Array()
	z.resize(p_h.size())
	return [p_h, z, z.duplicate()]
