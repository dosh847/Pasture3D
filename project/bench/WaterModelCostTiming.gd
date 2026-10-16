extends Node
## FFT against fBm, ALL of each one's GPU cost (FFT spec §6.4, after WaterModelBranchTiming).
##
## WaterModelBranchTiming compared draws only: the viewport timer does not see the FFT's compute, which
## Pasture3DWaterFFT dispatches on the render thread from the manager's NOTIFICATION_PROCESS. Here a node
## that processes BEFORE the manager queues a "begin" GPU timestamp onto the render thread and one that
## processes AFTER it queues "end"; call_on_render_thread is FIFO, so the dispatch sits between them.
##
##   FFT total  = viewport draw + (end - begin), at fft_resolution 128 / 256 (shipped) / 512 / 1024
##   fBm total  = viewport draw, at 40 (shipped) / 16 / 12 fragment octaves
##
## Instrument checks:
##   C1. the compute reading scales with resolution (1024 > 512 > 256 > 128), so it is the FFT
##   C2. CONTROL: on the fBm arms nothing is dispatched between the stamps, so begin..end reads ~0
##   C3. every arm's draw costs more than the frame with the water hidden
##
## Windowed Forward+ only. TIMING: run only with the user's go-ahead.

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const OCEAN_MAT := WATER_DIR + "M_water_ocean.tres"
const LAKE_MAT := WATER_DIR + "M_water_lake.tres"
const PASSES := 6
const WARM_FRAMES := 30
const SAMPLE_FRAMES := 90
const TS_BEGIN := "p3d_water_cost_begin"
const TS_END := "p3d_water_cost_end"

var _fail := 0
var _completed := 0
var _rd: RenderingDevice


class Stamp extends Node:
	var label := ""
	func _process(_dt: float) -> void:
		var rd := RenderingServer.get_rendering_device()
		var name := label
		RenderingServer.call_on_render_thread(func(): rd.capture_timestamp(name))


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 1200.0
	bail.one_shot = true
	bail.timeout.connect(func():
		push_error("timing timed out")
		get_tree().quit(2))
	add_child(bail)
	bail.start()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(Vector2i(1280, 800))
	print("=== Pasture3D water — FFT vs fBm, full GPU cost ===")
	print("Godot %s | %s | %s" % [Engine.get_version_info().string,
		RenderingServer.get_video_adapter_name(), DisplayServer.window_get_size()])
	_rd = RenderingServer.get_rendering_device()
	if _rd == null or not Pasture3DWaterFFT.is_supported():
		print("SKIPPED: no RenderingDevice")
		get_tree().quit(0)
		return
	var begin := Stamp.new()
	begin.label = TS_BEGIN
	begin.process_priority = -100000
	add_child(begin)
	var end := Stamp.new()
	end.label = TS_END
	end.process_priority = 100000
	add_child(end)
	await _run()
	var verdict := "PASS" if _fail == 0 and _completed == 1 else "FAIL"
	print("")
	print("=== MODEL COST TIMING %s (%d failures) ===" % [verdict, _fail])
	get_tree().quit(0 if verdict == "PASS" else 1)


func _run() -> void:
	var arms := []
	for body in ["ocean", "lake"]:
		for r in [128, 256, 512, 1024]:
			arms.append([body, "fft", r])
		for o in [40, 16, 12]:
			arms.append([body, "fbm", o])
		arms.append([body, "hidden", 0])
	var draw := {}
	var comp := {}
	for a in arms:
		draw[a] = []
		comp[a] = []
	for pass_i in PASSES:
		var order := arms.duplicate()
		if pass_i % 2 == 1:
			order.reverse()
		for a in order:
			var r: Vector2 = await _time(a)
			if pass_i > 0:
				draw[a].append(r.x)
				comp[a].append(r.y)

	print("")
	print("GPU ms, median of %d passes (draw = viewport timer, compute = FFT stamps):" % (PASSES - 1))
	print("    %-6s %-14s %8s %8s %8s   %s" % ["body", "arm", "draw", "compute", "TOTAL", "draw passes"])
	var med := {}
	var worst := 0.0
	for a in arms:
		var d: Array = draw[a]
		var c: Array = comp[a]
		d.sort()
		c.sort()
		var dm: float = d[d.size() / 2]
		var cm: float = c[c.size() / 2]
		med[a] = Vector2(dm, cm)
		worst = maxf(worst, (d[-1] - d[0]) / maxf(dm, 1e-9))
		var label: String = "FFT N=%d" % a[2] if a[1] == "fft" else ("fBm %d oct" % a[2] if a[1] == "fbm" else "water hidden")
		var shipped: bool = (a[1] == "fft" and a[2] == 256) or (a[1] == "fbm" and a[2] == 40)
		print("    %-6s %-14s %8.4f %8.4f %8.4f   %s%s" % [a[0], label, dm, cm, dm + cm, _fmt(d),
			"   <- shipped" if shipped else ""])
	print("    worst pass-to-pass spread of the draw %.1f%%" % (worst * 100.0))

	print("")
	for body in ["ocean", "lake"]:
		var c128: float = med[[body, "fft", 128]].y
		var c256: float = med[[body, "fft", 256]].y
		var c512: float = med[[body, "fft", 512]].y
		var c1024: float = med[[body, "fft", 1024]].y
		print("[C1] %s compute scales with N: %.4f < %.4f < %.4f < %.4f" % [body, c128, c256, c512, c1024])
		if not (c128 < c256 and c256 < c512 and c512 < c1024) or c256 <= 0.0:
			_fail += 1
			print("    !! the stamps are not bracketing the FFT")
		var fbm_c: float = med[[body, "fbm", 40]].y
		print("[C2] %s CONTROL, fBm arm begin..end %.4f ms (want ~0, well under the FFT's %.4f)" % [body, fbm_c, c256])
		if fbm_c > c256 * 0.25:
			_fail += 1
			print("    !! the stamps read time with no FFT between them, so they bracket something else")
		var hidden: float = med[[body, "hidden", 0]].x
		for a in arms:
			if a[0] == body and a[1] != "hidden" and med[a].x <= hidden * 1.02:
				_fail += 1
				print("    !! [C3] %s draws no more than the hidden frame" % [a])
	_completed += 1


## Returns (median draw ms, median compute ms).
func _time(p_arm: Array) -> Vector2:
	var w := await _build(p_arm)
	for i in WARM_FRAMES:
		await RenderingServer.frame_post_draw
	var vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var d: Array[float] = []
	var c: Array[float] = []
	for i in SAMPLE_FRAMES:
		await RenderingServer.frame_post_draw
		d.append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
		c.append(_stamp_ms())
	RenderingServer.viewport_set_measure_render_time(vp, false)
	d.sort()
	c.sort()
	w.queue_free()
	for i in 3:
		await RenderingServer.frame_post_draw
	return Vector2(d[d.size() / 2], c[c.size() / 2])


## begin..end of the last frame whose timestamps have resolved, in ms (the driver reports ns).
func _stamp_ms() -> float:
	var b := -1
	var e := -1
	for i in _rd.get_captured_timestamps_count():
		var n := _rd.get_captured_timestamp_name(i)
		if n == TS_BEGIN:
			b = i
		elif n == TS_END:
			e = i
	if b < 0 or e < 0:
		return 0.0
	return float(_rd.get_captured_timestamp_gpu_time(e) - _rd.get_captured_timestamp_gpu_time(b)) / 1.0e6


func _build(p_arm: Array) -> Node3D:
	var body: String = p_arm[0]
	var kind: String = p_arm[1]
	var root := Node3D.new()
	add_child(root)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-38, 130, 0)
	root.add_child(sun)
	var m := Pasture3DPoolManager.new()
	m.name = "Pasture3DPoolManager"
	m.wave_model = Pasture3DPoolManager.WAVE_MODEL_FBM if kind == "fbm" else Pasture3DPoolManager.WAVE_MODEL_FFT
	if kind == "fft":
		m.fft_resolution = p_arm[2]
	if kind == "fbm":
		for name in ["ocean_default", "lake_calm"]:
			m.get_profile(name).fbm.set("fragment/octaves", p_arm[2])
	m.set_physics_process(false)
	root.add_child(m)
	m.sun_light = sun

	var cam := Camera3D.new()
	cam.current = true
	if body == "ocean":
		var ocean := Pasture3DOcean.new()
		ocean.material = load(OCEAN_MAT)
		ocean.wave_profile = &"ocean_default"
		ocean.render_layers = 1
		ocean.enabled = kind != "hidden"
		root.add_child(ocean)
		cam.position = Vector3(0, 9, 0)
	else:
		var pool := Pasture3DPool.new()
		pool.wave_profile = &"lake_calm"
		pool.material = load(LAKE_MAT)
		pool.underwater_enabled = false
		pool.curve = _square(150.0)
		pool.visible = kind != "hidden"
		root.add_child(pool)
		cam.position = Vector3(0, 10, 60)
	cam.rotation_degrees = Vector3(-14, 0, 0)
	root.add_child(cam)
	for i in 4:
		await get_tree().physics_frame
	for i in 8:
		await RenderingServer.frame_post_draw
	return root


func _square(p_r: float) -> Curve3D:
	var c := Curve3D.new()
	c.add_point(Vector3(-p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, -p_r))
	c.add_point(Vector3(p_r, 0, p_r))
	c.add_point(Vector3(-p_r, 0, p_r))
	c.closed = true
	return c


func _fmt(p_s: Array) -> String:
	var parts := []
	for v in p_s:
		parts.append("%.3f" % v)
	return "[" + ", ".join(parts) + "]"
