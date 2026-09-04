# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeConstCurve — a GENERATOR constant node holding a Curve resource.
@tool
class_name Pasture3DGraphNodeConstCurve
extends Pasture3DGraphNode

## The Curve resource.
@export var curve: Curve:
	set(v):
		curve = v
		emit_changed()


## `super()` first, and it is not ceremony: the base `_init` is the ONLY place `changed` is wired to
## `_on_node_changed_bump_revision`. Without it this node emitted `changed` correctly from every setter
## and from the curve's own signal, and `_dirty_revision` still never moved — so it was permanently
## clean, served its first grid forever, and its curve was uneditable in the only sense that matters.
## Found by GraphNodeParamGate, which is the whole reason that gate reflects over the registry rather
## than over a list of nodes someone remembered to add.
func _init() -> void:
	super()
	if curve == null:
		curve = Curve.new()
		curve.add_point(Vector2(0.0, 0.0))
		curve.add_point(Vector2(1.0, 1.0))
	if not curve.changed.is_connected(_on_curve_changed):
		curve.changed.connect(_on_curve_changed)


func _on_curve_changed() -> void:
	emit_changed()


func op() -> StringName:
	return &"const_curve"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	var lut := PackedFloat32Array()
	p[0] = 0.0
	p[1] = 1.0
	p[2] = 0.0
	p[3] = 1.0
	p[4] = 1.0
	var c: Curve = curve
	if c != null:
		lut.resize(256)
		for li in range(256):
			lut[li] = c.sample_baked(float(li) / 255.0)
	return {"params": p, "lut": lut}


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 0


func input_names() -> PackedStringArray:
	return PackedStringArray()


func output_port_type() -> int:
	return PortType.CURVE


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.CURVE])


func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return curve.sample_baked(0.5) if curve != null else 0.0
