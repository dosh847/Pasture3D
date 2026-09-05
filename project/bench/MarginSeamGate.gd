# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# MarginSeamGate — the Modifier Margin must not put a step in any modifier's mask at the loop rim.
#
# The margin band carries a taper that runs 1 AT THE RIM down to 0 at the band's outer edge. The brush's own
# interior profile runs the other way: 1 at the loop centre down to 0 AT THE RIM. Both are 0..1 masks over
# the same grid, and folding the first into the second is what produced a visible seam: a GENERATOR — noise,
# relief, or a graph with no Input node — read a mask that fell to 0 at the rim and jumped straight back to
# ~1 one cell outside it, so it wrote a ring of its full amplitude around every loop.
#
# TWO RULES WERE TRIED AND BOTH WERE WRONG, in opposite directions, and [C] keeps both as controls:
#
#   fold the band's taper into the interior ramp — reaches into the band, but steps at the rim (the seam),
#   zero the band                                — no step, but CROPS the brush to its own footprint,
#                                                  which is the entire feature defeated.
#
# The shipped rule is neither: a generator takes the host's own ramp TRANSLATED OUTWARD by the margin. One
# curve, moved — so it is monotone from the band's outer edge all the way in, continuous by construction,
# and reaches. A filter is separate and unchanged: 1 across the loop, then `margin_feather` through the band.
#
# A gate that only measured the step could be passed by cropping, and one that only measured reach could be
# passed by the seam. Both are asserted, and [C] shows each rejected rule failing the half it fails.
#
# [E] was added 2026-09-05: a GRAPH modifier built its own mask and never got the translation, so it read
# the band's taper outside the loop and the un-translated ramp inside it — the seam above, in the one place
# that had been left out of the fix for it. Section [B] could not see it, because a graph does not go
# through `profile`.

extends Node

const CELL := 1.0
const MARGIN := 10.0 ## metres of band on each side
const HALF := 30.0 ## metres from the loop's centre to its rim
const FALLOFF := 30.0 ## metres the interior profile ramps over — a real mound's flank, not one cell
const N := 121

## The first cell INSIDE the loop and the last one outside it, derived from the signed field rather than
## counted by hand: the rim falls between two cells and an off-by-one here would compare two band cells to
## each other and report a seam of zero on code that has one.
var _rim_in := -1
var _rim_out := -1

var _fail := 0


func _ready() -> void:
	print("=== MarginSeamGate: no step in any mask at the loop rim ===\n")
	_test_masks()
	print("\n=== %s (%d failures) ===\n" % [
		"MARGIN SEAM PASS" if _fail == 0 else "MARGIN SEAM FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _count_band(p_mask: PackedByteArray) -> int:
	var c := 0
	for k in range(N):
		if p_mask[k] == 1:
			c += 1
	return c


func _check(p_label: String, p_ok: bool, p_detail: String = "") -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s%s" % ["PASS" if p_ok else "FAIL", p_label,
			("  (%s)" % p_detail) if p_detail != "" else ""])


## A 1-cell-tall strip through a loop: cells IN0..IN1 inside, everything else real ground the band can
## claim. One row is enough — the seam is a function of the signed distance and nothing else.
func _run() -> Dictionary:
	var mound := Pasture3DMound.new()
	mound.modifier_margin = MARGIN
	add_child(mound)

	var amp := PackedFloat64Array()
	var profile := PackedFloat64Array()
	var basey := PackedFloat32Array()
	var sdf := PackedFloat32Array()
	amp.resize(N)
	profile.resize(N)
	basey.resize(N)
	sdf.resize(N)

	var mid := 0.5 * float(N - 1)
	for i in range(N):
		basey[i] = 0.0
		# Signed distance in metres: positive inside the loop, negative outside.
		var d: float = HALF - absf(float(i) - mid) * CELL
		sdf[i] = d
		if d > 0.0:
			# Inside: the brush contributes, and its interior mask ramps 0 at the rim to 1 over the
			# falloff. At one metre in, that is 1/30 — which is why a band starting at 1 is a cliff.
			amp[i] = 1.0
			profile[i] = clampf(d / FALLOFF, 0.0, 1.0)
			if _rim_in < 0:
				_rim_in = i
				_rim_out = i - 1
		else:
			amp[i] = NAN # off the loop — the band is exactly these cells
			profile[i] = 0.0

	# The host's own ramp, translated outward by the margin — what Mound and Plow each build from their own
	# falloff curve. Same expression as `profile` above with `MARGIN` added to the distance.
	var profile_ext := PackedFloat64Array()
	profile_ext.resize(N)
	for i in range(N):
		profile_ext[i] = clampf((sdf[i] + MARGIN) / FALLOFF, 0.0, 1.0)

	var ctx := {
		"gw": N, "gh": 1, "add": false, "sdf": sdf, "edge_offset": 0.0,
		"profile_ext": profile_ext,
		"vertex_spacing": CELL, "min_x": 0.0, "min_z": 0.0,
	}
	mound._run_modifier_stack([], amp, profile, basey, ctx)
	mound.queue_free()
	return ctx


func _test_masks() -> void:
	var ctx := _run()
	var profile: PackedFloat64Array = ctx["profile"]
	var mask: PackedByteArray = ctx["margin_mask"]
	var feather: PackedFloat64Array = ctx["margin_feather"]

	print("[A] The band exists at all — without this every other row is vacuous")
	var band := 0
	var inside := 0
	for k in range(N):
		if mask[k] == 1:
			band += 1
		elif is_finite(profile[k]) and ctx["sdf"][k] > 0.0:
			inside += 1
	_check("the rim was located between two cells", _rim_in > 0 and _rim_out == _rim_in - 1,
			"inside starts at %d" % _rim_in)
	_check("every cell off the loop became a band cell", band == N - inside,
			"%d band + %d inside = %d" % [band, inside, N])
	_check("the feather is ~1 where the band meets the rim",
			absf(feather[_rim_out] - 1.0) < 0.05, "%.4f" % feather[_rim_out])
	_check("and falls to 0 at the band's outer edge", feather[0] < 0.05, "%.4f" % feather[0])
	print("")

	print("[B] A GENERATOR REACHES into the band, and does it without a step")
	# Two failures are possible here and they are opposites, so both get a row. Zeroing the band removes the
	# seam by cropping the brush to its own footprint, which is the feature defeated; carrying the band's
	# own taper reaches but steps. Only the translated ramp does both.
	_check("the mask at the rim is at full-ish strength, not ~0",
			profile[_rim_in] > 0.3, "%.4f — the ramp now starts %.1f m further out" % [profile[_rim_in], MARGIN])
	var reach := 0
	for k in range(N):
		if mask[k] == 1 and profile[k] > 0.01:
			reach += 1
	_check("control: band cells carry a NON-ZERO mask — the brush is not cropped", reach > 0,
			"%d of %d band cells reach" % [reach, _count_band(mask)])
	_check("and it still falls to 0 at the band's outer edge", profile[0] < 0.01, "%.4f" % profile[0])

	# The seam as the user sees it: the jump in the mask across the rim, in units of the modifier's
	# amplitude.
	var gen_step: float = absf(profile[_rim_out] - profile[_rim_in])
	_check("the generator's mask is continuous across the rim", gen_step < 0.05,
			"step %.4f" % gen_step)
	# Monotone through the band and into the loop — one ramp, not two meeting.
	var mono := true
	for k in range(1, _rim_in + 1):
		if profile[k] < profile[k - 1] - 1e-9:
			mono = false
	_check("and monotone from the band's outer edge to the rim — one ramp, not two", mono)
	print("")

	print("[C] Control: both rejected rules, recomputed from the same inputs")
	# The un-shifted interior ramp is what `profile` would be with no margin: 0 at the rim, rising inward.
	var plain := PackedFloat64Array()
	plain.resize(N)
	for k in range(N):
		plain[k] = clampf(ctx["sdf"][k] / FALLOFF, 0.0, 1.0) if ctx["sdf"][k] > 0.0 else 0.0

	# Rejected rule 1 — fold the band's taper into the interior ramp. Reaches, but steps at the rim.
	var folded := plain.duplicate()
	for k in range(N):
		if mask[k] == 1:
			folded[k] = feather[k]
	var fold_step: float = absf(folded[_rim_out] - folded[_rim_in])
	_check("folding the band's taper in DOES step at the rim", fold_step > 0.9,
			"step %.4f — this was the seam" % fold_step)

	# Rejected rule 2 — zero the band. Continuous, but crops the brush to its own footprint.
	var zeroed := plain.duplicate()
	var zero_reach := 0
	for k in range(N):
		if mask[k] == 1 and zeroed[k] > 0.01:
			zero_reach += 1
	_check("zeroing the band DOES crop — nothing reaches past the loop", zero_reach == 0,
			"%d band cells reach — this was the cropping" % zero_reach)

	_check("the shipped rule beats both: no step AND it reaches",
			gen_step < fold_step and reach > zero_reach,
			"step %.4f vs %.4f, reach %d vs %d" % [gen_step, fold_step, reach, zero_reach])
	print("")

	print("[D] A FILTER's mask is 1 across the loop, then the feather")
	# The mask `_apply_graph_step` builds for a graph that reads its input, reconstructed by the same rule.
	var fmask := PackedFloat64Array()
	fmask.resize(N)
	for k in range(N):
		fmask[k] = feather[k] if mask[k] == 1 else 1.0
	var filt_step: float = absf(fmask[_rim_out] - fmask[_rim_in])
	_check("full strength inside the loop", fmask[_rim_in] == 1.0 and fmask[N / 2] == 1.0)
	_check("continuous across the rim too", filt_step < 0.05, "step %.4f" % filt_step)
	_check("and it still tapers away — the erosion skirt survives the fix",
			fmask[0] < 0.05, "outer edge %.4f" % fmask[0])
	print("")

	print("[E] A GRAPH modifier's mask gets the SAME translation — the omission that read as a cut")
	# Asked of the shipped rule rather than restated: `_graph_feather_mask` is pure, so the gate hands it
	# the signed field and the two band grids the stack just built and reads back what a graph would see.
	var host := Pasture3DMound.new()
	add_child(host)
	var gmask: PackedFloat64Array = host._graph_feather_mask(N, ctx["sdf"], 0.0, MARGIN, 0, FALLOFF,
			null, mask, feather, profile)
	host.queue_free()

	# The rule this replaced, rebuilt from the same inputs: the band's taper outside the loop, the
	# un-translated ramp inside it. It is the control, and it has to still fail.
	var was := PackedFloat64Array()
	was.resize(N)
	for k in range(N):
		was[k] = feather[k] if mask[k] == 1 else plain[k]

	var g_step: float = absf(gmask[_rim_out] - gmask[_rim_in])
	var was_step: float = absf(was[_rim_out] - was[_rim_in])
	# The rim is measured against the ramp's OWN worst step anywhere else, not against a round number: the
	# mask is a smoothstep over 30 m, so "small" is a property of the curve and a fixed tolerance would be
	# a number picked to pass.
	var g_elsewhere := 0.0
	for k in range(1, N):
		if k == _rim_in:
			continue
		g_elsewhere = maxf(g_elsewhere, absf(gmask[k] - gmask[k - 1]))
	var g_reach := 0
	for k in range(N):
		if mask[k] == 1 and gmask[k] > 0.01:
			g_reach += 1
	_check("the rim carries no bigger jump than any other cell of the ramp",
			g_step <= g_elsewhere + 1e-9, "rim %.4f vs %.4f elsewhere" % [g_step, g_elsewhere])
	_check("the graph mask REACHES into the band — it is not cropped to the loop", g_reach > 0,
			"%d of %d band cells" % [g_reach, _count_band(mask)])
	_check("and still falls to 0 at the band's outer edge", gmask[0] < 0.01, "%.4f" % gmask[0])
	_check("control: the rule it replaced DOES step at the rim", was_step > 0.9,
			"step %.4f vs %.4f — a graph wrote nothing at the rim and its full amplitude one cell out"
			% [was_step, g_step])
	print("")
