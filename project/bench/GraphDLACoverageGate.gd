# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphDLACoverageGate — does `coverage` actually cover the loop?
#
# The complaint this gate exists for: at coverage 1.0 the massif stopped well short of the brush footprint.
# Two separate reasons, and this gate holds both fixed:
#   * THE ENVELOPE WAS AN ELLIPSE inscribed in the loop's bounding rectangle, so anything the loop had that
#     an ellipse does not — an arm, a corner, a hand-drawn bulge — was never grown into at any setting.
#     The growth now measures the loop's own outline off the wired input's no-data boundary.
#   * SIZE MUST STILL BE A CONTROL. An envelope that follows the loop is worthless if `coverage` stops
#     meaning anything, so the reach has to keep tracking it.
#
#   [A] The outline is measured and used: on a loop running across the DIAGONAL, following it puts markedly
#       more mountain in the bar's FAR ENDS -- the loop cells past 0.85 of the half-extent, which the ellipse
#       inscribed in the bounding box barely reaches -- than growing in that ellipse does. Control: the same
#       growth with no outline captured (the ellipse fallback), masked by the same loop -- and both runs must
#       be non-empty, so a dead growth cannot pass either side.
#
#       NOT the whole loop. That was the first version of this criterion and it was red for as long as it
#       existed, for a reason in the metric: across the bar's middle the ellipse overshoots both long sides
#       and is sliced by them, so it scores full, while the outline fades INSIDE them as [B] demands. The whole-
#       loop share rewarded exactly the cut-off [B] forbids. It also hid a real bug: the far ends grew no node
#       at all, because the launch offset was measured in the outline's typical (short-axis) radius.
#   [B] It fades INSIDE the loop rather than being cut off at it: the ring just inside the outline carries
#       only a small share of the peak. Control: the ellipse run, which overshoots the bar's long sides and
#       is sliced by them, must show materially more mass on that ring.
#   [C] `coverage` still sizes the massif on an outlined loop: 1.0 fills more of the loop than 0.5.
#       Control: the 0.5 run must be the smaller one.
#   [D] The fallback survives a loop with no data at its centre (nothing to march from): the growth still
#       produces a massif instead of collapsing to zero radius.
#
# Pure GDScript on the graph node + the relief growth engine. Native parity for the outline lives in
# GraphDLANativeParityGate, which is the gate that owns C++/GDScript equality.
extends Node

const GW := 64
const GH := 64
const RECT := Rect2(-100.0, -100.0, 200.0, 200.0)

var _fail := 0


func _ready() -> void:
	print("=== GraphDLACoverageGate: coverage covers the loop ===\n")
	_a_outline_fills_the_arms()
	_b_fades_inside_the_loop()
	_c_coverage_still_sizes_it()
	_d_no_centre_data_falls_back()
	print("\n=== %s (%d failures) ===\n" % ["DLA COVERAGE PASS" if _fail == 0 else "DLA COVERAGE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _new_dla(p_coverage: float) -> Pasture3DGraphNodeDLA:
	var d := Pasture3DGraphNodeDLA.new()
	d.resolution = 128
	d.hierarchy_levels = 3
	d.coverage = p_coverage
	d.amplitude = 1.0
	d.evaluation = 0 # LIVE
	return d


## A BAR ACROSS THE DIAGONAL: a band 28% of the grid wide, running corner to corner. NaN outside, which is
## what a brush hands a graph.
##
## The shape matters, and a plus is the wrong one: an ellipse inscribed in a plus's bounding box reaches
## furthest along exactly the axes where the plus keeps its arms, so the two envelopes agree where the test
## looks and the comparison measures nothing. A diagonal bar puts the loop's far ends near the bounding
## box's CORNERS, which an inscribed ellipse cannot reach at any coverage — the region only an outline can
## grow into.
func _bar_mask() -> PackedByteArray:
	var m := PackedByteArray()
	m.resize(GW * GH)
	for iz in range(GH):
		var v := (float(iz) + 0.5) / float(GH) * 2.0 - 1.0
		for ix in range(GW):
			var u := (float(ix) + 0.5) / float(GW) * 2.0 - 1.0
			m[iz * GW + ix] = 1 if absf(u + v) <= 0.28 else 0
	return m


## The plus as a wired input surface: a real value inside, NaN outside.
func _surface_from(p_mask: PackedByteArray) -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	for i in range(GW * GH):
		g[i] = 10.0 if p_mask[i] == 1 else NAN
	return g


## Cells inside the loop whose 4-neighbourhood leaves it — the outline's inner ring.
func _rim_cells(p_mask: PackedByteArray) -> PackedInt32Array:
	var out := PackedInt32Array()
	for iz in range(1, GH - 1):
		for ix in range(1, GW - 1):
			var i := iz * GW + ix
			if p_mask[i] == 0:
				continue
			if p_mask[i - 1] == 0 or p_mask[i + 1] == 0 or p_mask[i - GW] == 0 or p_mask[i + GW] == 0:
				out.append(i)
	return out


## The node's footprint MASK channel. `p_wired` false grows with nothing captured (the ellipse fallback) and
## the plus is applied here instead, so both runs are judged over exactly the same cells.
func _mask_channel(p_coverage: float, p_surface: PackedFloat32Array) -> PackedFloat32Array:
	var d := _new_dla(p_coverage)
	return d.eval_grid_channels([p_surface], GW, GH, null, RECT)[1]


func _peak(p_g: PackedFloat32Array) -> float:
	var m := 0.0
	for v in p_g:
		if is_finite(v):
			m = maxf(m, v)
	return m


## Share of `p_cells` carrying more than 1% of the field's peak — "how much of this region is mountain".
func _fill(p_g: PackedFloat32Array, p_cells: PackedInt32Array, p_peak: float) -> float:
	if p_cells.is_empty() or p_peak <= 0.0:
		return 0.0
	var hit := 0
	for i in p_cells:
		var v := p_g[i]
		if is_finite(v) and v > 0.01 * p_peak:
			hit += 1
	return float(hit) / float(p_cells.size())


func _mean(p_g: PackedFloat32Array, p_cells: PackedInt32Array) -> float:
	if p_cells.is_empty():
		return 0.0
	var s := 0.0
	for i in p_cells:
		var v := p_g[i]
		s += v if is_finite(v) else 0.0
	return s / float(p_cells.size())


# ---- [A] --------------------------------------------------------------------------------------------

func _a_outline_fills_the_arms() -> void:
	print("[A] The loop's outline is measured and grown into: a diagonal bar gets its far ends filled")
	var mask := _bar_mask()
	var inside := PackedInt32Array()
	for iz in range(GH):
		var v := (float(iz) + 0.5) / float(GH) * 2.0 - 1.0
		for ix in range(GW):
			var u := (float(ix) + 0.5) / float(GW) * 2.0 - 1.0
			var i := iz * GW + ix
			if mask[i] == 1 and u * u + v * v > 0.85 * 0.85:
				inside.append(i)
	var shaped := _mask_channel(1.0, _surface_from(mask))
	# The control: nothing captured, so the growth falls back to the inscribed ellipse. Masked by the same
	# plus here, so the only difference between the two numbers is the envelope the cluster grew to.
	var flat := PackedFloat32Array()
	flat.resize(GW * GH)
	var ellipse := _mask_channel(1.0, flat)
	for i in range(GW * GH):
		if mask[i] == 0:
			ellipse[i] = 0.0
	var pk_s := _peak(shaped)
	var pk_e := _peak(ellipse)
	var fill_s := _fill(shaped, inside, pk_s)
	var fill_e := _fill(ellipse, inside, pk_e)
	print("    far-end cells=%d   outline fills %.3f of them (peak %.3f)   ellipse fills %.3f (peak %.3f)" % [
		inside.size(), fill_s, pk_s, fill_e, pk_e])
	if pk_s <= 0.0 or pk_e <= 0.0:
		_fail += 1; print("    !! a growth produced nothing — neither side of this comparison measured a massif")
		return
	if fill_s < fill_e * 1.25:
		_fail += 1; print("    !! CONTROL: following the outline filled no more of the bar's far ends than the inscribed ellipse did (%.3f vs %.3f) — the outline is not being used" % [fill_s, fill_e])
	# The fill above cannot see a starved end on its own: slopes from growth nearer the middle spill into it
	# either way (measured 1.41x with the launch bug in, 1.68x fixed). The bug grew NO NODES there, so count them.
	var e = _new_dla(1.0)._make_engine(_surface_from(mask), GW, GH, RECT, 1.0, 0.12)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0
	var cl: Array = e._grow(rng, 32, 128)
	var xs: PackedFloat32Array = cl[0]
	var ys: PackedFloat32Array = cl[1]
	var far := 0
	for i in range(xs.size()):
		var u := xs[i] / 128.0 * 2.0 - 1.0
		var v := ys[i] / 128.0 * 2.0 - 1.0
		if u * u + v * v > 0.85 * 0.85:
			far += 1
	print("    nodes grown in the far ends: %d of %d" % [far, xs.size()])
	if far < 40:
		_fail += 1; print("    !! the growth never reached the bar's far ends; walkers launched there die in the corridor")


# ---- [B] --------------------------------------------------------------------------------------------

func _b_fades_inside_the_loop() -> void:
	print("[B] The massif fades inside its loop rather than being cut off at the outline")
	var mask := _bar_mask()
	var rim := _rim_cells(mask)
	var shaped := _mask_channel(1.0, _surface_from(mask))
	var flat := PackedFloat32Array()
	flat.resize(GW * GH)
	var ellipse := _mask_channel(1.0, flat)
	for i in range(GW * GH):
		if mask[i] == 0:
			ellipse[i] = 0.0
	var pk_s := _peak(shaped)
	var pk_e := _peak(ellipse)
	if pk_s <= 0.0 or pk_e <= 0.0:
		_fail += 1; print("    !! a growth produced nothing")
		return
	var rim_s := _mean(shaped, rim) / pk_s
	var rim_e := _mean(ellipse, rim) / pk_e
	print("    rim cells=%d   outline rim/peak=%.3f   ellipse rim/peak=%.3f" % [rim.size(), rim_s, rim_e])
	if rim_s > 0.25:
		_fail += 1; print("    !! the outlined massif is still standing up at the loop edge (%.3f of peak) — a step, not a fade" % rim_s)
	if rim_e <= rim_s:
		_fail += 1; print("    !! CONTROL: the ellipse run was not sliced by the loop (%.3f <= %.3f), so this measures nothing" % [rim_e, rim_s])


# ---- [C] --------------------------------------------------------------------------------------------

func _c_coverage_still_sizes_it() -> void:
	print("[C] Coverage still sizes the massif on an outlined loop")
	var mask := _bar_mask()
	var inside := PackedInt32Array()
	for i in range(GW * GH):
		if mask[i] == 1:
			inside.append(i)
	var surf := _surface_from(mask)
	var full := _mask_channel(1.0, surf)
	var half := _mask_channel(0.5, surf)
	var fill_full := _fill(full, inside, _peak(full))
	var fill_half := _fill(half, inside, _peak(half))
	print("    loop cells=%d   coverage 1.0 fill=%.3f   coverage 0.5 fill=%.3f" % [
		inside.size(), fill_full, fill_half])
	if fill_full <= fill_half * 1.15:
		_fail += 1; print("    !! coverage stopped sizing the massif (%.3f at 1.0 vs %.3f at 0.5)" % [fill_full, fill_half])
	if fill_half <= 0.0:
		_fail += 1; print("    !! CONTROL: the 0.5 run grew nothing at all, so the comparison is vacuous")


# ---- [D] --------------------------------------------------------------------------------------------

func _d_no_centre_data_falls_back() -> void:
	print("[D] A loop with no data at its centre falls back to the ellipse instead of collapsing")
	# A ring: data everywhere except a hole over the middle, where the cluster's own seed point sits. There
	# is nothing to march an outline from, and the growth must still produce a massif.
	var g := PackedFloat32Array()
	g.resize(GW * GH)
	for iz in range(GH):
		var v := (float(iz) + 0.5) / float(GH) * 2.0 - 1.0
		for ix in range(GW):
			var u := (float(ix) + 0.5) / float(GW) * 2.0 - 1.0
			g[iz * GW + ix] = NAN if sqrt(u * u + v * v) < 0.25 else 10.0
	var out := _mask_channel(1.0, g)
	var pk := _peak(out)
	print("    peak=%.3f" % pk)
	if pk <= 0.0:
		_fail += 1; print("    !! no-centre-data loop grew nothing — the ellipse fallback is not being taken")
