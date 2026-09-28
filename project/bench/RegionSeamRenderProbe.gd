# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Render probe for streaming phase 3 (PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md §D): what the GPU draws at
# a Standard/Background border, vertex collapse, and what a coarse region costs in VRAM. Headless compiles no
# shaders and allocates no textures, so this needs a window. A correctness check, not a benchmark: it reads
# one depth pixel per sample (get_intersection in GPU mode) and the texture-memory counter.
#
# Fixture: A (0, 0) is Background (ratio 4, collapse, colour only), B (1, 0) Standard. Heights are a plane,
# so a coarse cell's triangles and its bilinear agree, except:
#   - B's column 0 carries 4 * sin(pi z / 2): detail between A's lattice points, which the collapsed mesh
#     fans to. The stitch flattens it; without the stitch the drawn surface leaves the CPU's.
#   - A's lattice for z >= 128 carries a +-2 checkerboard (a saddle per cell). At a cell centre the bilinear
#     is the plane, while the collapsed mesh draws the cell as two triangles whose shared diagonal passes
#     through the centre: 2 off the plane. Collapse off draws the bilinear.
#
# Run (windowed): Godot_v4.7-stable_win64_console.exe --path project bench/RegionSeamRenderProbe.tscn
extends Node3D

const DIR := "user://region_seam_render_probe"
const BACKGROUND_PATH := "res://addons/pasture_3d/region_types/background.tres"
const A := Vector2i(0, 0)
const B := Vector2i(1, 0)
const TWIST := 2.0
const TOL := 0.15 # get_intersection's depth is quantised to ~0.05 m

var _fail := 0
const GATES := 4
var _completed := 0
var _terrain
var _cam: Camera3D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var da := DirAccess.open(DIR)
	for f in da.get_files():
		da.remove(f)
	RenderingServer.set_default_clear_color(Color(1, 0, 1)) # _clear_pixels looks for it
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60, 30, 0)
	add_child(light)
	_cam = Camera3D.new()
	_cam.rotation_degrees = Vector3(-90, 0, 0)
	add_child(_cam)
	_cam.current = true
	_terrain = ClassDB.instantiate("Pasture3D")
	add_child(_terrain)
	_terrain.data_directory = DIR
	_terrain.set_camera(_cam)
	_terrain.material.world_background = 0 # NONE: no region, no surface
	var d = _terrain.data
	d.add_region_blank(A, false)
	d.add_region_blank(B, false)
	d.update_maps()
	await _frames(10)
	print("\n=== Region seam render probe (streaming phase 3) ===\n")

	await _p1_vram()
	var bg: Pasture3DRegionType = d.load_region_type(BACKGROUND_PATH)
	var smooth := Pasture3DRegionType.new()
	smooth.type_name = "BackgroundSmooth"
	smooth.texel_ratio = 4
	smooth.vertex_collapse = false
	smooth.material_mode = Pasture3DRegionType.MATERIAL_COLOR_ONLY
	ResourceSaver.save(smooth, DIR + "/background_smooth.tres")
	smooth = ResourceLoader.load(DIR + "/background_smooth.tres", "", ResourceLoader.CACHE_MODE_REPLACE)

	await _p2_seam(bg)
	await _p3_collapse(bg, smooth)
	await _p4_misses()

	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["SEAM PROBE PASS" if ok else "SEAM PROBE FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


# --- P1: the texture-memory counter moves by 1/16 for a coarse slot ------------------------------------
func _p1_vram() -> void:
	print("[P1] VRAM:")
	var d = _terrain.data
	# The first coarse region creates the coarse arrays: SLOT_CHUNK layers at ratio 4.
	var m0 := _tex_mem()
	d.set_region_type(A, d.load_region_type(BACKGROUND_PATH))
	await _frames(4)
	var m1 := _tex_mem()
	var cap_c: int = d.get_coarse_slot_capacity()
	# Growing the fine arrays by one chunk: B plus 16 more Standard regions.
	var cap_f0: int = d.get_slot_capacity()
	for i in 16:
		d.add_region_blank(Vector2i(20 + i, 20), false)
	var m2 := _tex_mem()
	d.update_maps()
	await _frames(4)
	var m3 := _tex_mem()
	var cap_f1: int = d.get_slot_capacity()
	var s: Dictionary = d.get_upload_stats()
	var dc := m1 - m0
	var df := m3 - m2
	print("    coarse arrays +%d B (capacity %d), fine growth %d -> %d: +%d B" % [dc, cap_c, cap_f0, cap_f1, df])
	var want_c: float = cap_c * float(s.get("coarse_layer_bytes", 0))
	var want_f: float = (cap_f1 - cap_f0) * float(s.get("fine_layer_bytes", 0))
	_check("the counter measured both (%d, %d)" % [dc, df], dc > 0 and df > 0)
	# The counter charges every array layer a fixed ~2.7 KB beyond the image bytes, the same at 256 and 64 (it
	# sits in the small end of the colour mip chain), so the raw ratio is a little under 16. What scales
	# with the ratio is the rest: equal residuals per layer, and 16:1 once they are taken off.
	var per_c := float(dc) / cap_c
	var per_f := float(df) / (cap_f1 - cap_f0)
	var res_c := per_c - float(s.get("coarse_layer_bytes", 0))
	var res_f := per_f - float(s.get("fine_layer_bytes", 0))
	print("    per layer: coarse %.0f B, fine %.0f B, raw ratio %.3f; residual coarse %.0f B, fine %.0f B"
		% [per_c, per_f, per_f / per_c, res_c, res_f])
	_check("the residual is a fixed per-layer cost (%.0f vs %.0f B)" % [res_c, res_f],
		absf(res_c - res_f) <= 16.0 and res_c >= 0.0 and res_c < 0.01 * per_f)
	_check("the fine delta is its layers' bytes plus it (%d vs %d)" % [df, want_f + res_f * (cap_f1 - cap_f0)],
		absf(df - want_f - res_f * (cap_f1 - cap_f0)) < 1.0)
	var net := (per_f - res_f) / (per_c - res_c)
	_check("a ratio-4 slot is 1/16 of a Standard one (net %.3f, raw %.3f)" % [net, per_f / per_c],
		absf(net - 16.0) < 0.16 and per_f / per_c > 15.0)
	for i in 16:
		d.remove_regionl(Vector2i(20 + i, 20), false)
	d.update_maps()
	_completed += 1


# --- P2: the drawn surface meets the CPU's across A's last cell, with the stitch and not without ---------
func _p2_seam(p_bg: Pasture3DRegionType) -> void:
	print("[P2] the seam:")
	var d = _terrain.data
	d.set_region_type(A, p_bg)
	# At x = 254.5 the fan from A's collapsed column (x 252) to B's column 0 reaches the edge at
	# z0 + (z - z0) / 0.625: these land on B's detail peaks z0 + 1 and z0 + 3 (+-4).
	var zs := []
	for k in range(4, 30, 2):
		zs.append(4 * k + 0.625)
		zs.append(4 * k + 1.875)
	var dev := {}
	for stitch in [false, true]:
		d.set_seam_stitch_enabled(stitch)
		_author()
		var worst := 0.0
		for z in zs:
			var e := await _gpu_error(254.5, z)
			worst = maxf(worst, e)
		dev[stitch] = worst
	print("    A's last cell |gpu - cpu|: stitched %.3f, unstitched %.3f" % [dev[true], dev[false]])
	_check("stitched: the drawn surface is the CPU's (max %.3f)" % dev[true], dev[true] < TOL)
	_check("control: unstitched it leaves it (max %.3f)" % dev[false], dev[false] > 1.0)
	var worst_b := 0.0
	for z in [21.25, 55.25, 101.25]:
		worst_b = maxf(worst_b, await _gpu_error(257.5, z))
	_check("B's side agrees too (max %.3f)" % worst_b, worst_b < TOL)
	_completed += 1


# --- P3: vertex collapse draws a coarse cell as two triangles ------------------------------------------
func _p3_collapse(p_bg: Pasture3DRegionType, p_smooth: Pasture3DRegionType) -> void:
	print("[P3] vertex collapse:")
	var d = _terrain.data
	var dev := {}
	for pair in [[true, p_bg], [false, p_smooth]]:
		d.set_region_type(A, pair[1])
		_author()
		var lo := INF
		var hi := 0.0
		for c in [Vector2i(10, 40), Vector2i(21, 45), Vector2i(33, 50), Vector2i(47, 55), Vector2i(58, 60), Vector2i(5, 36)]:
			var e := await _gpu_error(c.x * 4 + 2, c.y * 4 + 2)
			lo = minf(lo, e)
			hi = maxf(hi, e)
		dev[pair[0]] = Vector2(lo, hi)
	print("    cell centres |gpu - cpu|: collapse %s, smooth %s" % [dev[true], dev[false]])
	_check("collapse: every centre is %.0f off the bilinear (%s)" % [TWIST, dev[true]],
		absf(dev[true].x - TWIST) < TOL and absf(dev[true].y - TWIST) < TOL)
	_check("control: collapse off draws the bilinear (max %.3f)" % dev[false].y, dev[false].y < TOL)
	_completed += 1


# --- P4: every sample hit, and a ray past the world misses ---------------------------------------------
func _p4_misses() -> void:
	# On screen, not through get_intersection: the picking camera draws ground where no region is.
	print("[P4] no crack on screen:")
	var seam := await _clear_pixels(Vector3(256, 40, 128))
	var edge := await _clear_pixels(Vector3(0, 40, 128))
	_check("a strip over the A/B border shows no clear colour (%d px)" % seam, seam == 0)
	_check("control: the same strip over the world's edge does (%d px)" % edge, edge > 100)
	# The picking camera sees 0.1 m, so it culls every clipmap mesh but the one under it: a collapsed
	# triangle that has moved back out of its mesh's cull AABB vanishes from it. Before the AABBs carried
	# the collapse margin, 4 of these 16 missed.
	var misses := 0
	for i in 16:
		var h := await _gpu_hit(128.5, 16.0 + i * 0.25)
		if not h.is_finite() or h.x > 1e6:
			misses += 1
	_check("picking down a collapsed cell never misses (%d of 16)" % misses, misses == 0)
	_completed += 1


# A plane, B's column 0 detail, and A's lattice twist for z >= 128; A written on its own lattice.
func _author() -> void:
	var d = _terrain.data
	var a_img: Image = d.get_region(A).get_height_map()
	var n := a_img.get_width()
	var r := 256 / n
	for j in n:
		for i in n:
			var h := _plane(i * r, j * r)
			if j * r >= 128:
				h += TWIST if (i + j) % 2 == 0 else -TWIST
			a_img.set_pixel(i, j, Color(h, 0, 0, 1))
	var b_img: Image = d.get_region(B).get_height_map()
	for z in 256:
		for x in 256:
			var h := _plane(256 + x, z)
			if x == 0:
				h += 4.0 * sin(PI * z / 2.0)
			b_img.set_pixel(x, z, Color(h, 0, 0, 1))
	for loc in [A, B]:
		d.get_region(loc).set_edited(true)
		d.get_region(loc).set_modified(true)
		d.get_region(loc).calc_height_range()
	d.update_maps(0, false)
	d.calc_height_range(true)


func _plane(p_x: float, p_z: float) -> float:
	return 5.0 + 0.05 * p_x + 0.03 * p_z


func _gpu_error(p_x: float, p_z: float) -> float:
	var hit := await _gpu_hit(p_x, p_z)
	if not hit.is_finite() or hit.x > 1e6:
		print("    MISS at (%.2f, %.2f)" % [p_x, p_z])
		return INF
	return absf(hit.y - _terrain.data.get_height(hit))


# get_intersection in GPU mode reads the depth pixel of the previous UPDATE_ONCE render: ask, let it
# render, ask again. The clipmap follows the camera, so it moves over the sample first.
func _gpu_hit(p_x: float, p_z: float) -> Vector3:
	_cam.global_position = Vector3(p_x, 80, p_z)
	for i in 2:
		await get_tree().physics_frame
	await _frames(2)
	# Nearly straight down (straight down takes the CPU path) and from close by, so the hit lands within
	# ~0.025 m of the sample: the collapse check sits on a triangle's diagonal.
	var src := Vector3(p_x, _plane(p_x, p_z) + 4.0, p_z)
	var dir := Vector3(0.006, -1, 0).normalized() # y -0.999982: -0.99999 and below is the CPU path
	_terrain.get_intersection(src, dir, true)
	await _frames(3)
	return _terrain.get_intersection(src, dir, true)


# Clear-colour pixels in a 40 px strip down the middle of the screen, looking straight down from p_at.
func _clear_pixels(p_at: Vector3) -> int:
	_cam.global_position = p_at
	for i in 2:
		await get_tree().physics_frame
	await _frames(3)
	var img := get_viewport().get_texture().get_image()
	var n := 0
	var cx := img.get_width() / 2
	for y in img.get_height():
		for x in range(cx - 20, cx + 20):
			var c := img.get_pixel(x, y)
			if absf(c.r - 1) < 0.02 and c.g < 0.02 and absf(c.b - 1) < 0.02:
				n += 1
	return n


func _tex_mem() -> int:
	return int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))


func _frames(p_n: int) -> void:
	for i in p_n:
		await get_tree().process_frame


func _check(p_name: String, p_ok: bool) -> void:
	print("  %s  %s" % ["ok  " if p_ok else "FAIL", p_name])
	if not p_ok:
		_fail += 1
