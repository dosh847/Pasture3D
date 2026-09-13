# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# BakeTraceGate — Pasture3DBakeTrace records what a bake actually did, and records NOTHING when it is off.
#
# The claim: driving the REAL graph step on a REAL brush produces graph-cache events whose result field
# matches what the cache really did, bake spans pair and carry their repaint count, the ring buffer evicts
# oldest-first, and the whole thing is inert while disabled.
#
# ---- WHAT THIS GATE DELIBERATELY DOES NOT COVER ----
#
# The arm/stack half — the field that answers "what woke this brush" — cannot be exercised here. All three
# schedulers sit behind `_can_auto_refresh()`, which requires `Engine.is_editor_hint()`, and `get_stack()`
# is only populated under the editor besides. A headless gate that called `Pasture3DBakeTrace.arm()`
# itself would be asserting on its own call rather than on anything the system did, and would pass with
# the scheduler wiring deleted. So criterion F REPORTS that gap instead of papering over it: a PASS here
# is not evidence that the schedulers are wired, and the gate says so out loud.
extends Node

const GW := 16
const GH := 16
const VS := 1.0

var _fail := 0
var _ran := 0
var _brush: Pasture3DMound


func _ready() -> void:
	print("=== BakeTraceGate: bake causality recorder ===\n")
	_brush = Pasture3DMound.new()
	add_child(_brush)
	_run_all()
	print("\n  criteria completed: %d" % _ran)
	print("\n=== %s (%d failures) ===\n" % ["BAKE TRACE PASS" if _fail == 0 else "BAKE TRACE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _run_all() -> void:
	_a_off_records_nothing()
	_b_miss_then_hit()
	_c_stale_is_distinguished()
	_d_bake_span_pairs()
	_e_ring_buffer_evicts()
	_g_session_toggle_writes_report()
	_f_report_the_uncovered_half()


## [A] The control that must fail if anything here is ambient. With tracing OFF, the same bake that
## criterion B records must produce ZERO events — otherwise B is measuring something other than the switch.
func _a_off_records_nothing() -> void:
	print("[A] disabled: a real bake records nothing")
	Pasture3DBakeTrace.stop()
	Pasture3DBakeTrace.start()      # clear the buffer...
	Pasture3DBakeTrace.stop()       # ...then go dark before the bake
	var m := _graph_mod()
	_bake(m, "0,0,16,16")
	var n := Pasture3DBakeTrace.event_count()
	print("    events while disabled = %d (want 0)" % n)
	if n != 0:
		_fail += 1
		print("    !! the recorder is not actually gated by `enabled`")
	_ran += 1


## [B] A cold frozen cache MISSES and is recorded as a miss; the next identical bake HITS and is recorded
## as a hit. Driven through `_run_modifier_stack`, the same call a bake makes — not through the tracer.
func _b_miss_then_hit() -> void:
	print("[B] cold bake records MISS, warm bake records HIT")
	Pasture3DBakeTrace.start(false)
	var m := _graph_mod()
	_bake(m, "0,0,16,16")
	_bake(m, "0,0,16,16")
	var results := _graph_results()
	print("    graph events = %s (want [MISS, HIT])" % str(results))
	if results != ["MISS", "HIT"]:
		_fail += 1
		print("    !! the recorded cache decisions do not match what the cache did")
	var miss_us := _first_graph_us()
	print("    the MISS carries a solve time: %d us (want > 0)" % miss_us)
	if miss_us <= 0:
		_fail += 1
		print("    !! a miss was recorded without the cost that makes it worth recording")
	_ran += 1


## [C] STALE is a distinct outcome from HIT. A served-but-outdated cache is the case that looks like a
## solver bug from outside, so collapsing it into HIT would hide exactly the thing worth seeing.
func _c_stale_is_distinguished() -> void:
	print("[C] a served-but-changed cache records STALE, not HIT")
	Pasture3DBakeTrace.start(false)
	var m := _graph_mod()
	_bake(m, "0,0,16,16")                    # MISS, fills the cache
	m.graph.nodes[0].set("amplitude", 99.0)  # the graph moves under the frozen cache
	_bake(m, "0,0,16,16")                    # served anyway, but no longer current
	var results := _graph_results()
	print("    graph events = %s (want [MISS, STALE])" % str(results))
	if results != ["MISS", "STALE"]:
		_fail += 1
		print("    !! STALE is not being distinguished from HIT")
	_ran += 1


## [D] A bake span opens and closes, and the close carries how many tools were repainted — the number that
## makes a shared layer legible. Driven through the real `_refresh_owner`, which is not editor-gated.
##
## THIS CRITERION USED TO BE A FALSE PASS. With no terrain assigned, `_refresh_owner` returns at its
## `is_configured()` guard, so it recorded begin=0 end=0 and the equality assertion was `0 == 0` — it would
## have passed with every `bake_begin` call deleted from the brush. So the unconfigured case is demoted to
## what it actually proves (an early return leaves no dangling span) and kept as the CONTROL, and the real
## assertion now runs against a live `Pasture3D` so there is a span to pair.
func _d_bake_span_pairs() -> void:
	print("[D] a real _refresh_owner opens and closes one span")

	# Control: unconfigured. The guard fires before `bake_begin`, so this must record NOTHING — and if it
	# records a begin, the span is dangling.
	Pasture3DBakeTrace.start(false)
	_brush.terrain = null
	_brush._refresh_owner(_brush._layer_owner, false, [])
	var ctl := _span_counts()
	print("    control (no terrain): begin=%d end=%d (want 0/0 — the guard returns first)" % ctl)
	if ctl[0] != 0 or ctl[1] != 0:
		_fail += 1
		print("    !! a span was opened before the is_configured() guard")

	# The measurement: a real terrain, so the body actually runs.
	Pasture3DBakeTrace.start(false)
	var terrain := Pasture3D.new()
	# user://, never the demo data directory — a gate must not be able to touch authored terrain.
	DirAccess.make_dir_recursive_absolute("user://_baketracegate_data")
	terrain.data_directory = "user://_baketracegate_data"
	add_child(terrain)
	_brush.terrain = terrain
	_brush._refresh_owner(_brush._layer_owner, false, [])
	var got := _span_counts()
	print("    configured:           begin=%d end=%d (want >=1 and equal)" % got)
	if got[0] < 1:
		_fail += 1
		print("    !! nothing was recorded — the criterion measured nothing, as it did before")
	elif got[0] != got[1]:
		_fail += 1
		print("    !! a bake span was left open — a return path skipped its bake_end")
	else:
		# The repaint count is the whole reason the close event carries a payload.
		var tools := -2
		for ev in Pasture3DBakeTrace.events():
			if ev["type"] == "bake_end":
				tools = int(ev.get("tools", -2))
				break
		print("    the close carries a repaint count: %d (want >= 0)" % tools)
		if tools < 0:
			_fail += 1
			print("    !! bake_end recorded no tool count")
	_brush.terrain = null
	terrain.queue_free()
	_ran += 1


## [E] The buffer is capped and drops OLDEST first, so a runaway rebake loop stays catchable instead of
## exhausting memory while you catch it.
func _e_ring_buffer_evicts() -> void:
	print("[E] the ring buffer caps and evicts oldest-first")
	Pasture3DBakeTrace.start(false)
	var saved: int = Pasture3DBakeTrace.max_events
	Pasture3DBakeTrace.max_events = 8
	for i in 20:
		Pasture3DBakeTrace.mark("m%d" % i)
	var evs := Pasture3DBakeTrace.events()
	var kept := evs.size()
	var first := String(evs[0]["text"]) if kept > 0 else "<none>"
	print("    kept %d of 20 (want 8), oldest kept = %s (want m12)" % [kept, first])
	if kept != 8 or first != "m12":
		_fail += 1
		print("    !! eviction is not oldest-first at the cap")
	Pasture3DBakeTrace.max_events = saved
	_ran += 1


## [G] The inspector toggle's logic: on starts recording, off stops and writes a report that contains what
## was recorded. The control is a stale file — deleted first, so a report left by an earlier run cannot
## pass this.
func _g_session_toggle_writes_report() -> void:
	print("[G] set_session(true/false) records, then writes the report")
	var path := Pasture3DBakeTrace.REPORT_PATH
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	Pasture3DBakeTrace.stop()
	var off_path := Pasture3DBakeTrace.set_session(false)
	print("    off while not running returns \"%s\" and writes nothing: exists=%s" % [off_path, FileAccess.file_exists(path)])
	if off_path != "" or FileAccess.file_exists(path):
		_fail += 1
		print("    !! stopping an idle trace wrote a report")
	Pasture3DBakeTrace.set_session(true)
	var running := Pasture3DBakeTrace.is_running()
	Pasture3DBakeTrace.mark("gate-G-marker")
	var wrote := Pasture3DBakeTrace.set_session(false)
	var text := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	print("    running after on=%s, stopped after off=%s, report has marker=%s" % [
			running, not Pasture3DBakeTrace.is_running(), text.contains("gate-G-marker")])
	if not running or Pasture3DBakeTrace.is_running() or wrote == "" or not text.contains("gate-G-marker"):
		_fail += 1
		print("    !! the toggle did not start, stop, or write what it recorded")
	_ran += 1


## [F] Not an assertion — a standing statement of what a PASS above does and does not mean.
func _f_report_the_uncovered_half() -> void:
	print("[F] NOT COVERED HERE: arm-time cause capture")
	print("    The three schedulers sit behind `_can_auto_refresh()`, which requires")
	print("    Engine.is_editor_hint(); `get_stack()` is editor-only besides. Nothing above")
	print("    exercises them, and this gate would still pass with the `Pasture3DBakeTrace.arm`")
	print("    calls deleted from pasture3d_terrain_brush.gd. Verify that half in the editor.")
	_ran += 1


# ---- helpers ------------------------------------------------------------------------------------

func _span_counts() -> Array:
	var opens := 0
	var closes := 0
	for ev in Pasture3DBakeTrace.events():
		if ev["type"] == "bake_begin":
			opens += 1
		elif ev["type"] == "bake_end":
			closes += 1
	return [opens, closes]


func _graph_results() -> Array:
	var out: Array = []
	for ev in Pasture3DBakeTrace.events():
		if ev["type"] == "graph":
			out.append(String(ev["result"]))
	return out


func _first_graph_us() -> int:
	for ev in Pasture3DBakeTrace.events():
		if ev["type"] == "graph" and int(ev["us"]) >= 0:
			return int(ev["us"])
	return -1


func _graph_mod() -> Pasture3DNodeGraph:
	var noise := FastNoiseLite.new()
	noise.seed = 42
	noise.frequency = 0.07
	var node := Pasture3DGraphNodeNoise.new()
	node.noise = noise
	node.amplitude = 10.0
	var g := Pasture3DTerrainGraph.new()
	var typed: Array[Pasture3DGraphNode] = [node]
	g.nodes = typed
	g.output_node = 0
	var m := Pasture3DNodeGraph.new()
	m.graph = g
	m.strength = 1.0 # defaults to FROZEN in _init
	return m


func _bake(p_m: Pasture3DNodeGraph, p_extent: String) -> void:
	var n := GW * GH
	var step := {"mod": p_m, "op": &"graph", "grid": true, "out": {}}
	var amp := PackedFloat64Array(); amp.resize(n)
	var basey := PackedFloat32Array(); basey.resize(n)
	var profile := PackedFloat64Array(); profile.resize(n); profile.fill(1.0)
	var ctx := {"gw": GW, "gh": GH, "vs": VS, "min_x": 0.0, "min_z": 0.0, "add": true, "extent": p_extent}
	_brush._run_modifier_stack([step], amp, profile, basey, ctx)
	_brush._commit_modifier_caches({"gd": [step]}, p_extent)
