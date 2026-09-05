# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# BrushDeferredDriverGate — the deferred bake driver in Pasture3DTerrainBrush.
# PASTURE3D_PIPELINE_REMEDIATION_SPEC.md P3 (§3.1-§3.6, gate §3.7).
#
# The claim: the three-pass driver survives being torn down, cancelled, or run on a path it does not
# usually take, and leaves nothing behind when it does. Six defects sat in it, and every one of them was
# invisible to a gate that only ever ran the HAPPY path — which is why each criterion here starts from an
# abnormal exit rather than from a bake that finishes.
#
# WHY IT ASSERTS WHAT IT ASSERTS. `_schedule_refresh` is editor-only, so a headless gate cannot see
# scheduling and must assert on the DECISION rather than on `_full_dirty` — the same rule the spec sets
# out. Nothing here loads demo data or touches `data_directory`: the terrain is built in memory, so a
# run cannot dirty the repo, and a clean `git status` afterwards is not being offered as evidence.
#
# House discipline: every criterion carries a CONTROL that must fail if the path is dead.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/BrushDeferredDriverGate.tscn
extends Node

var _fail := 0
var _terrain: Pasture3D
var _mound: Pasture3DMound


func _ready() -> void:
	print("=== BrushDeferredDriverGate: the driver's abnormal exits (P3) ===\n")
	_terrain = Pasture3D.new()
	_terrain.name = "Terrain"
	_terrain.vertex_spacing = 1.0
	add_child(_terrain)
	_mound = _make_mound()

	_a_evaluate_refuses_a_worker_thread()
	_b_teardown_clears_the_running_flag()
	_c_cancel_lands_between_states()
	_d_defer_reaches_the_gdscript_step()
	_e_a_rejected_tick_does_not_eat_the_edit()

	print("\n=== %s (%d failures) ===\n" % ["DEFERRED DRIVER PASS" if _fail == 0 else "DEFERRED DRIVER FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s: %s" % ["  " if p_ok else "!!", p_label, p_detail])


# --- A. evaluate() is a main-thread method, and says so (§3.1) -----------------------------------------
#
# It mutates the shared resource on both routes, so a worker calling it races any main-thread edit of
# graph.nodes. The driver used to call it from `_graph_solve_one`. The guard is the enforcement; this
# criterion is what stops the guard being deleted as noise.
func _a_evaluate_refuses_a_worker_thread() -> void:
	print("[A] Pasture3DTerrainGraph.evaluate() refuses to run off the main thread (§3.1)")
	var g := _graph()
	# CONTROL FIRST, and it is the half that matters: on the MAIN thread the same call produces a real
	# field. Without it, a graph that evaluates to zeros everywhere would pass the assertion below while
	# proving only that nothing happened.
	var on_main := g.evaluate(16, 16, Rect2(0, 0, 64, 64))
	_check("control", _spread(on_main) > 0.05,
			"on the main thread the same graph spreads %.3f m (want > 0.05)" % _spread(on_main))

	# The result comes back in an Array, not a local: a GDScript lambda captures by VALUE, so assigning
	# to a captured local inside the worker leaves the outer one untouched and the assertion below would
	# read an empty array whatever the guard did.
	var box: Array = [PackedFloat32Array()]
	var body := func() -> void:
		box[0] = g.evaluate(16, 16, Rect2(0, 0, 64, 64))
	var task := WorkerThreadPool.add_task(body, true, "gate: evaluate off-thread")
	WorkerThreadPool.wait_for_task_completion(task)
	var off: PackedFloat32Array = box[0]
	_check("off-thread", off.size() == 256 and _spread(off) == 0.0,
			"off the main thread it returns %d defined cells with spread %.3f (want 256, 0.000)"
					% [off.size(), _spread(off)])


# --- B. Teardown ends the run, so the brush is not deaf afterwards (§3.3, §3.2) -----------------------
#
# Every write to `_erosion_running` used to live inside `_bake_deferred`, so either teardown path left it
# set with no owner to clear it. `_on_refresh_timer` then re-armed and returned forever: the brush stopped
# responding to spline drags for the rest of the session, and after the rebake-loop fix landed it also
# stopped DLA seed surfaces re-converging. It is now derived from the run that owns it.
func _b_teardown_clears_the_running_flag() -> void:
	print("[B] EXIT_TREE ends a run in flight, and the driver is claimable again (§3.3)")
	var run: int = _mound._begin_deferred_run()
	_check("control", run != 0 and _mound._erosion_running,
			"a claimed run reads as running (run id %d)" % run)
	# A second claim must be refused while the first holds it — that is the re-entry guard the flag exists
	# for, and a flag that cleared too eagerly would break it just as badly as one that never cleared.
	_check("re-entry", _mound._begin_deferred_run() == 0, "a second claim is refused while one is live")

	_mound._notification(NOTIFICATION_EXIT_TREE)
	_check("after EXIT_TREE", not _mound._erosion_running, "the run is over")
	# And the phase flags it set are over with it: left standing, they make every later synchronous bake
	# behave as though a driver were about to redo it.
	_check("phase flags", not _mound._erosion_defer and not _mound._growth_defer and not _mound._graph_defer,
			"erosion_defer/growth_defer/graph_defer are all clear")
	var again: int = _mound._begin_deferred_run()
	_check("claimable", again != 0, "the driver can be claimed again (run id %d)" % again)
	_mound._end_deferred_run(again)


# --- C. Cancel lands BETWEEN states, not only inside a chunk loop (§3.6 note) -------------------------
#
# `_worker_body` tested `_cancel` only inside `while not p_chunk.call(st)`, and all three of the brush's
# chunk callables return true on their first call — so the body never ran and the flag was never read.
# Results were never wrong; what was lost is the ability to abandon between grids, which on a multi-grid
# solve is the whole point of the button.
func _c_cancel_lands_between_states() -> void:
	print("[C] Cancel abandons between states, not just inside one (§3.6 note)")
	var seen: Array[int] = []
	var chunk := func(p_st: Dictionary) -> bool:
		seen.append(int(p_st["i"]))
		# Cancel arrives while state 0 is being worked, exactly as a user's click would.
		if int(p_st["i"]) == 0:
			_mound._cancel = true
		return true # every real brush callable does this, which is what hid the bug
	var states: Array = [{"i": 0}, {"i": 1}, {"i": 2}]
	_mound._cancel = false
	_mound._worker_body(states, chunk)
	_check("abandoned", seen.size() == 1, "%d of 3 states were worked after the cancel (want 1)" % seen.size())

	# CONTROL: with no cancel the same body works all three. Without this, a `_worker_body` that returned
	# immediately for any reason would pass the assertion above.
	seen.clear()
	_mound._cancel = false
	var chunk_ok := func(p_st: Dictionary) -> bool:
		seen.append(int(p_st["i"]))
		return true
	_mound._worker_body(states, chunk_ok)
	_check("control", seen.size() == 3, "uncancelled, %d of 3 states were worked (want 3)" % seen.size())


# --- D. `defer` reaches the GDScript step, not only the C++ block (§3.6) ------------------------------
#
# The key was written into `blk` alone. `_apply_erosion_step` reads it off `step`, so on the forced
# GDScript path a frozen erosion solved synchronously on the main thread — the freeze the driver exists to
# remove — and `bake_without_erosion()`'s suppression was a no-op there, so "Clear Simulation On All
# Brushes" cleared every cache and re-eroded on the spot.
func _d_defer_reaches_the_gdscript_step() -> void:
	print("[D] a frozen erosion step defers on the forced-GDScript path too (§3.6)")
	var ero := Pasture3DNodeErosion.new()
	ero.evaluation = Pasture3DNode.Evaluation.FROZEN
	var mods: Array[Pasture3DNode] = [ero]
	_mound.modifiers = mods
	_mound.force_gdscript_raster = true

	_mound._erosion_defer = true
	var deferred: Dictionary = _mound._compile_modifiers()
	_mound._erosion_defer = false
	var undeferred: Dictionary = _mound._compile_modifiers()

	var gd_on := _first_erosion_step(deferred.get("gd", []))
	var gd_off := _first_erosion_step(undeferred.get("gd", []))
	if gd_on.is_empty() or gd_off.is_empty():
		_check("fixture", false, "no erosion step was compiled, so [D] proves nothing")
		return
	_check("gd step", bool(gd_on.get("defer", false)),
			"with _erosion_defer set, the GDScript step carries defer = %s (want true)"
					% gd_on.get("defer", "<missing>"))
	# CONTROL: it is not simply hardcoded true. A key written as a constant would pass the line above.
	_check("control", not bool(gd_off.get("defer", false)),
			"with _erosion_defer clear it carries defer = %s (want false)" % gd_off.get("defer", "<missing>"))
	# And the two consumers agree, which is the actual defect: one decision, both dicts.
	var cpp_on := _first_erosion_step(deferred.get("list", []))
	_check("both dicts", bool(cpp_on.get("defer", false)) == bool(gd_on.get("defer", false)),
			"the C++ block and the GDScript step carry the same answer")


# --- E. A tick the guards reject does not discard the edit that armed it (§3.4) -----------------------
#
# The snapshot-and-clear of `_dirty` / `_full_dirty` / `_dirty_splines` sat ABOVE the `is_configured()`
# return, so a rejected tick threw the queued state away: the edit was forgotten rather than deferred.
# And `is_configured()` has no tree check, so a detached node passed it and baked — repainting no
# layer-mate, which punched a permanent hole in a neighbour sharing the layer.
func _e_a_rejected_tick_does_not_eat_the_edit() -> void:
	print("[E] a rejected refresh tick defers the edit instead of eating it (§3.4)")
	var m := _make_mound()
	m._dirty = true
	m._full_dirty = true
	remove_child(m) # detached: is_configured() still passes, is_inside_tree() does not
	_check("fixture", m.is_configured() and not m.is_inside_tree(),
			"the fixture is detached but still is_configured() — the state the guard has to catch")
	m._on_refresh_timer()
	_check("edit kept", m._dirty and m._full_dirty,
			"after a rejected tick the queued edit is still pending (dirty %s, full %s)"
					% [m._dirty, m._full_dirty])

	# CONTROL. The path that DOES bake is unreachable here — `_on_refresh_timer` requires
	# `Engine.is_editor_hint()`, which is false in a headless run — so the control cannot be "the tick
	# consumed the edit". It is instead the §14 branch, which is reachable and has an observable effect:
	# attached, with a deferred run in flight, the tick re-arms a real SceneTreeTimer. That proves the
	# function was entered and read state, which is what rules out the vacuous pass above (an
	# `_on_refresh_timer` that returned at its first line would keep the edit too, for the wrong reason).
	add_child(m)
	var run: int = m._begin_deferred_run()
	m._dirty = true
	m._full_dirty = true
	m._on_refresh_timer()
	_check("control", is_instance_valid(m._timer) and m._dirty and m._full_dirty,
			"with a run in flight the tick re-armed (timer %s) and kept the edit"
					% is_instance_valid(m._timer))
	m._end_deferred_run(run)
	m._cancel_refresh_timer()
	m.queue_free()


# ---- helpers -----------------------------------------------------------------------------------------

func _make_mound() -> Pasture3DMound:
	var m := Pasture3DMound.new()
	m.name = "Gate%d" % (randi() % 100000)
	add_child(m)
	m.terrain = _terrain
	var path := Path3D.new()
	var c := Curve3D.new()
	for p in [Vector3(-20, 0, -20), Vector3(20, 0, -20), Vector3(20, 0, 20), Vector3(-20, 0, 20)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	m.add_child(path)
	return m


func _first_erosion_step(p_steps: Array) -> Dictionary:
	for st in p_steps:
		if st is Dictionary and st.get("op", &"") == &"erosion":
			return st
	return {}


func _graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var n := Pasture3DGraphNodeNoise.new()
	var fn := FastNoiseLite.new()
	fn.seed = 5
	fn.frequency = 0.05
	n.noise = fn
	n.amplitude = 12.0
	var nodes: Array[Pasture3DGraphNode] = [n]
	g.nodes = nodes
	g.output_node = 0
	return g


func _spread(p: PackedFloat32Array) -> float:
	if p.is_empty():
		return 0.0
	var lo := INF
	var hi := -INF
	for v in p:
		if not is_finite(v):
			continue
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return 0.0 if lo > hi else hi - lo
