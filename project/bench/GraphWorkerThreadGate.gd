# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphWorkerThreadGate — the SUPPORTED worker-thread route solves a solver graph correctly, and the
# unsupported one refuses. PASTURE3D_PIPELINE_REMEDIATION_SPEC.md §7.4 (the gate) for §3.1 (the contract).
#
# WHY THIS WAS REWRITTEN. The previous version had no failure counter, called `get_tree().quit(0)`
# unconditionally, and expressed its three checks as `assert()`s — compiled out of release builds, so a
# release run printed PASS and exited 0 whatever happened. One check, `state["done"] == 1` after
# `wait_for_task_completion`, is true by construction. Its graph was `Noise -> Output` with no solver in
# it, so the regression it is named for could not reach it. And it wired that graph with
# `graph.connect_nodes(...)`, which DOES NOT EXIST on Pasture3DTerrainGraph — the call errored, the two
# nodes were never connected, and what it timed was an unwired generator.
#
# THE CONTRACT (§3.1). `Pasture3DTerrainGraph.evaluate()` mutates the shared resource on both its routes
# — node caches, access ticks, eviction — so it refuses off the main thread and returns zeros. The
# supported split is COMPILE HERE, SOLVE THERE: `compile_graph_program()` on the main thread, the
# stateless `Pasture3DUtil.graph_eval_grid` on the worker. Both halves are checked.
#
#   [A] the worker solve completes, on the stateless entry point, with a solver in the graph
#   [B] and agrees with the main thread's evaluate, cell for cell
#   [C] the worker declines the GPU route (RenderingDevice is main-thread only)
#   [D] evaluate() itself refuses off the main thread rather than racing the resource
#   [E] the field is finite and actually eroded, so [B] is not two flat grids agreeing
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphWorkerThreadGate.tscn
@tool
extends Node

const GW := 128
const GH := 128

var _fail := 0
var _rect := Rect2(Vector2(-64.0, -64.0), Vector2(128.0, 128.0))


func _ready() -> void:
	print("=== GraphWorkerThreadGate: the worker-thread contract (§7.4 / §3.1) ===\n")
	var graph := _solver_graph()

	# Main thread: the reference field, and the compiled program the worker is allowed to carry.
	var main_z: PackedFloat32Array = graph.evaluate(GW, GH, _rect, null, PackedFloat32Array())
	var main_thr: int = _threshold()
	var prog: Dictionary = graph.compile_graph_program()

	var state := {"z": PackedFloat32Array(), "bad": PackedFloat32Array(), "thr": -1, "done": 0, "ms": 0}
	var task := WorkerThreadPool.add_task(func():
		var t0 := Time.get_ticks_msec()
		state["thr"] = _threshold()
		# The supported route: stateless, takes the program by value, touches no graph state.
		state["z"] = Pasture3DUtil.graph_eval_grid(prog, GW, GH, _rect, PackedFloat32Array())
		# ...and the unsupported one, for [D]. Expected to push an error and hand back zeros.
		state["bad"] = graph.evaluate(GW, GH, _rect, null, PackedFloat32Array())
		state["ms"] = Time.get_ticks_msec() - t0
		state["done"] = 1
	, true, "GraphWorkerThreadGate")

	# Bounded, not a bare `wait_for_task_completion`. The regression this gate is named for presents as a
	# DEADLOCK, and a gate that waits forever on one reports nothing at all. A hang must fail.
	var deadline := Time.get_ticks_msec() + 60000
	while not WorkerThreadPool.is_task_completed(task) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not WorkerThreadPool.is_task_completed(task):
		_check(false, "the worker task did not finish within 60 s — a worker blocking on main-thread "
				+ "state is exactly the §3.1 regression; not waiting further")
		print("\n=== GRAPH WORKER THREAD FAIL (%d failures) ===\n" % _fail)
		get_tree().quit(1)
		return
	WorkerThreadPool.wait_for_task_completion(task)

	_a_it_ran(state, prog)
	_b_same_field(main_z, state["z"])
	_c_no_gpu_on_the_worker(main_thr, int(state["thr"]))
	_d_evaluate_refuses(state["bad"])
	_e_the_field_is_real(main_z)

	print("\n=== %s (%d failures) ===\n" % ["GRAPH WORKER THREAD PASS" if _fail == 0 else "GRAPH WORKER THREAD FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])


## Noise -> Hydraulic erosion -> Output. The erosion node is the point: it is a Pasture3DGraphSolverNode,
## the class §3.1 is about, and its native solver is what a worker must be safe to enter.
func _solver_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var noise := Pasture3DGraphNodeNoise.new()
	# The node's noise slot is null by default and a null slot evaluates to a FLAT field — which [E]
	# would reject, and which would make [B] compare two identical zero grids and prove nothing.
	var fnl := FastNoiseLite.new()
	fnl.frequency = 0.02
	noise.noise = fnl
	noise.amplitude = 25.0
	g.nodes.append(noise)
	var ero := Pasture3DGraphNodeErosionHydraulic.new()
	ero.iterations = 8 # enough to move the surface, short enough to keep the gate quick
	g.nodes.append(ero)
	g.nodes.append(Pasture3DGraphNodeOutput.new())
	g.connect_ports(0, 0, 1, 0)
	g.connect_ports(1, 0, 2, 0)
	return g


## The GPU crossover as the CURRENT thread sees it — 0 off the main thread, which is how the graph
## declines RenderingDevice there.
func _threshold() -> int:
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_gpu_threshold", true):
		return -1
	return Pasture3DUtil.graph_gpu_threshold()


# --- A ------------------------------------------------------------------------------------------------
func _a_it_ran(p_state: Dictionary, p_prog: Dictionary) -> void:
	print("[A] the worker solved the compiled program")
	_check(not p_prog.is_empty(), "the graph compiled to a native program on the main thread")
	_check(int(p_state["done"]) == 1, "the task finished (in %d ms)" % int(p_state["ms"]))
	var z: PackedFloat32Array = p_state["z"]
	_check(z.size() == GW * GH, "and returned a full grid (%d, expected %d)" % [z.size(), GW * GH])


# --- B ------------------------------------------------------------------------------------------------
func _b_same_field(p_main: PackedFloat32Array, p_worker: PackedFloat32Array) -> void:
	print("\n[B] the worker's field matches the main thread's, cell for cell")
	if p_main.size() != p_worker.size() or p_main.is_empty():
		_check(false, "sizes differ (%d vs %d) — nothing to compare" % [p_main.size(), p_worker.size()])
		return
	var worst := 0.0
	var at := -1
	for i in range(p_main.size()):
		var d: float = absf(p_main[i] - p_worker[i])
		if d > worst:
			worst = d
			at = i
	# Not bit equality: the main-thread run may legitimately take the GPU route at a large enough grid,
	# and GPU/CPU agree to float precision. 1 mm is far below anything a terrain shows.
	_check(worst <= 1.0e-3, "worst cell disagreement %.6f m (cell %d), tolerance 0.001" % [worst, at])

	# CONTROL. The comparison must be able to FAIL — a loop that never read the values would pass on any
	# two arrays.
	var bent := p_worker.duplicate()
	bent[0] = bent[0] + 1.0
	var seen := false
	for i in range(p_main.size()):
		if absf(p_main[i] - bent[i]) > 1.0e-3:
			seen = true
			break
	_check(seen, "control: a 1 m error in one cell IS detected by this comparison")


# --- C ------------------------------------------------------------------------------------------------
func _c_no_gpu_on_the_worker(p_main_thr: int, p_worker_thr: int) -> void:
	print("\n[C] the worker declines the GPU route (RenderingDevice is main-thread only)")
	_check(p_main_thr >= 0 and p_worker_thr >= 0,
			"Pasture3DUtil.graph_gpu_threshold is bound, so this criterion can run at all")
	if p_main_thr < 0 or p_worker_thr < 0:
		return
	_check(p_worker_thr == 0, "graph_gpu_threshold() on the worker is 0 (got %d)" % p_worker_thr)
	# CONTROL. 0 on BOTH threads would pass the check above for the wrong reason — the GPU path disabled
	# everywhere rather than declined on workers.
	_check(p_main_thr > 0, "control: on the main thread it is non-zero (%d), so [C] is thread-specific"
			% p_main_thr)


# --- D ------------------------------------------------------------------------------------------------
func _d_evaluate_refuses(p_bad: PackedFloat32Array) -> void:
	print("\n[D] evaluate() itself refuses off the main thread rather than racing the resource")
	_check(p_bad.size() == GW * GH, "it still returns a defined grid (%d cells)" % p_bad.size())
	var nonzero := 0
	for v in p_bad:
		if v != 0.0:
			nonzero += 1
	# Zeros, not a half-evaluated field: the refusal's whole point is that a caller ignoring the pushed
	# error gets something defined instead of a race. A non-zero cell here means the walk ran anyway.
	_check(nonzero == 0, "and it is all zeros (%d non-zero cells) — the documented refusal" % nonzero)


# --- E ------------------------------------------------------------------------------------------------
func _e_the_field_is_real(p_z: PackedFloat32Array) -> void:
	print("\n[E] the field is finite and actually eroded")
	var lo := INF
	var hi := -INF
	var bad := 0
	for v in p_z:
		if not is_finite(v):
			bad += 1
			continue
		lo = minf(lo, v)
		hi = maxf(hi, v)
	_check(bad == 0, "no non-finite cells (%d)" % bad)
	# Two paths that both returned a flat zero grid would agree perfectly and mean nothing.
	_check(hi - lo > 1.0, "relief spans %.3f m, so the graph produced a surface" % (hi - lo))
