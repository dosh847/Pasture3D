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
# The default is one float for the three number types. A parameter travels the graph as a number whatever it
# is declared as (a driven port reads cell 0 of a uniform grid), so `coerce` is the single place a type means
# anything: INT rounds, BOOL is 0 or 1.
#
# ---- PATH: A SPLINE PER HOST ----
#
# A PATH parameter is not a number. The host supplies a SPLINE KEY (a String), and the empty key — which is
# also what a host that supplies nothing reads — means "the host brush's own first Pasture3DSpline child",
# the same rule Spline Source's empty key follows (PASTURE3D_SPLINE_GRAPH_SPEC.md §5.1). That is what lets
# four duplicated brushes share one graph and each carve its own line: the graph names no spline, each host
# answers with its child. The host resolves the key to a Pasture3DGraphPath and stamps the PATH, not the key
# (`Pasture3DNodeGraph.stamp_params`), because a Resource cannot reach the scene.
#
# Why not Spline Source with an empty key: that node HOLDS its path, so two hosts resolving it take turns
# writing one shared property, and each write emits `changed` on the shared graph — every host's bake
# re-bakes every other host. A parameter is bound silently, per host, the way every other parameter is.
#
# How the spline is read (which child spline, resampled or not) is part of the DECLARATION, not the host's
# value: it is the graph's contract with whoever supplies the line.
@tool
class_name Pasture3DGraphParam
extends Resource

enum Type {
	FLOAT = 0,
	INT = 1,
	BOOL = 2,
	PATH = 3,
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
		# The number and spline settings swap visibility (`_validate_property`).
		notify_property_list_changed()
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

@export_group("Spline")
## PATH only: which of the host spline's child curves to read. Past the end reads an EMPTY path, as Spline
## Source's index does.
@export_range(0, 32) var spline_index: int = 0:
	set(v):
		spline_index = maxi(v, 0)
		emit_changed()

## PATH only: resample the curve every `sample_interval` metres rather than taking its control points.
@export var sample_points: bool = false:
	set(v):
		sample_points = v
		emit_changed()

## PATH only: metres between resampled points.
@export_range(0.25, 200.0, 0.05, "or_greater", "suffix:m") var sample_interval: float = 4.0:
	set(v):
		sample_interval = maxf(v, 0.05)
		emit_changed()


## Hide what does not apply to this type: the number settings for PATH, the spline settings for numbers.
func _validate_property(property: Dictionary) -> void:
	var n: String = property["name"]
	var path_only := n == "spline_index" or n == "sample_points" or n == "sample_interval"
	var number_only := n == "default_value" or n == "range_min" or n == "range_max" or n == "step"
	if (path_only and type != Type.PATH) or (number_only and type == Type.PATH):
		property["usage"] &= ~PROPERTY_USAGE_EDITOR


func is_path() -> bool:
	return type == Type.PATH


## `p_v` as this parameter's type, as the number the graph evaluates: float32 for FLOAT (a compiled program
## carries float32, and the two evaluators must read the same value), a whole number for INT, 0 or 1 for BOOL.
func coerce(p_v: Variant) -> float:
	match type:
		Type.PATH:
			# A PATH parameter has no number; its Parameter node lowers the zero every PATH producer fills its
			# grid slot with.
			return 0.0
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
		Type.PATH:
			return ""
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
		Type.PATH:
			return Pasture3DGraphNode.PortType.PATH
	return Pasture3DGraphNode.PortType.FLOAT


func display_label() -> String:
	return label if label != "" else String(id)


## The entry a host returns from `_get_property_list` for this parameter, under `p_name`. `p_spline_keys` is the
## dropdown a PATH parameter offers: ENUM_SUGGESTION rather than ENUM, because the empty key (the host's own
## child) is the default and an enum cannot express "none of these" — Spline Source's reasoning.
func property_info(p_name: String, p_spline_keys: PackedStringArray = PackedStringArray()) -> Dictionary:
	var info := {"name": p_name, "usage": PROPERTY_USAGE_EDITOR}
	match type:
		Type.PATH:
			info["type"] = TYPE_STRING
			if not p_spline_keys.is_empty():
				info["hint"] = PROPERTY_HINT_ENUM_SUGGESTION
				info["hint_string"] = ",".join(p_spline_keys)
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
