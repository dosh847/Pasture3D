# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# PathHeightGate — the PATH's fourth channel, and the NaN that means "no elevation was authored" (S2).
#
# ---- WHAT S2 CHANGED, AND WHY IT NEEDS ITS OWN GATE ----
#
# PASTURE3D_SPLINE_GRAPH_SPEC.md §6 puts a per-vertex elevation into Pasture3DPathGeom and appends it to
# Path Distance as a fourth output. It is the smallest possible native change and it has three failure
# modes that all look like success:
#
#   * the interpolation is subtly different from Pasture3DGraphPath.height_at, so a carve grades to a line
#     half a metre off the one the gizmo draws — [A]
#   * "no heights" becomes 0.0 somewhere along the way, so a path that says WHERE and not HOW HIGH quietly
#     claims to be at sea level, and every consumer grades to it — [B]
#   * the channel is inserted rather than appended, so every saved graph's `s` wire now reads `t` — [C]
#
# ---- WHY THERE IS NO GPU PARITY CRITERION, AND WHAT [D] IS INSTEAD ----
#
# The spec's §6.1 asks for the height array in the binding-4 SSBO and the interpolation in the shader.
# That was not built, because the GPU evaluator cannot be asked for it: the guard near the top of
# `graph_eval_grid_gpu` refuses ANY program whose wires read a channel above 0, and `height` is channel 3.
# A shader that can never be reached is not a fast path, it is unmeasurable code — and the bail is
# graph-wide, so the cost of refusing is already paid by `s` and `t`.
#
# So [D] measures the thing that IS true: a graph wired to `height` must make the GPU evaluator BAIL, not
# serve it channel 0. That is the exact failure the guard exists to prevent, and it is the one that would
# ship a distance field where an elevation was asked for.
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D"]

const GW: int = 64
const GH: int = 64
const G_MIN: float = -32.0
const RECT := Rect2(G_MIN, G_MIN, 64.0, 64.0)
const EPS: float = 1.0e-4

var _fail: int = 0
var _seen: Dictionary = {}


func _ready() -> void:
	print("=== PathHeightGate: heights in the geometry table (S2) ===")
	print("    spec: PASTURE3D_SPLINE_GRAPH_SPEC.md §6")

	_a_the_native_height_matches_the_oracle()
	_b_no_heights_reads_nan_all_the_way_out()
	_c_the_appended_channel_did_not_move_the_others()
	_d_the_gpu_refuses_the_height_channel()

	for name in CRITERIA:
		if not _seen.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	print("=== PATH HEIGHT %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])


# ---- fixtures -----------------------------------------------------------------------------------

## A path that CLIMBS, and does not climb linearly.
##
## The slope is what makes [A] a test at all: a flat path's interpolation is right whatever the weights
## are, because every vertex has the same answer. The uneven spacing is what makes the ARC-LENGTH
## parameterisation testable — a height_at that interpolated by vertex INDEX instead would agree with the
## oracle on evenly spaced vertices and disagree here, where the segments are 8 m and 16 m long.
func _sloped() -> Pasture3DGraphPath:
	var path := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	var w := PackedFloat32Array()
	var h := PackedFloat32Array()
	var x := -28.0
	for i in 7:
		pts.append(Vector2(x, -6.0 + float(i) * 2.0))
		w.append(4.0)
		h.append(2.0 + float(i) * float(i) * 0.9) # quadratic: a linear lerp cannot match it by luck
		x += 8.0 if i < 3 else 16.0
	path.points = pts
	path.half_widths = w
	path.heights = h
	return path


## The SAME curve with the heights removed. Same points, same widths — so anything [B] sees is the height
## array and not the geometry.
func _heightless() -> Pasture3DGraphPath:
	var path := _sloped()
	path.heights = PackedFloat32Array()
	return path


func _prod(p_path: Pasture3DGraphPath) -> Array:
	var node := Pasture3DGraphNodePathDistance.new()
	node.set_path_inputs([p_path])
	return node.eval_grid_channels([], GW, GH, null, RECT)


func _oracle(p_path: Pasture3DGraphPath) -> Array:
	var node := Pasture3DGraphNodeDevPathDistance.new()
	node.set_path_inputs([p_path])
	return node.eval_grid_channels([], GW, GH, null, RECT)


## Worst disagreement, treating NaN as a VALUE that must match. Two fields that are NaN in different
## places are not "equal where they are both finite" — they disagree about where there is data at all.
func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
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


func _spread(p_v: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for v in p_v:
		if is_finite(v):
			lo = minf(lo, v)
			hi = maxf(hi, v)
	return 0.0 if lo > hi else hi - lo


func _nan_count(p_v: PackedFloat32Array) -> int:
	var n := 0
	for v in p_v:
		if is_nan(v):
			n += 1
	return n


## A graph that reads ONE channel of Path Distance and nothing else: Road Source → Path Distance[ch] →
## Output. Built per channel rather than once with four outputs, because the thing under test is which
## FIELD a port index selects, and one graph reading all four could not tell a swap from a rename.
func _channel_graph(p_path: Pasture3DGraphPath, p_channel: int) -> Pasture3DTerrainGraph:
	var src := Pasture3DGraphNodeRoadSource.new()
	src.path = p_path
	var g := Pasture3DTerrainGraph.new()
	var nodes: Array[Pasture3DGraphNode] = [
		src, Pasture3DGraphNodePathDistance.new(), Pasture3DGraphNodeOutput.new()]
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, p_channel, 2, 0]]
	return g


func _native(p_g: Pasture3DTerrainGraph) -> PackedFloat32Array:
	var surf := PackedFloat32Array()
	surf.resize(GW * GH)
	return Pasture3DUtil.graph_eval_grid(p_g.compile_graph_program(), GW, GH, RECT, surf)


# ---- A ------------------------------------------------------------------------------------------

## [A] The native `height` channel matches Pasture3DGraphPath.height_at, cell for cell.
##
## Both halves of the Tier-2 route are exercised: the production node calls the C++ `height_at` through
## `path_query_grid`, the [Dev/GD] node calls the GDScript one directly. Agreement means the port copied
## an algorithm, not a file.
func _a_the_native_height_matches_the_oracle() -> void:
	print("[A] the native height channel matches the [Dev/GD] oracle")
	if not ClassDB.class_has_method("Pasture3DUtil", "path_query_grid"):
		_check("A", false, "path_query_grid is not bound — rebuild the GDExtension")
		return
	var path := _sloped()
	var nat := _prod(path)
	var ora := _oracle(path)
	if nat.size() < 4 or ora.size() < 4:
		_check("A", false, "the node returned %d channel(s), not 4" % nat.size())
		return
	var w := _worst(nat[3], ora[3])
	_check("A", w < EPS, "worst |native - oracle| = %.7f over %d cells (want < %.4f)"
			% [w, GW * GH, EPS])

	# CONTROL: the field actually VARIES. A flat path — or a height_at that answered one constant — would
	# agree with an oracle doing the same, and this criterion would be two implementations of nothing.
	var span := _spread(nat[3])
	print("    control: the height field spans %.4f m (want a real climb, not a constant)" % span)
	if span < 5.0:
		_fail += 1
		print("    !! the height channel barely varies, so [A] compared two constants")

	# CONTROL: the native call really produced heights rather than falling back. A path_query_grid that
	# ignored its new argument would return NaN everywhere, and an oracle that did the same would agree
	# with it. Named separately because it is the failure a DEFAULTED parameter invites.
	var nans := _nan_count(nat[3])
	print("    control: %d NaN cell(s) in the native height field (want 0 — the path carries heights)"
			% nans)
	if nans > 0:
		_fail += 1
		print("    !! the native side answered 'no heights' for a path that has them")


# ---- B ------------------------------------------------------------------------------------------

## [B] A path with no heights reads NaN — through the node, through the whole-graph program, and on the
## empty path's separate branch — and the NaN is not turned into 0 on the way.
##
## Three routes rather than one, because each is a place a zero-fill could be introduced: the `height`
## array is copied verbatim in `build`, hoisted past `height_at` in the grid kernel, and copied into an
## aux buffer that was ZERO-FILLED on acquire. That last hop is the dangerous one — the destination is
## already full of the wrong answer before the op writes to it.
func _b_no_heights_reads_nan_all_the_way_out() -> void:
	print("[B] a path with no heights reads NaN, and it survives to the output")
	var bare := _heightless()
	var nat := _prod(bare)
	if nat.size() < 4:
		_check("B", false, "the node returned %d channel(s), not 4" % nat.size())
		return
	var n := GW * GH
	var node_nans := _nan_count(nat[3])
	var graph_out := _native(_channel_graph(bare, 3))
	var graph_nans := _nan_count(graph_out)
	# The empty path too: a different branch in the kernel entirely — one fill, no per-cell query — and
	# the branch where filling `unreachable_distance` would read as an elevation of ten kilometres.
	var empty_out := _prod(Pasture3DGraphPath.new())
	var empty_nans := _nan_count(empty_out[3]) if empty_out.size() >= 4 else -1
	print("    node %d/%d NaN, whole-graph %d/%d NaN, empty path %d/%d NaN"
			% [node_nans, n, graph_nans, graph_out.size(), empty_nans, n])
	_check("B", node_nans == n and graph_out.size() == n and graph_nans == n and empty_nans == n,
			"NaN everywhere on all three routes: %s"
			% str(node_nans == n and graph_nans == n and empty_nans == n))

	# CONTROL: the same fixture WITH heights reads finite, on both routes. Without this, a height channel
	# that answered NaN unconditionally — the easiest possible bug — would pass [B] outright.
	var with_h := _prod(_sloped())
	var finite_nans := _nan_count(with_h[3]) if with_h.size() >= 4 else n
	var graph_h := _native(_channel_graph(_sloped(), 3))
	print("    control: the same curve WITH heights reads %d NaN via the node and %d via the graph (want 0, 0)"
			% [finite_nans, _nan_count(graph_h)])
	if finite_nans > 0 or _nan_count(graph_h) > 0:
		_fail += 1
		print("    !! the height channel is NaN whether or not the path carries heights, so [B] proves nothing")

	# CONTROL: a ZERO-FILLED height array is not the same claim as an empty one. This is the distinction
	# "empty must stay representable" exists for, and it is invisible to a NaN count on its own.
	var sea := _heightless()
	var zeros := PackedFloat32Array()
	zeros.resize(sea.points.size())
	zeros.fill(0.0)
	sea.heights = zeros
	var sea_out := _prod(sea)
	var sea_nans := _nan_count(sea_out[3]) if sea_out.size() >= 4 else -1
	print("    control: a path at literal sea level reads %d NaN (want 0 — 0 m is a measurement)" % sea_nans)
	if sea_nans != 0:
		_fail += 1
		print("    !! 'no heights' and 'heights that are all zero' are being answered the same way")


# ---- C ------------------------------------------------------------------------------------------

## [C] Appending the channel did not move ports 0, 1 and 2.
##
## The expected values are HARD-CODED, not recomputed from the same node under test. Comparing port 0 to
## "whatever port 0 returns" is a tautology; comparing it to a number derived by hand from the fixture's
## geometry is the only version of this that can fail.
##
## The fixture is deliberately trivial for that reason: a straight 40 m line along +X at z = 0, half-width
## 5 m, climbing 10 m → 30 m. Every expected number below can be checked by reading it.
func _c_the_appended_channel_did_not_move_the_others() -> void:
	print("[C] the appended channel left ports 0-2 where they were")
	var path := Pasture3DGraphPath.new()
	path.points = PackedVector2Array([Vector2(-20.0, 0.0), Vector2(20.0, 0.0)])
	path.half_widths = PackedFloat32Array([5.0, 5.0])
	path.heights = PackedFloat32Array([10.0, 30.0])
	var node := Pasture3DGraphNodePathDistance.new()
	node.set_path_inputs([path])
	# 3x3 over a 6 m box whose corner is (-3, 0), so cell (2, 1)'s CENTRE is (-3 + 2.5, 0 + 3.0).
	var res: Array = node.eval_grid_channels([], 3, 3, null, Rect2(-3.0, 0.0, 6.0, 6.0))
	if res.size() < 4:
		_check("C", false, "the node returned %d channel(s), not 4" % res.size())
		return
	var i := 1 * 3 + 2 # the cell at (2.0, 3.0)
	# distance: 3 m perpendicular to the line. s: 22 m along it from x = -20. t: 3/5 = 0.6, POSITIVE
	# because +z is the driver's right on a road heading +x. height: lerp(10, 30, 22/40) = 21 m.
	var want := [3.0, 22.0, 0.6, 21.0]
	var names := ["distance", "s", "t", "height"]
	var bad := PackedStringArray()
	for c in 4:
		var got: float = res[c][i]
		print("    port %d %-8s got %.5f, want %.5f" % [c, names[c], got, want[c]])
		if absf(got - float(want[c])) > 1.0e-3:
			bad.append(names[c])
	_check("C", bad.is_empty(), "ports agreeing with their pre-S2 meanings: %s"
			% ("all four" if bad.is_empty() else "all but " + str(bad)))

	# CONTROL: the four expected values are mutually distinct, so a port SWAP cannot pass by coincidence.
	# Checked rather than left to the eye, because a later edit to the fixture could quietly collapse two.
	var distinct := true
	for a in 4:
		for b in range(a + 1, 4):
			if absf(float(want[a]) - float(want[b])) < 1.0e-3:
				distinct = false
	print("    control: the four expected values are mutually distinct: %s" % str(distinct))
	if not distinct:
		_fail += 1
		print("    !! two ports expect the same number, so [C] cannot detect a swap between them")

	# CONTROL: the node really declares four ports now. Everything above would pass unchanged on a node
	# that never gained the channel at all, since ports 0-2 would be exactly where they were.
	print("    control: output_count = %d, native_out_count = %d (want 4, 4)"
			% [node.output_count(), node.native_out_count()])
	if node.output_count() != 4 or node.native_out_count() != 4:
		_fail += 1
		print("    !! the fourth channel was never added, so [C] measured an unchanged node")


# ---- D ------------------------------------------------------------------------------------------

## [D] The GPU evaluator BAILS on a graph wired to `height`, rather than serving it channel 0.
##
## The bail is graph-wide and that is the correct trade: a graph reading an elevation gets a CPU pass,
## where a GPU path serving `distance` under the name `height` would grade a river bed to a distance
## field. A guard is only worth having if something measures it, and this is that.
func _d_the_gpu_refuses_the_height_channel() -> void:
	print("[D] the GPU evaluator refuses a graph that reads the height channel")
	if not ClassDB.class_has_method("Pasture3DUtil", "graph_eval_grid_gpu"):
		_check("D", false, "graph_eval_grid_gpu is not bound — rebuild the GDExtension")
		return
	var surf := PackedFloat32Array()
	surf.resize(GW * GH)
	var h_out: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
			_channel_graph(_sloped(), 3).compile_graph_program(), GW, GH, RECT, surf)
	# The CONTROL runs FIRST, because on this route an empty return is ambiguous: a machine with no
	# RenderingDevice bails on everything, and a criterion that read that as a refusal would report a
	# pass having measured nothing at all.
	var d_out: PackedFloat32Array = Pasture3DUtil.graph_eval_grid_gpu(
			_channel_graph(_sloped(), 0).compile_graph_program(), GW, GH, RECT, surf)
	if d_out.is_empty():
		print("    NO-SIGNAL: the GPU evaluator also bailed on the channel-0 graph, so there is no local")
		print("    RenderingDevice (headless / no driver). Re-run WITHOUT --headless to test the guard.")
		_seen["D"] = true
		return
	print("    channel 0 (distance): %d cell(s) returned — the GPU route is live here" % d_out.size())
	_check("D", h_out.is_empty(),
			"channel 3 (height) returned %d cell(s) (want 0 — a graph-wide bail)" % h_out.size())
	if not h_out.is_empty():
		print("    !! the GPU served a height port from a plan that holds one buffer per slot, so this is")
		print("       almost certainly channel 0's distance field wearing the name 'height'.")
