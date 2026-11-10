# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeSubgraphOutput — one output of a graph used as a SUBGRAPH
# (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §11.1). Every Subgraph node that references this graph gets an
# output port with this node's id, label and type, in node order, carrying whatever is wired in here.
#
# A passthrough, like Output: inside a parent, flattening wires each consumer of the Subgraph node's port
# straight to this node's source, so the node only runs when something taps the port itself (a preview, a
# sink reading it). It lowers to the same native passthrough Reroute does.
@tool
class_name Pasture3DGraphNodeSubgraphOutput
extends Pasture3DGraphNode

## The port id on every Subgraph node referencing this graph. See Pasture3DGraphNodeSubgraphInput.input_id.
@export var output_id: StringName = &"out":
	set(v):
		output_id = v
		emit_changed()

## Editor text for the port. Blank shows the id.
@export var output_label: String = "":
	set(v):
		output_label = v
		emit_changed()

## The port's type. Scalar types only in this phase; see Pasture3DGraphNodeSubgraphInput.port_type.
@export_enum("Height:0", "Mask:1", "Float:4", "Int:5", "Bool:7", "Field:10", "Signed:11") var port_type: int = 0:
	set(v):
		port_type = v
		emit_changed()


func op() -> StringName:
	return &"subgraph_output"


func role() -> Role:
	return Role.FILTER


## A boundary has nothing to mask; the Subgraph node carries the mask.
func mask_mode() -> MaskMode:
	return MaskMode.NONE


## A sink in its own graph, like Output: its value leaves through the Subgraph node.
func has_output() -> bool:
	return false


func _inputs() -> Array[Pasture3DGraphPort]:
	if Pasture3DGraphNode.is_value_type(port_type):
		return [Pasture3DGraphPort.value(&"in", port_type)]
	return [Pasture3DGraphPort.field(&"in", port_type).require()]


func _outputs() -> Array[Pasture3DGraphPort]:
	if Pasture3DGraphNode.is_value_type(port_type):
		return [Pasture3DGraphPort.value(&"out", port_type)]
	return [Pasture3DGraphPort.field(&"out", port_type)]


## The port this node becomes on a Subgraph node.
func as_port() -> Pasture3DGraphPort:
	var p: Pasture3DGraphPort
	if Pasture3DGraphNode.is_value_type(port_type):
		p = Pasture3DGraphPort.value(output_id, port_type)
	else:
		p = Pasture3DGraphPort.field(output_id, port_type)
	p.labelled(output_label if output_label != "" else String(output_id))
	return p


func eval_cell(_p_wx: float, _p_wz: float, p_inputs: PackedFloat32Array) -> float:
	return p_inputs[0] if p_inputs.size() > 0 else 0.0


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if output_id == &"":
		w.append("%s: no id, so no Subgraph node can show it as a port." % display_name())
	return w
