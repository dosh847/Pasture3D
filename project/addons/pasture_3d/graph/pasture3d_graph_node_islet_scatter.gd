# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeIsletScatter — small islands and sea stacks scattered offshore of a coast. The model and
# its limits are in src/pasture_3d_islet_scatter.h; the maths is C++ only and reuses the shared distance
# transform and wang_hash.
#
# Wire Wave Exposure's `exposure` into `exposure` so stacks gather off exposed shores; unwired, every shore
# reads fully exposed. Placement is in world metres, so islets stay put across resolutions. The standard mask
# is applied by the framework.
@tool
class_name Pasture3DGraphNodeIsletScatter
extends Pasture3DGraphNode

## Height below which a cell is water, metres. Also a value port.
@export var sea_level: float = 0.0:
	set(v):
		sea_level = v
		_param_changed()
## Variation seed.
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export_group("Placement")
## Lattice cell size, metres: at most one islet per cell.
@export_range(5.0, 2000.0, 1.0, "or_greater") var spacing: float = 150.0:
	set(v):
		spacing = maxf(v, 1.0)
		_param_changed()
## Chance a lattice cell holds an islet, 0..1.
@export_range(0.0, 1.0, 0.01) var density: float = 0.3:
	set(v):
		density = clampf(v, 0.0, 1.0)
		_param_changed()
## Nearest an islet centre may sit to land, metres.
@export_range(0.0, 2000.0, 1.0, "or_greater") var min_offshore: float = 30.0:
	set(v):
		min_offshore = maxf(v, 0.0)
		_param_changed()
## Furthest an islet centre may sit from land, metres.
@export_range(0.0, 5000.0, 1.0, "or_greater") var max_offshore: float = 400.0:
	set(v):
		max_offshore = maxf(v, 0.0)
		_param_changed()

@export_group("Shape")
## Smallest islet radius, metres. Stacks are 0.4x.
@export_range(0.5, 500.0, 0.5, "or_greater") var radius_min: float = 15.0:
	set(v):
		radius_min = maxf(v, 0.1)
		_param_changed()
## Largest islet radius, metres.
@export_range(0.5, 500.0, 0.5, "or_greater") var radius_max: float = 60.0:
	set(v):
		radius_max = maxf(v, 0.1)
		_param_changed()
## Lowest islet top above sea level, metres. Stacks are 1.5x.
@export_range(0.0, 200.0, 0.5, "or_greater") var height_min: float = 5.0:
	set(v):
		height_min = v
		_param_changed()
## Highest islet top above sea level, metres.
@export_range(0.0, 200.0, 0.5, "or_greater") var height_max: float = 30.0:
	set(v):
		height_max = v
		_param_changed()
## Depth below sea level where an islet's flank meets the floor, metres.
@export_range(0.0, 100.0, 0.5, "or_greater") var base_depth: float = 10.0:
	set(v):
		base_depth = maxf(v, 0.0)
		_param_changed()
## Outline irregularity, 0..1.
@export_range(0.0, 1.0, 0.01) var roughness: float = 0.3:
	set(v):
		roughness = clampf(v, 0.0, 1.0)
		_param_changed()
## Share of islets that become sea stacks at exposure 1, 0..1.
@export_range(0.0, 1.0, 0.01) var stack_fraction: float = 0.5:
	set(v):
		stack_fraction = clampf(v, 0.0, 1.0)
		_param_changed()


func op() -> StringName:
	return &"islet_scatter"


## The sixteen-slot block. The order is `islet_scatter_params_from`'s in src/pasture_3d_islet_scatter.cpp.
func native_lower() -> Dictionary:
	return {"params": _params()}


func _params() -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = sea_level
	p[1] = float(seed)
	p[2] = spacing
	p[3] = density
	p[4] = min_offshore
	p[5] = max_offshore
	p[6] = radius_min
	p[7] = radius_max
	p[8] = height_min
	p[9] = height_max
	p[10] = base_depth
	p[11] = roughness
	p[12] = stack_fraction
	return p


func native_out_count() -> int:
	return 3 # height, islets, stacks


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
		Pasture3DGraphPort.field(&"height", PortType.HEIGHT),
		Pasture3DGraphPort.field(&"islets", PortType.MASK),
		Pasture3DGraphPort.field(&"stacks", PortType.MASK),
	]


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var h: PackedFloat32Array = p_inputs[0] if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array \
			and p_inputs[0].size() == n else Pasture3DGraphOps.zeros(n)
	if not ClassDB.class_has_method("Pasture3DUtil", "islet_scatter_grid"):
		push_error("[Pasture3D] Pasture3DUtil.islet_scatter_grid is not bound. Rebuild GDExtension.")
		return _pass_through(h)
	var ex: PackedFloat32Array = p_inputs[1] if p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array \
			and p_inputs[1].size() == n else PackedFloat32Array()
	var prm := _params()
	# A wired sea level arrives as cell 0 of port 2 on this route, as the Leveler reads its value port.
	if p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0:
		prm[0] = float(p_inputs[2][0])
	var res: Dictionary = Pasture3DUtil.islet_scatter_grid(h, ex, p_gw, p_gh, p_rect, prm)
	var out_h: PackedFloat32Array = res.get("height", PackedFloat32Array())
	if out_h.size() != n:
		push_error("[Pasture3D] islet_scatter_grid returned %d cells for a %d cell grid." % [out_h.size(), n])
		return _pass_through(h)
	return [out_h, res["islets"], res["stacks"]]


## The surface unchanged and nothing placed: a failed solve must not flatten the sea.
func _pass_through(p_h: PackedFloat32Array) -> Array:
	var z := PackedFloat32Array()
	z.resize(p_h.size())
	return [p_h, z, z.duplicate()]
