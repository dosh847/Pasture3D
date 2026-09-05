# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# BrushStatsGate — the inspector's read-only "Brush Stats" category.
#
# The panel exists so the scale of an edit is legible before it is baked. Every figure is derived at read
# time, so the failure this gate is built against is not "the number is wrong" but "the number is a
# PLAUSIBLE CONSTANT": a sampler that bailed early, a cache that froze last frame's answer, or a shape
# measurement that silently reports the geometry of the bounding box instead of the curve.
#
# THE FIXTURE IS A CONSTANT-GRADIENT RAMP, h(x, z) = RAMP_K * x. It is chosen because mean |grad h| over
# ANY window of it is exactly RAMP_K, so criterion C can assert an exact value without re-deriving the
# sampler's own box or step — the trap in [[check-derived-values-outside-the-chain]], where comparing a
# derived value against the number it came from only proves the derivation is a function.
#
# NOTHING IS SAVED and no demo data is loaded: the terrain is built in memory with no data_directory, so a
# run cannot dirty the repo (see [[gate-data-directory-is-an-editor-risk]]). House discipline: every
# criterion measures a value and carries a CONTROL that must fail if the path is dead.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/BrushStatsGate.tscn
extends Node

const VS := 1.0
const REGION := 64          # region_size, and the extent of the authored ramp in metres (VS = 1)
const RAMP_K := 0.25        # 25% grade, so mean |grad h| is exactly 0.25 and the slope reads 25.0%
const RAMP_K2 := 0.5        # the "it is reading the terrain, not a constant" control
const SQ_HALF := 16.0       # the test ring: a 32 m square centred in the region
const SQ_CENTRE := Vector3(32.0, 0.0, 32.0)

var _fail := 0
var _terrain: Pasture3D


func _ready() -> void:
	print("=== BrushStatsGate: the Brush Stats readout measures, and keeps measuring ===\n")
	_terrain = Pasture3D.new()
	_terrain.name = "Terrain"
	_terrain.vertex_spacing = VS
	_terrain.region_size = REGION
	add_child(_terrain)
	_terrain.data.add_region_blankp(Vector3.ZERO)

	_a_shape_figures_come_from_the_curve()
	_b_elevation_brackets_the_ground_under_the_ring()
	_c_mean_slope_is_the_gradient_of_the_ground()
	# AWAITED. `_d` contains an `await`, which makes it a coroutine whether or not it suspends, and an
	# un-awaited call returns a signal object immediately — so its criteria used to run AFTER the summary
	# had printed and `quit()` had been called. The gate announced PASS with a failing criterion still in
	# flight, which is the exact shape of [[gate-pass-can-mean-nothing-ran]].
	await _d_the_cache_is_per_frame_not_forever()

	print("\n=== %s (%d failures) ===\n" % [
		"BRUSH STATS PASS" if _fail == 0 else "BRUSH STATS FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---- fixture helpers ---------------------------------------------------------------------------------

## Author h(x, z) = p_k * x across the whole region. Written through set_height (one call per vertex, 4096
## of them at REGION 64) rather than by filling the region's Image, so the gate exercises the same read
## path the stats sampler uses and cannot pass against a map the engine never composited.
func _ramp(p_k: float) -> void:
	var data := _terrain.data
	for z in range(REGION):
		for x in range(REGION):
			data.set_height(Vector3(float(x), 0.0, float(z)), p_k * float(x))
	data.update_maps(Pasture3DRegion.TYPE_HEIGHT, false, false)


func _flat() -> void:
	_ramp(0.0)


## A Mound (a closed brush) carrying one square ring of side 2 * SQ_HALF, centred in the region.
func _mound() -> Pasture3DMound:
	var m := Pasture3DMound.new()
	var p := Path3D.new()
	var c := Curve3D.new()
	for corner in [
		Vector3(-SQ_HALF, 0, -SQ_HALF), Vector3(SQ_HALF, 0, -SQ_HALF),
		Vector3(SQ_HALF, 0, SQ_HALF), Vector3(-SQ_HALF, 0, SQ_HALF),
	]:
		c.add_point(corner)
	p.curve = c
	m.add_child(p)
	m.position = SQ_CENTRE
	m.terrain = _terrain
	add_child(m)
	return m


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("    %s %s — %s" % ["OK  " if p_ok else "!!  ", p_label, p_detail])
	if not p_ok:
		_fail += 1


# ---- A. the shape figures ----------------------------------------------------------------------------

func _a_shape_figures_come_from_the_curve() -> void:
	print("[A] perimeter, area and footprint describe the ring, not its box")
	_flat()
	var m := _mound()
	var s: Dictionary = m._brush_stats()
	var side := 2.0 * SQ_HALF
	_check("perimeter", absf(float(s["length"]) - 4.0 * side) < 0.5,
		"expected %.1f m, got %.3f" % [4.0 * side, s["length"]])
	_check("area", absf(float(s["area"]) - side * side) < 2.0,
		"expected %.1f m², got %.3f" % [side * side, s["area"]])
	# The CONTROL for "area is not just the footprint box": the box is padded by the brush's reach, so a
	# stats build that reported the box would come out strictly larger. Without this, an area field wired
	# to the AABB would pass the check above on any brush whose reach happened to be zero.
	var fp: Vector2 = s["footprint"]
	var box_area := fp.x * fp.y
	_check("area is the ring, not the padded box", box_area > side * side + 1.0
			and absf(float(s["area"]) - box_area) > 1.0,
		"ring %.0f m² vs box %.0f m² (reach %.2f m)" % [s["area"], box_area, m._padding()])
	_check("splines counted", int(s["splines"]) == 1 and int(s["points"]) == 4,
		"%d spline(s), %d point(s)" % [int(s["splines"]), int(s["points"])])
	# Cells was never exercised before: with no terrain it reads "—", which is indistinguishable from a
	# broken divisor.
	var cells: String = str(m._get_stat(&"stats_cells"))
	_check("cells reads a count", cells != "—" and float(s["cells"]) > 0.0, cells)
	m.queue_free()


# ---- B. elevation ------------------------------------------------------------------------------------

func _b_elevation_brackets_the_ground_under_the_ring() -> void:
	print("\n[B] elevation range tracks the ground, and is not a constant")
	_ramp(RAMP_K)
	var m := _mound()
	var s: Dictionary = m._brush_stats()
	var drop := float(s["elev_max"]) - float(s["elev_min"])
	# A BRACKET, not an equality. The sampler reads the padded footprint box, whose extent depends on the
	# brush's reach and on the sample step — re-deriving those here would just restate the implementation.
	# The ring alone spans 2 * SQ_HALF of ramp; the box adds the reach on each side and at most one step.
	var lo_bound := RAMP_K * 2.0 * SQ_HALF
	var hi_bound := RAMP_K * (2.0 * SQ_HALF + 2.0 * m._padding() + 2.0 * maxf(VS, 1.0))
	_check("drop is inside the bracket", drop >= lo_bound - 0.01 and drop <= hi_bound + 0.01,
		"%.3f m in [%.3f, %.3f]" % [drop, lo_bound, hi_bound])
	# "MEASURED NOTHING" GUARD. Every elevation figure is NAN until a sample lands, and a sampler that
	# returned early would leave elev_min/elev_max NAN and the readout showing "—" — which reads as
	# "no terrain here", not as a bug. Assert the sample COUNT, not just the value.
	_check("the sampler actually read the terrain", int(s["sampled"]) > 100,
		"%d finite samples" % int(s["sampled"]))
	_check("readout is not dashed", str(m._get_stat(&"stats_elevation")) != "—",
		str(m._get_stat(&"stats_elevation")))
	m.queue_free()

	# CONTROL: the same ring over FLAT ground must report no relief. If elevation were wired to anything
	# other than the terrain — the spline's own Y, the footprint's nominal Y span — this is where it shows.
	_flat()
	var f := _mound()
	var fs: Dictionary = f._brush_stats()
	var flat_drop := float(fs["elev_max"]) - float(fs["elev_min"])
	_check("CONTROL flat ground reports no relief",
		int(fs["sampled"]) > 100 and absf(flat_drop) < 0.01,
		"Δ %.4f m over %d samples" % [flat_drop, int(fs["sampled"])])
	f.queue_free()


# ---- C. mean slope -----------------------------------------------------------------------------------

func _c_mean_slope_is_the_gradient_of_the_ground() -> void:
	print("\n[C] mean slope is the ramp's gradient, and follows it when it changes")
	_ramp(RAMP_K)
	var m := _mound()
	var slope := float(m._brush_stats()["slope"])
	# Exact: mean |grad h| over a constant-gradient field is that gradient, whatever window is used.
	_check("slope equals the ramp", is_finite(slope) and absf(slope - RAMP_K) < 0.005,
		"expected %.3f, got %.4f" % [RAMP_K, slope])
	_check("formatted as grade and angle", m._fmt_slope(RAMP_K) == "25.0%% (14.0°)" % [],
		m._fmt_slope(RAMP_K))
	m.queue_free()

	# CONTROL 1: a STEEPER ramp must move the number. A slope hardwired to a plausible constant, or read
	# off a stale cache, passes the check above and fails here.
	_ramp(RAMP_K2)
	var m2 := _mound()
	var slope2 := float(m2._brush_stats()["slope"])
	_check("CONTROL a steeper ramp reads steeper", is_finite(slope2)
			and absf(slope2 - RAMP_K2) < 0.005 and slope2 > slope + 0.1,
		"expected %.3f, got %.4f (was %.4f)" % [RAMP_K2, slope2, slope])
	m2.queue_free()

	# CONTROL 2: flat ground is zero slope, and reports it as a number rather than as "—".
	_flat()
	var f := _mound()
	var flat_slope := float(f._brush_stats()["slope"])
	_check("CONTROL flat ground reads zero slope",
		is_finite(flat_slope) and absf(flat_slope) < 0.005
			and str(f._get_stat(&"stats_mean_slope")) != "—",
		"%.5f — %s" % [flat_slope, str(f._get_stat(&"stats_mean_slope"))])
	f.queue_free()


# ---- D. the cache ------------------------------------------------------------------------------------

func _d_the_cache_is_per_frame_not_forever() -> void:
	print("\n[D] the per-frame cache collapses the repeat reads without freezing them")
	_flat()
	var m := _mound()
	var first: Dictionary = m._brush_stats()
	var second: Dictionary = m._brush_stats()
	# Same frame: the SAME dictionary instance, which is what makes the inspector's five-to-seven reads
	# one computation. Comparing contents would pass even with the cache removed entirely.
	_check("same frame returns the cached instance", is_same(first, second),
		"is_same=%s (a Dictionary is a reference, so this is identity, not equality)" % is_same(first, second))
	var before := float(first["length"])
	var path: Path3D = m._get_splines()[0]

	# The BAKE-PATH invalidation, which is the one that has to be right: `_refresh_stats_display` drops the
	# key outright. Deliberately checked WITHIN one frame, because that is the window the frame key cannot
	# close on its own — `process_frame` fires during a frame, so an edit and a re-read can sit either side
	# of it with the counter unchanged, and the first build of this gate caught exactly that.
	path.curve.set_point_position(0, Vector3(-SQ_HALF * 2.0, 0, -SQ_HALF * 2.0))
	var stale := float(m._brush_stats()["length"])
	m._refresh_stats_display()
	var fresh := float(m._brush_stats()["length"])
	_check("an explicit refresh drops the cache in the same frame", absf(fresh - before) > 1.0,
		"perimeter %.2f m → %.2f m (cached read in between: %.2f m)" % [before, fresh, stale])

	# And the frame key on its own, with two ticks so the counter is certainly past the edit. This is the
	# backstop for every path that changes a figure without telling anyone — a terrain rebake under a brush
	# that was never re-baked itself, a `corner_radius` tweak, a modifier added.
	await get_tree().process_frame
	await get_tree().process_frame
	path.curve.set_point_position(2, Vector3(SQ_HALF * 3.0, 0, SQ_HALF * 3.0))
	var later := float(m._brush_stats()["length"])
	_check("a later frame sees an untold edit", absf(later - fresh) > 1.0,
		"perimeter %.2f m → %.2f m" % [fresh, later])
	m.queue_free()
