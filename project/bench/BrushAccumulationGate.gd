# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# BrushAccumulationGate — brushes must not gain height when the ground under them moves (2026-09-15).
#
# The symptom: mounds "accumulating height" when roads or other layers changed, until an explicit Bake. Every
# criterion moves the ground on a layer BELOW the brush and asks whether the brush follows it.
#
#   [S] a relative Mound's cached stamp is re-keyed by the ground below; control: `stamp_key_ignores_below`
#       replays the old absolute heights and the mound sits the ground's rise lower than it should
#   [E] a stale FROZEN erosion cache is served as its change carried onto today's ground, on both rasterisers;
#       control: `stale_cache_pins_absolute` serves the old heights
#   [G] the same for a FROZEN graph (the default Input -> Output filter), on both rasterisers; same control
#   [L] a row deleted below a brush leaves its cached `_layer_id` pointing at its own row; the snap still reads
#       the ground below the brush's real row; control: `seat_trusts_cached_layer_id` climbs onto its own height
#   [R] after a reload (`_layer_id` = -1) the snap reads below the brush's row, not the full composite; same control
#   [F] `_terrain_fields` with `_layer_id` = -1 describes the ground below, not the brush's own top; same control
#   [C] a CLIPPED bake writes nothing outside its clip (2026-09-20). The batched tile-at-a-time write is
#       selected by `!composite`, which is exactly the dirty-rect bake -- the only caller that sets a clip
#       at all -- and it used to ignore it, so a brush stamped its whole grid while the rect path had
#       cleared only the box. NEEDS A FIELD STEP: without one `pre_clip` keeps the pre-pass inside the box
#       and the buffer is still NaN outside, so the write has nothing to leak. Controls: the same bake must
#       move the ground INSIDE the clip, and an unclipped bake must move BOTH probes.
#   [O] repeated RECT bakes of one of two OVERLAPPING layer-mates leave the shared cells where they were.
#       The rect path clears its box and repaints every mate intersecting it, so a mate that is repainted
#       without that cell having been cleared adds its stamp again on every bake.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/BrushAccumulationGate.tscn
extends Node

const CRITERIA := 10
const GROUND_OWNER := "gate:ground"
const RISE := 4.0
var RS := 64

var _fail := 0
var _ran := 0
var _terrain: Pasture3D


func _ready() -> void:
	print("=== BrushAccumulationGate ===")
	_terrain = Pasture3D.new()
	_terrain.name = "Terrain"
	_terrain.vertex_spacing = 1.0
	_terrain.region_size = RS
	add_child(_terrain)
	_terrain.data.add_region_blankp(Vector3.ZERO)
	_terrain.data.ensure_layer_stack()
	RS = _terrain.region_size
	# The movable ground: an ADD layer created first, so every brush row lands above it.
	_terrain.data.create_owned_layer_typed(GROUND_OWNER, "Ground", 1, Pasture3DTerrainBrush.PASTURE_3D_MAPTYPE_HEIGHT)
	for f in [_s, _e, _g, _l, _r, _f, _o, _c]:
		await f.call()
	if _ran != CRITERIA:
		_check("completed", false, "%d of %d criteria ran" % [_ran, CRITERIA])
	print("=== BRUSH ACCUMULATION %s (%d failures) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


func _settle() -> void:
	for i in range(3):
		await get_tree().process_frame


func _row(p_owner: String) -> int:
	return _terrain.data.get_layer_stack().find_layer_by_owner(p_owner)


func _set_ground(p_h: float) -> void:
	var patch := PackedFloat32Array()
	patch.resize(RS * RS)
	patch.fill(p_h)
	_terrain.data.stamp_grid(_row(GROUND_OWNER), patch, 0.0, 0.0, 1.0, RS, RS, 0)
	_terrain.data.composite_region(Vector2i.ZERO, Rect2i(), false)


func _mound(p_name: String, cx: float, cz: float, h: float) -> Pasture3DMound:
	var m := Pasture3DMound.new()
	m.name = p_name
	m.terrain = _terrain
	m.auto_refresh = false
	m.height = 3.0
	m.relative_to_terrain = true
	var path := Path3D.new()
	path.name = "Area"
	var c := Curve3D.new()
	for p in [Vector3(cx - h, 0, cz - h), Vector3(cx + h, 0, cz - h), Vector3(cx + h, 0, cz + h), Vector3(cx - h, 0, cz + h)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	m.add_child(path)
	_terrain.add_child(m)
	return m


func _bake(m: Pasture3DTerrainBrush) -> void:
	m._refresh_owner(m._layer_owner, false, [])


func _drop(p_nodes: Array) -> void:
	for n in p_nodes:
		if is_instance_valid(n):
			var r := _row(n._layer_owner)
			if r > 0:
				_terrain.data.layer_remove(r)
			n.free()
	_set_ground(0.0)


## Height of the mound above the ground at its centre, after the ground was set to 0, baked, raised by RISE and
## baked again. Equal to the first bake's when the brush followed the ground; RISE lower when it was pinned.
func _follow(m: Pasture3DTerrainBrush, c: Vector3, p_clear: Callable) -> Array:
	p_clear.call()
	_set_ground(0.0)
	_bake(m)
	var r0: float = _terrain.data.get_height(c)
	# Only the scheduled refresh clears these; without it a headless bake never reaches the stamp cache.
	m._dirty_splines = {}
	_set_ground(RISE)
	_bake(m)
	var r1: float = _terrain.data.get_height(c) - RISE
	return [r0, r1]


## [O] Overlap idempotence on the RECT path. Two mates on one layer, footprints crossing; re-bake ONE of
## them repeatedly with nothing moved. The shared cells must sit where the first bake put them.
##
## Every other criterion here moves the ground and asks whether a brush follows it. This one holds
## everything still and asks whether a bake is a function of the scene rather than of how many times it
## has run. The rect path clears its box and then repaints every mate whose footprint intersects that box,
## so the two sets have to agree: a cell repainted without having been cleared takes a second copy of the
## stamp, and the overlap climbs once per bake while each mound alone stays put.
##
## The single-mound arm is the control. If it climbs too, the fault is the clear box, not the overlap, and
## this criterion is measuring the wrong thing.
func _o() -> void:
	# A Layer brush with a Stage 1 modifier, the configuration the report came from: the rect clear skips
	# the `#base` row by design, and the base solve contributes a `base_change` box of its own.
	var lb := Pasture3DLayerBrush.new()
	lb.name = "OverlapLayer"
	lb.terrain = _terrain
	lb.auto_refresh = false
	var fn := FastNoiseLite.new()
	fn.seed = 7
	fn.frequency = 0.08
	var nz := Pasture3DNodeNoise.new()
	nz.noise = fn
	nz.strength = 4.0
	var mods: Array[Pasture3DNode] = [nz]
	lb.modifiers = mods
	_terrain.add_child(lb)
	var a := _mound("OverlapA", 24.0, 32.0, 8.0)
	var b := _mound("OverlapB", 36.0, 32.0, 8.0)
	for m in [a, b]:
		_terrain.remove_child(m)
		lb.add_child(m)
	lb.adopt_members()
	_set_ground(0.0)
	lb.bake_base()
	_bake(a)
	_bake(b)
	await _settle()
	var shared := Vector3(30.0, 0.0, 32.0)   # inside both footprints
	var solo := Vector3(20.0, 0.0, 32.0)     # inside A only
	var h_shared0: float = _terrain.data.get_height(shared)
	var h_solo0: float = _terrain.data.get_height(solo)
	var sid: int = a._get_splines()[0].get_instance_id()
	var trail := PackedStringArray()
	# Drag A across B and back to exactly where it started, the way the report's trace does (a gizmo
	# drag, then a commit). A bake is a function of the scene, so a round trip must leave no trace.
	var pa: Path3D = a._get_splines()[0]
	var home := pa.position
	for i in range(4):
		for step in [Vector3(6.0, 0.0, 0.0), home]:
			pa.position = step
			a._update_curve_cache_dirty(pa) if a.has_method("_update_curve_cache_dirty") else null
			a._dirty_splines = {sid: true}
			a._refresh_owner_rect(a._layer_owner, {sid: true}, true)
			await _settle()
		trail.append("%.3f" % (_terrain.data.get_height(shared) - h_shared0))
	var d_shared: float = _terrain.data.get_height(shared) - h_shared0
	var d_solo: float = _terrain.data.get_height(solo) - h_solo0
	_check("O overlap idempotence", absf(d_shared) < 0.01,
			"4 rect bakes, nothing moved: shared cell moved %.4f m (want 0) [%s], first bake %.3f m"
			% [d_shared, ", ".join(trail), h_shared0])
	_check("O control (no overlap)", absf(d_solo) < 0.01,
			"the same bakes moved A's own cell %.4f m — if this climbs too the clear box is at fault, not the overlap" % d_solo)
	_ran += 1
	_drop([a, b])
	var br := _row(lb.layer_owner_id())
	if br > 0:
		_terrain.data.layer_remove(br)
	lb.free()


## A clip says WHERE, so a bake that honours it inside the box and not outside has not honoured it.
##
## Driven by `slope_angle`, not `height`: this mound's flanks are slope-driven and `height` moves nothing,
## so a fixture that varies it compares a shape with itself and passes on any build.
##
## The SMOOTH modifier is load-bearing. It is a field step, and a field step is what turns `pre_clip` off so
## the pre-pass computes cells outside the clip at all. Without it the buffer is still NaN out there and the
## unclipped write leaks nothing -- the criterion then passes on a deliberately broken build, which is how
## the first four versions of it fooled me.
func _c() -> void:
	var m := _mound("Clipped", 32, 32, 14)
	m.snap_to_surface = false
	m.slope_angle = 30.0
	var sm := Pasture3DNodeSmooth.new()
	sm.passes = 2
	var mods: Array[Pasture3DNode] = [sm]
	m.modifiers = mods
	_set_ground(0.0)
	var p_in := Vector3(26, 0, 32)
	var p_out := Vector3(40, 0, 32)
	var all := AABB(Vector3(-4, -1000, -4), Vector3(RS + 8, 2000, RS + 8))
	_bake(m)
	await _settle()
	_terrain.data.composite_area(all, false)
	var a_in: float = _terrain.data.get_height(p_in)
	var a_out: float = _terrain.data.get_height(p_out)
	# The shape the second bake writes, measured UNCLIPPED first. Both probes must move, or the clipped bake
	# below has nothing to leak and the criterion is vacuous whichever way it reads.
	m.slope_angle = 55.0
	m.clear_stamp_cache()
	m._dirty_splines = {}
	_bake(m)
	await _settle()
	_terrain.data.composite_area(all, false)
	var b_in: float = _terrain.data.get_height(p_in)
	var b_out: float = _terrain.data.get_height(p_out)
	# Back to the first shape, then repaint the second one through a clip that covers p_in and not p_out.
	m.slope_angle = 30.0
	m.clear_stamp_cache()
	_bake(m)
	await _settle()
	var lid := _row(m._layer_owner)
	m.slope_angle = 55.0
	m.clear_stamp_cache()
	m._layer_id = lid
	m._clip_aabb = AABB(Vector3(10, -1000, 10), Vector3(22, 2000, 44)) # x[10..32]: p_in inside, p_out outside
	m._defer_composite = true # `!composite` is what selects the batched write
	m._paint_into(lid, m._get_blend_mode())
	m._defer_composite = false
	m._clip_aabb = AABB()
	_terrain.data.composite_area(all, false)
	await _settle()
	var c_in: float = _terrain.data.get_height(p_in)
	var c_out: float = _terrain.data.get_height(p_out)
	_check("C clipped bake stays in its box", absf(c_out - a_out) < 0.01,
			"outside the clip: %.4f m, was %.4f m before the bake and %.4f m when the same bake ran unclipped" % [c_out, a_out, b_out])
	_check("C control (inside the clip)", absf(c_in - b_in) < 0.01 and absf(b_in - a_in) > 0.01,
			"inside the clip: %.4f m, and the unclipped bake put it at %.4f m (from %.4f m) -- if these disagree the clipped bake painted nothing" % [c_in, b_in, a_in])
	_check("C control (the shape really changes)", absf(b_out - a_out) > 0.01,
			"unclipped, the second shape moved the outside probe %.4f m -- if this is 0 nothing could leak and the criterion above is vacuous" % (b_out - a_out))
	_ran += 3
	_drop([m])
	await _settle()


func _s() -> void:
	var m := _mound("Stamp", 32, 32, 8)
	# Only the GDScript route stores a stamp (mound.gd returns from the native branch before it).
	m.force_gdscript_raster = true
	# REPLACE: the stamp holds basey + amplitude, absolute heights. Under ADD it holds a delta that rides the ground.
	m.blend_mode = Pasture3DTerrainBrush.BLEND_REPLACE
	# Snap off: a snapping loop re-seats onto the risen ground, its curve changes and the key misses anyway.
	m.snap_to_surface = false
	await _settle()
	var c := Vector3(32, 0, 32)
	var clear := func(): m.clear_stamp_cache()
	var ok := _follow(m, c, clear)
	m.stamp_key_ignores_below = true
	var ctl := _follow(m, c, clear)
	m.stamp_key_ignores_below = false
	_check("S stamp follows", ok[0] > 1.0 and absf(ok[1] - ok[0]) < 0.01,
			"mound %.3f m above the ground, after a %.0f m rise %.3f m" % [ok[0], RISE, ok[1]])
	_check("S control", absf(ctl[1] - ctl[0] + RISE) < 0.01,
			"key without the ground: %.3f m -> %.3f m (pinned)" % [ctl[0], ctl[1]])
	_drop([m])
	await _settle()
	_ran += 1


## [E] and [G] share this: one FROZEN field modifier, both rasterisers, rebased vs pinned.
func _frozen(p_label: String, p_mod: Pasture3DNode) -> void:
	var m := _mound(p_label, 32, 32, 16)
	var mods: Array[Pasture3DNode] = [p_mod]
	m.modifiers = mods
	await _settle()
	var c := Vector3(32, 0, 32)
	var clear := func():
		m.clear_stamp_cache()
		p_mod.clear_cache()
	for gd in [false, true]:
		m.force_gdscript_raster = gd
		var route := "gdscript" if gd else "native"
		var ok := _follow(m, c, clear)
		var stale: bool = p_mod._stale if "_stale" in p_mod else true
		m.stale_cache_pins_absolute = true
		var ctl := _follow(m, c, clear)
		m.stale_cache_pins_absolute = false
		_check("%s %s follows" % [p_label, route], ok[0] > 1.0 and absf(ok[1] - ok[0]) < 0.05 and stale,
				"%.3f m above the ground, after the rise %.3f m, served stale %s" % [ok[0], ok[1], stale])
		_check("%s %s control" % [p_label, route], ctl[0] - ctl[1] > RISE * 0.75,
				"pinned: %.3f m -> %.3f m" % [ctl[0], ctl[1]])
	m.force_gdscript_raster = false
	_drop([m])
	await _settle()


func _e() -> void:
	var ero := Pasture3DNodeErosion.new()
	ero.iterations = 5
	ero.erosion_rate = 0.05
	ero.evaluation = Pasture3DNode.Evaluation.FROZEN
	await _frozen("E", ero)
	_ran += 1


func _g() -> void:
	var mod := Pasture3DNodeGraph.new()
	mod.graph = Pasture3DTerrainGraph.create_default()
	mod.evaluation = Pasture3DNode.Evaluation.FROZEN
	await _frozen("G", mod)
	_ran += 1


## Two baked mounds, A's row below B's. Returns [a, b].
func _pair() -> Array:
	var a := _mound("LowerA", 16, 16, 6)
	var b := _mound("UpperB", 48, 48, 6)
	# Every Mound shares the "Mounds" owner by default; two rows are what a delete below needs.
	a._layer_owner = "gate:lowerA"
	b._layer_owner = "gate:upperB"
	_set_ground(0.0)
	_bake(a)
	_bake(b)
	return [a, b]


## Seat B's centre both ways; [fixed error, control climb] against the ground below B's real row.
func _seat(b: Pasture3DMound) -> Array:
	var p := Vector3(48, 0, 48)
	var truth: float = _terrain.data.get_height_below(_row(b._layer_owner), p)
	var y: float = b.editor_seat_on_surface(p, true).y - b.surface_offset
	b.seat_trusts_cached_layer_id = true
	var yc: float = b.editor_seat_on_surface(p, true).y - b.surface_offset
	b.seat_trusts_cached_layer_id = false
	return [absf(y - truth), yc - truth]


func _l() -> void:
	var ab := _pair()
	await _settle()
	var a: Pasture3DMound = ab[0]
	var b: Pasture3DMound = ab[1]
	var before: int = b._layer_id
	_terrain.data.layer_remove(_row(a._layer_owner))
	var now := _row(b._layer_owner)
	var r := _seat(b)
	_check("L row delete", before != now and r[0] < 0.01,
			"cached row %d, real row %d, seat off the ground below by %.4f m" % [before, now, r[0]])
	_check("L control", r[1] > 2.0, "trusting the cached row climbs %.3f m" % r[1])
	a.free()
	_drop([b])
	await _settle()
	_ran += 1


func _r() -> void:
	var ab := _pair()
	await _settle()
	var b: Pasture3DMound = ab[1]
	b._layer_id = -1
	var r := _seat(b)
	_check("R reload", r[0] < 0.01, "a brush that has not baked seats %.4f m off the ground below" % r[0])
	_check("R control", r[1] > 2.0, "the full composite climbs %.3f m" % r[1])
	_drop(ab)
	await _settle()
	_ran += 1


func _f() -> void:
	var ab := _pair()
	await _settle()
	var b: Pasture3DMound = ab[1]
	var p := Vector3(48, 0, 48)
	var truth: float = _terrain.data.get_height_below(_row(b._layer_owner), p)
	var centre := 4 * 9 + 4
	b._layer_id = -1
	var alt: float = (b._terrain_fields(44.0, 44.0, 1.0, 9, 9)[0] as PackedFloat32Array)[centre]
	b.seat_trusts_cached_layer_id = true
	var alt_c: float = (b._terrain_fields(44.0, 44.0, 1.0, 9, 9)[0] as PackedFloat32Array)[centre]
	b.seat_trusts_cached_layer_id = false
	_check("F fields", absf(alt - truth) < 0.01, "altitude %.3f m, ground below %.3f m" % [alt, truth])
	_check("F control", alt_c - truth > 2.0, "stale row reads %.3f m, its own top" % alt_c)
	_drop(ab)
	await _settle()
	_ran += 1
