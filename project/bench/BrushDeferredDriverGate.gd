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
	_f_live_steps_defer_inside_a_run()
	_g_newest_edit_supersedes_live_only()
	await _h_live_solve_on_worker_matches_synchronous()
	_i_a_stack_edit_is_not_an_unchanged_curve()
	await _j_live_preview_resolution()
	await _k_spline_edit_rebakes_through_the_driver()
	await _l_bake_scale()

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


# --- F. A Live step defers inside a run, and only inside one (Live solves on the worker) --------------
#
# Before, `defer` was compiled for FROZEN steps alone, so a Live erosion solved synchronously on the main
# thread inside pass 1. Inside a run it is now compiled as a frozen step with the RUN's cache, deferring
# on every bake of the run and never serving a stale entry.
func _f_live_steps_defer_inside_a_run() -> void:
	print("[F] a Live erosion step defers inside a deferred run, and not outside one")
	var ero := Pasture3DNodeErosion.new()
	ero.evaluation = Pasture3DNode.Evaluation.LIVE
	var mods: Array[Pasture3DNode] = [ero]
	_mound.modifiers = mods
	_mound.force_gdscript_raster = false

	# CONTROL: outside a run a Live step is exactly what it was — not frozen, not deferred.
	var outside := _first_erosion_step(_mound._compile_modifiers("x").get("gd", []))
	_check("control", not outside.is_empty() and not bool(outside.get("defer", true))
			and not bool(outside.get("frozen", true)),
			"outside a run: defer %s, frozen %s (want false, false)"
					% [outside.get("defer", "<missing>"), outside.get("frozen", "<missing>")])

	var run: int = _mound._begin_deferred_run()
	var inside := _first_erosion_step(_mound._compile_modifiers("x").get("gd", []))
	_check("inside a run", bool(inside.get("defer", false)) and bool(inside.get("frozen", false))
			and bool(inside.get("live_async", false)) and not bool(inside.get("serve_stale", true)),
			"defer %s, frozen %s, live_async %s, serve_stale %s (want true, true, true, false)"
					% [inside.get("defer"), inside.get("frozen"), inside.get("live_async"),
					inside.get("serve_stale")])
	# A FROZEN step in the same run still defers on pass 1 only — so the rule above is not "every step".
	var frz := Pasture3DNodeErosion.new()
	frz.evaluation = Pasture3DNode.Evaluation.FROZEN
	var mods2: Array[Pasture3DNode] = [frz]
	_mound.modifiers = mods2
	var frozen_step := _first_erosion_step(_mound._compile_modifiers("x").get("gd", []))
	_check("frozen unchanged", not bool(frozen_step.get("defer", true))
			and bool(frozen_step.get("serve_stale", false)),
			"a FROZEN step past pass 1: defer %s, serve_stale %s (want false, true)"
					% [frozen_step.get("defer"), frozen_step.get("serve_stale")])

	# The run's cache is what the Live step is handed, and it dies with the run.
	_mound.modifiers = mods
	var grid := PackedFloat32Array([1.0, 2.0, 3.0])
	_mound._file_solved(ero, "x", {"key": 77, "grid": grid}, true)
	var served := _first_erosion_step(_mound._compile_modifiers("x").get("gd", []))
	_check("run cache served", int(served.get("cache_key", 0)) == 77
			and (served.get("cache", PackedFloat32Array()) as PackedFloat32Array) == grid,
			"the step carries key %s and a %d-cell cache (want 77, 3)"
					% [served.get("cache_key"), (served.get("cache", PackedFloat32Array()) as PackedFloat32Array).size()])
	_check("modifier cache untouched", ero.cache_for("x").is_empty(),
			"filing a Live answer wrote nothing into the modifier's own cache")
	_mound._end_deferred_run(run)
	_check("dies with the run", _mound._live_solved.is_empty(), "the run's cache is empty once it ends")
	_mound.modifiers = _no_mods()


# --- G. Newest edit wins, but never at the cost of a Frozen solve --------------------------------------
func _g_newest_edit_supersedes_live_only() -> void:
	print("[G] an edit during a Live-only run cancels it; during a run with a Frozen solve it waits")
	var m := _make_mound()
	var run: int = m._begin_deferred_run()
	m._cancel = false
	m._run_supersedable = m._all_live([{"live": true}, {"live": true}])
	m._on_refresh_timer()
	_check("live only", m._superseded and m._cancel and is_instance_valid(m._timer),
			"superseded %s, cancel %s, re-armed %s (want true, true, true)"
					% [m._superseded, m._cancel, is_instance_valid(m._timer)])
	m._cancel_refresh_timer()
	m._end_deferred_run(run)

	# CONTROL: one Frozen entry in the batch and the same tick only re-arms.
	run = m._begin_deferred_run()
	m._cancel = false
	m._superseded = false
	m._run_supersedable = m._all_live([{"live": true}, {"live": false}])
	m._on_refresh_timer()
	_check("control", not m._superseded and not m._cancel and is_instance_valid(m._timer),
			"superseded %s, cancel %s, re-armed %s (want false, false, true)"
					% [m._superseded, m._cancel, is_instance_valid(m._timer)])
	m._cancel_refresh_timer()
	m._end_deferred_run(run)
	m.queue_free()


# --- H. A Live stack solved on the worker is the stack solved synchronously ----------------------------
#
# End to end through `_bake_deferred`, on real layers. Two stacks: a Live erosion alone, and a Live graph
# over a Live erosion — the chain that needs a second round, because the erosion's surface only exists
# once the graph has landed. Each is baked synchronously and through the driver, and the heights must be
# BITWISE equal. Controls: the erosion must move the ground (else equality is vacuous), and the driver
# must actually have gone to the worker (else it is the synchronous bake twice).
func _h_live_solve_on_worker_matches_synchronous() -> void:
	print("[H] Live stacks solved on the worker equal the synchronous bake, bitwise")
	var t := Pasture3D.new()
	t.name = "LiveTerrain"
	t.vertex_spacing = 1.0
	t.region_size = 64
	add_child(t)
	t.data.add_region_blankp(Vector3.ZERO)
	t.data.update_maps(Pasture3DRegion.TYPE_HEIGHT, false, false)

	var bare := await _h_bake(t, [], false)
	var ero_sync := await _h_bake(t, [_h_erosion()], false)
	var moved := _h_max_diff(bare, ero_sync)
	_check("control: erosion moves the ground", moved > 0.01, "max |eroded - bare| %.4f m (want > 0.01)" % moved)
	var ero_def := await _h_bake(t, [_h_erosion()], true)
	_check("erosion alone", ero_def.get("worker", false) and _h_max_diff(ero_sync, ero_def) == 0.0,
			"worker used %s, max |deferred - sync| %.6f m (want true, 0)"
					% [ero_def.get("worker", false), _h_max_diff(ero_sync, ero_def)])

	var chain_sync := await _h_bake(t, [_h_graph(), _h_erosion()], false)
	var chain_def := await _h_bake(t, [_h_graph(), _h_erosion()], true)
	_check("control: the graph moves the ground", _h_max_diff(ero_sync, chain_sync) > 0.01,
			"max |graph+erosion - erosion| %.4f m (want > 0.01)" % _h_max_diff(ero_sync, chain_sync))
	_check("graph over erosion", chain_def.get("worker", false) and _h_max_diff(chain_sync, chain_def) == 0.0,
			"worker used %s, max |deferred - sync| %.6f m (want true, 0)"
					% [chain_def.get("worker", false), _h_max_diff(chain_sync, chain_def)])

	# The same chain on the GDScript rasteriser, which carries its own copy of the never-serve-stale rule.
	_h_force_gd = true
	var gd_sync := await _h_bake(t, [_h_graph(), _h_erosion()], false)
	var gd_def := await _h_bake(t, [_h_graph(), _h_erosion()], true)
	_h_force_gd = false
	_check("control: GDScript chain moved", _h_max_diff(bare, gd_sync) > 0.01,
			"max |graph+erosion - bare| %.4f m on the GDScript raster (want > 0.01)" % _h_max_diff(bare, gd_sync))
	_check("graph over erosion, GDScript raster", gd_def.get("worker", false) and _h_max_diff(gd_sync, gd_def) == 0.0,
			"worker used %s, max |deferred - sync| %.6f m (want true, 0)"
					% [gd_def.get("worker", false), _h_max_diff(gd_sync, gd_def)])
	t.queue_free()


var _h_force_gd := false


# --- I. A stack edit on an unmoved spline still bakes ---------------------------------------------------
#
# A graph/modifier edit arms every spline without moving a point, and the rect path's double-commit skip
# ("none changed since the last bake") threw it away: a Live graph only updated on an explicit Bake.
# `_last_rect_decision` is the decision itself, so this asks it rather than the editor-only timer.
func _i_a_stack_edit_is_not_an_unchanged_curve() -> void:
	print("[I] a modifier edit on an unmoved spline takes the rect bake, not the skip")
	var t := Pasture3D.new()
	t.name = "RectTerrain"
	t.vertex_spacing = 1.0
	t.region_size = 64
	add_child(t)
	t.data.add_region_blankp(Vector3.ZERO)
	t.data.update_maps(Pasture3DRegion.TYPE_HEIGHT, false, false)
	var m := Pasture3DMound.new()
	m.name = "RectGate"
	m.auto_refresh = false
	var path := Path3D.new()
	var c := Curve3D.new()
	for p in [Vector3(12, 0, 12), Vector3(52, 0, 12), Vector3(52, 0, 52), Vector3(12, 0, 52)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	m.add_child(path)
	add_child(m)
	m.terrain = t
	m._refresh_owner(m._layer_owner, false, [])
	var ids := {path.get_instance_id(): true}

	# CONTROL: the double-commit case the skip exists for still skips.
	m._refresh_owner_rect(m._layer_owner, ids, false, [], false)
	_check("control", m._last_rect_decision == "skip",
			"an armed, unmoved spline with no stack change decides '%s' (want skip)" % m._last_rect_decision)
	m._refresh_owner_rect(m._layer_owner, ids, false, [], true)
	_check("stack edit", m._last_rect_decision == "rect",
			"the same spline after a stack edit decides '%s' (want rect)" % m._last_rect_decision)

	# And the handler is what raises it: a modifier's `changed` sets the flag the tick passes through.
	m._stack_dirty = false
	m._on_modifier_changed()
	_check("handler", m._stack_dirty, "_on_modifier_changed sets _stack_dirty = %s (want true)" % m._stack_dirty)
	m._cancel_refresh_timer()
	remove_child(m)
	m.free()
	t.queue_free()


# --- J. Live Preview Resolution ------------------------------------------------------------------------
#
# Half/Quarter run a Live solver on a coarse grid and upsample its change. Controls: a coarse bake must
# DIFFER from the full one (else the coarse path never ran) and a smooth graph must stay CLOSE to it (else
# the upsample is wrong). Frozen steps and a Bake's full-res hold must be bitwise full resolution, and a
# worker solve of a coarse grid must equal the synchronous coarse bake — which is only true if the solver
# was handed the coarse cell size.
func _j_live_preview_resolution() -> void:
	print("[J] Live Preview Resolution: coarse while Live, full for Frozen and Bake")
	var t := Pasture3D.new()
	t.name = "PreviewTerrain"
	t.vertex_spacing = 1.0
	t.region_size = 64
	add_child(t)
	t.data.add_region_blankp(Vector3.ZERO)
	t.data.update_maps(Pasture3DRegion.TYPE_HEIGHT, false, false)

	var bare := await _h_bake(t, [], false)
	var g_full := await _h_bake(t, [_h_graph()], false, 0)
	var g_half := await _h_bake(t, [_h_graph()], false, 1)
	var g_quarter := await _h_bake(t, [_h_graph()], false, 2)
	var moved := _h_max_diff(bare, g_full)
	_check("control: coarse differs", _h_max_diff(g_full, g_half) > 0.0 and _h_max_diff(g_full, g_quarter) > 0.0,
			"max |half - full| %.4f, |quarter - full| %.4f m (want > 0)"
					% [_h_max_diff(g_full, g_half), _h_max_diff(g_full, g_quarter)])
	_check("graph half close to full", _h_max_diff(g_full, g_half) < 0.25 * moved,
			"max |half - full| %.4f m vs graph effect %.4f m (want < 25%%)" % [_h_max_diff(g_full, g_half), moved])
	_check("warning flag", g_half["coarse"] and g_quarter["coarse"] and not g_full["coarse"],
			"coarse_baked full/half/quarter = %s/%s/%s (want false/true/true)"
					% [g_full["coarse"], g_half["coarse"], g_quarter["coarse"]])

	var held := await _h_bake(t, [_h_graph()], false, 2, true)
	_check("bake holds full res", _h_max_diff(g_full, held) == 0.0 and not held["coarse"],
			"max |bake at quarter - full| %.6f m, coarse %s (want 0, false)" % [_h_max_diff(g_full, held), held["coarse"]])

	var fz_full := _h_graph()
	fz_full.evaluation = Pasture3DNode.Evaluation.FROZEN
	var fz_half := _h_graph()
	fz_half.evaluation = Pasture3DNode.Evaluation.FROZEN
	var f_full := await _h_bake(t, [fz_full], false, 0)
	var f_half := await _h_bake(t, [fz_half], false, 1)
	_check("frozen ignores it", _h_max_diff(f_full, f_half) == 0.0 and _h_max_diff(bare, f_full) > 0.01,
			"max |frozen half - frozen full| %.6f m, moved %.4f (want 0, > 0.01)"
					% [_h_max_diff(f_full, f_half), _h_max_diff(bare, f_full)])

	var e_full := await _h_bake(t, [_h_erosion()], false, 0)
	var e_sync := await _h_bake(t, [_h_erosion()], false, 1)
	var e_def := await _h_bake(t, [_h_erosion()], true, 1)
	_check("control: coarse erosion differs", _h_max_diff(e_full, e_sync) > 0.0,
			"max |half - full| %.4f m (want > 0)" % _h_max_diff(e_full, e_sync))
	_check("coarse erosion on the worker", e_def["worker"] and _h_max_diff(e_sync, e_def) == 0.0,
			"worker %s, max |deferred half - sync half| %.6f m (want true, 0)" % [e_def["worker"], _h_max_diff(e_sync, e_def)])
	t.queue_free()


# --- K. A spline edit re-bakes through the driver ------------------------------------------------------
#
# Pass 1 of a rect bake records the moved curve; pass 2 used to read that as "nothing changed" and skip,
# so a Live stack left the section cleared and unsolved after every point drag. The deferred rect bake must
# equal the synchronous one bitwise. Controls: the move must change the ground, and the worker must run.
func _k_spline_edit_rebakes_through_the_driver() -> void:
	print("[K] a point move re-bakes a Live stack through the deferred driver")
	var sync := await _k_rect_bake(false)
	var def := await _k_rect_bake(true)
	_check("control: the move changes the ground", _h_max_diff(sync["before"], sync) > 0.01,
			"max |after - before| %.4f m (want > 0.01)" % _h_max_diff(sync["before"], sync))
	_check("deferred rect equals sync rect", def["worker"] and _h_max_diff(sync, def) == 0.0,
			"worker %s, decision '%s', max |deferred - sync| %.6f m (want true, rect, 0)"
					% [def["worker"], def["decision"], _h_max_diff(sync, def)])


# --- L. Bake Scale -------------------------------------------------------------------------------------
#
# A Noise-only stack at 2x/4x evaluates the noise on a lattice and interpolates. Controls: it must DIFFER
# from 1x (else the lattice never ran) yet stay close for a smooth noise; a solver in the stack must make it
# bitwise 1x; and a noise too fine for the lattice must be capped back to bitwise 1x.
func _l_bake_scale() -> void:
	print("[L] Bake Scale: lattice point modifiers, refused for solvers, capped by period")
	var t := Pasture3D.new()
	t.name = "BakeScaleTerrain"
	t.vertex_spacing = 1.0
	t.region_size = 64
	add_child(t)
	t.data.add_region_blankp(Vector3.ZERO)
	t.data.update_maps(Pasture3DRegion.TYPE_HEIGHT, false, false)

	var bare := await _h_bake(t, [], false)
	var n1 := await _l_bake(t, [_l_noise(0.02)], 0)
	var n2 := await _l_bake(t, [_l_noise(0.02)], 1)
	var n4 := await _l_bake(t, [_l_noise(0.02)], 2)
	var moved := _h_max_diff(bare, n1)
	_check("control: lattice differs", _h_max_diff(n1, n2) > 0.0 and _h_max_diff(n1, n4) > 0.0,
			"max |2x - 1x| %.5f, |4x - 1x| %.5f m (want > 0)" % [_h_max_diff(n1, n2), _h_max_diff(n1, n4)])
	_check("smooth noise stays close", _h_max_diff(n1, n4) < 0.05 * moved,
			"max |4x - 1x| %.5f m vs noise effect %.4f m (want < 5%%)" % [_h_max_diff(n1, n4), moved])
	_check("scale reported", n2["scale"] == 2 and n4["scale"] == 4 and n1["scale"] == 1,
			"effective 1x/2x/4x = %d/%d/%d" % [n1["scale"], n2["scale"], n4["scale"]])

	var fine1 := await _l_bake(t, [_l_noise(0.2)], 0)
	var fine4 := await _l_bake(t, [_l_noise(0.2)], 2)
	_check("capped by period", fine4["scale"] == 1 and _h_max_diff(fine1, fine4) == 0.0,
			"5 m period at 4x: effective %d, max |4x - 1x| %.6f m (want 1, 0)" % [fine4["scale"], _h_max_diff(fine1, fine4)])

	var s1 := await _l_bake(t, [_l_noise(0.02), _h_erosion()], 0)
	var s4 := await _l_bake(t, [_l_noise(0.02), _h_erosion()], 2)
	_check("refused with a solver", s4["scale"] == 1 and _h_max_diff(s1, s4) == 0.0 and s4["blocked"],
			"effective %d, blocked %s, max |4x - 1x| %.6f m (want 1, true, 0)" % [s4["scale"], s4["blocked"], _h_max_diff(s1, s4)])
	t.queue_free()


func _l_noise(p_freq: float) -> Pasture3DNodeNoise:
	var n := Pasture3DNodeNoise.new()
	var fn := FastNoiseLite.new()
	fn.seed = 11
	fn.frequency = p_freq
	fn.fractal_type = FastNoiseLite.FRACTAL_NONE
	n.noise = fn
	n.strength = 6.0
	return n


func _l_bake(p_terrain: Pasture3D, p_mods: Array, p_scale: int) -> Dictionary:
	var m := Pasture3DMound.new()
	m.name = "BakeScaleGate"
	m.auto_refresh = false
	var path := Path3D.new()
	var c := Curve3D.new()
	for p in [Vector3(12, 0, 12), Vector3(52, 0, 12), Vector3(52, 0, 52), Vector3(12, 0, 52)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	m.add_child(path)
	add_child(m)
	m.terrain = p_terrain
	var mods: Array[Pasture3DNode] = []
	for x in p_mods:
		mods.append(x)
	m.modifiers = mods
	m.bake_scale = p_scale
	var rep: Dictionary = m._bake_scale_report()
	m._refresh_owner(m._layer_owner, false, [])
	var h := _k_heights(p_terrain)
	m.modifiers = _no_mods()
	remove_child(m)
	m.free()
	return {"h": h, "scale": int(rep["scale"]), "blocked": String(rep["blocker"]) != ""}


func _k_rect_bake(p_deferred: bool) -> Dictionary:
	var t := Pasture3D.new()
	t.name = "KTerrain%s" % p_deferred
	t.vertex_spacing = 1.0
	t.region_size = 64
	add_child(t)
	t.data.add_region_blankp(Vector3.ZERO)
	t.data.update_maps(Pasture3DRegion.TYPE_HEIGHT, false, false)
	var m := Pasture3DMound.new()
	m.name = "KGate"
	m.auto_refresh = false
	var path := Path3D.new()
	var c := Curve3D.new()
	for p in [Vector3(12, 0, 12), Vector3(40, 0, 12), Vector3(40, 0, 40), Vector3(12, 0, 40)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	m.add_child(path)
	add_child(m)
	m.terrain = t
	var mods: Array[Pasture3DNode] = [_h_graph(), _h_erosion()]
	m.modifiers = mods
	m.force_deferred_erosion = p_deferred
	m._refresh_owner(m._layer_owner, false, [])
	var before := _k_heights(t)
	if p_deferred:
		# Land the first bake's Live solves too, so both runs start from the same finished terrain.
		await m._bake_deferred(m._refresh_owner.bind(m._layer_owner, false, []), m._layer_owner, false)
		before = _k_heights(t)
	c.set_point_position(2, Vector3(52, 0, 52))
	var bake := m._refresh_owner_rect.bind(m._layer_owner, {path.get_instance_id(): true}, false, [], false)
	var worker := false
	if p_deferred:
		var box := [false]
		var drive := func() -> void:
			await m._bake_deferred(bake, m._layer_owner, false)
			box[0] = true
		drive.call()
		while not box[0]:
			worker = worker or m._running
			await get_tree().process_frame
	else:
		bake.call()
	var out := {"h": _k_heights(t), "before": {"h": before}, "worker": worker, "decision": m._last_rect_decision}
	remove_child(m)
	m.free()
	t.queue_free()
	return out


func _k_heights(p_terrain: Pasture3D) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	for z in range(64):
		for x in range(64):
			h.append(p_terrain.data.get_height(Vector3(float(x), 0.0, float(z))))
	return h


func _h_erosion() -> Pasture3DNodeErosion:
	var e := Pasture3DNodeErosion.new()
	e.evaluation = Pasture3DNode.Evaluation.LIVE
	e.iterations = 8
	return e


func _h_graph() -> Pasture3DNodeGraph:
	var gm := Pasture3DNodeGraph.new()
	gm.evaluation = Pasture3DNode.Evaluation.LIVE
	gm.graph = _graph()
	return gm


## One bake of a fresh 40 m Mound over the region, returning its heights and whether a worker solve ran.
func _h_bake(p_terrain: Pasture3D, p_mods: Array, p_deferred: bool, p_res: int = 0,
		p_full := false) -> Dictionary:
	var m := Pasture3DMound.new()
	m.name = "LiveGate"
	m.auto_refresh = false
	var path := Path3D.new()
	var c := Curve3D.new()
	for p in [Vector3(12, 0, 12), Vector3(52, 0, 12), Vector3(52, 0, 52), Vector3(12, 0, 52)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	m.add_child(path)
	add_child(m)
	m.terrain = p_terrain
	m.force_gdscript_raster = _h_force_gd
	var mods: Array[Pasture3DNode] = []
	for x in p_mods:
		mods.append(x)
	m.modifiers = mods
	m.live_preview_resolution = p_res
	m._preview_full_res = p_full
	var worker := false
	if p_deferred:
		m.force_deferred_erosion = true
		var bake := m._refresh_owner.bind(m._layer_owner, false, [])
		var box := [false]
		var drive := func() -> void:
			await m._bake_deferred(bake, m._layer_owner, false)
			box[0] = true
		drive.call()
		while not box[0]:
			worker = worker or m._running
			await get_tree().process_frame
	else:
		m._refresh_owner(m._layer_owner, false, [])
	var h := PackedFloat32Array()
	for z in range(64):
		for x in range(64):
			h.append(p_terrain.data.get_height(Vector3(float(x), 0.0, float(z))))
	var coarse := m._preview_coarse_baked
	# The next bake must start from bare ground, not from this one's layer.
	m.modifiers = _no_mods()
	remove_child(m)
	m.free()
	return {"h": h, "worker": worker, "coarse": coarse}


func _h_max_diff(p_a: Dictionary, p_b: Dictionary) -> float:
	var a: PackedFloat32Array = p_a.get("h", PackedFloat32Array())
	var b: PackedFloat32Array = p_b.get("h", PackedFloat32Array())
	if a.size() != b.size() or a.is_empty():
		return INF
	var worst := 0.0
	for i in range(a.size()):
		var fa := is_finite(a[i])
		if fa != is_finite(b[i]):
			return INF
		if fa:
			worst = maxf(worst, absf(a[i] - b[i]))
	return worst


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


func _no_mods() -> Array[Pasture3DNode]:
	var none: Array[Pasture3DNode] = []
	return none
