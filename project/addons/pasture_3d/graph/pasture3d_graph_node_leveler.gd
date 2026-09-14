# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeLeveler — flatten an area or level it to a height, with a feathered wall outside it
# (PASTURE3D_GRAPH_LEVELER_SPEC.md).
#
# ---- THE PRODUCTION NODE. THE MATHS IS IN C++ ----
#
# Every rule lives in Pasture3DGraphNodeDevLeveler, the [Dev/GD] oracle, and src/pasture_3d_leveler.cpp
# mirrors it; LevelerNativeParityGate holds them together. This file marshals the inputs, calls
# Pasture3DUtil.leveler_grid, and FAILS SAFE — height passed through, every mask empty — if the kernel is
# not bound. Lowered into a graph program it is GRAPH_OP_LEVELER and this file is not called at all.
@tool
class_name Pasture3DGraphNodeLeveler
extends Pasture3DGraphNodeLevelerBase


func op() -> StringName:
	return &"leveler"


## The sixteen-slot block. The order is `leveler_params_from`'s in src/pasture_3d_leveler.cpp, and that
## function is the only thing that reads it — on both routes.
func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = float(mode)
	p[1] = float(statistic)
	p[2] = target_height
	p[3] = float(cut_fill)
	p[4] = feather
	p[5] = 1.0 if feather_from_path_width else 0.0
	p[6] = path_width_scale
	p[7] = float(walls_shape)
	p[8] = wall_depth
	p[9] = float(median_bins)
	return {"params": p, "lut": falloff_lut()}


## Port 3 (`target_height`) drives slot 2. Ports 0-2 are grids or the path.
func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1, -1, -1, 2])


## The mask is the secondary grid, on port 2.
func aux_grid_port() -> int:
	return 2


func native_out_count() -> int:
	return 5 # height, level_mask, level_value, delta, walls


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var h: PackedFloat32Array = p_inputs[0] if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array \
			and p_inputs[0].size() == n else Pasture3DGraphOps.zeros(n)
	var mask: PackedFloat32Array = p_inputs[2] if p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array \
			and p_inputs[2].size() == n else PackedFloat32Array()
	var params: PackedFloat32Array = native_lower()["params"]
	# A driven target is cell 0 of its wire, exactly as the lowered evaluator reads a parameter port.
	if p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0:
		params[2] = float(p_inputs[3][0])

	if not ClassDB.class_has_method("Pasture3DUtil", "leveler_grid"):
		push_error("[Pasture3D] Pasture3DUtil.leveler_grid is not bound. Rebuild GDExtension.")
		return _passthrough(h, n)
	var pts := _path.points if _path != null else PackedVector2Array()
	var widths := _path.half_widths if _path != null else PackedFloat32Array()
	var res: Dictionary = Pasture3DUtil.leveler_grid(pts, widths, _path != null, h, mask, p_gw, p_gh,
			p_rect, falloff_lut(), params)
	if not bool(res.get("ok", false)):
		push_error("[Pasture3D] leveler_grid failed for a %d x %d grid." % [p_gw, p_gh])
		return _passthrough(h, n)
	evaluated = true
	last_core_count = int(res["core_count"])
	last_level = float(res["level"])
	return [res["height"], res["level_mask"], res["level_value"], res["delta"], res["walls"]]


## The safe answer when the kernel is missing or failed: the height UNCHANGED and every mask empty. Not
## zeros — a fail-fast that flattened the terrain would be worse than the missing kernel it reports.
func _passthrough(p_h: PackedFloat32Array, p_n: int) -> Array:
	return [p_h, Pasture3DGraphOps.zeros(p_n), Pasture3DGraphOps.filled(p_n, NAN),
			Pasture3DGraphOps.zeros(p_n), Pasture3DGraphOps.zeros(p_n)]
