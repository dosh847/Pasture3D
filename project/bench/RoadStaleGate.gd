# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadStaleGate — road content that the terrain never hears about.
# PASTURE3D_ROAD_STALENESS_AND_COST_SPEC.md §3, S1 ([SA] [SB] [SC] [SF] [SG]), S2 ([SD]), S3 ([SE]) and S4 ([SH]).
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

## A road brush that counts the re-bakes it asks for.
##
## `_schedule_refresh` gates on `_can_auto_refresh()`, which requires `Engine.is_editor_hint()` — false
## headless — so watching `_full_dirty` would see nothing whichever way the wiring behaved, and [SD]
## would pass on the unwired code it exists to catch. See [[SC]] above, which was caught doing exactly
## that. Counting the CALL observes the decision; `super()` keeps the real behaviour underneath.
class CountingRoadBrush extends Pasture3DRoadBrush:
	var refreshes: int = 0

	func _schedule_refresh() -> void:
		refreshes += 1
		super()


## Where the fixtures' terrains keep their regions.
##
## OUTSIDE THE REPO, deliberately. A Pasture3D with no `data_directory` set falls back to the demo's, so
## a fixture that calls `add_region_blank` writes a blank region into `project/demo/data/SimplePasture`
## and the on-quit save then rewrites — and on some runs deletes — the demo's real region files. This gate
## did exactly that on its first runs. `user://` is per-machine scratch that no commit can pick up.
const SCRATCH_DATA := "user://road_stale_gate"

var _fail: int = 0


func _ready() -> void:
	print("=== RoadStaleGate: road content the terrain never hears about (S1-S4) ===\n")
	_sa_junction_pins_reach_the_key()
	_sb_corridor_widening_converges()
	_sc_no_spurious_first_bake_rebake()
	_sd_every_edit_schedules_a_bake()
	_se_cross_section_edits_reach_the_graph()
	_sf_signature_is_stable_with_no_edit()
	_sg_chunk_host_shares_the_road_type_reading()
	_sh_closed_roads_actually_close()
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
	terrain.data_directory = SCRATCH_DATA
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
		var brush := CountingRoadBrush.new()
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
	var brush: CountingRoadBrush = fx["brushes"][1]
	var path: Path3D = brush.get_child(0)

	var before_sig := brush.road_content_signature()
	var before_key := brush._compute_stamp_key(path)
	var before_digest := brush.junction_digest()

	# Both roads need a solved alignment before they are detectable as crossing.
	for b: CountingRoadBrush in fx["brushes"]:
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
	var brush: CountingRoadBrush = fx["brushes"][0]
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
	var brush: CountingRoadBrush = fx["brushes"][0]
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

# ---- [SD] --------------------------------------------------------------------------------------

## A road brush under a group under a network, so all four levels of the resolve chain (§5.3) exist.
##
## `_crossing_fixture` parents its brushes straight under the network, which is legal and is the case
## [SA] and [SB] want. [SD] needs the group level too, because a group's defaults reach a brush through
## a DIFFERENT connection than the network's and wiring one is not wiring the other.
func _chained_fixture() -> Dictionary:
	var terrain := Pasture3D.new()
	terrain.region_size = 256
	terrain.vertex_spacing = 1.0
	terrain.data_directory = SCRATCH_DATA
	add_child(terrain)
	terrain.data.add_region_blank(Vector2i(0, 0))
	terrain.data.ensure_layer_stack()

	var net := Pasture3DRoadNetwork.new()
	terrain.add_child(net)
	var t := Pasture3DRoadType.new()
	t.type_name = "chained"
	t.lane_count = 2
	t.lane_width = 3.5
	net.road_types = [t]

	var grp := Pasture3DRoadGroup.new()
	net.add_child(grp)

	var brush := CountingRoadBrush.new()
	brush.name = "Chained"
	grp.add_child(brush)
	brush.terrain = terrain
	brush.snap_to_surface = false
	brush.road_road_type = t

	var path := Path3D.new()
	var curve := Curve3D.new()
	curve.add_point(Vector3(40.0, 0.0, 128.0))
	curve.add_point(Vector3(200.0, 0.0, 128.0))
	path.curve = curve
	brush.add_child(path)

	var seg := Pasture3DRoadSegment.new()
	seg.from_distance = 20.0
	seg.to_distance = 60.0
	brush.segments = [seg]

	var road_mod := Pasture3DNodeRoad.new()
	road_mod.alignment_step = 2.0
	brush.modifiers = [road_mod]
	return {"terrain": terrain, "net": net, "group": grp, "brush": brush, "type": t, "segment": seg}


## Each of the five levels that can change a resolved value schedules exactly one bake.
##
## ---- WHY FIVE SEPARATE ASSERTIONS AND NOT ONE LOOP ----
##
## A single combined criterion passes when four of the five are wired and one is not, which is exactly
## the state the code was in: `road_defaults` and `segments` connected at their setters and reached
## `_on_road_changed`, which incremented a counter nobody read. The group and the network incremented
## counters of their own that reached no child at all, and nothing anywhere connected to
## `Pasture3DRoadType.changed` — so editing `lane_width` on the type resource re-baked nothing, on any
## brush using it. Naming the five is what makes a partial wiring fail loudly.
##
## ---- WHY EXACTLY ONE, NOT AT LEAST ONE ----
##
## The brush attaches to its group AND its network AND its road type. If any two of those paths carried
## the same edit, one property change would schedule two full-layer bakes, and on a shared layer that is
## the whole cost of the edit paid twice. `== 1` is what refuses a double-wire; `>= 1` would not notice.
func _sd_every_edit_schedules_a_bake() -> void:
	print("[SD] every level of the resolve chain schedules a bake")
	var fx := _chained_fixture()
	var brush: CountingRoadBrush = fx["brush"]
	var grp: Pasture3DRoadGroup = fx["group"]
	var net: Pasture3DRoadNetwork = fx["net"]
	var t: Pasture3DRoadType = fx["type"]
	var seg: Pasture3DRoadSegment = fx["segment"]

	var edits: Array = [
		["brush override", func() -> void: brush.road_lane_count = 6],
		["segment", func() -> void: seg.is_bridge = true],
		["group defaults", func() -> void: grp.road_defaults.lane_count = 4],
		["network defaults", func() -> void: net.road_defaults.speed_limit = 22.0],
		["road type", func() -> void: t.lane_width = 7.0],
	]
	for e in edits:
		brush.refreshes = 0
		(e[1] as Callable).call()
		_check("[SD] %s" % e[0], brush.refreshes == 1,
				"scheduled %d bake(s)" % brush.refreshes)

	# The control. An edit to a road type this brush does NOT resolve must reach it zero times, or [SD]
	# is passed by a brush that re-bakes on every resource in the scene — which is not wiring, it is a
	# broadcast, and on a shared layer it costs more than the bug did.
	var other := Pasture3DRoadType.new()
	other.type_name = "unrelated"
	brush.refreshes = 0
	other.lane_width = 9.0
	_check("[SD] control", brush.refreshes == 0,
			"an unrelated road type scheduled %d bake(s)" % brush.refreshes)

	# And the re-wire: switching to that type must move the brush's attention to it. Without this, a
	# brush keeps listening to the type it no longer uses and stops hearing the one it does — the failure
	# the group and network connections cannot have, because those are found by walking parents.
	net.road_types = [t, other]
	brush.road_road_type = other
	brush.refreshes = 0
	other.lane_width = 11.0
	var followed := brush.refreshes
	brush.refreshes = 0
	t.lane_width = 3.5
	var let_go := brush.refreshes
	_check("[SD] rewire", followed == 1 and let_go == 0,
			"after switching types the brush follows the new one (%d) and drops the old (%d)"
			% [followed, let_go])
	fx["terrain"].queue_free()
# ---- [SE] --------------------------------------------------------------------------------------

## A cross-section edit reaches the graph, and an identical re-resolve still does not.
##
## ---- THE TWO HALVES ARE IN TENSION, WHICH IS WHY THEY ARE ONE CRITERION ----
##
## `Pasture3DRoadNetwork._assign` compared `points`, `half_widths` and `heights` — three of the thirteen
## fields a `Pasture3DGraphPath` carries. A cross-section edit changes none of them: crown and the batters
## are not geometry, and `sample_suppress` / `sample_skip` do not move the solved profile. So the rebuilt
## path was discarded and the Road Grade node kept grading to the old cross-section while the brush's own
## grading step used the new one — two roads, differing by centimetres in the corners, from one spline.
##
## But the narrowness was an OVER-correction, not an oversight, and "assign always" is not the fix.
## Assigning unconditionally emits `changed`, bumps the node's revision and re-solves every downstream
## erosion from scratch on every bake; `RoadGraphGate [G]` exists to refuse that. So the control here is
## not a broken variant of the scenario — it is the OPPOSITE property, restated inside this criterion so
## that a future "fix" cannot satisfy [SE] by throwing [G] away.
func _se_cross_section_edits_reach_the_graph() -> void:
	print("[SE] a cross-section edit reaches the graph, an identical rebuild does not")

	# Two paths built from the same road, differing in ONE cross-section field at a time. Built directly
	# rather than through a resolve: `_assign`'s decision is a function of the two paths, and driving a
	# whole network to produce them would test the resolve loop instead of the comparison.
	var base := _sample_path()
	var same := _sample_path()
	_check("[SE] identical", base.content_digest() == same.content_digest(),
			"two paths built from the same road compare equal, so [G]'s cache survives")

	var cases: Array = [
		["crown", func(p: Pasture3DGraphPath) -> void: p.crown = 0.09],
		["cut_batter", func(p: Pasture3DGraphPath) -> void: p.cut_batter = 2.0],
		["fill_batter", func(p: Pasture3DGraphPath) -> void: p.fill_batter = 0.3],
		["verges", func(p: Pasture3DGraphPath) -> void: p.sample_verges = _filled(8, 6.0)],
		["shoulders", func(p: Pasture3DGraphPath) -> void: p.sample_shoulders = _filled(8, 1.5)],
		["suppress (bridge)", func(p: Pasture3DGraphPath) -> void:
				var b := PackedByteArray(); b.resize(8); b[4] = 1; p.sample_suppress = b],
		["skip (junction)", func(p: Pasture3DGraphPath) -> void:
				var b := PackedByteArray(); b.resize(8); b[2] = 1; p.sample_skip = b],
		["alignment", func(p: Pasture3DGraphPath) -> void:
				p.alignment = _alignment_standing_clear(8, 5.0)],
	]
	for c in cases:
		var edited := _sample_path()
		(c[1] as Callable).call(edited)
		_check("[SE] %s" % c[0], edited.content_digest() != base.content_digest(),
				"the rebuilt path is seen as different, so Road Grade is handed it")

	# The control. `source_label` is a name for the inspector and no query reads it, so it must NOT count
	# as a change — a digest that moved on it would re-solve every downstream erosion over a rename, which
	# is [G]'s failure rather than [SE]'s.
	var relabelled := _sample_path()
	relabelled.source_label = "renamed in the inspector"
	_check("[SE] control", relabelled.content_digest() == base.content_digest(),
			"a field no query reads does not invalidate anything downstream")


## A path with every field a Road Grade node reads, populated and non-degenerate.
##
## Non-degenerate matters: arrays left empty would hash equal to each other no matter which one an edit
## touched, and half the cases above would pass without the digest covering anything.
func _sample_path() -> Pasture3DGraphPath:
	var p := Pasture3DGraphPath.new()
	var pts := PackedVector2Array()
	for i in 8:
		pts.append(Vector2(float(i) * 10.0, 0.0))
	p.points = pts
	p.half_widths = _filled(8, 4.0)
	p.heights = _filled(8, 2.0)
	p.sample_half_widths = _filled(8, 4.0)
	p.sample_shoulders = _filled(8, 0.5)
	p.sample_verges = _filled(8, 4.0)
	p.sample_suppress = PackedByteArray()
	p.sample_suppress.resize(8)
	p.sample_skip = PackedByteArray()
	p.sample_skip.resize(8)
	p.alignment = _alignment_standing_clear(8, 0.0)
	return p


func _filled(p_n: int, p_v: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(p_n)
	a.fill(p_v)
	return a

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
	var brush: CountingRoadBrush = fx["brushes"][0]
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


# ---- [SH] --------------------------------------------------------------------------------------

## Ticking `closed` closes the road, not only the gizmo.
##
## ---- WHY ASSERTING THE FLAG WOULD PROVE NOTHING ----
##
## `_is_closed()` returned `closed` correctly the whole time the bug existed. The flag was never the
## broken part: `_new_spline` wrote `curve.closed` at CREATION, when `closed` was still false, and the
## setter never revisited it — so the gizmo, which reads the brush flag directly, drew a ring while the
## grader, the mesher, the arc-length space, the junction detector and the graph path all saw a horseshoe.
## A criterion that read `brush._is_closed()` would have passed throughout. So this reads the three things
## that were actually wrong: the curve, the plan, and the path handed to the graph.
##
## ---- THE LENGTH IS THE POINT, NOT A SIDE EFFECT ----
##
## Closing lengthens the road by the seam distance, and every Pasture3DRoadSegment range, junction arc
## length and route waypoint is measured along that polyline. The criterion asserts the growth is the
## SEAM specifically — not merely that something got longer — because a plan that had been wrapped twice
## would also be longer, and would be wrong.
func _sh_closed_roads_actually_close() -> void:
	print("[SH] closing a road closes the plan, not just the gizmo")
	var fx := _ring_fixture()
	var brush: CountingRoadBrush = fx["brush"]
	var curve: Curve3D = (brush.get_child(0) as Path3D).curve

	var open_plan := brush._plan_points()
	var open_len := _polyline_length(open_plan)
	var seam := open_plan[open_plan.size() - 1].distance_to(open_plan[0])

	brush.closed = true

	var shut_plan := brush._plan_points()
	var shut_len := _polyline_length(shut_plan)

	_check("[SH] curve", curve.closed,
			"the setter wrote through to the child spline's Curve3D")
	_check("[SH] plan", shut_plan.size() > open_plan.size()
			and shut_plan[shut_plan.size() - 1].is_equal_approx(shut_plan[0]),
			"the plan now ends where it starts (%d -> %d vertices)"
			% [open_plan.size(), shut_plan.size()])
	_check("[SH] length", absf((shut_len - open_len) - seam) < 0.5,
			"arc length grew by the seam and nothing more: %.2f m + %.2f m -> %.2f m"
			% [open_len, seam, shut_len])

	# The control that a manual wrap would fail. `Curve3D.closed` already bakes the closing segment, so
	# appending points[0] on top of it — which is what Pasture3DRidge does, and what the plan for this fix
	# originally said to copy — would give the road TWO closing edges and a zero-length segment between
	# them. That doubles the seam in the length above and leaves a degenerate segment for the grader.
	var dup := 0
	for i in range(1, shut_plan.size()):
		if shut_plan[i].is_equal_approx(shut_plan[i - 1]):
			dup += 1
	_check("[SH] no double wrap", dup == 0,
			"%d zero-length segment(s) in the closed plan" % dup)

	# And the graph's view. The plan already ends at its start, so the resource must carry the seam as the
	# FLAG with the duplicate vertex dropped — closing it a second time would repeat points[0] again.
	brush.modifiers[0].last_alignment = _alignment_standing_clear(shut_plan.size(), 0.0)
	var gp := brush.graph_path()
	if gp.points.size() < 2:
		_check("[SH] graph", false, "the road built no graph path to check")
	else:
		var tail_dup: bool = gp.points[gp.points.size() - 1].is_equal_approx(gp.points[0])
		_check("[SH] graph", gp.closed and not tail_dup
				and gp.half_widths.size() == gp.points.size(),
				"the graph path carries the seam as a flag, not a repeated vertex "
				+ "(closed=%s, %d points, %d half widths)"
				% [str(gp.closed), gp.points.size(), gp.half_widths.size()])

	# Untick: all of it reverts, or "closing works" is passed by a road that was always closed.
	brush.closed = false
	_check("[SH] control", not curve.closed
			and brush._plan_points().size() == open_plan.size(),
			"unticking reopens the curve and the plan")
	fx["terrain"].queue_free()


## Three sides of a square, so the seam is a long, unambiguous distance and the open plan is plainly not
## a ring. A nearly-closed shape would make [SH] length pass on a fixture that was already closed.
func _ring_fixture() -> Dictionary:
	var terrain := Pasture3D.new()
	terrain.region_size = 256
	terrain.vertex_spacing = 1.0
	terrain.data_directory = SCRATCH_DATA
	add_child(terrain)
	terrain.data.add_region_blank(Vector2i(0, 0))
	terrain.data.ensure_layer_stack()

	var net := Pasture3DRoadNetwork.new()
	terrain.add_child(net)
	var t := Pasture3DRoadType.new()
	t.type_name = "ring"
	t.lane_count = 2
	t.lane_width = 3.5
	net.road_types = [t]

	var brush := CountingRoadBrush.new()
	brush.name = "Ring"
	net.add_child(brush)
	brush.terrain = terrain
	brush.snap_to_surface = false
	brush.road_road_type = t

	var path := Path3D.new()
	var curve := Curve3D.new()
	curve.add_point(Vector3(60.0, 0.0, 60.0))
	curve.add_point(Vector3(180.0, 0.0, 60.0))
	curve.add_point(Vector3(180.0, 0.0, 180.0))
	curve.add_point(Vector3(60.0, 0.0, 180.0))
	path.curve = curve
	brush.add_child(path)

	var road_mod := Pasture3DNodeRoad.new()
	road_mod.alignment_step = 4.0
	brush.modifiers = [road_mod]
	return {"terrain": terrain, "net": net, "brush": brush}


func _polyline_length(p_pts: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(1, p_pts.size()):
		total += p_pts[i].distance_to(p_pts[i - 1])
	return total
