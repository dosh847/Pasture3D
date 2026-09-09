# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevPathWidthField — the ORACLE for Path Width from Field. Pure GDScript, hidden.
#
# See PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md §1 & §3.2.
# The production node calls Pasture3DUtil.path_width_field_solve and fails fast without it.
@tool
class_name Pasture3DGraphNodeDevPathWidthField
extends Pasture3DGraphNodePathDerive

@export_range(0.0, 10000.0, 0.01, "or_greater") var field_min: float = 0.0:
	set(v):
		field_min = v
		_param_changed()

@export_range(0.0, 10000.0, 0.01, "or_greater") var field_max: float = 1.0:
	set(v):
		field_max = v
		_param_changed()

@export_range(0.0, 200.0, 0.01, "or_greater", "suffix:m") var half_width_min: float = 2.0:
	set(v):
		half_width_min = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 200.0, 0.01, "or_greater", "suffix:m") var half_width_max: float = 20.0:
	set(v):
		half_width_max = maxf(v, 0.0)
		_param_changed()

@export var response: Curve:
	set(v):
		if response != null and response.changed.is_connected(_param_changed):
			response.changed.disconnect(_param_changed)
		response = v
		if response != null and not response.changed.is_connected(_param_changed):
			response.changed.connect(_param_changed)
		_param_changed()

@export var scale_existing: bool = false:
	set(v):
		scale_existing = v
		_param_changed()

@export_range(0.001, 50.0, 0.001, "or_greater", "suffix:m") var min_half_width: float = 0.5:
	set(v):
		min_half_width = maxf(v, 0.001)
		_param_changed()


func op() -> StringName:
	return &"dev_path_width_field"


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["path", "field"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.PATH, PortType.MASK])


func input_unwired_default(p_port: int) -> float:
	return NAN if p_port == 1 else 0.0


func derive(_p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	if port_unwired(1):
		return
	var field: PackedFloat32Array = _grids[1]
	var pts := p_out.points
	var n := pts.size()
	var span: float = field_max - field_min
	var was := p_out.half_widths
	var hw := PackedFloat32Array()
	hw.resize(n)
	for i in n:
		var f: float = sample_grid(field, pts[i].x, pts[i].y)
		var u: float = 0.0 if not is_finite(f) else (0.0 if span <= 0.0 else clampf((f - field_min) / span, 0.0, 1.0))
		if response != null:
			u = clampf(response.sample_baked(u), 0.0, 1.0)
		var w: float = lerpf(half_width_min, half_width_max, u)
		if scale_existing:
			var prev: float = 1.0
			if was.size() > 0:
				prev = was[mini(i, was.size() - 1)]
			w *= prev
		hw[i] = maxf(w, min_half_width)
	p_out.half_widths = hw


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if _gw > 0 and port_unwired(1):
		out.append("Path Width from Field has no field wired, so the path keeps the widths it arrived "
				+ "with. Wire a flow or wetness channel into `field`.")
	if field_max <= field_min:
		out.append("Field Max is not above Field Min, so every vertex maps to the minimum width and the "
				+ "node produces a constant. Use Path Width if a constant is what you want.")
	return out
