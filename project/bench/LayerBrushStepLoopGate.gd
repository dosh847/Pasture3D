# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# LayerBrushStepLoopGate — LB-B of PASTURE3D_LAYER_BRUSH_SPEC.md: extracting the modifier step loop out of
# `stamp_mound_loop` (so the Layer brush can run it over supplied arrays) changed no Mound bake by one bit.
#
# A refactor gets a refactor's gate: the comparison is against heights RECORDED BY THE PRE-EXTRACTION BUILD,
# not against the new build run twice. The first run on a build writes the baseline and exits RECORDED; every
# later run compares.
#
#   F  floor: two bakes on this build are bitwise identical, or nothing below is a bitwise question
#   S  sensitivity: nudging the noise strength by 1e-4 moves a probe (the probes see float-level change —
#      the rounding a per-modifier point fold would introduce is that size)
#   B  every probe equals the pre-extraction baseline, at bake_scale 1 and with the point run at bake_scale 2
#   E  the new entry `brush_run_stack_on_field`, given a uniform profile over a flat field, matches the
#      GDScript oracle `_run_modifier_stack` within float32; control: a zero profile does not match
#
# Uses the demo terrain data read-only. Nothing is saved.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/LayerBrushStepLoopGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"
const BASELINE := "user://layer_brush_step_loop_baseline.bin"
const SITE := Vector3(300.0, 0.0, 300.0)
const HALF := 40.0
const MARGIN := 8.0
const PROBE_STRIDE := 2

var _fail := 0
var _done := 0
var _root: Node3D
var _terrain
var _vs := 1.0


func _ready() -> void:
	print("\n=== LayerBrushStepLoopGate (LB-B) ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_vs = _terrain.vertex_spacing
	var want := _run()
	if _done != want:
		_fail += 1
		print("    !! only %d of %d criteria completed" % [_done, want])
	print("\n=== %s (%d failures) ===\n" % ["STEP LOOP PASS" if _fail == 0 else "STEP LOOP FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


func _run() -> int:
	var mound: Pasture3DMound = _make_mound()
	var probes := _lattice()
	var a := _bake(mound, probes)
	# Bake Scale 2x reaches the lattice branch only while every step is Noise/Relief, so run it on those two.
	var full_stack: Array[Pasture3DNode] = mound.modifiers
	var point_only: Array[Pasture3DNode] = [full_stack[0], full_stack[1]]
	mound.modifiers = point_only
	mound.bake_scale = 1
	var a_bs := _bake(mound, probes)
	mound.bake_scale = 0
	mound.modifiers = full_stack
	var current := a.duplicate()
	current.append_array(a_bs)

	if not FileAccess.file_exists(BASELINE):
		var f := FileAccess.open(BASELINE, FileAccess.WRITE)
		f.store_32(current.size())
		for v in current:
			f.store_float(v)
		print("  RECORDED %d probes to %s (this build is the baseline)" % [current.size(), ProjectSettings.globalize_path(BASELINE)])
		_done = 1
		return 1

	var b := _bake(mound, probes)
	_check("F floor", _first_diff(a, b) < 0, "re-bake first difference %d" % _first_diff(a, b))
	_done += 1

	var n0: float = _step(mound, 0).strength
	_step(mound, 0).strength = n0 + 0.0001
	var nudged := _bake(mound, probes)
	_step(mound, 0).strength = n0
	_check("S sensitivity", _first_diff(a, nudged) >= 0, "1e-4 noise nudge moves a probe: %s" % (_first_diff(a, nudged) >= 0))
	_done += 1

	var base := PackedFloat32Array()
	var f := FileAccess.open(BASELINE, FileAccess.READ)
	var count := f.get_32()
	for i in range(count):
		base.append(f.get_float())
	var cur32 := PackedFloat32Array(current)
	var d := -1
	for i in range(mini(base.size(), cur32.size())):
		if not (base[i] == cur32[i] or (is_nan(base[i]) and is_nan(cur32[i]))):
			d = i
			break
	_check("B baseline", base.size() == cur32.size() and d < 0,
			"%d probes, first difference %d%s" % [cur32.size(), d, "" if d < 0 else " (%f vs %f)" % [base[d], cur32[d]]])
	_done += 1

	_entry_vs_oracle(mound)
	return 4


## The new entry over a flat 48x48 field with profile 1 (and a zero-profile control), Noise then Smooth.
func _entry_vs_oracle(p_mound) -> void:
	if not _terrain.data.has_method("brush_run_stack_on_field"):
		_check("E entry", false, "brush_run_stack_on_field is not bound in this build")
		return
	var gw := 48
	var gh := 48
	var min_x := SITE.x
	var min_z := SITE.z
	var n := gw * gh
	var basey := PackedFloat32Array()
	basey.resize(n)
	basey.fill(10.0)
	var amp := PackedFloat64Array()
	amp.resize(n)
	amp.fill(0.0)
	var prof := PackedFloat64Array()
	prof.resize(n)
	prof.fill(1.0)
	var full_stack: Array[Pasture3DNode] = p_mound.modifiers
	var mods: Array[Pasture3DNode] = [full_stack[0], full_stack[4]]
	p_mound.modifiers = mods
	var stack: Dictionary = p_mound._compile_modifiers()
	p_mound.modifiers = full_stack
	var params := {"min_x": min_x, "min_z": min_z, "vs": _vs, "gw": gw, "gh": gh, "blend": 0,
			"modifiers": stack["list"], "op_selectors": PackedFloat32Array()}
	var native: PackedFloat32Array = _terrain.data.brush_run_stack_on_field(params, basey, amp, prof)
	var ctx := {"gw": gw, "gh": gh, "add": false, "vs": _vs, "min_x": min_x, "min_z": min_z}
	var oracle: PackedFloat32Array = p_mound._run_modifier_stack(stack["gd"], amp.duplicate(), prof, basey, ctx)
	var worst := 0.0
	var moved := false
	for i in range(n):
		worst = maxf(worst, absf(native[i] - oracle[i]))
		moved = moved or absf(native[i] - 10.0) > 0.01
	var zero := prof.duplicate()
	zero.fill(0.0)
	var flat: PackedFloat32Array = _terrain.data.brush_run_stack_on_field(params, basey, amp, zero)
	var ctl := 0.0
	for i in range(n):
		ctl = maxf(ctl, absf(flat[i] - oracle[i]))
	_check("E entry", native.size() == n and moved and worst < 1e-4 and ctl > 0.01,
			"native vs oracle max %.7f m (moved %s); zero-profile control differs by %.4f m" % [worst, moved, ctl])
	_done += 1


func _make_mound():
	var mound := Pasture3DMound.new()
	mound.name = "StepLoop"
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = SITE
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	for p in [Vector3(-HALF, 0, -HALF), Vector3(HALF, 0, -HALF * 0.6), Vector3(HALF * 0.8, 0, HALF), Vector3(-HALF, 0, HALF * 0.7)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	mound.add_child(path)
	mound.height = 20.0
	mound.relative_to_terrain = true
	mound.modifier_margin = MARGIN
	mound.modifiers = _stack()
	return mound


## Noise -> Relief(below-layer slope) -> Relief(host profile) -> Graph -> Smooth.
func _stack() -> Array[Pasture3DNode]:
	var noise := FastNoiseLite.new()
	noise.seed = 1337
	noise.frequency = 0.03
	var mn := Pasture3DNodeNoise.new()
	mn.noise = noise
	mn.strength = 2.5

	var slope_mat := Pasture3DReliefFractal.new()
	slope_mat.style = Pasture3DReliefFractal.Style.CRAGGY
	slope_mat.feature_size = 10.0
	slope_mat.seed = 11
	var slope_sel := Pasture3DTerrainMask.new()
	slope_sel.filter_type = 0
	slope_sel.range_min = 0.0
	slope_sel.range_max = 25.0
	slope_sel.falloff_high = 8.0
	slope_mat.selector = slope_sel
	var mr_slope := Pasture3DNodeRelief.new()
	mr_slope.material = slope_mat
	mr_slope.strength = 3.0

	var host_mat := Pasture3DReliefFractal.new()
	host_mat.feature_size = 7.0
	host_mat.seed = 23
	var host_sel := Pasture3DTerrainMask.new()
	host_sel.filter_type = 1
	host_sel.field_source = Pasture3DTerrainMask.FieldSource.HOST_PROFILE
	host_sel.range_min = 6.0
	host_sel.range_max = 10000.0
	host_sel.falloff_low = 3.0
	host_mat.selector = host_sel
	var mr_host := Pasture3DNodeRelief.new()
	mr_host.material = host_mat
	mr_host.strength = 2.0

	var gnoise := FastNoiseLite.new()
	gnoise.seed = 4242
	gnoise.frequency = 0.05
	var g := Pasture3DTerrainGraph.new()
	var gn := Pasture3DGraphNodeNoise.new()
	gn.noise = gnoise
	gn.amplitude = 4.0
	var blend := Pasture3DGraphNodeBlend.new()
	blend.mode = Pasture3DGraphNodeBlend.Mode.ADD
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), gn, blend, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 2, 0]), PackedInt32Array([1, 0, 2, 1]), PackedInt32Array([2, 0, 3, 0])]
	var mg := Pasture3DNodeGraph.new()
	mg.graph = g
	mg.strength = 0.6
	mg.evaluation = Pasture3DNode.Evaluation.LIVE

	var ms := Pasture3DNodeSmooth.new()
	ms.passes = 2
	var out: Array[Pasture3DNode] = [mn, mr_slope, mr_host, mg, ms]
	return out


func _step(p_mound, p_index: int):
	return p_mound.modifiers[p_index]


func _lattice() -> Array[Vector3]:
	var out: Array[Vector3] = []
	var reach := HALF + MARGIN - _vs * 2.0
	var x := -reach
	while x <= reach:
		var z := -reach
		while z <= reach:
			out.append(Vector3(snappedf(SITE.x + x, _vs), 0.0, snappedf(SITE.z + z, _vs)))
			z += _vs * PROBE_STRIDE
		x += _vs * PROBE_STRIDE
	return out


func _bake(p_mound, p_probes: Array[Vector3]) -> Array[float]:
	p_mound._refresh_owner(p_mound._layer_owner, false, [])
	var out: Array[float] = []
	for p in p_probes:
		out.append(_terrain.data.get_height(p))
	return out


func _first_diff(p_a: Array, p_b: Array) -> int:
	for i in range(mini(p_a.size(), p_b.size())):
		if not (p_a[i] == p_b[i] or (is_nan(p_a[i]) and is_nan(p_b[i]))):
			return i
	return -1
