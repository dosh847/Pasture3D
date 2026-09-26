# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Bench — the GPU cost of the water terrain check (PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md §I, phase 4b).
#
# WaterBodiesPhase2Gate times the ocean with no terrain in the scene, where the check reads
# pasture3d_terrain.y == 0 and returns at once, so it cannot see this cost. Here the ocean sits over the demo
# terrain at a level that puts part of the view on land, and each tier is drawn two ways:
#   ON   the shipped material (WATER_TERRAIN_CHECK defined: five region-map + height fetch pairs per vertex)
#   OFF  the same material with a runtime copy of its shader that drops the #define
# The arms alternate over ROUNDS so drift lands on both. The spread between repeats of the SAME arm is the
# noise floor; an ON-OFF difference inside it is reported as "not resolved", not as a cost.
#
# Witness that ON measures a working check. The CPU mirror (get_water_terrain_state) finds both land (2)
# and water over terrain (3) at the chosen level, so the shader takes both branches. And the check is live
# on the GPU: with land_margin -1000 every vertex over terrain is "land", so ON must visibly remove the
# ocean there. (global_shader_parameter_get is editor-only, so the published globals cannot be read.)
# Control: the same margin on OFF changes nothing, so the difference is the check, not the uniform.
#
# WINDOWED (headless draws nothing). Reads res://demo/data; never saves.
# Run: Godot_v4.7-stable_win64_console.exe --path project res://bench/RegionWaterCheckBench.tscn
#      [-- --witness-only] skips the timing; [-- --dump] saves the witness frames to user://wcb_*.png
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const TIERS := [["ocean_high", WATER_DIR + "M_water_ocean.tres"], ["ocean_low", WATER_DIR + "M_water_ocean_low.tres"]]
const DEMO_DATA := "res://demo/data"
const DEFINE := "#define WATER_TERRAIN_CHECK"
const PITCHES := [-20.0, -50.0]
const ROUNDS := 4
const PERF_WARMUP := 60
const PERF_FRAMES := 150

var _fail := 0
var _done := 0
var _rows: Array[String] = []


func _ready() -> void:
	get_window().size = Vector2i(1280, 800)
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	await _run()
	print("")
	for r in _rows:
		print(r)
	print("=== WATER CHECK BENCH %s (%d failures, %d/%d criteria completed) ===" % [
		"PASS" if _fail == 0 and _done == 2 else "FAIL", _fail, _done, 2])
	get_tree().quit(0 if _fail == 0 and _done == 2 else 1)


func _run() -> void:
	var root := Node3D.new()
	add_child(root)
	var cam := _make_world(root)
	var terrain := Pasture3D.new()
	terrain.render_layers = 1
	root.add_child(terrain)
	terrain.data_directory = DEMO_DATA
	await _settle_physics(30)

	# The ground in view: a level that leaves ~40% of the terrain above water.
	var locs: Array = terrain.data.region_locations
	if locs.is_empty():
		_fail += 1
		print("!! demo data loaded no regions; nothing to measure over")
		return
	var world_rs: float = terrain.region_size * terrain.vertex_spacing
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for l in locs:
		lo = Vector2(minf(lo.x, l.x), minf(lo.y, l.y))
		hi = Vector2(maxf(hi.x, l.x + 1), maxf(hi.y, l.y + 1))
	lo *= world_rs
	hi *= world_rs
	var heights: Array[float] = []
	for i in 40:
		for j in 40:
			var p := Vector3(lerpf(lo.x, hi.x, (i + 0.5) / 40.0), 0, lerpf(lo.y, hi.y, (j + 0.5) / 40.0))
			var h: float = terrain.data.get_height(p)
			if not is_nan(h):
				heights.append(h)
	heights.sort()
	var level: float = heights[int(heights.size() * 0.6)]
	var centre := (lo + hi) * 0.5
	print("terrain: %d regions, extent %s..%s m, level %.1f m (60th percentile of %d samples)" % [
		locs.size(), str(lo), str(hi), level, heights.size()])

	# [W] witness: the check has real work at this level, and runs on the GPU.
	print("[W] the check sees land and water over terrain, and is live on the GPU:")
	var states := [0, 0, 0, 0]
	for i in 30:
		for j in 30:
			var xz := Vector2(lerpf(lo.x, hi.x, (i + 0.5) / 30.0), lerpf(lo.y, hi.y, (j + 0.5) / 30.0))
			states[terrain.data.get_water_terrain_state(xz, level, 2.0)] += 1
	print("    CPU mirror over the extent [none, unloaded, land, water] = %s" % str(states))
	cam.position = Vector3(centre.x, level + 80.0, hi.y + 40.0)
	cam.rotation_degrees = Vector3(-20.0, 0, 0)
	var wbase: ShaderMaterial = load(TIERS[0][1])
	var w_on: ShaderMaterial = wbase.duplicate()
	var w_off: ShaderMaterial = wbase.duplicate()
	var w_shader := Shader.new()
	w_shader.code = wbase.shader.code.replace(DEFINE, "// (bench) check removed")
	w_off.shader = w_shader
	var wocean := _make_ocean(root, w_on)
	wocean.position.y = level
	await _settle_physics(20)
	var manager: Node = root.get_node("Pasture3DPoolManager")
	manager.set_physics_process(false)
	RenderingServer.global_shader_parameter_set("water_time", 37.5)
	var imgs := {}
	for arm in [["on", w_on, 2.0], ["on_all", w_on, -1000.0], ["off", w_off, 2.0], ["off_all", w_off, -1000.0]]:
		# A fresh material per arm: Pasture3DOcean.set_material ignores the same object, so a uniform edited
		# on the material it already holds never reaches its private duplicate.
		var m: ShaderMaterial = arm[1].duplicate()
		m.set_shader_parameter("land_margin", arm[2])
		wocean.material = m
		await _settle_physics(5)
		imgs[arm[0]] = get_viewport().get_texture().get_image()
		if OS.get_cmdline_user_args().has("--dump"):
			var png := OS.get_user_data_dir().path_join("wcb_%s.png" % arm[0])
			imgs[arm[0]].save_png(png)
			print("    saved ", png)
	var d_on := _mean_delta(imgs["on"], imgs["on_all"])
	var d_off := _mean_delta(imgs["off"], imgs["off_all"])
	print("    land_margin 2 -> -1000: ON image changes by %.5f, OFF (control) by %.5f" % [d_on, d_off])
	if d_on < 0.01:
		_fail += 1
		print("    !! ON does not remove the ocean over land; the check is not live, so ON measures OFF")
	if d_off > 0.001:
		_fail += 1
		print("    !! OFF changed with the margin; the witness is measuring something besides the check")
	wocean.queue_free()
	manager.queue_free()
	await _settle()
	if states[2] < 90 or states[3] < 90:
		_fail += 1
		print("    !! the level does not split the ground; the check would take one branch only")
	_done += 1

	# [T] timing.
	if OS.get_cmdline_user_args().has("--witness-only"):
		print("[T] SKIPPED (--witness-only)")
		root.queue_free()
		return
	print("[T] ON vs OFF, alternating, %d rounds:" % ROUNDS)
	for pitch in PITCHES:
		cam.position = Vector3(centre.x, level + 80.0, hi.y + 40.0)
		cam.rotation_degrees = Vector3(pitch, 0, 0)
		for tier in TIERS:
			var base: ShaderMaterial = load(tier[1])
			if not base.shader.code.contains(DEFINE):
				_fail += 1
				print("    !! %s does not define the check; ON is not the check" % tier[0])
				continue
			var on_mat: ShaderMaterial = base.duplicate()
			var off_mat: ShaderMaterial = base.duplicate()
			var off_shader := Shader.new()
			off_shader.code = base.shader.code.replace(DEFINE, "// (bench) check removed")
			off_mat.shader = off_shader
			var ocean := _make_ocean(root, on_mat)
			ocean.position.y = level
			await _settle_physics(20)
			var on_s: Array[float] = []
			var off_s: Array[float] = []
			for arm_mat in [on_mat, off_mat]: # one discarded pass each: first-draw pipeline stall
				ocean.material = arm_mat
				await _settle_physics(5)
				await _measure_ms()
			for r in ROUNDS:
				ocean.material = on_mat
				await _settle_physics(5)
				on_s.append(await _measure_ms())
				ocean.material = off_mat
				await _settle_physics(5)
				off_s.append(await _measure_ms())
			ocean.queue_free()
			root.get_node("Pasture3DPoolManager").queue_free()
			await _settle()
			var on_m := _median(on_s)
			var off_m := _median(off_s)
			var noise := maxf(on_s.max() - on_s.min(), off_s.max() - off_s.min())
			var d := on_m - off_m
			var verdict := "resolved" if absf(d) > noise else "NOT resolved (inside the A/A spread)"
			var row := "    %-10s pitch %3d: ON %.4f ms  OFF %.4f ms  delta %+.4f ms (%+.1f%%)  A/A spread %.4f -> %s" % [
				tier[0], int(pitch), on_m, off_m, d, 100.0 * d / maxf(off_m, 1e-6), noise, verdict]
			print(row)
			print("        ON %s  OFF %s" % [str(on_s), str(off_s)])
			_rows.append(row)
	_done += 1
	root.queue_free()


func _make_world(p_root: Node3D) -> Camera3D:
	var env := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	p_root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-38, 130, 0)
	sun.shadow_enabled = false
	p_root.add_child(sun)
	var cam := Camera3D.new()
	cam.far = 20000.0
	cam.cull_mask = 1
	cam.current = true
	p_root.add_child(cam)
	return cam


# WaterBodiesPhase2Gate's ocean: the same wave profile and manager.
func _make_ocean(p_root: Node3D, p_material: Material) -> Node3D:
	var manager := Pasture3DPoolManager.new()
	manager.name = "Pasture3DPoolManager"
	manager.loop_period = 120.0
	var profile := Pasture3DWaveProfile.new()
	profile.profile_name = &"ocean_default"
	profile.wave_count = 8
	profile.direction_deg = 20.0
	profile.spread_deg = 28.0
	profile.amplitude = 1.6
	profile.length_max = 137.0
	profile.steepness = 0.35
	var profiles: Array[Pasture3DWaveProfile] = [profile]
	manager.profiles = profiles
	p_root.add_child(manager)
	manager.sun_light = p_root.get_node("Sun")
	var ocean := Pasture3DOcean.new()
	ocean.material = p_material
	ocean.wave_profile = &"ocean_default"
	ocean.render_layers = 1
	p_root.add_child(ocean)
	return ocean


func _measure_ms() -> float:
	var vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	for i in PERF_WARMUP:
		await RenderingServer.frame_post_draw
	var samples: Array[float] = []
	for i in PERF_FRAMES:
		await RenderingServer.frame_post_draw
		var ms := RenderingServer.viewport_get_measured_render_time_gpu(vp)
		if ms > 0.0:
			samples.append(ms)
	return _median(samples)


func _mean_delta(a: Image, b: Image) -> float:
	var sa := a.duplicate() as Image
	var sb := b.duplicate() as Image
	sa.resize(160, 100, Image.INTERPOLATE_BILINEAR)
	sb.resize(160, 100, Image.INTERPOLATE_BILINEAR)
	var sum := 0.0
	for y in 100:
		for x in 160:
			var ca := sa.get_pixel(x, y)
			var cb := sb.get_pixel(x, y)
			sum += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
	return sum / 16000.0


func _median(p: Array[float]) -> float:
	if p.is_empty():
		return 0.0
	var s := p.duplicate()
	s.sort()
	return s[s.size() / 2]


func _settle() -> void:
	for i in 10:
		await RenderingServer.frame_post_draw


func _settle_physics(p_n: int) -> void:
	for i in p_n:
		await get_tree().physics_frame
	await _settle()
