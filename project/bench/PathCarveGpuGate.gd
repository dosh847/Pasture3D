# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# PathCarveGpuGate — the GPU carve against the CPU one (S3b).
#
# ---- WHAT THIS GATE IS FOR ----
#
# PASTURE3D_SPLINE_GRAPH_SPEC.md §7.7 puts Path Carve on the GPU for the `height` channel only. Two
# dispatches: one samples the terrain under each path VERTEX, the other carves. This gate is what makes
# the second implementation worth having rather than a second place to be wrong.
#
# ---- THE FAILURE THIS GATE EXISTS TO CATCH ----
#
# A GPU criterion that compares `graph_eval_grid_gpu` to `graph_eval_grid` and finds them equal has
# proved NOTHING on its own, because the most likely defect makes them equal: the GPU route refuses the
# program, the caller falls back to the CPU, and the "GPU" result IS the CPU result. Per
# `graph-gpu-bail-is-graph-wide`, only a DIRECT graph_eval_grid_gpu call can tell those apart — an empty
# return is the refusal, a filled one is the shader. Every criterion here calls it directly, and [A]
# additionally proves the returned field is not the input wearing the carve's name.
#
# Tolerance is 2e-3 m. The CPU kernel accumulates in double; the shader is float32 throughout, and the
# nearest-segment scan is where that shows — a cell equidistant from two segments can resolve to either
# in the last bits, and the two answers differ by the width of one profile step. That is a real
# difference between the routes, not a defect in either, and it is why this is not PathCarveGate's 1e-4.
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D"]

const GW: int = 96
const GH: int = 96
const G_MIN: float = -48.0
const RECT := Rect2(G_MIN, G_MIN, 96.0, 96.0)
const EPS: float = 2.0e-3

var _fail: int = 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== PathCarveGpuGate: the GPU carve vs the CPU one (S3b) ===")
	print("    spec: PASTURE3D_SPLINE_GRAPH_SPEC.md §7.7")

	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		print("!! graph_eval_grid_gpu is not bound — rebuild the GDExtension")
		get_tree().quit(1)
		return

	# THE PRECONDITION, before any criterion. A bare Input -> Output graph is the simplest thing the GPU
	# evaluator can be asked for; if THAT comes back empty there is no local RenderingDevice and every
	# criterion below would be measuring an absence. Reported as NO-SIGNAL rather than as a pass, because
	# a green sweep on a machine that ran no shader is the failure this whole file is guarding against.
	var probe: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
			_io_graph().compile_graph_program(), GW, GH, RECT, _terrain())
	if probe.is_empty():
		print("    NO-SIGNAL: the GPU evaluator bailed on a bare in->out graph, so there is no local")
		print("    RenderingDevice (headless / no driver). Re-run WITHOUT --headless.")
		print("=== PATH CARVE GPU SKIPPED (no RenderingDevice) ===")
		get_tree().quit(0)
		return
	print("    precondition: the GPU route is live (%d cells on a bare in->out graph)" % probe.size())

	_a_gpu_matches_cpu_on_four_sections()
	_b_a_mask_channel_still_bails()
	_c_a_heightless_path_agrees_too()
	_d_the_ground_reference_is_per_vertex()

	for name in CRITERIA:
		if not _seen.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	print("=== PATH CARVE GPU %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])


# ---- fixtures -----------------------------------------------------------------------------------

## The SAME sloping, bumpy terrain PathCarveGate uses, and for the same two reasons: over flat ground a
## two-reference drape and a fixed-height skirt are indistinguishable, and over SMOOTH ground a per-vertex
## ground reference and a per-cell one are indistinguishable. [D] measures the second of those directly.
func _terrain() -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(GW * GH)
	for iz in GH:
		for ix in GW:
			var wx := G_MIN + float(ix) + 0.5
			var wz := G_MIN + float(iz) + 0.5
			s[iz * GW + ix] = (0.12 * wx + 0.05 * wz
					+ 3.0 * sin(wx * 0.17) * cos(wz * 0.11)
					+ 1.2 * sin(wx * 0.53 + wz * 0.31))
	return s


func _spline(p_heights: bool = true) -> Pasture3DGraphPath:
	var path := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var w := PackedFloat32Array()
	var h := PackedFloat32Array()
	for i in 9:
		var f := float(i) / 8.0
		pts.append(Vector2(-34.0 + f * 68.0, -18.0 + 26.0 * sin(f * PI)))
		w.append(6.0 + 10.0 * f)
		h.append(4.0 + 9.0 * f)
	path.points = pts
	path.half_widths = w
	if p_heights:
		path.heights = h
	return path


## Input -> Spline-less Road Source -> Path Carve[height] -> Output.
func _carve_graph(p_path: Pasture3DGraphPath, p_cfg: Dictionary, p_channel: int = 0) -> Pasture3DTerrainGraph:
	var src := Pasture3DGraphNodeRoadSource.new()
	src.path = p_path
	var carve := Pasture3DGraphNodePathCarve.new()
	for k in p_cfg:
		carve.set(String(k), p_cfg[k])
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), src, carve, Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 2, 0], [1, 0, 2, 1], [2, p_channel, 3, 0]]
	return g


func _io_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0]]
	return g


func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in p_a.size():
		var na := is_nan(p_a[i])
		var nb := is_nan(p_b[i])
		if na or nb:
			if na != nb:
				return INF
			continue
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


func _moved(p_out: PackedFloat32Array, p_surf: PackedFloat32Array) -> Array:
	var most := 0.0
	var cells := 0
	for i in mini(p_out.size(), p_surf.size()):
		var d := absf(p_out[i] - p_surf[i])
		if d > 0.01:
			cells += 1
		most = maxf(most, d)
	return [most, cells]


# ---- A ------------------------------------------------------------------------------------------

## [A] The GPU carve matches the CPU carve, on the four cross-sections PathCarveGate [A] uses.
##
## Four rather than one because they take different branches of the SHADER as well as of the kernel: the
## flat-top case, the sign flip on the offset, and the two blends that clamp in opposite directions.
func _a_gpu_matches_cpu_on_four_sections() -> void:
	print("[A] the GPU carve matches the CPU carve on four cross-sections")
	var surf := _terrain()
	var path := _spline()
	var cfgs := {
		"peaked crest": {"cross_section": 0, "flat_width": 0.0, "offset": 12.0, "blend": 1},
		"flat crest": {"cross_section": 0, "flat_width": 8.0, "offset": 12.0, "blend": 1},
		"V bed": {"cross_section": 1, "flat_width": 0.0, "offset": 9.0, "blend": 2},
		"flat bed": {"cross_section": 1, "flat_width": 6.0, "offset": 9.0, "blend": 2},
	}
	var worst := 0.0
	var worst_on := ""
	var least_move := INF
	var bailed := PackedStringArray()
	for name in cfgs:
		var prog := _carve_graph(path, cfgs[name]).compile_graph_program()
		var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(prog, GW, GH, RECT, surf)
		var cpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(prog, GW, GH, RECT, surf)
		if gpu.is_empty():
			bailed.append(name)
			print("    %-13s the GPU REFUSED this program" % name)
			continue
		var w := _worst(gpu, cpu)
		var mv := _moved(gpu, surf)
		print("    %-13s worst %.7f m, the GPU moved %d cell(s) by up to %.3f m" % [name, w, mv[1], mv[0]])
		least_move = minf(least_move, float(mv[0]))
		if w > worst:
			worst = w
			worst_on = name
	_check("A", bailed.is_empty() and worst < EPS,
			"worst |GPU - CPU| = %.7f m on %s (want < %.4f), %d refusal(s) %s"
			% [worst, "nothing" if worst_on == "" else worst_on, EPS, bailed.size(), str(bailed)])

	# CONTROL: the GPU actually CARVED. This is the criterion's whole load-bearing check — a shader that
	# copied its input would agree with nothing, but a plan that quietly passed the surface through would
	# agree with a CPU route doing the same, and `worst` would read 0.0000000 as a triumph.
	print("    control: the least-moving configuration moved the ground %.3f m on the GPU (want > 1)"
			% least_move)
	if least_move <= 1.0 or bailed.size() > 0:
		_fail += 1
		print("    !! the GPU did not carve, so [A] compared two pass-throughs")


# ---- B ------------------------------------------------------------------------------------------

## [B] A graph wiring a MASK channel still bails.
##
## S3b is `height` only: the plan holds one buffer per slot, so `bed` cannot be served and must not be
## served-as-channel-0. Without this the phase's own scope limit is unenforced, and the first graph to
## wire `bed` would get a copy of the carved height wearing a mask's name — which looks like a mask,
## because it is a field between two numbers.
func _b_a_mask_channel_still_bails() -> void:
	print("[B] a graph reading a mask channel still refuses the GPU")
	var surf := _terrain()
	var cfg := {"cross_section": 0, "flat_width": 7.0, "offset": 6.0, "blend": 0}
	var bad := PackedStringArray()
	var names := ["height", "bed", "flank", "cut", "fill"]
	for ch in range(1, 5):
		var prog := _carve_graph(_spline(), cfg, ch).compile_graph_program()
		var got: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(prog, GW, GH, RECT, surf)
		if not got.is_empty():
			bad.append(names[ch])
	_check("B", bad.is_empty(), "mask channels served by the GPU: %s (want none)"
			% ("none" if bad.is_empty() else str(bad)))

	# CONTROL: channel 0 on the SAME graph is NOT refused. Without it, [B] passes on a build where the
	# whole op bails — which is S3's behaviour, not S3b's, and would mean the phase did nothing.
	var h_prog := _carve_graph(_spline(), cfg, 0).compile_graph_program()
	var h_got: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(h_prog, GW, GH, RECT, surf)
	print("    control: the same graph reading `height` returned %d cell(s) (want %d)"
			% [h_got.size(), GW * GH])
	if h_got.size() != GW * GH:
		_fail += 1
		print("    !! `height` was refused too, so [B] is measuring the op bailing, not the channel guard")


# ---- C ------------------------------------------------------------------------------------------

## [C] A path with NO drawn heights and `follow_path_height` on behaves identically on both routes.
##
## This is the NaN stripe (§7.7 step 1). The upload fills the height stripe with NaN rather than omitting
## or zeroing it, and the shader falls back to the ground reference exactly as `height_at`'s NaN makes the
## CPU do. A zeroed stripe would read as sea level and pull a ridge drawn at 400 m down to the water —
## and it would do it while still agreeing with itself, which is why the control matters more than the
## comparison.
func _c_a_heightless_path_agrees_too() -> void:
	print("[C] a path carrying no heights agrees across routes (the NaN stripe)")
	var surf := _terrain()
	var cfg := {"cross_section": 0, "flat_width": 4.0, "offset": 10.0, "blend": 1,
		"follow_path_height": true}
	var prog := _carve_graph(_spline(false), cfg).compile_graph_program()
	var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(prog, GW, GH, RECT, surf)
	var cpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(prog, GW, GH, RECT, surf)
	var w := _worst(gpu, cpu)
	var mv := _moved(gpu, surf) if not gpu.is_empty() else [0.0, 0]
	print("    heightless: worst %.7f m, the GPU moved %d cell(s) by up to %.3f m" % [w, mv[1], mv[0]])
	_check("C", not gpu.is_empty() and w < EPS,
			"worst |GPU - CPU| on a heightless path = %.7f m (want < %.4f)" % [w, EPS])

	# CONTROL: the same path WITH heights produces a DIFFERENT surface. Without it, both routes reading
	# the stripe as zero would agree perfectly and pass — the exact defect this criterion is named for.
	var with_h := _carve_graph(_spline(true), cfg).compile_graph_program()
	var gpu_h: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(with_h, GW, GH, RECT, surf)
	var diff := _worst(gpu, gpu_h)
	print("    control: the same path WITH heights differs by %.3f m (want a real difference)" % diff)
	if diff < 1.0:
		_fail += 1
		print("    !! drawn heights changed nothing, so the height stripe is not being read")

	# CONTROL: and the heightless carve still CARVED. "Falls back to the ground reference" must mean an
	# offset ridge, not an inert pass-through — those look the same from the comparison above.
	print("    control: the heightless carve still moved %d cell(s) (want many)" % mv[1])
	if int(mv[1]) < 100:
		_fail += 1
		print("    !! the heightless fallback carved nothing rather than offsetting from the ground")


# ---- D ------------------------------------------------------------------------------------------

## [D] The GPU uses the PER-VERTEX ground reference, not a per-cell one.
##
## The reason the phase needs two dispatches at all, so it needs a measurement that can tell the two
## apart — and the obvious one is backwards. Sitting the crest at `ground + offset` makes the reference
## CANCEL (`diff` is the offset either way), so any fixture with `follow_path_height` off measures
## nothing no matter how bumpy the ground is.
##
## With `follow_path_height` ON it does not cancel. The crest lands at `ground + (drawn - ground_ref)`:
##
##   * a PER-CELL reference makes `ground_ref` equal `ground`, the two cancel, and the crest is the drawn
##     height EXACTLY — dead flat, and completely independent of the terrain under it
##   * the PER-VERTEX reference is a smooth interpolation between a few dozen samples, so it does not
##     cancel and the crest carries the terrain's own variation
##
## So the discriminator is the crest's roughness against the TERRAIN'S: comparable means per-vertex, near
## zero means per-cell. That is the opposite of the intuition that a per-cell reference is the rough one,
## and it is why this is measured rather than reasoned about.
func _d_the_ground_reference_is_per_vertex() -> void:
	print("[D] the crest is anchored to the per-vertex ground reference on the GPU too")
	var surf := _terrain()
	# Straight along z = 0 so the crest is one grid row; a WIDE flat top so that row sits at p = 1, where
	# the reference is undiluted by the profile; a CONSTANT drawn height so anything the crest inherits
	# came from the ground reference and not from the spline.
	var path := Pasture3DGraphPath.new()
	path.points = PackedVector2Array([Vector2(-40.0, 0.0), Vector2(40.0, 0.0)])
	path.half_widths = PackedFloat32Array([14.0, 14.0])
	path.heights = PackedFloat32Array([30.0, 30.0])
	var cfg := {"cross_section": 0, "flat_width": 12.0, "offset": 0.0, "blend": 0,
		"follow_path_height": true, "falloff": 0.0}
	var prog := _carve_graph(path, cfg).compile_graph_program()
	var gpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(prog, GW, GH, RECT, surf)
	var cpu: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(prog, GW, GH, RECT, surf)
	if gpu.is_empty():
		_check("D", false, "the GPU refused the ground-reference fixture")
		return
	var iz := int((0.0 - G_MIN) - 0.5)
	var r_gpu := _roughness(gpu, iz)
	var r_cpu := _roughness(cpu, iz)
	var r_raw := _roughness(surf, iz)
	print("    crest roughness: GPU %.4f, CPU %.4f, bare terrain %.4f" % [r_gpu, r_cpu, r_raw])
	_check("D", absf(r_gpu - r_cpu) < 0.02 and r_gpu > 0.5 * r_raw,
			"the GPU crest carries the terrain's variation (%.0f%% of it) and matches the CPU to %.4f"
			% [100.0 * r_gpu / maxf(r_raw, 1.0e-6), absf(r_gpu - r_cpu)])

	# CONTROL: the crest is NOT the drawn height. That is precisely the per-cell answer — a dead-flat 30 m
	# ridge — and it is the one result that would prove the vertex dispatch is being ignored.
	var flat_cells := 0
	for ix in range(1, GW - 1):
		if absf(gpu[iz * GW + ix] - 30.0) < 0.01:
			flat_cells += 1
	print("    control: %d of %d crest cells sit exactly at the drawn 30 m (want few — many means per-cell)"
			% [flat_cells, GW - 2])
	if flat_cells > (GW - 2) / 2:
		_fail += 1
		print("    !! the crest collapsed onto the drawn height, which is what a per-cell reference gives")

	# CONTROL: the fixture's terrain is genuinely rough. On smooth ground the two references produce the
	# same crest and the criterion above would pass without having distinguished anything.
	print("    control: the bare terrain along the same line has roughness %.4f (want > 0.05)" % r_raw)
	if r_raw <= 0.05:
		_fail += 1
		print("    !! the fixture is too smooth to tell a per-vertex reference from a per-cell one")

	# CONTROL: and the carve ran at all on that row — a pass-through would also "carry the terrain's
	# variation", perfectly, by being the terrain.
	var lift := absf(gpu[iz * GW + GW / 2] - surf[iz * GW + GW / 2])
	print("    control: the crest sits %.2f m above the ground it was cut from (want a real lift)" % lift)
	if lift < 5.0:
		_fail += 1
		print("    !! the crest row was not carved, so [D] measured the terrain against itself")


## Mean absolute second difference along row `p_iz` — a scallop detector. Insensitive to slope (a ramp
## has a second difference of zero) and to offset, which is exactly what is wanted: the crest is supposed
## to be tilted and raised, and only its BUMPINESS is under test.
func _roughness(p_h: PackedFloat32Array, p_iz: int) -> float:
	var sum := 0.0
	var count := 0
	for ix in range(1, GW - 1):
		var a := p_h[p_iz * GW + ix - 1]
		var b := p_h[p_iz * GW + ix]
		var c := p_h[p_iz * GW + ix + 1]
		if is_finite(a) and is_finite(b) and is_finite(c):
			sum += absf(a - 2.0 * b + c)
			count += 1
	return sum / maxf(float(count), 1.0)
