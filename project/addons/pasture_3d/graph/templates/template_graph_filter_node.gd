# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# TemplateGraphFilterNode — Boilerplate starting template for a 3-tier accelerated Pasture3D graph filter.

@tool
class_name TemplateGraphFilterNode
extends Pasture3DGraphNode

@export_range(0.0, 1.0, 0.05) var intensity: float = 0.5:
	set(v):
		intensity = clampf(v, 0.0, 1.0)
		emit_changed()


func op() -> StringName:
	return &"template_filter"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"input", PortType.HEIGHT).require(),
		Pasture3DGraphPort.field(&"mask", PortType.MASK).unwired(1.0),
	]


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var in_grid: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var mask: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array) else Pasture3DGraphOps.filled(n, 1.0)

	# Tier 2 GDExtension fast path (Fail-fast if not available)
	if not ClassDB.class_has_method("Pasture3DUtil", "template_filter_grid"):
		push_error("[Pasture3D] Pasture3DUtil.template_filter_grid is not bound. Rebuild GDExtension.")
		return in_grid.duplicate()

	var util = ClassDB.instantiate("Pasture3DUtil")
	if util == null:
		return in_grid.duplicate()
	var res_var = util.call("template_filter_grid", in_grid, mask, p_gw, p_gh, intensity)
	var res: PackedFloat32Array = (res_var as PackedFloat32Array) if res_var is PackedFloat32Array else PackedFloat32Array()
	if res.size() != n:
		push_error("[Pasture3D] Template filter native solve returned invalid grid size.")
		return in_grid.duplicate()

	return res
