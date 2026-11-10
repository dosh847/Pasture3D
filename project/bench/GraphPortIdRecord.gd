# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphPortIdRecord — what a saved graph's wires ARE, in both spellings, and what the graph compiles to.
# PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §7.
#
# One record per graph file: its index rows (`connections`), the same rows by port id, and a fingerprint of
# the program compiled with each node as the root. It reads only `nodes`, `connections` and the port
# descriptors, so the same code records a graph stored by index and a graph stored by id — which is the
# point: the two records of one graph must be equal.
#
#   godot --headless --path project --script bench/GraphPortIdRecord.gd -- <dir of .tres> <out.json>
#
# `GraphPortIdGate` calls `record()` on its fixtures and compares against the golden this wrote before the
# conversion.
extends SceneTree

const Programs := preload("res://bench/GraphPortPrograms.gd")


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("GraphPortIdRecord: usage: -- <dir> <out.json>")
		quit(2)
		return
	var dir: String = args[0]
	var out := {}
	var names := Array(DirAccess.get_files_at(dir))
	names.sort()
	for fn in names:
		if not String(fn).ends_with(".tres"):
			continue
		var g = ResourceLoader.load(dir.path_join(fn), "", ResourceLoader.CACHE_MODE_IGNORE)
		out[fn] = record(g)
	var f := FileAccess.open(args[1], FileAccess.WRITE)
	f.store_string(JSON.stringify(out, " ", true))
	f.close()
	print("GraphPortIdRecord: wrote %d record(s) to %s" % [out.size(), args[1]])
	quit(0)


## The record of one graph. `problems` is non-empty when a row names a node or port that is not there.
static func record(p_graph) -> Dictionary:
	if not (p_graph is Pasture3DTerrainGraph):
		return {"error": "not a Pasture3DTerrainGraph"}
	var g: Pasture3DTerrainGraph = p_graph
	var rows: Array = []
	var ids: Array = []
	var problems: Array = []
	for c in g.connections:
		var fn := int(c[0]); var fp := int(c[1]); var tn := int(c[2]); var tp := int(c[3])
		rows.append([fn, fp, tn, tp])
		var from: Pasture3DGraphNode = g.nodes[fn] if fn >= 0 and fn < g.nodes.size() else null
		var to: Pasture3DGraphNode = g.nodes[tn] if tn >= 0 and tn < g.nodes.size() else null
		if from == null or to == null:
			problems.append("row %s names a node that is not there" % [[fn, fp, tn, tp]])
			continue
		var outs: Array = from.output_ports()
		var ins: Array = to.input_ports()
		if fp < 0 or fp >= outs.size() or tp < 0 or tp >= ins.size():
			problems.append("row %s names a port that is not there (%s has %d outputs, %s has %d inputs)"
					% [[fn, fp, tn, tp], from.op(), outs.size(), to.op(), ins.size()])
			continue
		ids.append([fn, String(outs[fp].id), tn, String(ins[tp].id)])
	var ops: Array = []
	var programs: Array = []
	for i in range(g.nodes.size()):
		ops.append(String(g.nodes[i].op()) if g.nodes[i] != null else "null")
		var prog: Dictionary = g.compile_graph_program(i)
		programs.append("none" if prog.is_empty() else "%d" % Programs._digest(prog))
	return {"ops": ops, "rows": rows, "ids": ids, "problems": problems, "programs": programs,
			"output_node": g.output_node, "format_version": g.format_version}
