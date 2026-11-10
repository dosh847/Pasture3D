# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphFormatVersionGate — a terrain graph in a format this plugin does not read is REFUSED, not run.
# PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §4 (P0).
#
# The claim has four parts:
#   [A] a refused graph compiles to nothing and evaluates to nothing, on every route;
#   [B] a brush holding a refused graph bakes exactly as if the modifier were not there;
#   [C] the refusal is decided BEFORE anything reads the graph's wires, so wires that index nothing
#       cannot raise a script error;
#   [D] the version survives a save and a reload, and a file with no version reads as 0.
#
# No test seam: FORMAT_MIN_COMPATIBLE..FORMAT_CURRENT is [3, 3] since the standard mask (P5), so
# stamping a graph 1 or 99 is refused from both sides with the shipped constants. 1 is what every graph
# saved before that change says, and 0 (no version in the file) is refused with it; [D] checks that.
#
# `_ran` counts sub-cases that reached their assert. A GDScript error aborts the function it is in without
# failing anything, so a criterion that threw would otherwise read as a pass
# (`gate-pass-can-mean-nothing-ran`). [C] in particular IS that count.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/GraphFormatVersionGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"
const SITE := Vector3(200.0, 0.0, 160.0)
const HALF := 50.0
const PROBE_STRIDE := 2
const GW := 8
const GH := 8
const RECT := Rect2(0, 0, 10, 10)
const SAVE_STAMPED := "user://graph_format_gate_stamped.tres"
const SAVE_LEGACY := "user://graph_format_gate_legacy.tres"
const EXPECTED_RAN := 25 # [A] 5 + 2*5 + 1, [C] 1, [D] 3, [B] 1 + 2*2

var _fail := 0
var _ran := 0
var _root: Node3D
var _terrain
var _vs := 1.0


func _ready() -> void:
	print("\n=== GraphFormatVersionGate: an incompatible graph is refused, not run (ports spec P0) ===\n")
	_a_refused_graph_is_empty()
	_c_bad_wires_raise_nothing()
	_d_version_round_trips()
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_vs = _terrain.vertex_spacing
	_b_host_brush_skips_it()
	print("\n    sub-cases that reached their assert: %d (want %d)" % [_ran, EXPECTED_RAN])
	if _ran != EXPECTED_RAN:
		_fail += 1; print("    !! a criterion stopped early — a script error aborted it, or the count is stale")
	print("\n=== %s (%d failures) ===\n" % ["GRAPH FORMAT VERSION PASS" if _fail == 0 else "GRAPH FORMAT VERSION FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	_ran += 1
	if not p_ok:
		_fail += 1; print("    !! %s" % p_what)


# ---- [A] -------------------------------------------------------------------------------------------

func _a_refused_graph_is_empty() -> void:
	print("[A] a refused graph compiles and evaluates to nothing")
	var g := _filter_graph(_make_noise(), 6.0)

	# CONTROL FIRST, on the same object: at the current version every one of these answers is non-empty.
	# Without it, "empty when refused" would also be satisfied by a fixture that never compiled at all.
	g.format_version = Pasture3DTerrainGraph.FORMAT_CURRENT
	var live_prog: Dictionary = g.compile_graph_program()
	var live_eval := g.evaluate(GW, GH, RECT)
	print("    control (format %d): compatible=%s, output=%d, program keys=%d, evaluate non-zero=%s, native=%s"
			% [g.format_version, g.is_compatible(), g.output_index(), live_prog.size(),
			not _all_zero(live_eval), g.native_supported()])
	_check(g.is_compatible() and g.format_refusal() == "", "the current-format control is not compatible")
	_check(g.output_index() == 3, "the control has no output node")
	_check(not live_prog.is_empty(), "the control compiled to an empty program")
	_check(not _all_zero(live_eval), "the control evaluated flat")
	_check(g.native_supported(), "the control is not native-supported, so the refused case below proves less")

	# Refused from both sides, on the SAME graph — which also puts the per-revision native memo to the
	# question: an answer cached while the graph was current must not survive the version changing.
	for v in [99, 1]:
		g.format_version = v
		var prog: Dictionary = g.compile_graph_program()
		var prog_root: Dictionary = g.compile_graph_program(3)
		var multi: Dictionary = g.compile_graph_program_multi([3])
		var cell: Dictionary = g.compile_cell_program()
		var ev := g.evaluate(GW, GH, RECT)
		var warn := g.graph_warnings(true)
		print("    format %d: compatible=%s, output=%d, programs empty=%s/%s/%s/%s, evaluate flat=%s, native=%s"
				% [v, g.is_compatible(), g.output_index(), prog.is_empty(), prog_root.is_empty(),
				multi.is_empty(), cell.is_empty(), _all_zero(ev), g.native_supported()])
		print("        warning: %s" % (warn[0] if warn.size() > 0 else "<none>"))
		_check(not g.is_compatible() and g.output_index() == -1, "format %d was not refused" % v)
		_check(prog.is_empty() and prog_root.is_empty() and multi.is_empty() and cell.is_empty(),
				"format %d still compiled a program (an explicit root must not get round the refusal)" % v)
		_check(ev.size() == GW * GH and _all_zero(ev), "format %d still evaluated" % v)
		_check(not g.native_supported() and not g.native_supported(3) and not g.reads_input(),
				"format %d still reports native support or an input read" % v)
		_check(warn.size() == 1 and warn[0].contains(str(v))
				and warn[0] == g.format_refusal(),
				"format %d did not warn with exactly the refusal line naming its version" % v)

	# Back to current: the refusal is a property of the version, not a latch.
	g.format_version = Pasture3DTerrainGraph.FORMAT_CURRENT
	_check(not g.compile_graph_program().is_empty() and g.native_supported(),
			"the graph stayed refused after its version was set back to current")


# ---- [C] -------------------------------------------------------------------------------------------

func _c_bad_wires_raise_nothing() -> void:
	print("[C] a refused graph with wires that index nothing raises no script error")
	var g := _filter_graph(_make_noise(), 6.0)
	g.format_version = 99
	# Node indices past the end, a negative one, a port no node has, and a short row: what a layout from
	# another format looks like when read by this one.
	g.connections = [PackedInt32Array([7, 0, 9, 3]), PackedInt32Array([-1, 0, 2, 0]),
			PackedInt32Array([0, 40, 3, 12]), PackedInt32Array([1, 0])]
	g.output_override = 50
	var touched := 0
	touched += int(g.output_index() == -1)
	touched += int(g.compile_graph_program().is_empty())
	touched += int(g.compile_graph_program(2).is_empty())
	touched += int(g.compile_graph_program_multi([0, 1, 2, 3]).is_empty())
	touched += int(g.compile_cell_program().is_empty())
	touched += int(_all_zero(g.evaluate(GW, GH, RECT)))
	touched += int(not g.native_supported())
	touched += int(not g.reads_input())
	touched += int(not g.reads_footprint())
	touched += int(is_zero_approx(g.outward_reach()))
	touched += int(g.resolved_path_of(0) == null)
	touched += int(g.graph_warnings(true).size() == 1)
	touched += int(Pasture3DGraphChannelSinks.sinks_of(g).is_empty())
	touched += int(Pasture3DGraphExportSinks.sinks_of(g).is_empty())
	touched += int(Pasture3DGraphRuntimeSinks.sinks_of(g).is_empty())
	var m := Pasture3DNodeGraph.new()
	m.graph = g
	touched += int(not m.is_active())
	touched += int(m.modifier_warnings(null).size() >= 1)
	print("    %d of 17 entry points answered 'refused' and returned" % touched)
	# This line is only reached if none of the 17 calls above aborted the function. A script error in any
	# of them leaves `_ran` one short, and the count check at the end fails the gate.
	_check(touched == 17, "an entry point read a refused graph's wires, or did not answer 'refused'")


# ---- [D] -------------------------------------------------------------------------------------------

func _d_version_round_trips() -> void:
	print("[D] the version is saved, and a file without one reads as 0")
	var made := Pasture3DTerrainGraph.create_default()
	var added := Pasture3DTerrainGraph.new()
	var empty_version := added.format_version
	added.add_node(Pasture3DGraphNodeRegistry.create(&"const"))
	print("    create_default -> %d, new() -> %d, new() after its first add_node -> %d (current is %d)"
			% [made.format_version, empty_version, added.format_version, Pasture3DTerrainGraph.FORMAT_CURRENT])
	_check(made.format_version == Pasture3DTerrainGraph.FORMAT_CURRENT
			and added.format_version == Pasture3DTerrainGraph.FORMAT_CURRENT and empty_version == 0,
			"a graph built by this plugin is not stamped with the current format")

	var err := ResourceSaver.save(made, SAVE_STAMPED)
	var back = ResourceLoader.load(SAVE_STAMPED, "", ResourceLoader.CACHE_MODE_IGNORE)
	var back_version: int = back.format_version if back != null else -999
	print("    saved at %d (err %d) -> reloads as %d" % [made.format_version, err, back_version])
	_check(err == OK and back_version == Pasture3DTerrainGraph.FORMAT_CURRENT and back.is_compatible(),
			"a stamped graph did not reload with its version")

	# CONTROL: the same graph at 0 writes no `format_version` line at all — 0 is the script default, and
	# that is exactly what every graph saved before versioning looks like on disk — and reloads as 0. If
	# the loader stamped on load (an `_init` that set the current version would), this reads 1.
	var legacy := Pasture3DTerrainGraph.create_default()
	legacy.format_version = 0
	var err2 := ResourceSaver.save(legacy, SAVE_LEGACY)
	var text := FileAccess.get_file_as_string(SAVE_LEGACY)
	var back2 = ResourceLoader.load(SAVE_LEGACY, "", ResourceLoader.CACHE_MODE_IGNORE)
	var back2_version: int = back2.format_version if back2 != null else -999
	print("    control: saved at 0 (err %d) -> file names format_version=%s, reloads as %d, compatible=%s"
			% [err2, text.contains("format_version"), back2_version, back2 != null and back2.is_compatible()])
	_check(err2 == OK and not text.is_empty() and not text.contains("format_version") and back2_version == 0
			and not back2.is_compatible(),
			"a graph with no version in its file did not read as format 0, or was not refused")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_STAMPED))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_LEGACY))


# ---- [B] -------------------------------------------------------------------------------------------

func _b_host_brush_skips_it() -> void:
	print("[B] a brush holding a refused graph bakes as if the modifier were not there")
	var mound = _make_mound(SITE)
	if mound == null:
		return
	mound.height = 40.0
	var probes := _lattice(SITE)

	var none: Array[Pasture3DNode] = []
	mound.modifiers = none
	var bare := _bake(mound, probes)
	if not _all_finite(bare):
		_fail += 1; print("    !! the probes read no terrain; the fixture is outside demo/data"); return

	var g := _filter_graph(_make_noise(), 6.0)
	g.format_version = Pasture3DTerrainGraph.FORMAT_CURRENT
	var gmod := Pasture3DNodeGraph.new()
	gmod.graph = g
	gmod.strength = 1.0
	gmod.evaluation = Pasture3DNode.Evaluation.LIVE # no frozen result may stand in for a solve
	mound.modifiers = [gmod] as Array[Pasture3DNode]

	# CONTROL: at the current format the graph moves the bake. If it did not, "identical to no modifier"
	# below would hold for a graph that never reached the stack in the first place.
	var live := _bake(mound, probes)
	var moved := _max_abs_diff(bare, live)
	print("    %d probes; control: the current-format graph moves the bake by %.4f m (want > 0.5)"
			% [probes.size(), moved])
	_check(moved > 0.5, "the current-format graph did not change the bake, so the comparison below proves nothing")

	# Both rasterisers, and both sides of the range. LIVE on the same modifier that just baked, so a
	# refused graph that was still served from the previous solve shows up here as a non-zero difference.
	for v in [99, 1]:
		g.format_version = v
		var worst := 0.0
		for gd in [false, true]:
			mound.force_gdscript_raster = gd
			worst = maxf(worst, _max_abs_diff(bare, _bake(mound, probes)))
		mound.force_gdscript_raster = false
		print("    format %d: active=%s, forces GDScript=%s, worst difference from no modifier = %.9f m (want 0)"
				% [v, gmod.is_active(), mound._stack_forces_gdscript(), worst])
		_check(not gmod.is_active(), "the modifier holding a format-%d graph is still active" % v)
		_check(worst == 0.0, "a format-%d graph still changed the bake" % v)
	mound.queue_free()


# ---- fixtures ---------------------------------------------------------------------------------------

## Input -> Blend(ADD) <- Noise -> Output: a native-supported filter that visibly moves the surface.
## Built by assigning `nodes`, as a loaded file does, so nothing stamps it and the caller sets the version.
func _filter_graph(p_noise: FastNoiseLite, p_amp: float) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var noise := Pasture3DGraphNodeNoise.new(); noise.noise = p_noise; noise.amplitude = p_amp
	var blend := Pasture3DGraphNodeBlend.new(); blend.mode = Pasture3DGraphNodeBlend.Mode.ADD
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), noise, blend, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 2, 0]), PackedInt32Array([1, 0, 2, 1]), PackedInt32Array([2, 0, 3, 0])]
	return g


func _make_noise() -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = 1337
	n.frequency = 0.02
	return n


func _make_mound(p_at: Vector3):
	if not is_finite(_height(p_at)):
		_fail += 1; print("    !! no terrain at %s; the fixture is outside demo/data" % p_at); return null
	var mound := Pasture3DMound.new()
	mound.name = "GraphFormatVersion"
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = p_at
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, HALF))
	c.add_point(Vector3(-HALF, 0.0, HALF))
	c.closed = true
	path.curve = c
	mound.add_child(path)
	return mound


func _lattice(p_centre: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var step := _vs * PROBE_STRIDE
	var reach := HALF - _vs * 2.0
	var x := -reach
	while x <= reach:
		var z := -reach
		while z <= reach:
			out.append(Vector3(snappedf(p_centre.x + x, _vs), 0.0, snappedf(p_centre.z + z, _vs)))
			z += step
		x += step
	return out


func _bake(p_mound, p_probes: Array[Vector3]) -> Array[float]:
	p_mound._refresh_owner(p_mound._layer_owner, false, [])
	var out: Array[float] = []
	for p in p_probes:
		out.append(_height(p))
	return out


func _height(p_at: Vector3) -> float:
	return _terrain.data.get_height(Vector3(p_at.x, 0.0, p_at.z))


func _max_abs_diff(p_a: Array[float], p_b: Array[float]) -> float:
	var worst := 0.0
	for i in range(mini(p_a.size(), p_b.size())):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			worst = maxf(worst, absf(p_a[i] - p_b[i]))
	return worst


func _all_finite(p_vals: Array[float]) -> bool:
	for v in p_vals:
		if not is_finite(v):
			return false
	return true


func _all_zero(p_vals: PackedFloat32Array) -> bool:
	for v in p_vals:
		if v != 0.0:
			return false
	return true
