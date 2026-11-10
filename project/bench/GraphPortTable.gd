# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphPortTable — every graph node script's port declarations as plain text, one row per port.
# PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §6.3.
#
# It reads ONLY the public accessors (`input_count`, `input_names`, `input_port_types`,
# `input_unwired_default`, `native_param_ports`, `aux_grid_port`, `output_*`), which is what every
# evaluator, the editor and the sinks read. So the same table can be taken before and after the way a node
# DECLARES its ports changes, and a difference between the two is a port that moved.
#
# Keyed by SCRIPT FILE, not by registry op: the abstract bases (leveler, path shape, the sinks) and the
# node template carry declarations too, and no registry entry names them.
#
# `GraphPortTableWrite.gd` writes the golden file; `GraphPortDescriptorGate` [A] compares against it.
extends RefCounted

const GRAPH_DIR := "res://addons/pasture_3d/graph"
const GOLDEN := "res://bench/golden/graph_port_table.txt"


## Every node script under the graph directory, sorted, as res:// paths.
static func node_scripts() -> PackedStringArray:
	var out := PackedStringArray()
	for dir in [GRAPH_DIR, GRAPH_DIR + "/templates"]:
		for f in DirAccess.get_files_at(dir):
			if f.ends_with(".gd"):
				var path: String = dir + "/" + f
				var s := load(path) as Script
				if s != null and _is_graph_node(s):
					out.append(path)
	out.sort()
	return out


static func _is_graph_node(p_script: Script) -> bool:
	var s := p_script
	while s != null:
		if s.get_global_name() == &"Pasture3DGraphNode":
			return true
		s = s.get_base_script()
	return false


## The rows for one node instance, each prefixed with `p_key`.
static func rows_of(p_key: String, p_node: Pasture3DGraphNode) -> PackedStringArray:
	var out := PackedStringArray()
	var n_in := p_node.input_count()
	var names := p_node.input_names()
	var types := p_node.input_port_types()
	var pmap := p_node.native_param_ports()
	var aux := p_node.aux_grid_port()
	out.append("%s|counts|in=%d|out=%d|has_output=%s" % [p_key, n_in, p_node.output_count(), p_node.has_output()])
	for i in range(n_in):
		out.append("%s|in|%d|%s|%d|%s|%d|%s" % [p_key, i,
				names[i] if i < names.size() else "<missing>",
				int(types[i]) if i < types.size() else -99,
				_num(p_node.input_unwired_default(i)),
				int(pmap[i]) if i < pmap.size() else -1,
				"aux" if i == aux else "-"])
	# An aux index or a names/types array that disagrees with the port count is a declaration too, and one
	# the per-port rows above cannot show. The LENGTH of the params map is deliberately not here: every
	# reader treats a short map as -1 past its end, so `[]` and `[-1, -1]` are the same declaration.
	out.append("%s|in_extra|aux=%d|names=%d|types=%d" % [p_key, aux, names.size(), types.size()])
	var onames := p_node.output_names()
	var otypes := p_node.output_port_types()
	for i in range(p_node.output_count()):
		out.append("%s|out|%d|%s|%d" % [p_key, i,
				onames[i] if i < onames.size() else "<missing>",
				int(otypes[i]) if i < otypes.size() else -99])
	out.append("%s|out_extra|names=%d|types=%d|port0=%d" % [p_key, onames.size(), otypes.size(), p_node.output_port_type()])
	return out


## The whole table, one line per row.
static func table() -> PackedStringArray:
	var out := PackedStringArray()
	for path in node_scripts():
		var s := load(path) as GDScript
		var n = s.new() if s != null and s.can_instantiate() else null
		var key := path.get_file().get_basename()
		if n == null or not (n is Pasture3DGraphNode):
			out.append("%s|uninstantiable" % key)
			continue
		out.append_array(rows_of(key, n))
	return out


static func _num(p_v: float) -> String:
	if is_nan(p_v):
		return "nan"
	if is_inf(p_v):
		return "inf" if p_v > 0.0 else "-inf"
	return String.num(p_v, 6)
