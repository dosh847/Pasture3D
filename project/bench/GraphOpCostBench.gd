# GraphOpCostBench — where the time goes in a Plow-shaped terrain graph.
#
# Not a gate. It rebuilds the op mix reported by the game project's Plow graph
# (noise -> noise_jordan -> remap -> blend x2 -> hydraulic_stream_log -> output) and times
# the whole evaluation, then times it again with one op muted at a time. The delta names
# the op that owns the wall clock, and `native_supported` / the GPU route are reported
# alongside so a CPU fallback is visible rather than inferred.
@tool
extends Node

const GW: int = 1024
const GH: int = 1024


func _ready() -> void:
	print("=== GraphOpCostBench ===\n")
	_run()
	get_tree().quit(0)


func _build() -> Dictionary:
	var g := Pasture3DTerrainGraph.new()
	var idx := {}
	idx["input"] = g.add_node(Pasture3DGraphNodeInput.new())
	idx["noise"] = g.add_node(Pasture3DGraphNodeNoise.new())
	idx["noise_jordan"] = g.add_node(Pasture3DGraphNodeNoiseJordan.new())
	idx["remap"] = g.add_node(Pasture3DGraphNodeRemap.new())
	idx["blend"] = g.add_node(Pasture3DGraphNodeBlend.new())
	idx["stream_log"] = g.add_node(Pasture3DGraphNodeHydraulicStreamLog.new())
	var out := g.add_node(Pasture3DGraphNodeOutput.new())
	idx["_out"] = out

	g.connect_ports(idx["noise"], 0, idx["noise_jordan"], 0)
	g.connect_ports(idx["noise_jordan"], 0, idx["remap"], 0)
	g.connect_ports(idx["remap"], 0, idx["blend"], 0)
	g.connect_ports(idx["input"], 0, idx["blend"], 1)
	g.connect_ports(idx["blend"], 0, idx["stream_log"], 0)
	g.connect_ports(idx["stream_log"], 0, out, 0)
	g.set_output(out)
	return {"graph": g, "idx": idx}


func _time(g: Pasture3DTerrainGraph, p_rect: Rect2) -> float:
	var t0: int = Time.get_ticks_usec()
	g.evaluate(GW, GH, p_rect)
	return (Time.get_ticks_usec() - t0) / 1000.0


func _run() -> void:
	var built := _build()
	var g: Pasture3DTerrainGraph = built["graph"]
	var idx: Dictionary = built["idx"]
	var rect := Rect2(0.0, 0.0, 2048.0, 2048.0)

	print("grid %dx%d over %.0f x %.0f m" % [GW, GH, rect.size.x, rect.size.y])
	print("native_supported(): %s" % g.native_supported())
	var gpu_ok: bool = ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu")
	print("graph_eval_grid_gpu bound: %s\n" % gpu_ok)

	# Warm: first call pays compile + any one-time table build.
	g.evaluate(GW, GH, rect)
	var base: float = _time(g, rect)
	print("  full graph                       %9.1f ms" % base)

	var names: Array = ["noise", "noise_jordan", "remap", "blend", "stream_log"]
	print("\n  muting one op at a time — the drop is what that op costs:")
	for n in names:
		var ni: int = int(idx[n])
		g.nodes[ni].muted = true
		g.bump_revision() if g.has_method("bump_revision") else null
		g.evaluate(GW, GH, rect)
		var t: float = _time(g, rect)
		g.nodes[ni].muted = false
		g.bump_revision() if g.has_method("bump_revision") else null
		print("    without %-16s %9.1f ms   (saves %8.1f ms, %5.1f%%)" % [
				n, t, base - t, 100.0 * (base - t) / maxf(base, 0.001)])
