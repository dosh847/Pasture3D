# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphPortPrograms — a fingerprint of the NATIVE PROGRAM each registered node compiles to, wired and
# unwired. PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §6.3.
#
# The port table (`GraphPortTable.gd`) proves the accessors still answer the same. This proves the thing
# they feed: `native_param_ports`, `aux_grid_port` and `input_unwired_default` all land in the compiled
# program, so a port that moved changes these bytes even if some reader of the table would not notice.
#
# Two fixtures per op, built by assigning `nodes` / `connections` directly so that nothing here depends on
# what `connect_ports` accepts:
#   unwired   the node alone, compiled with itself as the root.
#   wired     one Const driving every scalar input the node has, compiled with the node as the root.
#
# The spec asks for "every demo graph". There are no standalone graph files — every authored graph is a
# sub-resource of a demo scene, and those are not loaded headless — so this covers every op instead.
#
# `GraphPortProgramsWrite.gd` writes the golden; `GraphPortDescriptorGate` [B] compares against it.
extends RefCounted

const GOLDEN := "res://bench/golden/graph_port_programs.txt"


## One row per (op, fixture): `op|fixture|fingerprint`. "none" when the graph does not lower.
static func table() -> PackedStringArray:
	var out := PackedStringArray()
	for e in Pasture3DGraphNodeRegistry.entries(true):
		var script: GDScript = e["script"]
		out.append("%s|unwired|%s" % [e["op"], fingerprint(script.new(), false)])
		out.append("%s|wired|%s" % [e["op"], fingerprint(script.new(), true)])
	return out


## The fingerprint of `p_node`'s compiled program. `p_node` is not `on_created()`: that step may pick a
## random seed, and this has to be the same number on every run.
static func fingerprint(p_node: Pasture3DGraphNode, p_wired: bool) -> String:
	var g := Pasture3DTerrainGraph.create_empty()
	var c := Pasture3DGraphNodeConst.new()
	c.value = 0.5
	var conns: Array = []
	if p_wired:
		var types := p_node.input_port_types()
		for i in range(p_node.input_count()):
			var t: int = types[i]
			if t == Pasture3DGraphNode.PortType.COLOR or t == Pasture3DGraphNode.PortType.PATH:
				continue
			conns.append(PackedInt32Array([0, 0, 1, i]))
	g.nodes = [c, p_node]
	g.connections = conns
	var prog: Dictionary = g.compile_graph_program(1)
	if prog.is_empty():
		return "none"
	return "%d" % _digest(prog)


static func _digest(p_v) -> int:
	match typeof(p_v):
		TYPE_DICTIONARY:
			var keys: Array = p_v.keys()
			keys.sort_custom(func(a, b): return str(a) < str(b))
			var h := 17
			for k in keys:
				# A frozen solver's row carries its instance id. Ids are handed out in allocation order,
				# so the number moves whenever anything allocates one more object before it — measured:
				# Erosion and DLA were the only rows that differed across the port migration, by this.
				if str(k) == "node_id":
					continue
				h = hash([h, str(k), _digest(p_v[k])])
			return h
		TYPE_ARRAY:
			var h := 19
			for e in p_v:
				h = hash([h, _digest(e)])
			return h
		TYPE_OBJECT:
			# A FastNoiseLite or a node reference: identity is not stable between runs and is not a port fact.
			return 23 if p_v != null else 29
		TYPE_NIL:
			return 29
		TYPE_PACKED_FLOAT32_ARRAY:
			# NaN is a legal parameter (an "unwired" sentinel) and hashes unpredictably as a float.
			return hash((p_v as PackedFloat32Array).to_byte_array())
	return hash(p_v)
