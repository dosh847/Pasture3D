# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphPort — one port of one graph node, declared once.
# PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §6.
#
# A port used to be declared in up to seven places matched by index: `input_count`, `input_names`,
# `input_port_types`, `input_unwired_default`, `native_param_ports`, `aux_grid_port`, and the editor's
# `SLOT_SPINS` table keyed by op and port number. Adding a port meant editing all of them in step, and
# nothing checked that they agreed. A node now returns a list of these from `_inputs()` / `_outputs()`
# and every one of those accessors is derived from it.
#
# ---- field() AND value() ARE SEPARATE ON PURPOSE ----
#
# A FIELD port carries one value per cell; a VALUE port carries one number for the whole port
# (`Pasture3DGraphNode.PortType` header). The native evaluator needs to know which, and a port that says
# one thing by its type and another by its params slot is the bug seven shipped ports had. So a field port
# cannot be given a params slot at all, and a value port is where the slot and the backing property live.
#
# ---- `id` IS FOREVER ----
#
# It becomes the identity a saved wire names (spec §7). Renaming one orphans every wire into it. `label`
# is the text the editor shows and is free to change.
@tool
class_name Pasture3DGraphPort
extends RefCounted

## Stable identity within the node's inputs (or its outputs).
var id: StringName = &""
## Editor text. Defaults to the id.
var label: String = ""
## A `Pasture3DGraphNode.PortType`.
var type: int = 0
## What the port reads unwired, when no `property` backs it.
var default_value: float = 0.0
## Unwired is a warning. A port that has a meaningful unwired reading is not required.
var required: bool = false
## The node property that is this port's unwired value and its inline widget; `&""` for none.
var property: StringName = &""
## The native params slot a wire into this port overrides; -1 when it has none. Always -1 on a field port.
var native_slot: int = -1
## True on the node's secondary GRID operand (the mask, the noise field), which rides the program's aux
## input rather than one of the four numbered ones.
var aux: bool = false
## True when built by `value()`.
var is_value: bool = false
## P8 (spec §12): an input that takes any number of wires, each an operand, in `connections` row order.
## Only a node the flat view lowers (Combine) may declare one: every evaluator below it reads one wire per
## input.
var multi: bool = false


## A port carrying a grid (or a PATH).
static func field(p_id: StringName, p_type: int) -> Pasture3DGraphPort:
	var p := Pasture3DGraphPort.new()
	p.id = p_id
	p.label = String(p_id)
	p.type = p_type
	return p


## A port carrying one number. `p_property` is the node property that supplies it unwired and that the
## editor edits inline; `p_slot` is the native params slot a wire overrides, or -1 when the op has none.
static func value(p_id: StringName, p_type: int, p_property: StringName = &"", p_slot: int = -1) -> Pasture3DGraphPort:
	var p := Pasture3DGraphPort.new()
	p.id = p_id
	p.label = String(p_id)
	p.type = p_type
	p.property = p_property
	p.native_slot = p_slot
	p.is_value = true
	return p


## Unwired is a warning.
func require() -> Pasture3DGraphPort:
	required = true
	return self


## The unwired reading, for a port no property backs.
func unwired(p_value: float) -> Pasture3DGraphPort:
	default_value = p_value
	return self


## A FIELD port whose unwired reading is a node property: unwired, every cell reads that number.
func backed_by(p_property: StringName) -> Pasture3DGraphPort:
	property = p_property
	return self


## An input that keeps every wire made into it instead of replacing the last (spec §12).
func accepts_many() -> Pasture3DGraphPort:
	multi = true
	return self


## Marks the node's secondary grid operand. At most one input per node.
func as_aux() -> Pasture3DGraphPort:
	aux = true
	return self


## Editor text different from the id.
func labelled(p_label: String) -> Pasture3DGraphPort:
	label = p_label
	return self
