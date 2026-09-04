# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeLakeFlooding — a SOLVER grid node: hydrological basin depression flooding.
#
# Floods closed basins or fills all terrain below a specified target water level, generating 3 outputs:
#
#   port 0  "height"       HEIGHT  surface elevation with flat lake water levels filled
#   port 1  "water_depth"  MASK    water column depth in metres (z_water - z_bed)
#   port 2  "shoreline"    MASK    feathered shore mask along the water-land boundary
#
# Provides an editor tool button to spawn a Pasture3DPond / Pasture3DPool directly into the scene
# from the computed lake shoreline contour.
@tool
class_name Pasture3DGraphNodeLakeFlooding
extends Pasture3DGraphSolverNode

enum FloodMode {
	SPILLWAY_BASIN,    ## Flood each closed depression up to its minimum drainage spillway.
	GLOBAL_ELEVATION,  ## Flood all terrain up to a fixed global water plane elevation.
}


@export var flood_mode: FloodMode = FloodMode.SPILLWAY_BASIN:
	set(v):
		flood_mode = v
		_param_changed()

## In GLOBAL_ELEVATION mode: the world Y elevation of the water plane.
@export var water_elevation: float = 10.0:
	set(v):
		water_elevation = v
		_param_changed()

## In SPILLWAY_BASIN mode: percentage of the depression's spillway depth to flood (0.0..1.0).
@export_range(0.0, 1.0, 0.01) var flood_percent: float = 1.0:
	set(v):
		flood_percent = clampf(v, 0.0, 1.0)
		_param_changed()


## Shoreline transition feathering width in metres.
@export_range(0.5, 32.0, 0.5) var shoreline_width: float = 4.0:
	set(v):
		shoreline_width = maxf(v, 0.1)
		_param_changed()

@export_group("Evaluation")

@export_tool_button("Bake Lakes") var _bake_btn = clear_cache
@export_tool_button("Spawn Pasture3DPond in Scene") var _spawn_btn = spawn_pond_in_scene

# ---- Runtime cache ----
var _last_lake_polys: Array[PackedVector2Array] = []
var _last_water_level: float = 0.0


## Names this node's own Bake button, for the freeze warning.
func bake_label() -> String:
	return "Bake Lakes"


func op() -> StringName:
	return &"lake_flooding"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = float(flood_mode)
	p[1] = water_elevation
	p[2] = flood_percent
	p[3] = shoreline_width
	return {"params": p}


func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1, 1, -1, 3])


func role() -> Role:
	return Role.SOLVER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "water_elevation", "flood_percent", "shoreline_width"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.FLOAT,
		PortType.MASK,
		PortType.FLOAT,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return water_elevation
		2: return flood_percent
		3: return shoreline_width
		_: return 0.0


func output_count() -> int:
	return 3


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "water_depth", "shoreline"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.MASK])


func _param_changed() -> void:
	_dirty_since_bake = true
	emit_changed()


func node_warnings() -> PackedStringArray:
	var w := super()
	return w


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and (p_inputs[0] as PackedFloat32Array).size() == n:
		in_grid = p_inputs[0]
	else:
		in_grid = Pasture3DGraphOps.zeros(n)

	var we: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else water_elevation
	var fp: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else flood_percent
	var sw: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else shoreline_width

	return solve_cached(_grid_hash(in_grid, p_gw, p_gh), func(): return _solve_dynamic(in_grid, p_gw, p_gh, p_rect, we, fp, sw))


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


# ---- Solver Logic ----------------------------------------------------------------------------------

func _solve_dynamic(p_h: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_we: float, p_fp: float, p_sw: float) -> Array:
	var n := p_gw * p_gh
	_last_water_level = p_we if flood_mode == FloodMode.GLOBAL_ELEVATION else 0.0
	if not ClassDB.class_has_method("Pasture3DUtil", "lake_flooding_grid"):
		push_error("[Pasture3D] Pasture3DUtil.lake_flooding_grid is not bound. Rebuild GDExtension.")
		return [p_h.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	var res: Dictionary = Pasture3DUtil.lake_flooding_grid(p_h, p_gw, p_gh, p_rect, int(flood_mode),
			p_we, p_fp, p_sw)
	if not bool(res.get("ok", false)):
		push_error("[Pasture3D] Lake flooding native solve failed.")
		return [p_h.duplicate(), Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	_last_lake_polys.clear()
	var polys: Array = res.get("contours", [])
	for poly in polys:
		if poly is PackedVector2Array:
			_last_lake_polys.append(poly)
	return [res["height"], res["water_depth"], res["shoreline"]]


## Spawns a Pasture3DPond in the active edited scene from the detected lake basin.
func spawn_pond_in_scene() -> void:
	if _last_lake_polys.is_empty():
		push_warning("Pasture3DGraphNodeLakeFlooding: No lake basin found to spawn a pond.")
		return

	var root := EditorInterface.get_edited_scene_root() if Engine.is_editor_hint() else null
	if root == null:
		push_warning("Pasture3DGraphNodeLakeFlooding: No edited scene root found.")
		return

	var poly := _last_lake_polys[0]
	var pond := Pasture3DPond.new()
	pond.name = "Pond_Lake"

	var path := Path3D.new()
	path.name = "Loop1"
	var curve := Curve3D.new()
	for pt in poly:
		curve.add_point(Vector3(pt.x, 0.0, pt.y))
	if poly.size() > 0:
		curve.add_point(Vector3(poly[0].x, 0.0, poly[0].y)) # close loop
	path.curve = curve

	pond.add_child(path)
	path.owner = root

	root.add_child(pond)
	pond.owner = root
	pond.global_position = Vector3(0.0, _last_water_level, 0.0)

	print("Spawned Pasture3DPond '%s' at elevation Y=%.2f" % [pond.name, _last_water_level])
	if Engine.is_editor_hint():
		EditorInterface.edit_node(pond)


## The freeze key: a hash of the WHOLE surface. It used to sample 32 cells at a fixed stride, which is
## not an identity — on a radial mound that stride lands on one column, every value in it is 0, and a
## flat surface hashes the same. The node then served its cached solve for a different surface and did
## NOT flag itself stale, which is the one thing the freeze is supposed to tell you.
func _grid_hash(arr: PackedFloat32Array, p_gw: int, p_gh: int) -> int:
	return solver_cache_key(p_gw, p_gh, [arr])
