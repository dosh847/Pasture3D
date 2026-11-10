# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# A fixture node for GraphPortIdGate [C]: two inputs, `a` and `b`, and a switch that declares a third one
# IN FRONT of them. That is the edit port ids exist to survive — every index after the new port moves, and
# no id does. A file of its own, not an inner class: the gate saves a graph holding one, and a sub-resource
# needs a script the loader can find.
@tool
extends Pasture3DGraphNode

@export var extra_first: bool = false:
	set(v):
		extra_first = v
		emit_changed()


func _init() -> void:
	super()


func op() -> StringName:
	return &"blend"


func _inputs() -> Array[Pasture3DGraphPort]:
	var ports: Array[Pasture3DGraphPort] = []
	if extra_first:
		ports.append(Pasture3DGraphPort.field(&"extra", PortType.HEIGHT))
	ports.append(Pasture3DGraphPort.field(&"a", PortType.HEIGHT))
	ports.append(Pasture3DGraphPort.field(&"b", PortType.HEIGHT))
	return ports
