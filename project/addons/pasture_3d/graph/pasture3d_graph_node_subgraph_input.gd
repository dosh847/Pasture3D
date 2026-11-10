# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeSubgraphInput — one input of a graph used as a SUBGRAPH
# (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §11.1). Every Subgraph node that references this graph gets an
# input port with this node's id, label and type, in node order.
#
# ---- WHAT IT READS ----
#
# Inside a parent, nothing: flattening rewires every consumer of this node straight to whatever the parent
# wired into the matching port, so the node itself never runs there. Where that port is unwired, and where
# this graph is evaluated on its own (a brush hosting it directly, its own editor previews), the node is a
# constant: `default_value`. That is what §11.1 means by "its Subgraph Inputs read their defaults".
@tool
class_name Pasture3DGraphNodeSubgraphInput
extends Pasture3DGraphNode

## The port id on every Subgraph node referencing this graph. A saved wire into that port names this, so
## renaming it orphans those wires, exactly as renaming a built-in port would.
@export var input_id: StringName = &"in":
	set(v):
		input_id = v
		emit_changed()

## Editor text for the port. Blank shows the id.
@export var input_label: String = "":
	set(v):
		input_label = v
		emit_changed()

## The port's type. Scalar types only in this phase: a PATH or a COLOR does not travel as a grid, and the
## flattened view carries neither across the boundary yet.
@export_enum("Height:0", "Mask:1", "Float:4", "Int:5", "Bool:7", "Field:10", "Signed:11") var port_type: int = 0:
	set(v):
		port_type = v
		emit_changed()

## What the port reads unwired, and what this node outputs when the graph runs on its own.
@export var default_value: float = 0.0:
	set(v):
		default_value = v
		emit_changed()


func op() -> StringName:
	return &"subgraph_input"


func role() -> Role:
	return Role.GENERATOR


func _inputs() -> Array[Pasture3DGraphPort]:
	return []


func _outputs() -> Array[Pasture3DGraphPort]:
	if Pasture3DGraphNode.is_value_type(port_type):
		return [Pasture3DGraphPort.value(&"out", port_type)]
	return [Pasture3DGraphPort.field(&"out", port_type)]


## The port this node becomes on a Subgraph node.
func as_port() -> Pasture3DGraphPort:
	var p: Pasture3DGraphPort
	if Pasture3DGraphNode.is_value_type(port_type):
		p = Pasture3DGraphPort.value(input_id, port_type)
	else:
		p = Pasture3DGraphPort.field(input_id, port_type)
	p.unwired(default_value)
	p.labelled(input_label if input_label != "" else String(input_id))
	return p


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = default_value
	return {"params": p}


func eval_cell(_p_wx: float, _p_wz: float, _p_inputs: PackedFloat32Array) -> float:
	return default_value


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if input_id == &"":
		w.append("%s: no id, so no Subgraph node can show it as a port." % display_name())
	elif input_id == Pasture3DGraphNode.MASK_PORT_ID:
		w.append("%s: 'mask' is the standard mask's id and cannot be a subgraph input." % display_name())
	return w
