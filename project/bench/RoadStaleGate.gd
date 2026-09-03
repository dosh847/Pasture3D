# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadStaleGate — the brush stamp key is blind to road content.
# PASTURE3D_ROAD_STALENESS_AND_COST_SPEC.md §3 S1, criteria [SA] [SB] [SC] [SF] [SG].
#
# ---- WHAT THIS GATE IS ABOUT ----
#
# `_compute_stamp_key` hashed a brush's geometry and its modifier params. A ROAD's baked surface also
# depends on the resolve chain (§5.3), its segments, its junction pins and the corridor width the bake
# committed to — none of which the key could see. So `_paint_into` recomputed an identical key after any
# of those moved, hit `_stamp_cache`, and replayed the block solved from the OLD values. `_paint_spline`
# never ran, so the alignment was never re-solved either.
#
# ---- WHY EVERY CRITERION ASSERTS THE CACHE DECISION, NOT THE HEIGHT FIELD ----
#
# The bug was INTERMITTENT, and a gate that measured the terrain could pass for the wrong reason.
# `_refresh_owner` runs `_apply_surface_snap` before `_paint_into`, and road brushes default
# `snap_to_surface = true` — so when the previous bake moved the ground under a control point, the snap
# moved its Y, `get_baked_points()` changed, and the key changed BY ACCIDENT. On flat ground it did not.
# An outcome-only assertion therefore passes on a snapping fixture with the bug fully present. Every
# criterion below reads the KEY, and the fixture pins `snap_to_surface = false` so the accidental route
# is closed and the only thing that can move the key is the thing under test.
#
# ---- THE SHAPE OF THE CONTROLS ----
#
# For [SA] and [SB] the control is not a separate scenario, it is a term-by-term diff of
# `road_content_signature()`. Asserting only "the key changed" would pass if ANY term had moved — and
# several move together during a resolve. Asserting that exactly one term moved, and naming which, is
# what proves the key is sensitive to the junction pins (resp. the corridor width) specifically. It is
# also the pre-fix control stated directly: the old key contained NONE of these terms, so a signature in
# which every other term is unchanged is a signature the old key could not have distinguished.
@tool
extends Node

## The name of each term in `Pasture3DRoadBrush.road_content_signature()`, in order. Named rather than
## inlined so that a term added to the middle of that array fails here as a wrong NAME instead of
## silently re-pointing a criterion at its neighbour.
const TERM_NAMES: PackedStringArray = [
	"closed", "lane_count", "follow_terrain", "one_way", "surface_id",
	"road_type", "brush_defaults", "segments", "junction_digest", "padding",
]
const TERM_JUNCTION: int = 8
const TERM_PADDING: int = 9

var _fail: int = 0


func _ready() -> void:
	print("=== RoadStaleGate: the stamp key and road content (spec S1) ===\n")
	_sa_junction_pins_reach_the_key()
	_sb_corridor_widening_converges()
	_sc_no_spurious_first_bake_rebake()
	_sf_signature_is_stable_with_no_edit()
	_sg_chunk_host_shares_the_road_type_reading()
	print("\n=== %s (%d failures) ===\n" % [
		"ROAD STALE PASS" if _fail == 0 else "ROAD STALE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["    " if p_ok else "!!  ", p_name, p_detail])


## The names of the signature terms that differ between two signatures. The control for [SA] and [SB].
func _terms_changed(p_before: Array, p_after: Array) -> PackedStringArray:
	var out := PackedStringArray()
	if p_before.size() != p_after.size() or p_before.size() != TERM_NAMES.size():
		out.append("SIGNATURE ARITY CHANGED (%d vs %d, expected %d)"
				% [p_before.size(), p_after.size(), TERM_NAMES.size()])
		return out
	for i in p_before.size():
		if hash(p_before[i]) != hash(p_after[i]):
			out.append(TERM_NAMES[i])
	return out


# ---- fixture -------------------------------------------------------------------------------------

## Two crossing roads on a real terrain under one network, neither baked.
##
## `snap_to_surface` is FALSE on both. That is the load-bearing line of this whole file: with it true a
## bake can move its own control points and change `get_baked_points()`, which changes the stamp key
## through the base class and hands every criterion below a pass it did not earn. See the header.
func _crossing_fixture() -> Dictionary:
	var terrain := Pasture3D.new()
	terrain.region_size = 256
	terrain.vertex_spacing = 1.0
	add_child(terrain)
	var data: Pasture3DData = terrain.data
	data.add_region_blank(Vector2i(0, 0))
	data.ensure_layer_stack()
	var stack := data.get_layer_stack()
	var layer_id: int = stack.add_layer("stale_bake")
	var lay: Pasture3DLayer = stack.get_layer(layer_id)
	lay.set_map_type(0)
	lay.set_base(false)
	lay.set_visible(true)

	var net := Pasture3DRoadNetwork.new()
	terrain.add_child(net)
	var t := Pasture3DRoadType.new()
	t.type_name = "cross"
	t.lane_count = 2
	t.lane_width = 3.5
	net.road_types = [t]

	var brushes: Array = []
	for spec in [[Vector3(40.0, 0.0, 128.0), Vector3(200.0, 0.0, 128.0), "EW"],
			[Vector3(128.0, 0.0, 40.0), Vector3(128.0, 0.0, 200.0), "NS"]]:
		var brush := Pasture3DRoadBrush.new()
		brush.name = String(spec[2])
		net.add_child(brush)
		brush.terrain = terrain
		brush.snap_to_surface = false
		brush.road_road_type = t
		var path := Path3D.new()
		var curve := Curve3D.new()
		curve.add_point(spec[0])
		curve.add_point(spec[1])
		path.curve = curve
		brush.add_child(path)
		var road_mod := Pasture3DNodeRoad.new()
		road_mod.alignment_step = 2.0
		brush.modifiers = [road_mod]
		brushes.append(brush)
	return {"terrain": terrain, "net": net, "layer": layer_id, "brushes": brushes}


## An alignment standing `p_offset` metres clear of the ground at every sample, so `_deepest_structure`
## reports that depth and `corridor_half_width` widens by `p_offset / batter`. Driving the depth directly
## is deliberate: a real deep cutting needs a mountain in the fixture, and the criterion is about what the
## KEY does with a depth, not about whether the solver can produce one.
func _alignment_standing_clear(p_n: int, p_offset: float) -> Pasture3DRoadAlignment:
	var a := Pasture3DRoadAlignment.new()
	a.ds = 2.0
	var z := PackedFloat32Array()
	var g := PackedFloat32Array()
	z.resize(p_n)
	g.resize(p_n)
	for i in p_n:
		g[i] = 0.0
		z[i] = -p_offset
	a.z = z
	a.ground = g
	a.bank = Pasture3DRoadGrader._zeros(p_n)
	a.curvature = Pasture3DRoadGrader._zeros(p_n)
	return a


# ---- [SA] --------------------------------------------------------------------------------------

## The junction pins reach the stamp key, so the re-bake that carries them is a MISS.
##
## `schedule_junction_rebake` records the digest and asks for a refresh. Before this fix that refresh set
## `_full_dirty` and nothing else — `_stamp_cache` was untouched and the key was unchanged, so the bake
## replayed the block solved WITHOUT pins and `_paint_spline` never ran. And because the digest had
## already been advanced, the next resolve did not ask again: the minor road stayed at the height it
## wanted before it was asked to meet the major road, permanently.
func _sa_junction_pins_reach_the_key() -> void:
	print("[SA] junction pins move the stamp key")
	var fx := _crossing_fixture()
	var brush: Pasture3DRoadBrush = fx["brushes"][1]
	var path: Path3D = brush.get_child(0)

	var before_sig := brush.road_content_signature()
	var before_key := brush._compute_stamp_key(path)
	var before_digest := brush.junction_digest()

	# Both roads need a solved alignment before they are detectable as crossing.
	for b: Pasture3DRoadBrush in fx["brushes"]:
		var m: Pasture3DNodeRoad = b.modifiers[0]
		m.last_alignment = _alignment_standing_clear(90, 0.0)
	fx["net"].resolve_junctions()

	var after_digest := brush.junction_digest()
	var after_sig := brush.road_content_signature()
	var after_key := brush._compute_stamp_key(path)
	var moved := _terms_changed(before_sig, after_sig)

	# FIXTURE, not the criterion: if the resolve produced no pins there is nothing to be sensitive to,
	# and every assertion below would pass vacuously.
	_check("[SA] fixture", before_digest != after_digest,
			"the resolve gave this road a junction demand (%d -> %d chars)"
			% [before_digest.length(), after_digest.length()])
	_check("[SA]", after_key != before_key,
			"the stamp key moved with the pins (%d -> %d), so the re-bake is a miss"
			% [before_key, after_key])
	# The control. Exactly one term moved, and it is the junction term — so the key moved BECAUSE of the
	# pins. The pre-fix key held none of these terms and could not have moved at all.
	_check("[SA] control", moved.size() == 1 and moved[0] == TERM_NAMES[TERM_JUNCTION],
			"only the junction term moved: [%s]" % ", ".join(moved))
	fx["terrain"].queue_free()


# ---- [SB] --------------------------------------------------------------------------------------

## The corridor widens on the second bake, and stops on the third.
##
## Two halves, and only the pair proves the fix. The FIRST half is that the padding term moves at all: a
## signature without it replays the narrow block and the road keeps its sheer wall, which is the bug.
## The SECOND is that it then settles — an unquantised float would move on every bake, the key would
## never repeat, and the stamp cache on the most expensive brush the layer has would be permanently cold.
## A fix that passes one and fails the other is not a fix.
func _sb_corridor_widening_converges() -> void:
	print("[SB] the corridor widens once and then settles")
	var fx := _crossing_fixture()
	var brush: Pasture3DRoadBrush = fx["brushes"][0]
	var path: Path3D = brush.get_child(0)
	var mod: Pasture3DNodeRoad = brush.modifiers[0]

	# Bake 1: nothing solved yet, so `_deepest_structure` is 0 and the corridor is the road's own width.
	var sig1 := brush.road_content_signature()
	var key1 := brush._compute_stamp_key(path)
	var pad1 := brush._padding()

	# Bake 1 solves an alignment standing well clear of the ground: the corridor the NEXT bake wants.
	mod.last_alignment = _alignment_standing_clear(90, 18.0)
	var sig2 := brush.road_content_signature()
	var key2 := brush._compute_stamp_key(path)
	var pad2 := brush._padding()

	# Bake 2 re-solves the SAME alignment — it is sampled along the plan at `alignment_step` and does not
	# depend on the grid width — so the third key must equal the second.
	mod.last_alignment = _alignment_standing_clear(90, 18.0)
	var key3 := brush._compute_stamp_key(path)
	var pad3 := brush._padding()

	var moved := _terms_changed(sig1, sig2)
	_check("[SB] fixture", pad2 > pad1 + Pasture3DRoadBrush.PAD_QUANTUM,
			"the solved depth widened the corridor %.2f m -> %.2f m" % [pad1, pad2])
	_check("[SB] widens", key2 != key1,
			"bake 2 is a miss (%d -> %d), so the wider footprint is actually rasterised" % [key1, key2])
	_check("[SB] settles", key3 == key2 and is_equal_approx(pad3, pad2),
			"bake 3 is a hit at the same %.2f m corridor, so the loop terminates" % pad3)
	_check("[SB] control", moved.size() == 1 and moved[0] == TERM_NAMES[TERM_PADDING],
			"only the padding term moved: [%s]" % ", ".join(moved))
	fx["terrain"].queue_free()


# ---- [SC] --------------------------------------------------------------------------------------

## A road whose corridor did not outgrow its bake schedules NO extra bake.
##
## The old guard compared against `_last_corridor_half`, an unsaved float initialised to 0.0, while
## `corridor_half_width` returns at least `allowance / batter` — 12 / 0.6 = 20 m with default batters. So
## `20.0 > 0.0 + 0.5` held on the FIRST bake after every scene load, undo and plugin reload, for every
## road brush on the layer, and each redundant refresh ran `_refresh_owner` over the whole shared layer.
## N roads meant N full-layer re-bakes before anything had changed.
func _sc_no_spurious_first_bake_rebake() -> void:
	print("[SC] a first bake that was wide enough asks for nothing")
	var fx := _crossing_fixture()
	var brush: Pasture3DRoadBrush = fx["brushes"][0]
	var mod: Pasture3DNodeRoad = brush.modifiers[0]

	# Exactly what a bake does: capture the padding it is about to commit to, solve, then ask.
	var used_pad := brush._padding()
	mod.last_alignment = _alignment_standing_clear(90, 0.0)
	# The RETURN value, not `_full_dirty`. `_schedule_refresh` early-returns unless the editor is running,
	# so headless the flag never moves either way and both halves below would pass vacuously — which is
	# exactly what happened on the first run of this gate, and what the control caught.
	var quiet := not brush._rebake_if_corridor_outgrew(used_pad)

	# The other half: it must still fire when the corridor really did outgrow the bake, or "asks for
	# nothing" is passed by a function that asks for nothing ever.
	mod.last_alignment = _alignment_standing_clear(90, 18.0)
	var fired := brush._rebake_if_corridor_outgrew(used_pad)

	_check("[SC]", quiet, "a road already wide enough scheduled no re-bake")
	_check("[SC] control", fired, "a road that outgrew its bake still scheduled one")
	fx["terrain"].queue_free()


# ---- [SF] --------------------------------------------------------------------------------------

## The signature repeats when nothing is edited.
##
## The reason `_padding()` is quantised. It derives from the worst offset the last bake produced, which
## wobbles in the last decimal place across otherwise identical bakes; a raw float in a hash key means
## every bake mints a new key, the cache never hits, and S1 would have bought correctness by making the
## most expensive brush on the layer permanently uncacheable.
func _sf_signature_is_stable_with_no_edit() -> void:
	print("[SF] the signature repeats when nothing changed")
	var fx := _crossing_fixture()
	var brush: Pasture3DRoadBrush = fx["brushes"][0]
	var path: Path3D = brush.get_child(0)
	var mod: Pasture3DNodeRoad = brush.modifiers[0]

	mod.last_alignment = _alignment_standing_clear(90, 12.0)
	var key_a := brush._compute_stamp_key(path)
	# The same road, re-solved with a depth differing by far less than the quantum — the float wobble a
	# real re-bake produces.
	mod.last_alignment = _alignment_standing_clear(90, 12.0 + 0.011)
	var key_b := brush._compute_stamp_key(path)
	# And a depth differing by MORE than the quantum, which must still be seen.
	mod.last_alignment = _alignment_standing_clear(90, 12.0 + 4.0)
	var key_c := brush._compute_stamp_key(path)

	_check("[SF]", key_b == key_a, "wobble below the %.2f m quantum leaves the key alone"
			% Pasture3DRoadBrush.PAD_QUANTUM)
	_check("[SF] control", key_c != key_a, "a real widening past the quantum still moves it")
	fx["terrain"].queue_free()


# ---- [SG] --------------------------------------------------------------------------------------

## The brush signature and the chunk host's digest read the road type's geometry through ONE function.
##
## They stay two lists, deliberately — the mesher reads `surface_material`, which moves no terrain
## vertex, and the height bake reads the batters, which move no ribbon vertex. What they must not do is
## each maintain their own reading of the CROSS-SECTION, because that is the drift the chunk host's own
## digest already had to be rescued from once (R4).
func _sg_chunk_host_shares_the_road_type_reading() -> void:
	print("[SG] one reading of the road type's cross-section")
	var t := Pasture3DRoadType.new()
	t.lane_count = 2
	t.lane_width = 3.5
	t.cut_batter = 1.0
	var before_sig := t.grading_signature()
	var before_half := t.half_width(2)

	t.lane_width = 7.0
	var widened_sig := t.grading_signature()
	var widened_half := t.half_width(2)

	# A batter edit moves the terrain corridor and NOT the ribbon: the brush term must see it, the
	# mesher's `half_width` must not. That asymmetry is the reason the two lists exist.
	t.lane_width = 3.5
	t.cut_batter = 0.25
	var batter_sig := t.grading_signature()
	var batter_half := t.half_width(2)

	_check("[SG]", hash(widened_sig) != hash(before_sig)
			and not is_equal_approx(widened_half, before_half),
			"a lane_width edit moves both readings (%.2f -> %.2f m half width)"
			% [before_half, widened_half])
	_check("[SG] control", hash(batter_sig) != hash(before_sig)
			and is_equal_approx(batter_half, before_half),
			"a cut_batter edit moves the grade signature and leaves the mesher's half width at %.2f m"
			% batter_half)
