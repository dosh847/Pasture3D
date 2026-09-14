# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSolveStallRepro — RectBakeJunctionGate [C] hung on 2026-09-13: Road2 point 1 dragged (8.5, 0, 8.5)
# logged "evaluating terrain graph on 2 grid(s)…" and nothing for over five minutes, where every earlier
# solve took 90-150 ms. This reproduces that edit with a watchdog, to find WHICH of these it is:
#
#   worker still running   heartbeats continue, task incomplete  -> the native solve itself is not returning
#   not collected          heartbeats continue, task complete    -> the driver's wait loop is not exiting
#   main thread stalled    heartbeats stop                       -> something blocks the main thread
#
# A heartbeat prints once a second with elapsed time, frame count, task id/state and every graph event's
# extent (x,z,gw,gh) — so a grid size gone wild is visible before the solve starts. At WATCHDOG_S it prints
# the verdict, sets `_cancel` and quits. The native solve cannot be interrupted mid-grid, so quitting may
# itself hang waiting for the pool: ALWAYS run this under an outer `timeout`.
#
# Not a gate: there is no pass/fail. Exit 0 = both edits completed, 3 = watchdog fired, 1 = setup failed.
#
# Run: timeout 120 Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphSolveStallRepro.tscn
#      add `-- --prelude` to replay RectBakeJunctionGate [A] and [B] first, if the minimal sequence completes.
extends Node

const MOVER := "Road2"
const DRAG := Vector3(8.5, 0.0, 8.5)
const NUDGE := Vector3(0.5, 0.0, 0.5)
const WATCHDOG_S := 30.0

var _scene: Node
var _net: Pasture3DRoadNetwork
var _mover: Pasture3DRoadBrush
var _owner: String
var _graphs: Array = []
var _in_edit := ""
var _edit_started_ms := 0
var _fired := false

## The first run printed NO heartbeat during the stalled edit — either the main thread stopped, or stdout
## was still buffered when `timeout` killed the process. Both of these survive a kill, so the question
## can be answered: the bake trace journal (flushed per event: the last line is the last thing the main
## thread recorded) and a watcher on its own OS thread (flushed per line: it keeps writing while the main
## thread is blocked, and records whether the frame counter still advances).
const JOURNAL := "user://_graphsolvestall_journal.txt"
const WATCH_LOG := "user://_graphsolvestall_watch.txt"
var _watch_thread: Thread
var _watch_stop := false


func _ready() -> void:
	print("=== GraphSolveStallRepro ===")
	var prelude := OS.get_cmdline_user_args().has("--prelude")
	if not await _setup():
		get_tree().quit(1)
		return
	Pasture3DBakeTrace.journal_path = JOURNAL
	Pasture3DBakeTrace.journal_prev_path = JOURNAL.replace(".txt", "_prev.txt")
	Pasture3DBakeTrace.set_session(true)
	print("journal: %s\nwatcher: %s" % [ProjectSettings.globalize_path(JOURNAL), ProjectSettings.globalize_path(WATCH_LOG)])
	_watch_thread = Thread.new()
	_watch_thread.start(_watch)
	_heartbeat()
	if prelude:
		print("-- prelude: RectBakeJunctionGate [A] rect nudges, then [B] deferred nudges")
		var sp: Path3D = _mover._get_splines()[0]
		for i in sp.curve.point_count:
			var orig := sp.curve.get_point_position(i)
			sp.curve.set_point_position(i, orig + NUDGE)
			_mover._refresh_owner_rect(_owner, {sp.get_instance_id(): true})
			_mover._refresh_owner(_owner, false, [])
			sp.curve.set_point_position(i, orig)
			_mover._refresh_owner(_owner, false, [])
		for i in sp.curve.point_count:
			if not await _deferred_edit(i, NUDGE):
				return
	for i in [0, 1]:
		if not await _deferred_edit(i, DRAG):
			return
	print("\n=== both drags completed: NO STALL reproduced%s ===" % (" (with prelude)" if prelude else
			" (minimal sequence; retry with -- --prelude)"))
	_stop_watch()
	get_tree().quit(0)


func _stop_watch() -> void:
	_watch_stop = true
	if _watch_thread != null and _watch_thread.is_started():
		_watch_thread.wait_to_finish()


## RUNS ON ITS OWN THREAD. Reads only ints/bools/strings the main thread writes (racy by design — this is a
## diagnostic, and a torn read of an int is still a number) and never touches the tree or the trace buffer.
func _watch() -> void:
	var f := FileAccess.open(WATCH_LOG, FileAccess.WRITE)
	if f == null:
		return
	var t0 := Time.get_ticks_msec()
	var last_frame := -1
	var frozen_since := -1
	while not _watch_stop:
		OS.delay_msec(500)
		var frame := Engine.get_process_frames()
		var now := Time.get_ticks_msec()
		if frame == last_frame:
			if frozen_since < 0:
				frozen_since = now
		else:
			frozen_since = -1
		last_frame = frame
		var tid: int = _mover._task_id
		var task := "-" if tid == -1 else ("COMPLETE" if WorkerThreadPool.is_task_completed(tid) else "running")
		f.store_line("[%6.1f s] frame %d%s  edit '%s'  task %d %s  run %s  trace seq %d" % [
				(now - t0) / 1000.0, frame,
				("  FROZEN %.1f s" % ((now - frozen_since) / 1000.0)) if frozen_since >= 0 else "",
				_in_edit, tid, task, _mover._deferred_run != 0, Pasture3DBakeTrace._seq])
		f.flush()
	f.close()


func _setup() -> bool:
	var packed: PackedScene = load("res://demo_road_network.tscn")
	if packed == null:
		print("setup: demo_road_network.tscn did not load")
		return false
	_scene = packed.instantiate()
	add_child(_scene)
	await get_tree().process_frame
	_net = _scene.find_child("Pasture3DRoadNetwork", true, false)
	if _net == null:
		print("setup: no road network")
		return false
	for b in _net.road_brushes():
		if b != null and b.name == MOVER:
			_mover = b
	if _mover == null or _mover._get_splines().is_empty():
		print("setup: %s with a spline not found" % MOVER)
		return false
	_owner = _mover._layer_owner
	for m in _mover.modifiers:
		if m is Pasture3DNodeGraph and m.is_active():
			_graphs.append(m)
	_mover.force_deferred_erosion = true
	_settle()
	print("setup: %s, %d active graph modifier(s), %d control point(s)" % [MOVER, _graphs.size(),
			_mover._get_splines()[0].curve.point_count])
	return true


func _settle() -> void:
	_mover._refresh_owner(_owner, false, [])
	_net.resolve_junctions()
	_mover._refresh_owner(_owner, false, [])


## One RectBakeJunctionGate `_deferred_edits` step, minus the measuring. Returns false if the watchdog fired.
func _deferred_edit(p_i: int, p_off: Vector3) -> bool:
	var sp: Path3D = _mover._get_splines()[0]
	var orig := sp.curve.get_point_position(p_i)
	sp.curve.set_point_position(p_i, orig + p_off)
	for g in _graphs:
		g.clear_cache()
	if not _mover._wants_deferred_bake():
		print("point %d %s: driver not taken" % [p_i, p_off])
		sp.curve.set_point_position(p_i, orig)
		_settle()
		return true
	_in_edit = "point %d %s" % [p_i, p_off]
	_edit_started_ms = Time.get_ticks_msec()
	print("\n-- %s: start (world %s -> %s)" % [_in_edit, sp.global_transform * orig,
			sp.global_transform * (orig + p_off)])
	Pasture3DBakeTrace.mark("repro: %s start" % _in_edit)
	var bake := _mover._refresh_owner_rect.bind(_owner, {sp.get_instance_id(): true}, false)
	await _mover._bake_deferred(bake, _owner, false)
	if _fired:
		return false
	Pasture3DBakeTrace.mark("repro: %s driver returned" % _in_edit)
	print("-- %s: driver returned after %d ms" % [_in_edit, Time.get_ticks_msec() - _edit_started_ms])
	_in_edit = ""
	_mover._refresh_owner(_owner, false, [])
	sp.curve.set_point_position(p_i, orig)
	_settle()
	return true


## Once a second while an edit is in the driver. Runs on process_frame, so if the main thread blocks these
## lines stop — which is itself the "main thread stalled" answer.
func _heartbeat() -> void:
	var last_print := 0
	while true:
		await get_tree().process_frame
		if _in_edit == "":
			continue
		var now := Time.get_ticks_msec()
		if now - last_print < 1000:
			continue
		last_print = now
		var elapsed := (now - _edit_started_ms) / 1000.0
		var tid: int = _mover._task_id
		var completed := tid != -1 and WorkerThreadPool.is_task_completed(tid)
		var extents := PackedStringArray()
		var marks := PackedStringArray()
		for ev in Pasture3DBakeTrace.events():
			if ev["type"] == "graph":
				extents.append("%s %s" % [ev["result"], ev["extent"]])
			elif ev["type"] == "mark" and String(ev["text"]).contains("deferred driver pass"):
				marks.append(String(ev["text"]).get_slice(": ", 1))
		print("   [%5.1f s] frame %d  task %d %s  run %s  cancel %s  last pass [%s]  graphs [%s]" % [
				elapsed, Engine.get_process_frames(), tid,
				"-" if tid == -1 else ("COMPLETE" if completed else "running"),
				_mover._erosion_running, _mover._cancel,
				marks[marks.size() - 1] if not marks.is_empty() else "none", "; ".join(extents)])
		if elapsed >= WATCHDOG_S and not _fired:
			_fired = true
			var verdict := "driver waiting with no task (not a worker stall)"
			if tid != -1 and not completed:
				verdict = "WORKER STILL RUNNING: the native graph solve has not returned"
			elif tid != -1 and completed:
				verdict = "NOT COLLECTED: the task finished but the driver's wait loop did not exit"
			print("\n=== WATCHDOG %.0f s on %s: %s ===" % [WATCHDOG_S, _in_edit, verdict])
			_mover._cancel = true
			_stop_watch()
			get_tree().quit(3)
			return
