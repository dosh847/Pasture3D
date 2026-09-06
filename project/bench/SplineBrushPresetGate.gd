# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# SplineBrushPresetGate — Ridge and Trough as Pasture3DPlow presets (S6).
#
# ---- WHAT THIS GATE IS FOR ----
#
# PASTURE3D_SPLINE_GRAPH_SPEC.md §9 reparents Ridge and Trough onto Pasture3DPlow. They stop being
# rasterisers and become a Plow that arrives with a Pasture3DSpline child and a graph already wired:
# `Input -> Path Carve.surface -> Output`, `Spline Source -> Path Carve.path`. `stamp_ridge_line` and
# `stamp_trough_line` are deleted, and old scenes migrate through a `_set` shim.
#
# ---- WHY THIS IS A HARD THING TO GATE, AND WHAT THE CONTROLS ARE FOR ----
#
# Almost every failure mode of a preset LOOKS like success from a distance. A preset that never built
# its graph bakes the Plow's own falloff and produces a plateau, which is terrain moving. A Spline
# Source that resolves nothing hands Path Carve an empty path, and Path Carve's fail-fast passes the
# surface through — so "the ground did not explode" is not evidence the wiring works. A migration that
# silently dropped every parameter still produces a ridge, just the default one.
#
# So each criterion below carries a control that fails when the fixture stopped being a test:
#
#   [A] the crest is measured AGAINST the untouched ground beside it, and the control is a preset whose
#       Spline Source has been pointed at a key nothing answers — it must bake NOTHING, not a wall.
#   [B] the fit is measured as a signed containment of the carved line by the loop, and the control is a
#       line already well inside: auto-fit must leave it alone. Plus the agreement check the code
#       comments promise, between `polygon_signed_distance` and the rasteriser's `_signed_distance_field`.
#   [C] the undo record is measured by restoring it and comparing geometry, and the control is that the
#       record is non-empty — an empty one restores perfectly and means nothing.
#   [D] the migrated crest is compared to the LEGACY numbers, with the fixture proved non-flat and an
#       unmigrated preset proved to differ measurably. Without the second control, "the crest is at the
#       right height" would also pass if the default happened to be close.
#   [E] the duplicate must carve its OWN line, and the control is that the two lines are far apart.
#   [F] ClassDB, which cannot be fooled by a stale binary because the gate would not have loaded.
#   [G] Add Water on a Trough must build a Stream; the control is a plain Plow, which must still build a
#       Pool from the same shape of loop.
#
# ---- WHAT THIS GATE CANNOT MEASURE HEADLESS, AND SAYS SO ----
#
# `EditorUndoRedoManager` does not exist outside the editor, so [C] cannot press Ctrl+Z. What it CAN do
# is exercise the record `fit_loop_to_splines` builds and the method it registers, which is the whole of
# what the single action is made of. The gate prints that distinction rather than implying a full undo.
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D", "E", "F", "G"]

const DEMO_DATA := "res://demo/data"

## One site per criterion that bakes, spaced so no two brushes ever share ground.
const SITE_A := Vector3(180.0, 0.0, 120.0)
const SITE_A_CTRL := Vector3(420.0, 0.0, 120.0)
const SITE_D := Vector3(660.0, 0.0, 120.0)
const SITE_D_CTRL := Vector3(180.0, 0.0, 360.0)
const SITE_E := Vector3(420.0, 0.0, 360.0)

## Half-extent of a fixture's carved line, metres.
const LINE_HALF := 40.0

var _fail: int = 0
var _seen: Dictionary = {}
var _root: Node3D
var _terrain
var _vs := 1.0


func _ready() -> void:
	print("=== SplineBrushPresetGate: Ridge and Trough as Plow presets (S6) ===")
	print("    spec: PASTURE3D_SPLINE_GRAPH_SPEC.md §9, §12.2")
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DEMO_DATA
	_vs = _terrain.vertex_spacing

	_a_a_fresh_ridge_carves_without_wiring()
	_b_auto_fit_grows_and_never_shrinks()
	_c_the_fit_records_a_restorable_state()
	_d_a_migrated_ridge_keeps_its_numbers()
	_e_a_duplicate_carves_its_own_line()
	_f_the_old_kernels_are_gone()
	await _g_add_water_follows_the_child_spline()

	for name in CRITERIA:
		if not _seen.has(name):
			_fail += 1
			print("!! criterion %s never reported" % name)
	print("=== SPLINE BRUSH PRESET %s (%d failures) ===" % [
			"PASS" if _fail == 0 else "FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	if not p_ok:
		_fail += 1
	print("    %s%s: %s" % ["" if p_ok else "!! ", p_name, p_detail])


# ---- [A] a fresh preset carves, and an unwired one does not ---------------------------------------

func _a_a_fresh_ridge_carves_without_wiring() -> void:
	print("[A] a fresh Ridge bakes a raised crest along its child spline, with no wiring by hand")
	var ridge = _preset_at(Pasture3DRidge, "RidgeA", SITE_A)
	if ridge == null:
		_check("A", false, "no terrain at %s; the fixture is outside demo/data" % SITE_A)
		return
	# The graph must exist and be the shape §9.3 describes, BEFORE anything is baked. A preset that
	# baked a plausible mound out of the Plow's own falloff would otherwise pass the height test below.
	var carve = ridge.preset_carve()
	var sp = ridge._preset_spline()
	var wired := carve != null and sp != null
	_check("A", wired, "preset built itself: Path Carve %s, child Pasture3DSpline %s" % [
			"yes" if carve != null else "NO", ("'%s'" % sp.name) if sp != null else "NO"])
	if not wired:
		return
	if carve.cross_section != Pasture3DGraphNodePathCarve.CrossSection.CREST:
		_check("A", false, "the preset's Path Carve is not a CREST")

	var before := _profile(SITE_A)
	ridge._refresh_owner(ridge._layer_owner, false, [])
	var after := _profile(SITE_A)
	# ON the line versus 3 * LINE_HALF away from it, so "the whole tile rose" is not a pass.
	var on_line := after[0] - before[0]
	var off_line := absf(after[1] - before[1])
	_check("A", on_line > 1.0 and off_line < 0.05,
			"crest rose %.3f m on the line; ground %.0f m away moved %.4f m" % [
					on_line, 3.0 * LINE_HALF, off_line])

	# CONTROL: the same preset with its Spline Source pointed at a key nothing answers, set BEFORE the
	# source has ever resolved. Path Carve's fail-fast passes the surface through, so the ground must be
	# untouched -- a preset that fell back on the Plow's own mask would raise a wall the shape of the
	# loop, which is the failure this catches.
	#
	# "Before it has ever resolved" is load-bearing and is not the gate being gentle. `resolve_shapes`
	# states the policy for the whole family: a key that names nothing LEAVES the node's path alone,
	# because clearing it would flatten every terrain reading a brush mid-rename for one bake. So a
	# source that once resolved keeps its line, correctly, and pointing an already-resolved one at a bad
	# key would measure that policy rather than the fail-fast.
	var ctrl = _preset_at(Pasture3DRidge, "RidgeACtrl", SITE_A_CTRL, false, false)
	if ctrl == null:
		_check("A", false, "no terrain at the control site")
		return
	ctrl.install_preset_now()
	var mis := 0
	for m in ctrl.modifiers:
		if not (m is Pasture3DNodeGraph):
			continue
		for n in (m as Pasture3DNodeGraph).graph.nodes:
			if n is Pasture3DGraphNodeSplineSource:
				n.spline_key = "no_such_spline_key"
				mis += 1
	_check("A", mis == 1, "the control's Spline Source was misdirected before it ever resolved")
	_line_curve(ctrl)
	ctrl.ensure_area_loop()
	var c_before := _profile(SITE_A_CTRL)
	ctrl._refresh_owner(ctrl._layer_owner, false, [])
	var c_after := _profile(SITE_A_CTRL)
	var c_on := absf(c_after[0] - c_before[0])
	_check("A", c_on < 0.05,
			"CONTROL an unwired Spline Source bakes nothing: %.4f m on the line (a wall would be metres)"
					% c_on)


# ---- [B] auto-fit only ever grows ------------------------------------------------------------------

func _b_auto_fit_grows_and_never_shrinks() -> void:
	print("[B] Fit to Splines grows the loop around the carved line, and leaves a contained one alone")
	var ridge = _preset_at(Pasture3DRidge, "RidgeB", SITE_A, false)
	if ridge == null:
		_check("B", false, "no terrain at %s" % SITE_A)
		return
	# A loop deliberately far too small: a 5 m square around a 80 m line.
	var loop := _loop_curve(ridge, 5.0)
	var before_area := absf(_signed_area(ridge.loop_polygon_xz(ridge._get_splines()[0])))
	var violations_before: int = ridge.loop_fit_violations(ridge._get_splines()[0]).size()
	ridge.fit_loop_to_splines()
	var after_area := absf(_signed_area(ridge.loop_polygon_xz(ridge._get_splines()[0])))
	var violations_after: int = ridge.loop_fit_violations(ridge._get_splines()[0]).size()
	_check("B", violations_before > 0,
			"the fixture starts uncontained: %d sample(s) outside the margin" % violations_before)
	_check("B", violations_after == 0 and after_area > before_area,
			"after the fit: %d violation(s), area %.0f m² -> %.0f m²" % [
					violations_after, before_area, after_area])

	# CONTROL: a loop that already contains the line by more than the margin must not move. Without it,
	# "the loop grew" would also pass for a fit that grows unconditionally, every refresh, forever.
	var settled_area := absf(_signed_area(ridge.loop_polygon_xz(ridge._get_splines()[0])))
	var moved: bool = ridge.auto_fit_loop_now(false)
	var again_area := absf(_signed_area(ridge.loop_polygon_xz(ridge._get_splines()[0])))
	_check("B", not moved and absf(again_area - settled_area) < 1.0,
			"CONTROL a second fit on a contained line moves nothing: moved=%s, area %.0f -> %.0f m²" % [
					moved, settled_area, again_area])
	loop = loop # the curve is held by the tree; named for the reader

	# The agreement the code comments promise: `polygon_signed_distance` is the point-wise twin of the
	# rasteriser's `_signed_distance_field`, same half-open even-odd rule and the same exact edge
	# distance. Two implementations of one rule, and the loop fit trusts the cheap one.
	_b_the_two_distance_fields_agree(ridge)


## `polygon_signed_distance` against `_signed_distance_field` on the same polygon.
##
## The field is sampled at CELL CENTRES, so the point-wise call has to be made at the same places or the
## comparison is measuring the offset between two lattices. Tolerance is 1e-3 m: the field returns
## float32 and the point-wise version accumulates in double.
func _b_the_two_distance_fields_agree(p_brush) -> void:
	var poly: PackedVector2Array = p_brush.loop_polygon_xz(p_brush._get_splines()[0])
	if poly.size() < 3:
		_check("B", false, "no loop polygon to compare the two distance fields on")
		return
	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF
	for q in poly:
		min_x = minf(min_x, q.x)
		max_x = maxf(max_x, q.x)
		min_z = minf(min_z, q.y)
		max_z = maxf(max_z, q.y)
	# One cell of pad each side, so the comparison covers OUTSIDE as well as inside -- the sign is half
	# of what is being checked and a box clipped to the polygon would never test it. Samples are taken at
	# `ox + ix * vs`, which is where `_signed_distance_field` evaluates: it walks grid VERTICES, not cell
	# centres, and sampling the twin half a cell away would report half a diagonal of disagreement on
	# perfectly matching code.
	var vs := 1.0
	var ox := min_x - vs
	var oz := min_z - vs
	var gw := int(ceil((max_x - min_x) / vs)) + 2
	var gh := int(ceil((max_z - min_z) / vs)) + 2
	var res: Array = p_brush._signed_distance_field(poly, ox, oz, vs, gw, gh)
	var field: PackedFloat32Array = res[0]
	var worst := 0.0
	var sign_flips := 0
	var inside := 0
	for iz in gh:
		for ix in gw:
			var q := Vector2(ox + float(ix) * vs, oz + float(iz) * vs)
			var a: float = field[iz * gw + ix]
			var b: float = Pasture3DTerrainBrush.polygon_signed_distance(poly, q)
			worst = maxf(worst, absf(a - b))
			# A tie is not a disagreement. Both are exact rules and a sample landing ON an edge is
			# genuinely zero; the axis-aligned fixtures below put dozens of grid vertices there. Only a
			# sign difference at a distance that is unambiguously non-zero says the two rules differ.
			if (a > 0.0) != (b > 0.0) and minf(absf(a), absf(b)) > 1.0e-3:
				sign_flips += 1
			if a > 0.0:
				inside += 1
	# The guard against measuring nothing: a box entirely outside the polygon agrees perfectly and says
	# nothing about the inside rule.
	_check("B", inside > 0 and inside < gw * gh,
			"the comparison box straddles the rim: %d of %d cells inside" % [inside, gw * gh])
	_check("B", worst < 1.0e-3 and sign_flips == 0,
			"polygon_signed_distance vs _signed_distance_field over %d cells: worst %.6f m, %d sign disagreement(s)"
					% [gw * gh, worst, sign_flips])


# ---- [C] the fit records one restorable state ------------------------------------------------------

func _c_the_fit_records_a_restorable_state() -> void:
	print("[C] Fit to Splines records a state that restores the loop exactly")
	print("    (EditorUndoRedoManager does not exist headless, so what is measured is the RECORD the")
	print("     single undo action is built out of, not a Ctrl+Z)")
	var ridge = _preset_at(Pasture3DRidge, "RidgeC", SITE_A, false)
	if ridge == null:
		_check("C", false, "no terrain at %s" % SITE_A)
		return
	_loop_curve(ridge, 5.0)
	var curve: Curve3D = ridge._get_splines()[0].curve
	var before := PackedVector3Array()
	for i in curve.point_count:
		before.append(curve.get_point_position(i))

	ridge._pending_fit_undo.clear()
	var moved: bool = ridge.auto_fit_loop_now(true)
	var record: Array = ridge._pending_fit_undo
	# The control: an EMPTY record restores perfectly and proves nothing at all.
	_check("C", moved and record.size() == 1,
			"the fit moved geometry and recorded %d entry (want 1)" % record.size())
	if record.size() != 1:
		return
	var after := PackedVector3Array()
	for i in curve.point_count:
		after.append(curve.get_point_position(i))
	_check("C", not _points_match(before, after, 1.0e-4),
			"CONTROL the fit really changed the loop: %d point(s) -> %d point(s)" % [
					before.size(), after.size()])

	# The undo half of the record, through the same method the action registers.
	ridge._restore_loop_points(record[0][0], record[0][1])
	var undone := PackedVector3Array()
	for i in curve.point_count:
		undone.append(curve.get_point_position(i))
	_check("C", _points_match(before, undone, 1.0e-5),
			"restoring the recorded 'before' reproduces the original loop exactly (%d points)"
					% undone.size())
	# And the redo half, so the record is not merely a snapshot of the start.
	ridge._restore_loop_points(record[0][0], record[0][2])
	var redone := PackedVector3Array()
	for i in curve.point_count:
		redone.append(curve.get_point_position(i))
	_check("C", _points_match(after, redone, 1.0e-5),
			"restoring the recorded 'after' reproduces the fitted loop exactly")


# ---- [D] a migrated legacy Ridge keeps its numbers --------------------------------------------------

func _d_a_migrated_ridge_keeps_its_numbers() -> void:
	print("[D] an old Ridge's saved properties survive the rebuild")
	# What a scene saved by the old brush hands the new class: names it no longer declares, arriving
	# through `_set` before `_ready`. Set here in the same order and by the same route.
	const CREST := 18.0
	const WIDTH := 22.0
	var ridge = _preset_at(Pasture3DRidge, "RidgeD", SITE_D, false, false)
	if ridge == null:
		_check("D", false, "no terrain at %s" % SITE_D)
		return
	ridge.set("crest_height", CREST)
	ridge.set("width", WIDTH)
	ridge.set("slope_angle", 40.0)
	# The control that the shim is even engaged: an unknown-to-the-class name must have been PARKED, not
	# dropped on the floor. Godot silently ignores an unhandled set, so without this the whole criterion
	# could be measuring a default.
	_check("D", ridge._legacy.size() == 3,
			"the shim parked %d legacy propert(ies) (want 3)" % ridge._legacy.size())
	# The old brush's crest lived as a Path3D DIRECTLY under the Ridge, so that is where the fixture puts
	# it. Migration is what moves it onto the preset's child spline, and moving it here instead would
	# skip the step §9.5 calls the one that can silently produce a wrong-looking brush.
	_legacy_line(ridge)
	ridge.install_preset_now()
	var carve = ridge.preset_carve()
	var sp = ridge._preset_spline()
	if carve == null or sp == null:
		_check("D", false, "migration produced no preset")
		return
	_check("D", absf(carve.offset - CREST) < 1.0e-5 and absf(sp.half_width - WIDTH) < 1.0e-5,
			"crest_height %.2f -> Path Carve.offset %.2f; width %.2f -> spline half_width %.2f" % [
					CREST, carve.offset, WIDTH, sp.half_width])
	_check("D", ridge._legacy.is_empty(), "the parked values were consumed, so a second load cannot reapply them")

	# The BAKE, which is what the numbers are for. The crest must land CREST metres above the ground the
	# carve draped onto, within 0.05 m, and the flank must reach the ground within one cell of WIDTH.
	var before := _profile(SITE_D, ridge)
	var lat_before := _lateral(SITE_D)
	ridge._refresh_owner(ridge._layer_owner, false, [])
	var after := _profile(SITE_D, ridge)
	var lat_after := _lateral(SITE_D)
	# CONTROL: the fixture must not be flat. A flat site makes a draped crest and a fixed-height one the
	# same surface, and a migration that dropped `follow_path_height` would pass unnoticed.
	_check("D", absf(before[0] - before[1]) > 0.5,
			"CONTROL the site is not flat: %.2f m of relief between the two probes" % absf(before[0] - before[1]))
	var rise := after[0] - before[0]
	_check("D", absf(rise - CREST) < 0.05,
			"the migrated crest sits %.3f m above the ground it draped onto (want %.2f ± 0.05)" % [rise, CREST])

	# The flank, which is the half of the shape a height probe on the crest cannot see. `width` migrated
	# onto the child spline's `half_width`, and `width_source = PATH` is what makes Path Carve read it, so
	# the carve must stop within about a cell of WIDTH metres either side of the line.
	var reach := _reach(lat_before, lat_after)
	_check("D", absf(reach - WIDTH) <= _vs,
			"the flank reaches %.2f m from the line (want %.2f ± %.2f, one cell)" % [reach, WIDTH, _vs])

	# CONTROL: the SAME fixture with no legacy properties at all — a preset carrying only its own
	# defaults. Without it, "the crest is 18 m up and 22 m wide" would also pass if 18 and 22 were what
	# the preset ships with.
	var ctrl = _preset_at(Pasture3DRidge, "RidgeDCtrl", SITE_D_CTRL)
	if ctrl == null:
		_check("D", false, "no terrain at the control site")
		return
	var c_before := _profile(SITE_D_CTRL, ctrl)
	var c_lat_before := _lateral(SITE_D_CTRL)
	ctrl._refresh_owner(ctrl._layer_owner, false, [])
	var c_after := _profile(SITE_D_CTRL, ctrl)
	var c_rise := c_after[0] - c_before[0]
	var c_reach := _reach(c_lat_before, _lateral(SITE_D_CTRL))
	_check("D", absf(c_rise - rise) > 0.5 and absf(c_reach - reach) > _vs,
			"CONTROL an unmigrated Ridge rises %.3f m and reaches %.2f m, against %.3f m and %.2f m — the defaults are not the answer"
					% [c_rise, c_reach, rise, reach])


# ---- [E] a duplicate carves its own line -----------------------------------------------------------

func _e_a_duplicate_carves_its_own_line() -> void:
	print("[E] a duplicated Ridge carves ITS OWN child spline, not the original's")
	var a = _preset_at(Pasture3DRidge, "RidgeE", SITE_E)
	if a == null:
		_check("E", false, "no terrain at %s" % SITE_E)
		return
	var b = a.duplicate()
	b.name = "RidgeEDup"
	_root.add_child(b)
	b.terrain = _terrain
	# 200 m away, which is the CONTROL: two brushes on top of each other would agree by accident.
	b.global_position = SITE_E + Vector3(200.0, 0.0, 0.0)
	b.install_preset_now()
	var sa = a._preset_spline()
	var sb = b._preset_spline()
	if sa == null or sb == null:
		_check("E", false, "the duplicate has no preset spline")
		return
	_check("E", sa != sb and not sa._get_splines().is_empty() and not sb._get_splines().is_empty(),
			"the duplicate owns a separate Pasture3DSpline with its own Path3D")
	# What the graph actually RESOLVES, which is the question. Two brushes whose Spline Source both
	# resolved the original's line would still have separate children and still pass the test above.
	var pa := _resolved_centre(a.input_spline_polylines())
	var pb := _resolved_centre(b.input_spline_polylines())
	_check("E", pa.distance_to(pb) > 100.0,
			"each graph resolves its own host's line: centres %.1f m apart (want > 100)"
					% pa.distance_to(pb))


# ---- [F] the deleted kernels ------------------------------------------------------------------------

func _f_the_old_kernels_are_gone() -> void:
	print("[F] the old rasterisers are deleted, not merely unused")
	var methods := PackedStringArray()
	for m in ClassDB.class_get_method_list("Pasture3DData", true):
		methods.append(String(m["name"]))
	var has_ridge := methods.has("stamp_ridge_line")
	var has_trough := methods.has("stamp_trough_line")
	# CONTROL: the class must actually be there and carry the kernel the rebuild KEPT, or "the method is
	# missing" would also be true of a typo'd class name or a binary that failed to load.
	var has_carve := methods.has("stamp_plow_loop") and methods.has("stamp_mound_loop")
	_check("F", has_carve,
			"CONTROL Pasture3DData is bound and still exposes its kept kernels (%d methods)" % methods.size())
	_check("F", not has_ridge and not has_trough,
			"stamp_ridge_line present: %s; stamp_trough_line present: %s (want false, false)" % [
					has_ridge, has_trough])


# ---- [G] Add Water on a preset follows the child spline (§12.2) --------------------------------------

func _g_add_water_follows_the_child_spline() -> void:
	print("[G] Add Water on a rebuilt Trough builds a Pasture3DStream, not a Pasture3DPool")
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	_root.add_child(sun)
	var mgr := Pasture3DPoolManager.new()
	mgr.name = "Pasture3DPoolManager"
	_root.add_child(mgr)
	mgr.sun_light = sun

	var trough = _preset_at(Pasture3DTrough, "TroughG", SITE_E + Vector3(0.0, 0.0, 240.0), false)
	if trough == null:
		_check("G", false, "no terrain for the Trough fixture")
		return
	_loop_curve(trough, 60.0)
	await get_tree().process_frame
	# `add_pool_now`, not `add_pool`: a Plow preset's layer blend is ADD, so `brush_raises()` is true and
	# `add_pool` correctly puts up a confirmation dialog nobody can answer headless. The dialog is
	# WaterBodiesPhase4Gate [D]'s subject; this criterion is about which SPLINE the water follows, and
	# `add_pool_now` is the same code path past the prompt -- it is what `_attach_generated` presses too.
	var made: Array = trough.add_pool_now()
	await get_tree().process_frame
	var got_stream := made.size() == 1 and made[0] is Pasture3DStream
	_check("G", got_stream, "a Trough whose OWN spline is a closed loop produced: %s" % _kinds(made))
	# The claim underneath it: the water followed the CHILD, so the closed/open rule was never bent.
	if got_stream:
		var child_paths: Array = trough._preset_spline()._get_splines()
		_check("G", child_paths.has(made[0].source_spline),
				"the Stream's source_spline is the preset's child line, not the brush's loop")

	# CONTROL: a plain Pasture3DPlow with the same shape of closed loop must still produce a Pool. It is
	# what makes [G] a statement about the OVERRIDE rather than about Add Water having stopped making
	# pools at all.
	var plow := Pasture3DPlow.new()
	plow.name = "PlowG"
	plow.auto_refresh = false
	_root.add_child(plow)
	plow.terrain = _terrain
	plow.global_position = SITE_E + Vector3(240.0, 0.0, 240.0)
	_loop_curve(plow, 60.0)
	await get_tree().process_frame
	var ctrl_made: Array = plow.add_pool_now()
	await get_tree().process_frame
	_check("G", ctrl_made.size() == 1 and ctrl_made[0] is Pasture3DPool,
			"CONTROL Add Water on a plain Plow still builds a Pool: %s" % _kinds(ctrl_made))


# ---- fixtures ---------------------------------------------------------------------------------------


## A preset brush at `p_at` with a straight carved line under it, and optionally an area loop fitted
## around it. Returns null when there is no terrain at the site, which is checked rather than assumed.
func _preset_at(p_class, p_name: String, p_at: Vector3, p_fit: bool = true, p_install: bool = true):
	if not is_finite(_height(p_at)):
		return null
	var b = p_class.new()
	b.name = p_name
	b.auto_refresh = false
	# auto_fit_loop off unless a criterion is about it: a fit that ran inside every refresh would move
	# the geometry the other criteria are measuring, and [B] is where the fit gets measured.
	b.auto_fit_loop = false
	_root.add_child(b)
	b.terrain = _terrain
	b.global_position = p_at
	if p_install:
		b.install_preset_now()
		_line_curve(b)
		if p_fit:
			b.ensure_area_loop()
	return b


## Replace the preset's child line with a straight run along X, centred on the brush and SEATED ON THE
## GROUND.
##
## The seating is not cosmetic. Path Carve's `follow_path_height` puts the crest at the LINE's height
## plus the offset, so a line left at the brush's local zero would put the crest wherever the brush's
## origin happens to be — tens of metres off the terrain, and the height assertions would be measuring
## the site rather than the carve.
func _line_curve(p_brush) -> Path3D:
	var path := Path3D.new()
	path.name = "Line1"
	var c := Curve3D.new()
	var org: Vector3 = p_brush.global_position
	for i in 9:
		var f := float(i) / 8.0
		var lx := -LINE_HALF + f * 2.0 * LINE_HALF
		var g := _height(Vector3(org.x + lx, 0.0, org.z))
		c.add_point(Vector3(lx, g - org.y, 0.0))
	path.curve = c
	p_brush.adopt_preset_line(path)
	return path


## The same seated line, but attached the way a scene saved by the OLD Ridge attached it: a plain Path3D
## directly under the brush. `_apply_migration` is what reparents it.
func _legacy_line(p_brush) -> Path3D:
	var path := Path3D.new()
	path.name = "Crest1"
	var c := Curve3D.new()
	var org: Vector3 = p_brush.global_position
	for i in 9:
		var f := float(i) / 8.0
		var lx := -LINE_HALF + f * 2.0 * LINE_HALF
		c.add_point(Vector3(lx, _height(Vector3(org.x + lx, 0.0, org.z)) - org.y, 0.0))
	path.curve = c
	p_brush.add_child(path)
	p_brush._connect_spline(path)
	return path


## Give the brush a closed square loop of half-extent `p_half`, replacing any it has.
func _loop_curve(p_brush, p_half: float) -> Curve3D:
	for existing in p_brush._get_splines():
		p_brush.remove_child(existing)
		existing.queue_free()
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-p_half, 0.0, -p_half))
	c.add_point(Vector3(p_half, 0.0, -p_half))
	c.add_point(Vector3(p_half, 0.0, p_half))
	c.add_point(Vector3(-p_half, 0.0, p_half))
	c.closed = true
	path.curve = c
	p_brush.add_child(path)
	p_brush._connect_spline(path)
	return c


# ---- measurement ------------------------------------------------------------------------------------


## `[height on the carved line, height well away from it]` at a site, in world metres.
##
## The second probe is the whole point: a criterion that only reads the crest cannot tell a carve from a
## bake that raised the entire region.
func _profile(p_at: Vector3, _p_brush = null) -> Array[float]:
	var on := Vector3(p_at.x, 0.0, p_at.z)
	var off := Vector3(p_at.x, 0.0, p_at.z + 3.0 * LINE_HALF)
	return [_height(on), _height(off)] as Array[float]


## Heights on the vertex lattice walking away from the line, `_vs` at a time out to LINE_HALF * 2.
##
## Taken before and before/after a bake so the flank can be measured as a DIFFERENCE. Against the
## terrain's own shape it could not be: the site has 78 m of relief across the probe span, which swamps
## any threshold a "did this cell move" test could use.
func _lateral(p_at: Vector3) -> Array[float]:
	var out: Array[float] = []
	var d := _vs
	while d <= 2.0 * LINE_HALF:
		out.append(_height(Vector3(p_at.x, 0.0, p_at.z + d)))
		d += _vs
	return out


## The furthest distance from the line at which the bake changed the ground, in metres. 0 when nothing
## moved at all, which the caller's tolerance reports as a failure rather than as a narrow ridge.
func _reach(p_before: Array[float], p_after: Array[float]) -> float:
	var reach := 0.0
	for i in mini(p_before.size(), p_after.size()):
		if absf(p_after[i] - p_before[i]) > 0.05:
			reach = float(i + 1) * _vs
	return reach


func _height(p_at: Vector3) -> float:
	return _terrain.data.get_height(Vector3(p_at.x, 0.0, p_at.z))


static func _signed_area(p_poly: PackedVector2Array) -> float:
	var a := 0.0
	var n := p_poly.size()
	for i in n:
		var p := p_poly[i]
		var q := p_poly[(i + 1) % n]
		a += p.x * q.y - q.x * p.y
	return a * 0.5


static func _points_match(p_a: PackedVector3Array, p_b: PackedVector3Array, p_eps: float) -> bool:
	if p_a.size() != p_b.size():
		return false
	for i in p_a.size():
		if p_a[i].distance_to(p_b[i]) > p_eps:
			return false
	return true


func _graph_of(p_brush) -> Pasture3DTerrainGraph:
	for m in p_brush.modifiers:
		if m is Pasture3DNodeGraph:
			return (m as Pasture3DNodeGraph).graph
	return null


## Mean of every world-XZ point the brush's graph actually RESOLVES, via `input_spline_polylines()` --
## the same walk the loop fit uses, so this reads what the Spline Source found rather than what the tree
## looks like. An empty resolution returns a sentinel far from any site, so the distance test below fails
## loudly rather than dividing by zero.
static func _resolved_centre(p_polys: Array) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for pts in p_polys:
		for q in (pts as PackedVector2Array):
			sum += q
			n += 1
	return sum / float(n) if n > 0 else Vector2(1.0e9, 1.0e9)


static func _kinds(p_nodes: Array) -> String:
	if p_nodes.is_empty():
		return "nothing"
	var out := PackedStringArray()
	for n in p_nodes:
		out.append("%s '%s'" % [n.get_class(), n.name])
	return ", ".join(out)
