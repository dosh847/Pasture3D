# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphParam — one DECLARED parameter of a Pasture3DTerrainGraph
# (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §10).
#
# The graph declares it; a Parameter node reads it by `id`; whoever HOSTS the graph supplies the value. The
# value is never stored here: this resource holds only what an unsupplied parameter reads (`default_value`)
# and how a host should present it (label, type, range). That split is what lets two brushes share one graph
# and bake different terrain from it.
#
# The default is one float for all three types. A parameter travels the graph as a number whatever it is
# declared as (a driven port reads cell 0 of a uniform grid), so `coerce` is the single place a type means
# anything: INT rounds, BOOL is 0 or 1.
@tool
class_name Pasture3DGraphParam
extends Resource

enum Type {
	FLOAT = 0,
	INT = 1,
	BOOL = 2,
}

## What Parameter nodes and host overrides name. Stable: renaming it orphans both.
@export var id: StringName = &"":
	set(v):
		id = v
		emit_changed()

## What the host's inspector shows. Empty reads the id.
@export var label: String = "":
	set(v):
		label = v
		emit_changed()

@export var type: Type = Type.FLOAT:
	set(v):
		type = v
		emit_changed()

## What a host that supplies nothing reads. INT rounds it, BOOL reads non-zero as true.
@export var default_value: float = 0.0:
	set(v):
		default_value = v
		emit_changed()

@export_group("Range")
## The host's slider range. A hint for the inspector only: a value outside it is not clamped.
@export var range_min: float = 0.0:
	set(v):
		range_min = v
		emit_changed()

@export var range_max: float = 1.0:
	set(v):
		range_max = v
		emit_changed()

@export var step: float = 0.01:
	set(v):
		step = v
		emit_changed()


## `p_v` as this parameter's type, as the number the graph evaluates: float32 for FLOAT (a compiled program
## carries float32, and the two evaluators must read the same value), a whole number for INT, 0 or 1 for BOOL.
func coerce(p_v: Variant) -> float:
	match type:
		Type.BOOL:
			if p_v is bool:
				return 1.0 if p_v else 0.0
			return 1.0 if absf(float(p_v)) > 0.5 else 0.0
		Type.INT:
			return float(roundi(float(p_v)))
	return PackedFloat32Array([float(p_v)])[0]


## The declared default, coerced.
func default_number() -> float:
	return coerce(default_value)


## `p_number` as the Variant an inspector edits: float, int or bool.
func typed(p_number: float) -> Variant:
	match type:
		Type.BOOL:
			return p_number > 0.5
		Type.INT:
			return roundi(p_number)
	return p_number


## The Pasture3DGraphNode.PortType a Parameter node reading this exposes.
func port_type() -> int:
	match type:
		Type.BOOL:
			return Pasture3DGraphNode.PortType.BOOL
		Type.INT:
			return Pasture3DGraphNode.PortType.INT
	return Pasture3DGraphNode.PortType.FLOAT


func display_label() -> String:
	return label if label != "" else String(id)


## The entry a host returns from `_get_property_list` for this parameter, under `p_name`.
func property_info(p_name: String) -> Dictionary:
	var info := {"name": p_name, "usage": PROPERTY_USAGE_EDITOR}
	match type:
		Type.BOOL:
			info["type"] = TYPE_BOOL
		Type.INT:
			info["type"] = TYPE_INT
			if range_max > range_min:
				info["hint"] = PROPERTY_HINT_RANGE
				info["hint_string"] = "%d,%d,1,or_less,or_greater" % [roundi(range_min), roundi(range_max)]
		_:
			info["type"] = TYPE_FLOAT
			if range_max > range_min:
				info["hint"] = PROPERTY_HINT_RANGE
				info["hint_string"] = "%s,%s,%s,or_less,or_greater" % [String.num(range_min), String.num(range_max),
						String.num(step if step > 0.0 else 0.001)]
	return info
