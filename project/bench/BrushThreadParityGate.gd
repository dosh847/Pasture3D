# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# BrushThreadParityGate — the brush rasteriser bakes the same terrain at 1 thread as at every thread.
#
# The claim under test: splitting `stamp_mound_loop`'s pre-passes, its point run and its graph profile, the
# relief field builders and the graph composite across rows changed NOTHING. Threading a refactor gets a
# refactor's gate — bitwise equality through `get_height`, not a tolerance.
#
# WHY THIS GATE EXISTS AND THE OTHERS WERE NOT ENOUGH. `Pasture3DThreadPool::parallel_for_rows` runs serial
# under 128 rows, and every brush parity fixture before this one is a ±50 m loop — about 100 rows. They all
# passed after the threading, having run every threaded region serially: they validate the refactor of the
# loop bodies, never the split. This fixture is ±90 m plus a margin, and the gate reads the pool's dispatch
# counter to prove its threaded arm really split and its serial arm really did not.
#
# Criteria:
#   A  the thread cap works: a bake at `set_max_threads(1)` dispatches no parallel region, and the same
#      bake uncapped dispatches at least one. Without A, B could be comparing serial with serial.
#   B  serial and threaded bakes are bitwise identical at every probe.
#   F  THE FLOOR: two threaded bakes are bitwise identical, or the probe cannot answer a bitwise question.
#   C  every threaded feature reaches the probes: switching each one off moves at least one probe. A
#      feature whose output never reaches a probe is a feature B says nothing about.
#
# NOT COVERED, said out loud: the per-cell `get_height` fallback for a NaN below-layer base (demo data has a
# dense base, so that branch does not fire), the Sim-link field builder, and the Plow rasteriser.
#
# NOTHING IS SAVED. Bakes write into the terrain's in-memory layer. This is a correctness gate, not a
# benchmark — it prints no timings.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/BrushThreadParityGate.tscn
extends Node

const DEMO_DATA := "res://demo/data"

const SITE := Vector3(300.0, 0.0, 300.0)
## Half-extent of the loop, metres. At 1 m spacing that is ~184 rows, clear of the pool's 128-row floor.
const HALF := 90.0
const MARGIN := 12.0
const PROBE_STRIDE := 3

const K_SLOPE := 0
const K_ALTITUDE := 1

var _fail := 0
var _done := 0
var _root: Node3D
var _terrain
var _vs := 1.0


func _ready() -> void:
	print("\n=== BrushThreadParityGate: 1 thread == every thread, bit for bit ===\n")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_vs = _terrain.vertex_spacing

	var cap_before: int = Pasture3DUtil.get_max_threads()
	_run()
	Pasture3DUtil.set_max_threads(cap_before)

	# Four criteria, and a criterion that returned early completed nothing — count them, not just failures.
	if _done != 4:
		_fail += 1
		print("\n    !! only %d of 4 criteria completed" % _done)
	print("\n=== %s (%d failures) ===\n" % ["THREAD PARITY PASS" if _fail == 0 else "THREAD PARITY FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _run() -> void:
	if OS.get_processor_count() < 2:
		_fail += 1
		print("    !! one hardware thread: nothing can split, so this machine cannot run the gate")
		return
	var mound = _make_mound()
	if mound == null:
		return
	var probes := _lattice()
	var grid_rows := int(ceil((HALF + MARGIN) * 2.0 / _vs))
	print("    %d probes, loop ±%.0f m + %.0f m margin = ~%d rows at %.2f m (pool floor 128)"
			% [probes.size(), HALF, MARGIN, grid_rows, _vs])

	# ---- A: the cap is real, both ways ------------------------------------------------------------
	print("\n[A] the serial arm dispatches nothing; the threaded arm splits:")
	Pasture3DUtil.set_max_threads(1)
	var d0: int = Pasture3DUtil.parallel_dispatch_count()
	var serial := _bake(mound, probes)
	var d_serial: int = Pasture3DUtil.parallel_dispatch_count() - d0
	Pasture3DUtil.set_max_threads(0)
	d0 = Pasture3DUtil.parallel_dispatch_count()
	var threaded := _bake(mound, probes)
	var d_threaded: int = Pasture3DUtil.parallel_dispatch_count() - d0
	print("    regions split: serial %d (want 0), threaded %d (want > 0)" % [d_serial, d_threaded])
	if not _all_finite(serial) or not _all_finite(threaded):
		_fail += 1
		print("    !! a probe read no terrain; the fixture is outside demo/data")
		return
	if d_serial != 0:
		_fail += 1
		print("    !! set_max_threads(1) still split a region — the serial arm is not serial")
	if d_threaded <= 0:
		_fail += 1
		print("    !! the uncapped bake split nothing — B would compare serial with serial")
		return
	_done += 1

	# ---- F: the floor ------------------------------------------------------------------------------
	print("\n[F] two threaded bakes agree bitwise (the probe can answer a bitwise question):")
	var threaded_b := _bake(mound, probes)
	var floor_diff := _first_difference(threaded, threaded_b)
	print("    first difference: %s" % ("none" if floor_diff < 0 else "probe %d" % floor_diff))
	if floor_diff >= 0:
		_fail += 1
		print("    !! re-baking drifts by %.9f m; no bitwise comparison below means anything"
				% _max_abs_diff(threaded, threaded_b))
		return
	_done += 1

	# ---- B: the headline -----------------------------------------------------------------------------
	print("\n[B] serial == threaded at every probe:")
	var diff := _first_difference(serial, threaded)
	print("    shape span %.3f m; first difference: %s"
			% [_span(threaded), "none" if diff < 0 else "probe %d at %s" % [diff, probes[diff]]])
	if diff >= 0:
		_fail += 1
		print("    !! threading changed the bake: max |serial - threaded| = %.9f m"
				% _max_abs_diff(serial, threaded))
	_done += 1

	# ---- C: every threaded feature reaches a probe ---------------------------------------------------
	# Each control bakes threaded with ONE feature switched off and must differ from the full bake. A
	# feature that fails this is one criterion B could not have seen break.
	print("\n[C] switching each feature off moves the probes (so B saw it):")
	var controls_ok := true
	controls_ok = _control(mound, probes, threaded, "crease blur (raster_box_pass)",
			func(): mound.crease_smoothing = 0.0,
			func(): mound.crease_smoothing = 6.0) and controls_ok
	controls_ok = _control(mound, probes, threaded, "noise (point run)",
			func(): _step(mound, 0).strength = 0.0,
			func(): _step(mound, 0).strength = 2.5) and controls_ok
	controls_ok = _control(mound, probes, threaded, "below-layer slope relief, measure_radius (relief_fields_*)",
			func(): _step(mound, 1).strength = 0.0,
			func(): _step(mound, 1).strength = 3.0) and controls_ok
	controls_ok = _control(mound, probes, threaded, "host-profile relief (host pre-pass)",
			func(): _step(mound, 2).strength = 0.0,
			func(): _step(mound, 2).strength = 3.0) and controls_ok
	controls_ok = _control(mound, probes, threaded, "graph modifier (gprofile + composite)",
			func(): _step(mound, 3).strength = 0.0,
			func(): _step(mound, 3).strength = 0.6) and controls_ok
	controls_ok = _control(mound, probes, threaded, "modifier margin (margin pre-pass)",
			func(): mound.modifier_margin = 0.0,
			func(): mound.modifier_margin = MARGIN) and controls_ok
	if controls_ok:
		_done += 1


## Bake threaded with `p_off` applied, compare with the full bake, then restore with `p_on`.
func _control(p_mound, p_probes: Array[Vector3], p_full: Array[float], p_label: String,
		p_off: Callable, p_on: Callable) -> bool:
	p_off.call()
	var without := _bake(p_mound, p_probes)
	p_on.call()
	var moved := _first_difference(p_full, without) >= 0
	print("    %-58s %s" % [p_label, "moves %.4f m" % _max_abs_diff(p_full, without) if moved else "INERT"])
	if not moved:
		_fail += 1
		print("    !! switching it off changed no probe, so B says nothing about its threaded split")
	return moved


# ---- fixture ----------------------------------------------------------------------------------------


func _make_mound():
	var reach := HALF + MARGIN
	for c in [Vector3(-reach, 0, -reach), Vector3(reach, 0, -reach), Vector3(reach, 0, reach),
			Vector3(-reach, 0, reach), Vector3.ZERO]:
		if not is_finite(_height(SITE + c)):
			_fail += 1
			print("    !! no terrain at %s; the fixture is outside demo/data" % (SITE + c))
			return null
	var mound := Pasture3DMound.new()
	mound.name = "ThreadParity"
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = SITE
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

	mound.height = 30.0
	mound.relative_to_terrain = true
	mound.crease_smoothing = 6.0
	mound.modifier_margin = MARGIN
	mound.modifiers = _stack()
	return mound


## Noise -> Relief(slope, below layer, measured) -> Relief(altitude, host profile) -> Graph -> Smooth.
## One of each threaded path; the indices are what the controls switch off.
func _stack() -> Array[Pasture3DNode]:
	var noise := FastNoiseLite.new()
	noise.seed = 1337
	noise.frequency = 0.02
	var mn := Pasture3DNodeNoise.new()
	mn.noise = noise
	mn.strength = 2.5

	var slope_mat := Pasture3DReliefFractal.new()
	slope_mat.style = Pasture3DReliefFractal.Style.CRAGGY
	slope_mat.feature_size = 14.0
	slope_mat.seed = 11
	var slope_sel := Pasture3DTerrainMask.new()
	slope_sel.filter_type = K_SLOPE # first: a type change re-defaults an untouched band
	slope_sel.range_min = 0.0
	slope_sel.range_max = 25.0
	slope_sel.falloff_low = 0.0
	slope_sel.falloff_high = 8.0
	slope_sel.measure_radius = 4.0
	slope_mat.selector = slope_sel
	var mr_slope := Pasture3DNodeRelief.new()
	mr_slope.material = slope_mat
	mr_slope.strength = 3.0

	var host_mat := Pasture3DReliefFractal.new()
	host_mat.style = Pasture3DReliefFractal.Style.CRAGGY
	host_mat.feature_size = 9.0
	host_mat.seed = 23
	var host_sel := Pasture3DTerrainMask.new()
	host_sel.filter_type = K_ALTITUDE
	host_sel.field_source = Pasture3DTerrainMask.FieldSource.HOST_PROFILE
	host_sel.range_min = 10.0
	host_sel.range_max = 10000.0
	host_sel.falloff_low = 4.0
	host_sel.falloff_high = 0.0
	host_mat.selector = host_sel
	var mr_host := Pasture3DNodeRelief.new()
	mr_host.material = host_mat
	mr_host.strength = 3.0

	var gnoise := FastNoiseLite.new()
	gnoise.seed = 4242
	gnoise.frequency = 0.035
	var g := Pasture3DTerrainGraph.new()
	var gn := Pasture3DGraphNodeNoise.new()
	gn.noise = gnoise
	gn.amplitude = 5.0
	var blend := Pasture3DGraphNodeBlend.new()
	blend.mode = Pasture3DGraphNodeBlend.Mode.ADD
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), gn, blend,
			Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [PackedInt32Array([0, 0, 2, 0]), PackedInt32Array([1, 0, 2, 1]),
			PackedInt32Array([2, 0, 3, 0])]
	var mg := Pasture3DNodeGraph.new()
	mg.graph = g
	mg.strength = 0.6
	mg.evaluation = Pasture3DNode.Evaluation.LIVE # a Frozen step would serve a cache across the two arms

	var ms := Pasture3DNodeSmooth.new()
	ms.passes = 2

	var out: Array[Pasture3DNode] = [mn, mr_slope, mr_host, mg, ms]
	return out


func _step(p_mound, p_index: int):
	return p_mound.modifiers[p_index]


## Vertex-lattice probes over the loop AND the margin band, inset from the outer edge by two cells. The
## margin band has to be probed: off the loop is the only place the margin pre-pass writes.
func _lattice() -> Array[Vector3]:
	var out: Array[Vector3] = []
	var step := _vs * PROBE_STRIDE
	var reach := HALF + MARGIN - _vs * 2.0
	var x := -reach
	while x <= reach:
		var z := -reach
		while z <= reach:
			out.append(Vector3(snappedf(SITE.x + x, _vs), 0.0, snappedf(SITE.z + z, _vs)))
			z += step
		x += step
	return out


func _bake(p_mound, p_probes: Array[Vector3]) -> Array[float]:
	p_mound._refresh_owner(p_mound._layer_owner, false, [])
	var out: Array[float] = []
	for p in p_probes:
		out.append(_height(p))
	return out


# ---- measurement -------------------------------------------------------------------------------------


## Index of the first probe where two bakes differ AT ALL, or -1. Exact `!=` on purpose.
func _first_difference(p_a: Array[float], p_b: Array[float]) -> int:
	for i in range(mini(p_a.size(), p_b.size())):
		var same := p_a[i] == p_b[i] or (not is_finite(p_a[i]) and not is_finite(p_b[i]))
		if not same:
			return i
	return -1


func _max_abs_diff(p_a: Array[float], p_b: Array[float]) -> float:
	var worst := 0.0
	for i in range(mini(p_a.size(), p_b.size())):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			worst = maxf(worst, absf(p_a[i] - p_b[i]))
	return worst


func _span(p_vals: Array[float]) -> float:
	var lo := INF
	var hi := -INF
	for v in p_vals:
		if is_finite(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	return hi - lo if hi > -INF else 0.0


func _all_finite(p_vals: Array[float]) -> bool:
	for v in p_vals:
		if not is_finite(v):
			return false
	return true


func _height(p_at: Vector3) -> float:
	return _terrain.data.get_height(Vector3(p_at.x, 0.0, p_at.z))
