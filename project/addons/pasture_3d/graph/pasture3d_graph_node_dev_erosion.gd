# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevErosion — reference/dev erosion node.
# Used for algorithm prototyping, A/B testing, and automated headless CI parity verification.
@tool
class_name Pasture3DGraphNodeDevErosion
extends Pasture3DGraphSolverNode


@export_range(1, 200, 1, "or_greater") var iterations: int = 30:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

@export_range(0.0, 1.0, 0.005, "or_greater") var erosion_rate: float = 0.08:
	set(v):
		erosion_rate = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var area_exponent: float = 0.45:
	set(v):
		area_exponent = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.0, 10.0, 0.01, "or_greater") var hillslope_diffusion: float = 0.15:
	set(v):
		hillslope_diffusion = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var deposition: float = 0.0:
	set(v):
		deposition = clampf(v, 0.0, 1.0)
		_param_changed()

@export_group("Evaluation")

@export_tool_button("Bake Erosion") var _bake_btn = clear_cache


## This solve is heavy enough that FROZEN is the right default; the base defaults to LIVE.
func _init() -> void:
	# `super()` is not optional. Pasture3DGraphNode._init connects `changed` to the revision bump, and a
	# subclass `_init` that does not chain silently drops that connection — every parameter on this node,
	# `muted` included, then becomes invisible to invalidation and it serves its first grid forever.
	# GraphNodeParamGate names each one that stops bumping.
	super()
	evaluation = Evaluation.FROZEN


## Names this node's own Bake button, for the freeze warning.
func bake_label() -> String:
	return "Bake Erosion"


func op() -> StringName:
	return &"dev_erosion"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "[Dev/GD] Erosion"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["field"])


func output_count() -> int:
	return 5


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "flow", "erosion", "deposition", "wetness"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.MASK, PortType.MASK, PortType.MASK])


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if p_inputs.size() > 0 \
			else Pasture3DGraphOps.zeros(n)
	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	return solve_cached(_surface_hash(surface, p_gw, p_gh), func(): return _solve(surface, p_gw, p_gh, p_rect))


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func _param_changed() -> void:
	mark_dirty_since_bake()
	emit_changed()


func _solve(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	var cell_size := sqrt(maxf(dx * dz, 1e-12))
	var params := {
		"iterations": iterations,
		"erosion_rate": erosion_rate,
		"area_exponent": area_exponent,
		"diffusion": hillslope_diffusion,
		"deposition": deposition,
	}
	if not ClassDB.class_has_method("Pasture3DUtil", "erosion_solve_grid"):
		push_error("[Pasture3D] Pasture3DUtil.erosion_solve_grid is not bound.")
		return [p_surface, Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n),
				Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]

	var res: Dictionary = Pasture3DUtil.erosion_solve_grid(p_surface, p_gw, p_gh, cell_size, params,
			PackedFloat32Array())
	if res.is_empty() or not bool(res.get("ok", false)):
		return [p_surface, Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n),
				Pasture3DGraphOps.zeros(n), Pasture3DGraphOps.zeros(n)]
	return [res["z"], res["flow"], res["ero"], res["dep"], res["wet"]]


func _surface_hash(p_surface: PackedFloat32Array, p_gw: int, p_gh: int) -> int:
	return solver_cache_key(p_gw, p_gh, [p_surface])
