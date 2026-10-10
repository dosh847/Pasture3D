extends Node
## What the runtime wave-model switch costs (FFT spec §3, deferred from Phase 4).
##
## `_wave_model` is a UNIFORM branch so a manager can fall back from FFT to fBm without swapping the
## shader on every cached material. The alternative is two static variants. This times the shipped
## material against the same shader with WATER_STATIC_MODEL defined, which turns `_wave_model` into a
## const and lets the compiler fold the branch -- exactly the code the twin-variant route would ship.
##
## Arms: {ocean (clipmap, water_ocean), lake (meshed pool, water_body)} x {FFT, fBm} x {uniform, folded},
## each through the real manager upload. INTERLEAVED, one warm-up pass discarded (shader compilation),
## median of the remaining passes, spread printed (WaterBodiesPhase7Gate [E]'s lesson).
##
## Correctness of the instrument, asserted before any number is believed:
##   I. the folded variant draws the same frame as the uniform one (else it is not the same work)
##      CONTROL: the folded FFT and folded fBm frames differ (else the fold selects nothing)
##   T. the water is visible to the timer: every arm costs more than the same frame with it hidden
##
## Windowed Forward+ only. TIMING: run only with the user's go-ahead (another engine shares the GPU).

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const OCEAN_MAT := WATER_DIR + "M_water_ocean.tres"
const LAKE_MAT := WATER_DIR + "M_water_lake.tres"
const MODEL_FFT := 1
const MODEL_FBM := 2
const PASSES := 6
const WARM_FRAMES := 30
const SAMPLE_FRAMES := 90

var _fail := 0
var _completed := 0
var _folded_shaders := {}


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 900.0
	bail.one_shot = true
	bail.timeout.connect(func():
		push_error("timing timed out")
		get_tree().quit(2))
	add_child(bail)
	bail.start()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(Vector2i(1280, 800))
	print("=== Pasture3D water — uniform wave-model branch cost ===")
	print("Godot %s | %s | %s" % [Engine.get_version_info().string,
		RenderingServer.get_video_adapter_name(), DisplayServer.window_get_size()])
	if not Pasture3DWaterFFT.is_supported():
		print("SKIPPED: no RenderingDevice, so there is no FFT arm to time")
		get_tree().quit(0)
		return
	await _criterion_i()
	await _criterion_timing()
	var verdict := "PASS" if _fail == 0 and _completed == 2 else "FAIL"
	print("")
	print("=== MODEL BRANCH TIMING %s (%d failures, %d/2 criteria reported) ===" % [verdict, _fail, _completed])
	get_tree().quit(0 if verdict == "PASS" else 1)


# ---- I: the folded variant is the same work --------------------------------------------------

func _criterion_i() -> void:
	print("")
	print("[I] the folded variant draws what the uniform one draws:")
	var frames := {}
	for body in ["ocean", "lake"]:
		for model in [MODEL_FFT, MODEL_FBM]:
			for folded in [false, true]:
				var w := await _build(body, model, folded)
				frames[[body, model, folded]] = get_viewport().get_texture().get_image()
				await _teardown(w)
	for body in ["ocean", "lake"]:
		for model in [MODEL_FFT, MODEL_FBM]:
			var d := _diff(frames[[body, model, false]], frames[[body, model, true]])
			print("    %-5s %-3s uniform vs folded: mean abs diff %.5f (want ~0)" % [body, _name(model), d])
			if d > 0.002:
				_fail += 1
				print("    !! the folded shader does not draw the same frame, so it is not the same work")
		var c := _diff(frames[[body, MODEL_FFT, true]], frames[[body, MODEL_FBM, true]])
		print("    %-5s CONTROL, folded FFT vs folded fBm: %.5f (want clearly > 0)" % [body, c])
		if c < 0.005:
			_fail += 1
			print("    !! the fold selects nothing: both folded models draw the same frame")
	_completed += 1


# ---- timing ----------------------------------------------------------------------------------

func _criterion_timing() -> void:
	print("")
	print("[T] GPU frame time, uniform branch vs folded (%d passes, first discarded):" % PASSES)
	var rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var arms := []
	for body in ["ocean", "lake"]:
		for model in [MODEL_FFT, MODEL_FBM]:
			arms.append([body, model, false])
			arms.append([body, model, true])
		arms.append([body, MODEL_FFT, null]) # the same frame with the water hidden
	var samples := {}
	for a in arms:
		samples[a] = []
	for pass_i in PASSES:
		# Alternate the order so drift and clock state land on every arm alike.
		var order := arms.duplicate()
		if pass_i % 2 == 1:
			order.reverse()
		for a in order:
			var ms := await _time(a[0], a[1], a[2])
			if pass_i > 0:
				samples[a].append(ms)
	RenderingServer.viewport_set_measure_render_time(rid, false)

	var med := {}
	var worst_spread := 0.0
	for a in arms:
		var s: Array = samples[a]
		s.sort()
		med[a] = s[s.size() / 2]
		worst_spread = maxf(worst_spread, (s[-1] - s[0]) / maxf(med[a], 1e-9))
	var zero := false
	for body in ["ocean", "lake"]:
		var hidden: float = med[[body, MODEL_FFT, null]]
		print("    %-5s water hidden          %.4f ms  %s" % [body, hidden, _fmt(samples[[body, MODEL_FFT, null]])])
		for model in [MODEL_FFT, MODEL_FBM]:
			var u: float = med[[body, model, false]]
			var f: float = med[[body, model, true]]
			if u <= 0.0 or f <= 0.0:
				zero = true
			print("    %-5s %-3s uniform  %.4f ms  %s" % [body, _name(model), u, _fmt(samples[[body, model, false]])])
			print("    %-5s %-3s folded   %.4f ms  %s" % [body, _name(model), f, _fmt(samples[[body, model, true]])])
			print("    %-5s %-3s branch cost %+.4f ms = %+.1f%% of the frame, %+.1f%% of the water (frame minus hidden)" % [
				body, _name(model), u - f, (u / f - 1.0) * 100.0, (u - f) / maxf(f - hidden, 1e-9) * 100.0])
			if f <= hidden * 1.02:
				_fail += 1
				print("    !! %s %s costs no more than the hidden frame: the timer is not seeing the water" % [body, _name(model)])
	print("    worst pass-to-pass spread %.1f%%" % (worst_spread * 100.0))
	if zero:
		_fail += 1
		print("    !! GPU timing read zero: measured nothing, not 'measured free'")
	_completed += 1


func _time(p_body: String, p_model: int, p_folded) -> float:
	var w := await _build(p_body, p_model, p_folded == true, p_folded == null)
	for i in WARM_FRAMES:
		await RenderingServer.frame_post_draw
	var rid := get_viewport().get_viewport_rid()
	var s: Array[float] = []
	for i in SAMPLE_FRAMES:
		await RenderingServer.frame_post_draw
		s.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	s.sort()
	await _teardown(w)
	return s[s.size() / 2]


# ---- fixtures --------------------------------------------------------------------------------

func _build(p_body: String, p_model: int, p_folded: bool, p_hidden: bool = false) -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-38, 130, 0)
	root.add_child(sun)
	var m := Pasture3DPoolManager.new()
	m.name = "Pasture3DPoolManager"
	m.wave_model = Pasture3DPoolManager.WAVE_MODEL_FFT if p_model == MODEL_FFT else Pasture3DPoolManager.WAVE_MODEL_FBM
	# Frozen, so I compares frames rather than clocks. The FFT still dispatches every frame (dt 0),
	# which is the same work on every arm.
	m.set_physics_process(false)
	m.paused = true
	root.add_child(m)
	m.sun_light = sun
	RenderingServer.global_shader_parameter_set("water_time", 7.5)

	var preset := OCEAN_MAT if p_body == "ocean" else LAKE_MAT
	var mat: ShaderMaterial = load(preset)
	if p_folded:
		mat = mat.duplicate()
		mat.shader = _folded(preset, p_model)
	var cam := Camera3D.new()
	cam.current = true
	if p_body == "ocean":
		var ocean := Pasture3DOcean.new()
		ocean.material = mat
		ocean.wave_profile = &"ocean_default"
		ocean.render_layers = 1
		ocean.enabled = not p_hidden
		root.add_child(ocean)
		cam.position = Vector3(0, 9, 0)
		cam.rotation_degrees = Vector3(-14, 0, 0)
	else:
		var pool := Pasture3DPool.new()
		pool.wave_profile = &"lake_calm"
		pool.material = mat
		pool.underwater_enabled = false
		pool.curve = _square(150.0)
		pool.visible = not p_hidden
		root.add_child(pool)
		cam.position = Vector3(0, 10, 60)
		cam.rotation_degrees = Vector3(-14, 0, 0)
	root.add_child(cam)
	for i in 4:
		await get_tree().physics_frame
	for i in 8:
		await RenderingServer.frame_post_draw
	return root


func _teardown(p_root: Node3D) -> void:
	p_root.queue_free()
	for i in 3:
		await RenderingServer.frame_post_draw


## The preset's own shader with the branch folded. Cached: one compile per (preset, model).
func _folded(p_preset: String, p_model: int) -> Shader:
	var key := "%s|%d" % [p_preset, p_model]
	if not _folded_shaders.has(key):
		var src: String = (load(p_preset) as ShaderMaterial).shader.code
		var nl := src.find("\n")
		var sh := Shader.new()
		sh.code = src.substr(0, nl + 1) + "#define WATER_STATIC_MODEL %d\n" % p_model + src.substr(nl + 1)
		_folded_shaders[key] = sh
	return _folded_shaders[key]


func _square(p_r: float) -> Curve3D:
	var c := Curve3D.new()
	c.add_point(Vector3(-p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, p_r))
	c.add_point(Vector3(-p_r, 0, p_r))
	c.closed = true
	return c


func _diff(p_a: Image, p_b: Image) -> float:
	var total := 0.0
	var n := 0
	for y in range(0, p_a.get_height(), 4):
		for x in range(0, p_a.get_width(), 4):
			var a := p_a.get_pixel(x, y)
			var b := p_b.get_pixel(x, y)
			total += (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0
			n += 1
	return total / maxf(n, 1)


func _name(p_model: int) -> String:
	return "FFT" if p_model == MODEL_FFT else "fBm"


func _fmt(p_s: Array) -> String:
	var parts := []
	for v in p_s:
		parts.append("%.3f" % v)
	return "[" + ", ".join(parts) + "]"
