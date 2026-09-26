# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Render probe for streaming phase 4b (PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md §I): does the GPU water
# terrain check remove what RegionWaterGate says the CPU mirror removes? Headless compiles no shaders, so this
# needs a window. A correctness check, not a benchmark: it reads pixels, it times nothing.
#
# The ocean is drawn with a flat white unshaded shader built from the real water includes (common, waves,
# surface, terrain), seen top-down through an orthographic camera; the terrain is on a render layer the
# camera does not see, so every pixel is either water (white) or the clear colour (magenta). What would hide
# the water in a real scene, the depth test against the terrain, is out of the picture: only the check is.
#
# Fixture as RegionWaterGate: A (0,0) land +20, B (1,0) seabed -20, C (2,0) unloaded, D (0,1) coarse ratio 4
# with land only in its pixel columns [8, 16), i.e. world x [32, 64).
#
# Criteria:
#   P1 feature points: land, unknown and the coarse stripe hide the water; open sea, seabed and beyond the
#      world keep it. Control: the same shader with WATER_TERRAIN_CHECK undefined shows water everywhere.
#   P2 the shoreline: on 20 m cells (so a removed vertex is visible), water reaches the A | B shore with no
#      gap. Control: a reach of 0 (the centre tap alone) opens a gap on B's side.
#   P3 the published globals are cleared when the terrain leaves: the check goes inert and water returns.
#   P4 the shipped clipmap shaders (ocean, ocean low, lake clipmap) compile with the check and apply it: sea
#      drawn, land removed. A shader that failed to compile draws nothing, so the sea point is its control.
#
# Run (windowed): Godot_v4.7-stable_win64_console.exe --path project res://bench/RegionWaterRenderProbe.tscn
extends Node3D

const DIR := "user://region_water_render_probe"
const A := Vector2i(0, 0)
const B := Vector2i(1, 0)
const C := Vector2i(2, 0)
const D := Vector2i(0, 1)

var _fail := 0
const GATES := 4
var _completed := 0
var _terrain
var _cam: Camera3D
var _ocean: Pasture3DOcean
var _target: Node3D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var da := DirAccess.open(DIR)
	for f in da.get_files():
		da.remove(f)
	RenderingServer.set_default_clear_color(Color(1, 0, 1))
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.rotation_degrees = Vector3(-90, 0, 0)
	_cam.far = 2000.0
	_cam.cull_mask = 1
	add_child(_cam)
	_cam.current = true
	_target = Node3D.new()
	add_child(_target)

	_terrain = ClassDB.instantiate("Pasture3D")
	add_child(_terrain)
	_terrain.data_directory = DIR
	_terrain.set_camera(_cam)
	_terrain.render_layers = 1 << 5 # not in the camera's cull mask
	_terrain.material.world_background = 0
	var d = _terrain.data
	var coarse := Pasture3DRegionType.new()
	coarse.type_name = "Coarse4"
	coarse.texel_ratio = 4
	ResourceSaver.save(coarse, DIR + "/coarse4.tres")
	coarse = ResourceLoader.load(DIR + "/coarse4.tres", "", ResourceLoader.CACHE_MODE_REPLACE)
	for loc in [A, B, C, D]:
		d.add_region_blank(loc, false)
	d.update_maps()
	_fill(A, 20.0)
	_fill(B, -20.0)
	_fill(C, -20.0)
	d.set_region_type(D, coarse, false)
	var dimg: Image = d.get_region(D).get_height_map()
	for y in dimg.get_height():
		for x in dimg.get_width():
			dimg.set_pixel(x, y, Color(15.0 if x >= 8 and x < 16 else -15.0, 0, 0, 1))
	d.get_region(D).set_modified(true)
	d.update_maps(3, true, false)
	d.save_directory(DIR)
	d.unload_region(C, false)
	d.update_maps()

	_ocean = _make_ocean()
	await _frames(10)
	print("\n=== Region water render probe (streaming phase 4b) ===\n")

	await _p1_feature_points()
	await _p2_shoreline()
	await _p3_globals_cleared()
	await _p4_shipped_shaders()

	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION WATER RENDER PASS" if ok else "REGION WATER RENDER FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


func _p1_feature_points() -> void:
	print("[P1] the check hides land, unknown and the coarse stripe; keeps sea and beyond the world:")
	_ocean.vertex_spacing = 1.0
	_ocean.tessellation_level = 2
	# The clipmap centred on D's 32 m stripe, so its cells there are fine and the reach is under a metre;
	# every other point is at least 70 m inside its region, beyond the reach of the coarser rings around it.
	_target.position = Vector3(48, 0, 380)
	_cam.size = 900.0
	_cam.position = Vector3(330, 500, 250)
	var points := {
		"beyond the world (-100, 128)": [Vector2(-100, 128), true],
		"A land (150, 180)": [Vector2(150, 180), false],
		"A cave spot (100, 100)": [Vector2(100, 100), false],
		"B seabed (450, 180)": [Vector2(450, 180), true],
		"B pit spot (356, 100)": [Vector2(356, 100), true],
		"C unloaded (640, 128)": [Vector2(640, 128), false],
		"D stripe land (48, 380)": [Vector2(48, 380), false],
		"D sea (150, 380)": [Vector2(150, 380), true],
		"D sea west of the stripe (12, 380)": [Vector2(12, 380), true],
	}
	_set_shader(true, 3.5)
	var img: Image = await _capture()
	var d = _terrain.data
	for name: String in points:
		var p: Vector2 = points[name][0]
		var want: bool = points[name][1]
		var cpu_hidden: bool = d.is_water_hidden(p, 0.0, 2.0, 0.0)
		var got := _water_at(img, p)
		_check("%s: water %s (want %s, CPU mirror hidden %s)" % [name, got, want, cpu_hidden],
				got == want and cpu_hidden == not want)
	# The stripe's edges, zoomed: the lattice read puts land at world x [32, 64). An unshifted read (pixel =
	# local) would put it at [8, 16), where both of these sea points sit.
	_cam.size = 80.0
	_cam.position = Vector3(40, 500, 380)
	var zoom: Image = await _capture()
	var edges := {"x 35 (inside)": [35.0, false], "x 61 (inside)": [61.0, false], "x 29 (sea)": [29.0, true],
			"x 12 (sea; land if unshifted)": [12.0, true], "x 67 (sea)": [67.0, true]}
	for name: String in edges:
		var got := _water_at(zoom, Vector2(edges[name][0], 380))
		_check("stripe %s: water %s" % [name, got], got == edges[name][1])
	_cam.size = 900.0
	_cam.position = Vector3(330, 500, 250)
	# Control: the check compiled out. The same frame draws water over land and the unknown region.
	_set_shader(false, 3.5)
	var img_c: Image = await _capture()
	var all_water := true
	for name: String in points:
		all_water = all_water and _water_at(img_c, points[name][0])
	_check("control: without WATER_TERRAIN_CHECK every point is water", all_water)
	_completed += 1


func _p2_shoreline() -> void:
	print("[P2] water reaches the shore on coarse cells:")
	# 20 m cells with no tessellation: vertices sit 20 m apart, so a vertex on A's side of x = 256 that is
	# removed takes triangles reaching up to 20 m into B.
	_ocean.vertex_spacing = 20.0
	_ocean.tessellation_level = 0
	_target.position = Vector3(256, 0, 128)
	_cam.size = 60.0
	_cam.position = Vector3(256, 500, 128)
	_set_shader(true, 3.5)
	var img: Image = await _capture()
	var gap := _gap_on_b_side(img)
	_check("reach 3.5: no missing water along B's first 20 m (missing samples %d)" % gap, gap == 0)
	_set_shader(true, 0.0)
	var img_c: Image = await _capture()
	var gap_c := _gap_on_b_side(img_c)
	_check("control: reach 0 opens a gap on B's side (missing samples %d)" % gap_c, gap_c > 0)
	_completed += 1


func _p3_globals_cleared() -> void:
	print("[P3] a terrain that leaves clears the globals:")
	_ocean.vertex_spacing = 1.0
	_ocean.tessellation_level = 2
	_target.position = Vector3(200, 0, 300)
	_cam.size = 900.0
	_cam.position = Vector3(330, 500, 250)
	_set_shader(true, 3.5)
	var before := _water_at(await _capture(), Vector2(150, 180))
	remove_child(_terrain)
	var after := _water_at(await _capture(), Vector2(150, 180))
	add_child(_terrain)
	_terrain.set_camera(_cam)
	var back := _water_at(await _capture(), Vector2(150, 180))
	_check("A land: hidden with the terrain in (water %s)" % before, not before)
	_check("terrain out of the tree: the check is inert, water shows (water %s)" % after, after)
	_check("terrain back: hidden again (water %s)" % back, not back)
	_completed += 1


func _p4_shipped_shaders() -> void:
	print("[P4] the shipped clipmap water shaders apply the check:")
	_target.position = Vector3(200, 0, 300)
	var dir := "res://addons/pasture_3d/extras/shaders/water/"
	for shader_name in ["water_ocean", "water_ocean_low", "water_lake_clipmap"]:
		var mat := ShaderMaterial.new()
		mat.shader = load(dir + shader_name + ".gdshader")
		_ocean.material = mat
		var img: Image = await _capture()
		var sea := _drawn_at(img, Vector2(450, 180))
		var land := _drawn_at(img, Vector2(150, 180))
		var unknown := _drawn_at(img, Vector2(640, 128))
		_check("%s: sea drawn %s, land drawn %s, unloaded drawn %s" % [shader_name, sea, land, unknown],
				sea and not land and not unknown)
	_completed += 1


# ---- helpers ----

## Anything but the clear colour: the shipped shaders are lit, so water is not white.
func _drawn_at(p_img: Image, p_xz: Vector2) -> bool:
	var c := p_img.get_pixelv(Vector2i(_cam.unproject_position(Vector3(p_xz.x, 0, p_xz.y))))
	return not (absf(c.r - 1) < 0.02 and c.g < 0.02 and absf(c.b - 1) < 0.02)

## Samples along z = 128 from x = 256.5 to 275.5, on B's sea: every one should be water.
func _gap_on_b_side(p_img: Image) -> int:
	var missing := 0
	for i in 20:
		if not _water_at(p_img, Vector2(256.5 + i, 128)):
			missing += 1
	return missing


func _water_at(p_img: Image, p_xz: Vector2) -> bool:
	var px := _cam.unproject_position(Vector3(p_xz.x, 0, p_xz.y))
	var c := p_img.get_pixelv(Vector2i(px))
	return c.r > 0.9 and c.g > 0.9 and c.b > 0.9


func _set_shader(p_check: bool, p_reach: float) -> void:
	var code := "shader_type spatial;\n"
	code += "render_mode unshaded, cull_disabled, depth_draw_never, skip_vertex_transform;\n"
	code += "#define WATER_CLIPMAP\n#define WATER_WAVE_COUNT 1\n"
	if p_check:
		code += "#define WATER_TERRAIN_CHECK\n#define WATER_TERRAIN_REACH %s\n" % String.num(p_reach, 2)
	for inc in ["water_common", "water_waves", "water_surface"]:
		code += "#include \"res://addons/pasture_3d/extras/shaders/water/%s.gdshaderinc\"\n" % inc
	code += "void fragment() { ALBEDO = vec3(1.0); }\n"
	var sh := Shader.new()
	sh.code = code
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("land_margin", 2.0)
	_ocean.material = mat


func _make_ocean() -> Pasture3DOcean:
	var manager := Pasture3DPoolManager.new()
	var profile := Pasture3DWaveProfile.new()
	profile.profile_name = &"flat"
	profile.wave_count = 1
	profile.amplitude = 0.0
	var profiles: Array[Pasture3DWaveProfile] = [profile]
	manager.profiles = profiles
	add_child(manager)
	var ocean := Pasture3DOcean.new()
	ocean.wave_profile = &"flat"
	ocean.render_layers = 1
	ocean.clipmap_target = _target
	add_child(ocean)
	return ocean


func _capture() -> Image:
	for i in 2:
		await get_tree().physics_frame
	await _frames(4)
	return get_viewport().get_texture().get_image()


func _fill(p_loc: Vector2i, p_h: float) -> void:
	var r = _terrain.data.get_region(p_loc)
	r.get_height_map().fill(Color(p_h, 0, 0, 1))
	r.set_modified(true)
	r.calc_height_range()


func _frames(p_n: int) -> void:
	for i in p_n:
		await get_tree().process_frame


func _check(p_name: String, p_ok: bool) -> void:
	print("  %s  %s" % ["ok  " if p_ok else "FAIL", p_name])
	if not p_ok:
		_fail += 1
