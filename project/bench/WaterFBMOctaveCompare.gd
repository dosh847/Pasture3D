extends Node
## Visual A/B of the fBm's fragment octave count: 40 (shipped) against 16 (and 12), same instant.
##
## WaterModelCostTiming put fBm 16 octaves 27% under the shipped FFT and fBm 40 level with it; whether
## 16 can ship depends on what the 24 dropped octaves were drawing. Per view this writes one sheet:
##
##   +------------------+------------------------+
##   | 40 octaves       | 16 octaves RESPACED    |
##   +------------------+------------------------+
##   | 16 octaves plain | |40 - respaced| x8     |
##   +------------------+------------------------+
##
## PLAIN cuts the series' tail, which is its SHORT waves: it went glassy near the camera. RESPACED spans
## the same wavelength range in 16 steps (frequency_mult 1.18^(39/15), amplitude_mult 0.82^(39/15)) and
## rescales `height` by the amplitude-sum ratio, so the slope it draws is the shipped one's in level.
## Printed: mean and p99 of |40 - plain| and |40 - respaced| per view. Clock frozen, manager paused, same camera and sun.
## Output: $BENCH_OUT or user://, files fbm_octaves_<view>.png. Windowed (any renderer with a window).

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const OCEAN_MAT := WATER_DIR + "M_water_ocean.tres"
const LAKE_MAT := WATER_DIR + "M_water_lake.tres"
const STRETCH := 39.0 / 15.0
const DIFF_GAIN := 8.0

# name, body, camera position, camera pitch (deg), camera yaw (deg)
const VIEWS := [
	["ocean_grazing", "ocean", Vector3(0, 3, 0), -6.0, 0.0],
	["ocean_mid", "ocean", Vector3(0, 9, 0), -14.0, 0.0],
	["ocean_down_close", "ocean", Vector3(0, 4, 0), -50.0, 0.0],
	["ocean_into_sun", "ocean", Vector3(0, 6, 0), -8.0, -50.0],
	["lake_mid", "lake", Vector3(0, 10, 60), -14.0, 0.0],
	["lake_down_close", "lake", Vector3(0, 3, 0), -45.0, 0.0],
]

var _out := ""


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(Vector2i(1280, 800))
	_out = OS.get_environment("BENCH_OUT")
	if _out == "":
		_out = "user://"
	if not _out.ends_with("/"):
		_out += "/"
	print("=== fBm fragment octaves: 40 vs 16 vs 12 ===")
	print("%s | %s" % [RenderingServer.get_video_adapter_name(), DisplayServer.window_get_size()])
	for v in VIEWS:
		var full := await _shoot(v, 40, false)
		var plain := await _shoot(v, 16, false)
		var spaced := await _shoot(v, 16, true)
		var dp := _diff_stats(full, plain)
		var ds := _diff_stats(full, spaced)
		var sheet := _sheet(full, spaced, plain)
		var path: String = _out + "fbm_octaves_%s.png" % v[0]
		sheet.save_png(path)
		print("    %-18s |40-plain16| mean %.4f p99 %.4f | |40-respaced16| mean %.4f p99 %.4f" % [
			v[0], dp.x, dp.y, ds.x, ds.y])
	get_tree().quit(0)


func _shoot(p_view: Array, p_octaves: int, p_respaced: bool) -> Image:
	var root := Node3D.new()
	add_child(root)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-38, 130, 0)
	root.add_child(sun)
	# A sky, so the water has something to reflect: without one only the sun's glint reads.
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = Sky.new()
	env.environment.sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	root.add_child(env)
	var m := Pasture3DPoolManager.new()
	m.name = "Pasture3DPoolManager"
	m.wave_model = Pasture3DPoolManager.WAVE_MODEL_FBM
	for name in ["ocean_default", "lake_calm"]:
		var fbm: Pasture3DWaterFBM = m.get_profile(name).fbm
		var sum_before := fbm.get_amplitude_sum(Pasture3DWaterFBM.SET_FRAGMENT)
		fbm.set("fragment/octaves", p_octaves)
		if p_respaced:
			fbm.set("fragment/frequency_mult", pow(float(fbm.get("fragment/frequency_mult")), STRETCH))
			fbm.set("fragment/amplitude_mult", pow(float(fbm.get("fragment/amplitude_mult")), STRETCH))
			fbm.set("fragment/speed_ramp", pow(float(fbm.get("fragment/speed_ramp")), STRETCH))
		# Same metres on the first octave: the sum is normalised by its amplitude sum.
		var sum_after := fbm.get_amplitude_sum(Pasture3DWaterFBM.SET_FRAGMENT)
		fbm.set("fragment/height", float(fbm.get("fragment/height")) * sum_after / sum_before)
	m.set_physics_process(false)
	m.paused = true
	root.add_child(m)
	m.sun_light = sun
	RenderingServer.global_shader_parameter_set("water_time", 7.5)
	if p_view[1] == "ocean":
		var ocean := Pasture3DOcean.new()
		ocean.material = load(OCEAN_MAT)
		ocean.wave_profile = &"ocean_default"
		ocean.render_layers = 1
		root.add_child(ocean)
	else:
		var pool := Pasture3DPool.new()
		pool.wave_profile = &"lake_calm"
		pool.material = load(LAKE_MAT)
		pool.underwater_enabled = false
		pool.curve = _square(150.0)
		root.add_child(pool)
	var cam := Camera3D.new()
	cam.current = true
	cam.position = p_view[2]
	cam.rotation_degrees = Vector3(p_view[3], p_view[4], 0)
	root.add_child(cam)
	for i in 4:
		await get_tree().physics_frame
	for i in 12:
		await RenderingServer.frame_post_draw
	RenderingServer.global_shader_parameter_set("water_time", 7.5)
	for i in 4:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	root.queue_free()
	for i in 3:
		await RenderingServer.frame_post_draw
	return img


## Top: a | b. Bottom: c | |a - b| x DIFF_GAIN.
func _sheet(p_a: Image, p_b: Image, p_c: Image) -> Image:
	var w := p_a.get_width()
	var h := p_a.get_height()
	var sheet := Image.create(w * 2, h * 2, false, Image.FORMAT_RGB8)
	sheet.blit_rect(p_a, Rect2i(0, 0, w, h), Vector2i(0, 0))
	sheet.blit_rect(p_b, Rect2i(0, 0, w, h), Vector2i(w, 0))
	var diff := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in h:
		for x in w:
			var a := p_a.get_pixel(x, y)
			var b := p_b.get_pixel(x, y)
			var v := minf((absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0 * DIFF_GAIN, 1.0)
			diff.set_pixel(x, y, Color(v, v, v))
	sheet.blit_rect(p_c, Rect2i(0, 0, w, h), Vector2i(0, h))
	sheet.blit_rect(diff, Rect2i(0, 0, w, h), Vector2i(w, h))
	# Thin separators so the panels read as panels.
	sheet.fill_rect(Rect2i(w - 1, 0, 2, h * 2), Color(1, 0.2, 0.2))
	sheet.fill_rect(Rect2i(0, h - 1, w * 2, 2), Color(1, 0.2, 0.2))
	return sheet


## (mean, p99) of the per-pixel |a - b|, averaged over channels.
func _diff_stats(p_a: Image, p_b: Image) -> Vector2:
	var vals := PackedFloat32Array()
	for y in range(0, p_a.get_height(), 2):
		for x in range(0, p_a.get_width(), 2):
			var a := p_a.get_pixel(x, y)
			var b := p_b.get_pixel(x, y)
			vals.append((absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0)
	var sum := 0.0
	for v in vals:
		sum += v
	vals.sort()
	return Vector2(sum / maxf(vals.size(), 1), vals[int(vals.size() * 0.99)])


func _square(p_r: float) -> Curve3D:
	var c := Curve3D.new()
	c.add_point(Vector3(-p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, p_r))
	c.add_point(Vector3(-p_r, 0, p_r))
	c.closed = true
	return c
