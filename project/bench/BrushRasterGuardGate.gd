# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# BrushRasterGuardGate — the native brush rasteriser's guards against MISSING, NON-FINITE and OUT-OF-RECT
# data. PASTURE3D_PIPELINE_REMEDIATION_SPEC.md P2 §2.2, §2.3 and §2.4.
#
# The first two defects share a shape: a SENTINEL used as if it were a value.
#
#   §2.2  Pasture3DData::get_control answers UINT32_MAX for "there is no control map here". The splat
#         rasteriser ORed its texture bits straight into that answer, and 0xFFFFFFFF carries base id 31,
#         the HOLE bit and the NAVIGATION bit. So painting a texture over a region whose control map had
#         not been created yet punched a hole in the terrain -- get_height there returns NaN -- and turned
#         navigation on, in the last texture slot.
#
#   §2.4  NAN is the plow rasteriser's "this cell writes nothing" sentinel, and it tested for exactly that
#         with isnan. An INFINITY is equally unwritable and is not NaN, so it survived the test, went
#         through the buffer and got smeared across the neighbourhood by the NaN-aware blur.
#
#   §2.3  is a different animal: nothing is out of range, the grid is simply INCOMPLETE. A field modifier
#         reads the whole grid, and the pre-pass that fills it was clipped to the dirty rect, so the
#         modifier saw the brush end at the rect edge instead of at the loop edge.
#
# NOTHING IS SAVED and no demo data is loaded: the terrain is built in memory with no data_directory, so
# a run cannot dirty the repo. House discipline: every criterion measures a value and carries a CONTROL
# that must fail if the path is dead.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/BrushRasterGuardGate.tscn
extends Node

const VS := 1.0
const SITE := Vector3(64.0, 0.0, 64.0)

var _fail := 0
var _terrain: Pasture3D


func _ready() -> void:
	print("=== BrushRasterGuardGate: missing data is not data (P2 §2.2, §2.3, §2.4) ===\n")
	_terrain = Pasture3D.new()
	_terrain.name = "Terrain"
	_terrain.vertex_spacing = VS
	add_child(_terrain)

	_a_splat_over_a_bare_region_paints_no_hole()
	_b_an_infinite_amplitude_writes_nothing()
	_c_a_field_modifier_does_not_see_the_clip_edge()

	print("\n=== %s (%d failures) ===\n" % ["BRUSH RASTER GUARD PASS" if _fail == 0 else "BRUSH RASTER GUARD FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A. A splat over a region with no control map (§2.2) ----------------------------------------------
func _a_splat_over_a_bare_region_paints_no_hole() -> void:
	print("[A] splat over a region whose control map does not exist yet")
	var data := _terrain.data
	var region := data.add_region_blankp(SITE)
	# A blank region ships with a control map already zeroed, so the sentinel never appears and the bug
	# cannot be reached. Fill it with COLOR_NAN, which is exactly the state get_control tests for and
	# exactly what a region that has never had control authored -- or one whose control map was deleted --
	# looks like on disk. NaN in, UINT32_MAX out.
	var ctrl: Image = region.get_map(Pasture3DRegion.TYPE_CONTROL)
	if ctrl == null:
		_fail += 1
		print("    !! the region has no control map image at all; the fixture cannot be built")
		return
	ctrl.fill(Color(NAN, NAN, NAN, NAN))

	# THE FIXTURE, and it is the whole criterion: the control map has to be ABSENT. If the blank region
	# already carries one, get_control answers a real word, the sentinel never appears and this gate would
	# pass with the bug in place -- the "measured nothing" failure, wearing a green tick.
	var before := data.get_control(SITE)
	print("    fixture: control before the paint = 0x%08X (want 0xFFFFFFFF, i.e. absent)" % before)
	if before != 0xFFFFFFFF:
		_fail += 1
		print("    !! the region already has a control map, so this fixture cannot reach the bug")
		return

	_splat(4)

	var after := data.get_control(SITE)
	var base := Pasture3DUtil.get_base(after)
	var hole := Pasture3DUtil.is_hole(after)
	var nav := Pasture3DUtil.is_nav(after)
	print("    after the paint: base = %d, hole = %s, nav = %s (want 4, false, false)" % [base, hole, nav])
	if base != 4:
		_fail += 1; print("    !! the splat did not paint the material it was given")
	if hole:
		_fail += 1; print("    !! the splat punched a HOLE — the UINT32_MAX sentinel reached the encode")
	if nav:
		_fail += 1; print("    !! the splat turned NAVIGATION on — same sentinel, other bit")

	# CONTROL: the terrain is really readable here, so "no hole" is a fact about the paint rather than
	# about a cell nothing ever touched.
	var h := data.get_height(SITE)
	print("    control: height at the site = %s (want finite)" % h)
	if not is_finite(h):
		_fail += 1; print("    !! the site is not solid ground, so the hole assertion proves nothing")


# --- B. An INFINITE amplitude writes nothing (§2.4) ---------------------------------------------------
func _b_an_infinite_amplitude_writes_nothing() -> void:
	print("[B] a plow whose source data carries +INF leaves the ground alone")
	var data := _terrain.data
	var site := SITE + Vector3(0.0, 0.0, 40.0)
	data.add_region_blankp(site)
	var before := data.get_height(site)
	print("    fixture: height before = %s" % before)

	# A 2x2 source image, every sample +INF. `sv` is then INF, `amp` is INF, and before the fix the
	# buffered value was an infinity that isnan() waved through.
	var inf_src := PackedFloat32Array([INF, INF, INF, INF])
	_plow(site, inf_src, 2, 2)
	var after := data.get_height(site)
	print("    after an INF plow: height = %s (want unchanged, and finite)" % after)
	if not is_finite(after):
		_fail += 1; print("    !! an infinity reached the terrain")
	elif absf(after - before) > 1.0e-4:
		_fail += 1; print("    !! the INF plow moved the ground by %.6f m" % absf(after - before))

	# CONTROL: the same plow with FINITE source data does move the ground. Without this, a rasteriser
	# that silently did nothing at all — wrong params, empty polygon, missed region — would pass [B].
	var live_src := PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
	_plow(site, live_src, 2, 2)
	var moved := absf(data.get_height(site) - before)
	print("    control: the same plow with finite data moved the ground by %.4f m (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! control dead — the plow never wrote anything, so [B] proves nothing")


# --- C. A field modifier sees the whole brush, not the dirty rect (§2.3) -------------------------------
#
# A FIELD modifier -- erosion, a graph stage -- reads the WHOLE grid. The pre-pass that fills that grid
# used to be clipped to the dirty rect along with the write loop, so every cell outside the rect stayed
# NaN and the erosion computed its drainage network against a cliff that existed only because of which
# cells happened to be dirty. Dragging one spline point therefore produced different terrain from a full
# bake of the same brush -- and the difference sat exactly ON the clip boundary.
#
# So this compares heights along that BOUNDARY, not over the whole rect: a whole-grid mean averages a
# one-cell seam away to nothing, which is how a criterion like this gets written so it cannot fail.
func _c_a_field_modifier_does_not_see_the_clip_edge() -> void:
	print("[C] a clipped bake with an erosion modifier matches the full bake inside the rect")
	var data := _terrain.data
	var site := SITE + Vector3(0.0, 0.0, 80.0)
	var clip := AABB(Vector3(site.x - 12.0, -500.0, site.z - 12.0), Vector3(12.0, 1000.0, 24.0))
	# The seam lands on the clip's +X wall, so probe a column of cells just INSIDE it.
	var probes: Array[Vector3] = []
	for k in range(-8, 9):
		probes.append(Vector3(clip.position.x + clip.size.x - VS, 0.0, site.z + float(k)))

	data.add_region_blankp(site)
	_mound_eroded(site, AABB())
	var full := _heights(probes)

	data.remove_regionp(site)
	data.add_region_blankp(site)
	_mound_eroded(site, clip)
	var clipped := _heights(probes)

	var d := _max_delta(full, clipped)
	print("    max |clipped - full| along the clip wall = %.6f m (want < 0.0001)" % d)
	if d > 1.0e-4:
		_fail += 1; print("    !! the clip rect changed what the erosion produced — a seam at the rect edge")

	# CONTROL: the erosion is actually doing something. Against a brush that erodes nothing, a clipped and
	# an unclipped bake agree trivially and [C] would pass with the pre-pass still clipped.
	data.remove_regionp(site)
	data.add_region_blankp(site)
	_mound_eroded(site, AABB(), false)
	var bare := _heights(probes)
	var moved := _max_delta(full, bare)
	print("    control: the erosion moved the probed wall by %.4f m (want > 0.01)" % moved)
	if moved <= 0.01:
		_fail += 1; print("    !! control dead — no erosion ran, so [C] proves nothing")


# ---- helpers -----------------------------------------------------------------------------------------

## A square loop around a point, in world XZ, as the rasterisers take it.
func _loop(p_at: Vector3, p_half: float) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(p_at.x - p_half, p_at.z - p_half), Vector2(p_at.x + p_half, p_at.z - p_half),
		Vector2(p_at.x + p_half, p_at.z + p_half), Vector2(p_at.x - p_half, p_at.z + p_half)])


func _grid(p_at: Vector3, p_half: float) -> Dictionary:
	return {
		"min_x": p_at.x - p_half, "min_z": p_at.z - p_half, "vs": VS,
		"gw": int(round(2.0 * p_half / VS)) + 1, "gh": int(round(2.0 * p_half / VS)) + 1,
	}


func _splat(p_material: int) -> void:
	var params := _grid(SITE, 12.0)
	params.merge({
		"strength": 1.0, "edge_offset": 0.0, "falloff_width": 0.0,
		"material": p_material, "preserve_base": false,
		"uv_bits": 0, "composite": true, "noise": null, "noise_strength": 0.0,
	})
	_terrain.data.stamp_splat_loop(-1, _loop(SITE, 12.0), AABB(), params, _ramp())


func _plow(p_at: Vector3, p_src: PackedFloat32Array, p_w: int, p_h: int) -> void:
	var params := _grid(p_at, 12.0)
	params.merge({
		"strength": 1.0, "edge_offset": 0.0, "falloff_width": 0.0,
		"source": 1, "data_w": p_w, "data_h": p_h, "tile_size": 24.0,
		"height_scale": 10.0, "height_offset": 0.0, "relative": true, "add": false,
		"composite": true, "smooth_passes": 0,
	})
	_terrain.data.stamp_plow_loop(-1, _loop(p_at, 12.0), AABB(), params, _ramp(), p_src)


## A MOUND, not a plow: stamp_mound_loop is the rasteriser that runs the modifier stack, and an EROSION
## step is the FIELD modifier the criterion needs -- a point modifier reads one cell and could never
## notice the clip.
func _mound_eroded(p_at: Vector3, p_clip: AABB, p_erode: bool = true) -> void:
	var params := _grid(p_at, 24.0)
	params.merge({
		"height": 40.0, "capped": false, "invert": false,
		"falloff_width": 10.0, "edge_offset": 0.0,
		"relative_to_terrain": true, "plane_y": 0.0, "blend": 0, "composite": true,
	})
	if p_erode:
		# A noise step before the erosion: erosion subtracts along a drainage network, and a perfectly
		# smooth dome has nothing to route. The noise is what gives it relief to work on.
		params["modifiers"] = [
			{"op": "noise", "noise": _relief_noise(), "strength": 6.0},
			{"op": "erosion", "iterations": 20, "erosion_rate": 0.6, "diffusion": 0.3},
		]
	else:
		params["modifiers"] = [{"op": "noise", "noise": _relief_noise(), "strength": 6.0}]
	_terrain.data.stamp_mound_loop(-1, _loop(p_at, 24.0), p_clip, params, _ramp())


func _relief_noise() -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = 31
	n.frequency = 0.06
	return n


func _heights(p_at: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in p_at:
		out.append(_terrain.data.get_height(p))
	return out


## NaN on either side counts as a difference, not as a skip: "the clipped bake wrote nothing here" is
## exactly the failure this criterion is looking for.
func _max_delta(p_a: Array[float], p_b: Array[float]) -> float:
	var m := 0.0
	for i in range(mini(p_a.size(), p_b.size())):
		var x: float = p_a[i]
		var y: float = p_b[i]
		if not is_finite(x) or not is_finite(y):
			if is_finite(x) != is_finite(y):
				return INF
			continue
		m = maxf(m, absf(x - y))
	return m


## A flat 1.0 ramp LUT: full strength everywhere inside the loop, so the mask is never the reason a
## criterion measured nothing.
func _ramp() -> PackedFloat32Array:
	var lut := PackedFloat32Array()
	lut.resize(64)
	lut.fill(1.0)
	return lut
