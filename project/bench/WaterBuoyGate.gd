extends Node
# Phase 5 of PASTURE3D_WATER_FFT_SPEC.md: the CPU's surface, which every buoy and get_water_height() reads.
#
# Three runs, as WaterFBMGate:
#   windowed Forward+      Godot_v4.7-stable_win64_console.exe --path project res://bench/WaterBuoyGate.tscn
#   headless               ... --headless --path project res://bench/WaterBuoyGate.tscn
#   windowed Compatibility ... --rendering-method gl_compatibility --path project res://bench/WaterBuoyGate.tscn
#
#   [H] fBm transcription (every mode). Pasture3DWaterFBM.evaluate() against _fbm(), water_fbm()'s arithmetic
#       in GDScript double, over 200 points within H_RANGE metres and seconds of the origin: height and
#       slope within H_TOL x height. Small on purpose: evaluate() is float32, as the shader is, and its
#       distance from the double grows with the phase (reported over +-300 m and the whole period -- a
#       precision fact the GPU shares, not a transcription error). The loop: evaluate() at t = 0 and at
#       t = period agree within H_LOOP x height; control, the second instant at 97 s misses. Then the
#       routing: a profile on an FBM manager answers get_height_at() with exactly evaluate()'s vertex set and
#       solve_domain() with its input. Controls: the oracle without drag misses by over H_CTRL x height; the
#       same profile with its fbm removed answers differently (flat).
#   [B] fBm buoy against the drawn surface (Forward+, Compatibility). A paused manager in the tree, the sheet
#       of WaterFBMGate seen through WATER_DEBUG_SURFACE: each pixel's height against the manager's
#       evaluate_height(solve_domain(xz)) -- the call path of every body. Relative RMS under B_TOL. Control:
#       the CPU a quarter second early misses by over B_CTRL.
#   [R] FFT readback runs on demand and lags at most R_LAG updates (Forward+). A running manager with two
#       FFT profiles, both drawn. One is queried every frame: its readbacks land, and update_count minus
#       the readback's update stays within R_LAG. Controls: the other, never queried, reads nothing back;
#       and the queried one stops reading back once the queries have stopped for READBACK_KEEPALIVE updates.
#   [S] The readback is the frame it says it is (Forward+). Paused, the CPU's displacement at 64 points
#       equals a sum over a synchronous read_layer() of the same textures (decoded here, independently)
#       within S_TOL. Control, the stale buffer: those CPU answers, kept, against a synchronous read taken
#       after the clock ran on for a second, miss by over S_CTRL metres.
#   [A] FFT buoy against the drawn surface (Forward+). Paused, the sheet at mip 0 everywhere: each pixel's
#       height against evaluate_height(solve_domain(xz)). Relative RMS under A_TOL. Controls: the stale
#       buffer (answers kept from a second earlier) misses by over A_CTRL. Reported, not asserted: the
#       error without the horizontal solve.
#
# Every criterion counts its completions; one that throws before asserting reports as missing.

const SHADER := "res://addons/pasture_3d/extras/shaders/water/water_body.gdshader"
const INC := "res://addons/pasture_3d/extras/shaders/water/"
const PIXELS := 64
const VIEW := 64.0
const SPACING := 0.25
const PERIOD := 120.0
const HEIGHT := 2.0
const LAMBDA0 := 16.0
const H_TOL := 1e-3
const H_RANGE := 10.0
const H_LOOP := 0.01
const H_CTRL := 0.1
const B_TOL := 0.03
const B_TOL_LDR := 0.12
const B_CTRL := 0.3
const R_LAG := 3
const S_TOL := 1e-5
const S_CTRL := 0.05
const A_TOL := 0.02
const A_CTRL := 0.3
const FFT_RES := 128

var _fail := 0
var _seen: Dictionary = {}
var _criteria: PackedStringArray = []
var _mode := ""
var _vp: SubViewport
var _cam: Camera3D
var _sheet: MeshInstance3D
var _debug_shader: Shader


func _ready() -> void:
	var headless := DisplayServer.get_name() == "headless"
	var device := RenderingServer.get_rendering_device() != null
	if headless:
		_mode = "headless"
		_criteria = ["H"]
	elif not device:
		_mode = "compatibility"
		_criteria = ["H", "B"]
	else:
		_mode = "forward+"
		_criteria = ["H", "B", "R", "S", "A"]
	print("=== WaterBuoyGate (%s) ===" % _mode)
	_criterion_h()
	if not headless:
		_build_view()
		await _criterion_b()
		if _criteria.has("R"):
			await _criterion_r()
		if _criteria.has("S"):
			await _criteria_s_a()
	var missing := 0
	for c in _criteria:
		if not _seen.has(c):
			missing += 1
			print("  FAIL %s: never reported" % c)
	var ok := _fail == 0 and missing == 0
	print("=== WATER BUOY %s (%s: %d failures, %d/%d criteria reported) ===" % [
			"PASS" if ok else "FAIL", _mode, _fail + missing, _criteria.size() - missing, _criteria.size()])
	get_tree().quit(0 if ok else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_fail += 1


func _fbm_profile(p_name: StringName) -> Pasture3DWaveProfile:
	var p := Pasture3DWaveProfile.new()
	p.profile_name = p_name
	var fbm := Pasture3DWaterFBM.new()
	for s in 2:
		fbm.set_knob(s, &"frequency", TAU / LAMBDA0)
		fbm.set_knob(s, &"seed", 0.4)
		fbm.set_knob(s, &"speed", 2.0)
		fbm.set_knob(s, &"height", HEIGHT)
	p.fbm = fbm
	return p


func _fft_profile(p_name: StringName) -> Pasture3DWaveProfile:
	var p := Pasture3DWaveProfile.new()
	p.profile_name = p_name
	p.fft = Pasture3DWaterFFT.new()
	return p


func _make_manager(p_model: int, p_profiles: Array) -> Pasture3DPoolManager:
	var m := Pasture3DPoolManager.new()
	m.loop_period = PERIOD
	m.fft_resolution = FFT_RES
	m.profiles = p_profiles
	m.wave_model = p_model
	return m


# water_fbm() in water_waves.gdshaderinc, in double. p_drag is the control's break.
func _fbm(p_dom: Vector2, p: PackedVector4Array, p_time: float, p_period: float, p_drag := true) -> Vector3:
	var seed := p[0].x
	var k0 := maxf(p[0].z, 1e-6)
	var f := 1.0
	var a := p[1].x
	var speed := p[1].z
	var q := p_dom * k0
	var h := 0.0
	var n := Vector2.ZERO
	for i in int(p[3].z):
		var d := Vector2(cos(seed), sin(seed))
		var period := maxf(p_period, 1e-3)
		var rate := roundf(speed * period / TAU) * (TAU / period)
		var x := d.dot(q) * f + p_time * rate
		var wave := a * exp(p[2].z * sin(x) - p[2].w)
		var dwave := p[2].z * wave * cos(x)
		h += wave - a * p[3].y
		n += (f * dwave) * d
		if p_drag:
			q -= d * (dwave * a * p[2].x)
		f *= p[0].w
		a *= p[1].y
		speed *= p[1].w
		seed += p[0].y
	var scale := p[2].y / maxf(p[3].x, 1e-6)
	return Vector3(h * scale, n.x * scale * k0, n.y * scale * k0)


func _criterion_h() -> void:
	var profile := _fbm_profile(&"buoy_h")
	var fbm := profile.fbm
	var pack := fbm.get_shader_pack(Pasture3DWaterFBM.SET_VERTEX)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var err := 0.0
	var ctrl := 0.0
	var far := 0.0
	var loop := 0.0
	var loop_ctrl := 0.0
	for i in 200:
		var dom := Vector2(rng.randf_range(-H_RANGE, H_RANGE), rng.randf_range(-H_RANGE, H_RANGE))
		var t := rng.randf_range(0.0, H_RANGE)
		var got: Vector3 = fbm.evaluate(Pasture3DWaterFBM.SET_VERTEX, dom, t, PERIOD)
		var want := _fbm(dom, pack, t, PERIOD)
		var nodrag := _fbm(dom, pack, t, PERIOD, false)
		err = maxf(err, (got - want).abs()[(got - want).abs().max_axis_index()])
		ctrl = maxf(ctrl, absf(nodrag.x - want.x))
		var far_dom := Vector2(rng.randf_range(-300.0, 300.0), rng.randf_range(-300.0, 300.0))
		var far_t := rng.randf_range(0.0, PERIOD)
		far = maxf(far, absf(fbm.evaluate(Pasture3DWaterFBM.SET_VERTEX, far_dom, far_t, PERIOD).x - _fbm(far_dom, pack, far_t, PERIOD).x))
		var at0: float = fbm.evaluate(Pasture3DWaterFBM.SET_VERTEX, dom, 0.0, PERIOD).x
		loop = maxf(loop, absf(fbm.evaluate(Pasture3DWaterFBM.SET_VERTEX, dom, PERIOD, PERIOD).x - at0))
		loop_ctrl = maxf(loop_ctrl, absf(fbm.evaluate(Pasture3DWaterFBM.SET_VERTEX, dom, 97.0, PERIOD).x - at0))
	var transcribed := err < H_TOL * HEIGHT and ctrl > H_CTRL * HEIGHT 			and loop < H_LOOP * HEIGHT and loop_ctrl > H_CTRL * HEIGHT

	# Routing: what the bodies call.
	var dom := Vector2(13.7, -41.2)
	var t := 37.25
	var m := _make_manager(Pasture3DPoolManager.WAVE_MODEL_FBM, [profile])
	var fbm_h := profile.get_height_at(dom, t)
	var exact: float = fbm.evaluate(Pasture3DWaterFBM.SET_VERTEX, dom, t, PERIOD).x
	var solved := profile.solve_domain(dom, t)
	var kept: Pasture3DWaterFBM = profile.fbm
	profile.fbm = null
	var flat_h := profile.get_height_at(dom, t)
	profile.fbm = kept
	m.free()
	var routed := fbm_h == exact and solved == dom and absf(flat_h - fbm_h) > 1e-3
	_check("H", transcribed and routed, ("max |evaluate - oracle| %.7f m (tol %.7f) within %.0f m/s, %.4f m over +-300 m and the period (float32, reported); " +
			"oracle without drag misses by %.3f m (ctrl > %.3f); t=0 vs t=period %.5f m (tol %.3f), vs t=97 s %.3f m (ctrl > %.3f); " +
			"FBM profile height %.5f == evaluate %.5f: %s, solve_domain identity: %s; without its fbm %.5f (must differ)") % [
			err, H_TOL * HEIGHT, H_RANGE, far, ctrl, H_CTRL * HEIGHT, loop, H_LOOP * HEIGHT, loop_ctrl, H_CTRL * HEIGHT, fbm_h, exact, fbm_h == exact, solved == dom, flat_h])


func _build_view() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(PIXELS, PIXELS)
	_vp.own_world_3d = true
	_vp.use_hdr_2d = true
	_vp.msaa_3d = Viewport.MSAA_DISABLED
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)

	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = VIEW
	_cam.far = 200.0
	_cam.current = true
	_vp.add_child(_cam)
	# Straight down, screen-up = -Z: image column i is world x, image row j is world z.
	_cam.look_at_from_position(Vector3(0.0, 50.0, 0.0), Vector3.ZERO, Vector3.FORWARD)

	# Margin past the view on every side, and an even number of SPACING-wide cells, so every pixel centre is
	# a rest-grid vertex. The FFT displaces them sideways; the solve is what puts them back.
	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	var size := VIEW + 8.0
	plane.size = Vector2(size, size)
	plane.subdivide_width = int(size / SPACING) - 1
	plane.subdivide_depth = int(size / SPACING) - 1
	mi.mesh = plane
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sheet = mi
	_vp.add_child(mi)

	var code := "shader_type spatial;\n"
	code += "render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform;\n"
	code += "#define WATER_DEBUG_SURFACE\n"
	for f in ["water_common", "water_waves", "water_surface", "water_shading"]:
		code += "#include \"%s%s.gdshaderinc\"\n" % [INC, f]
	_debug_shader = Shader.new()
	_debug_shader.code = code


func _render(p_mat: Material) -> PackedFloat64Array:
	_sheet.material_override = p_mat
	for i in 6:
		await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	var ldr := img.get_format() == Image.FORMAT_RGBA8 or img.get_format() == Image.FORMAT_RGB8
	var h := PackedFloat64Array()
	for j in PIXELS:
		for i in PIXELS:
			var c := img.get_pixel(i, j)
			if ldr:
				c = c.srgb_to_linear()
			h.append((c.b - 0.5) * 8.0)
	return h


func _pixel_xz(p_i: int, p_j: int) -> Vector2:
	return Vector2(-VIEW * 0.5 + p_i + 0.5, -VIEW * 0.5 + p_j + 0.5)


# What a body does for a world point: solve, then evaluate. The sheet sits at the origin with no domain
# origin, so world XZ is the domain target.
func _cpu_heights(p_m: Pasture3DPoolManager, p_name: StringName, p_solve := true) -> PackedFloat64Array:
	var h := PackedFloat64Array()
	for j in PIXELS:
		for i in PIXELS:
			var xz := _pixel_xz(i, j)
			var dom: Vector2 = p_m.solve_domain(p_name, xz) if p_solve else xz
			h.append(p_m.evaluate_height(p_name, dom))
	return h


# RMS of (a - b) over RMS of b, skipping pixels where the debug channel clipped (|h| near 4 m).
func _rel_rms(p_a: PackedFloat64Array, p_b: PackedFloat64Array) -> Array:
	var num := 0.0
	var den := 0.0
	var used := 0
	for k in p_b.size():
		if absf(p_b[k]) > 3.9:
			continue
		num += (p_a[k] - p_b[k]) * (p_a[k] - p_b[k])
		den += p_b[k] * p_b[k]
		used += 1
	return [sqrt(num / maxf(den, 1e-12)), used]


func _settle(p_frames: int) -> void:
	for i in p_frames:
		await get_tree().process_frame


func _criterion_b() -> void:
	var profile := _fbm_profile(&"buoy_b")
	var m := _make_manager(Pasture3DPoolManager.WAVE_MODEL_FBM, [profile])
	add_child(m)
	await _settle(30)
	m.paused = true
	await _settle(3)
	var mat := ShaderMaterial.new()
	mat.shader = _debug_shader
	m.upload_profile_into(mat, &"buoy_b")
	_sheet.set_instance_shader_parameter(&"_fft_vertex_spacing", SPACING)
	var drawn := await _render(mat)
	var t: float = m.get_water_time()
	var cpu := _cpu_heights(m, &"buoy_b")
	var r: Array = _rel_rms(cpu, drawn)
	# Control: the same buoy a quarter second early.
	var early := PackedFloat64Array()
	var fbm := profile.fbm
	for j in PIXELS:
		for i in PIXELS:
			early.append(fbm.evaluate(Pasture3DWaterFBM.SET_VERTEX, _pixel_xz(i, j), t - 0.25, PERIOD).x)
	var rc: Array = _rel_rms(early, drawn)
	var tol := B_TOL_LDR if _mode == "compatibility" else B_TOL
	_check("B", r[0] < tol and rc[0] > B_CTRL and r[1] > PIXELS * PIXELS * 0.95,
			"rel RMS %.4f (tol %.2f) over %d px at water_time %.3f; 0.25 s early %.3f (ctrl > %.2f)" % [
			r[0], tol, r[1], t, rc[0], B_CTRL])
	m.queue_free()
	await _settle(2)


func _criterion_r() -> void:
	var asked := _fft_profile(&"buoy_asked")
	var quiet := _fft_profile(&"buoy_quiet")
	var m := _make_manager(Pasture3DPoolManager.WAVE_MODEL_FFT, [asked, quiet])
	add_child(m)
	# Both drawn: the upload is what makes a simulation live.
	for name in [&"buoy_asked", &"buoy_quiet"]:
		var mat := ShaderMaterial.new()
		mat.shader = load(SHADER)
		m.upload_profile_into(mat, name)
	await _settle(10)
	var max_lag := 0
	var lags := {}
	var first_seen := -1
	for f in 120:
		m.evaluate_height(&"buoy_asked", Vector2(3.0, 5.0))
		await get_tree().process_frame
		if asked.fft.get_readback_count() > 0:
			if first_seen < 0:
				first_seen = f
			var lag: int = asked.fft.get_update_count() - asked.fft.get_readback_update()
			lags[lag] = lags.get(lag, 0) + 1
			if f > first_seen + 5:
				max_lag = maxi(max_lag, lag)
	var count_on: int = asked.fft.get_readback_count()
	var quiet_count: int = quiet.fft.get_readback_count()
	# Stop asking: the readback runs out its keepalive, then stops.
	await _settle(Pasture3DWaterFFT.READBACK_KEEPALIVE + 15)
	var c1: int = asked.fft.get_readback_count()
	await _settle(30)
	var c2: int = asked.fft.get_readback_count()
	var ok := first_seen >= 0 and first_seen <= R_LAG + 2 and max_lag <= R_LAG and count_on >= 100 \
			and quiet_count == 0 and c1 == c2 and c1 > count_on
	_check("R", ok, ("first readback after %d frames; lag histogram %s, max %d after warm-up (<= %d); %d readbacks in 120 queried frames; " +
			"never-queried profile read back %d (ctrl == 0); after the keepalive %d then %d (must not grow)") % [
			first_seen, lags, max_lag, R_LAG, count_on, quiet_count, c1, c2])
	m.queue_free()
	await _settle(2)


# Displacement at a domain point from four synchronous layer reads: the sampler, written again here.
func _sync_sample(p_layers: Array, p_n: int, p_lengths: Vector4, p_dom: Vector2) -> Vector3:
	var sum := Vector3.ZERO
	for c in 4:
		var bytes: PackedByteArray = p_layers[c]
		var x := p_dom.x / p_lengths[c] * p_n - 0.5
		var z := p_dom.y / p_lengths[c] * p_n - 0.5
		var fx := floorf(x)
		var fz := floorf(z)
		var tx := x - fx
		var tz := z - fz
		var i0 := posmod(int(fx), p_n)
		var j0 := posmod(int(fz), p_n)
		var i1 := (i0 + 1) % p_n
		var j1 := (j0 + 1) % p_n
		var t00 := _texel(bytes, p_n, i0, j0)
		var t10 := _texel(bytes, p_n, i1, j0)
		var t01 := _texel(bytes, p_n, i0, j1)
		var t11 := _texel(bytes, p_n, i1, j1)
		sum += t00.lerp(t10, tx).lerp(t01.lerp(t11, tx), tz)
	return sum


func _texel(p_bytes: PackedByteArray, p_n: int, p_i: int, p_j: int) -> Vector3:
	var o := (p_j * p_n + p_i) * 8
	return Vector3(p_bytes.decode_half(o), p_bytes.decode_half(o + 2), p_bytes.decode_half(o + 4))


func _sync_layers(p_fft: Pasture3DWaterFFT) -> Array:
	var layers := []
	for c in 4:
		layers.append(p_fft.read_layer(Pasture3DWaterFFT.OUTPUT_DISPLACEMENT, c, 0))
	return layers


# Hold the clock, keep asking, and wait until the readback is of a frame dispatched at the held time.
func _hold(p_m: Pasture3DPoolManager, p_profile: Pasture3DWaveProfile, p_name: StringName) -> bool:
	p_m.paused = true
	var t: float = p_m.get_water_time()
	for i in 30:
		p_m.evaluate_height(p_name, Vector2.ZERO)
		await get_tree().process_frame
	return p_profile.fft.get_readback_time() == t and p_profile.fft.get_update_count() - p_profile.fft.get_readback_update() <= R_LAG


func _criteria_s_a() -> void:
	var profile := _fft_profile(&"buoy_fft")
	var fft := profile.fft
	var m := _make_manager(Pasture3DPoolManager.WAVE_MODEL_FFT, [profile])
	add_child(m)
	var mat := ShaderMaterial.new()
	mat.shader = _debug_shader
	m.upload_profile_into(mat, &"buoy_fft")
	await _settle(20)
	# The manager re-uploads its cache on a texture rebuild, but this material is not in its cache.
	m.upload_profile_into(mat, &"buoy_fft")
	print("    FFT sea: resolution %d, lengths %s, height sigma %.3f m" % [fft.get_resolution(), fft.get_cascade_lengths(), fft.get_height_sigma()])

	# The earlier instant: CPU answers kept, the stale buffer of both controls.
	var held0: bool = await _hold(m, profile, &"buoy_fft")
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var points: Array[Vector2] = []
	for k in 64:
		points.append(Vector2(rng.randf_range(-600.0, 600.0), rng.randf_range(-600.0, 600.0)))
	var cpu0: Array[Vector3] = []
	for p in points:
		cpu0.append(fft.sample_cpu_displacement(p))
	var stale_heights := _cpu_heights(m, &"buoy_fft")
	var stale_t: float = fft.get_readback_time()

	# One second on, by the clock: frames are uncapped here, so a frame count is not a time.
	m.paused = false
	var waited := 0
	while m.get_water_time() < stale_t + 1.0 and waited < 5000:
		await get_tree().process_frame
		waited += 1
	var held1: bool = await _hold(m, profile, &"buoy_fft")
	var t1: float = fft.get_readback_time()

	# [S]
	var layers := _sync_layers(fft)
	var n: int = fft.get_resolution()
	var lengths: Vector4 = fft.get_cascade_lengths()
	var s_err := 0.0
	var s_ctrl := 0.0
	for k in points.size():
		var want := _sync_sample(layers, n, lengths, points[k])
		var got: Vector3 = fft.sample_cpu_displacement(points[k])
		s_err = maxf(s_err, (got - want).length())
		s_ctrl = maxf(s_ctrl, (cpu0[k] - want).length())
	_check("S", held0 and held1 and s_err < S_TOL and s_ctrl > S_CTRL,
			"held at t %.3f and %.3f: %s/%s; max |readback - sync read| %.7f m (tol %.7f) over %d points; the stale buffer from t %.3f misses by %.3f m (ctrl > %.2f)" % [
			stale_t, t1, held0, held1, s_err, S_TOL, points.size(), stale_t, s_ctrl, S_CTRL])

	# [A]
	_sheet.set_instance_shader_parameter(&"_fft_vertex_spacing", 0.001) # mip 0 in every cascade
	var drawn := await _render(mat)
	var cpu := _cpu_heights(m, &"buoy_fft")
	var unsolved := _cpu_heights(m, &"buoy_fft", false)
	var r: Array = _rel_rms(cpu, drawn)
	var rs: Array = _rel_rms(stale_heights, drawn)
	var ru: Array = _rel_rms(unsolved, drawn)
	var sum := 0.0
	for k in drawn.size():
		sum += drawn[k] * drawn[k]
	var rms_h := sqrt(sum / drawn.size())
	_check("A", r[0] < A_TOL and rs[0] > A_CTRL and r[1] > PIXELS * PIXELS * 0.95,
			("rel RMS %.4f (tol %.2f) over %d px, surface RMS %.3f m; the stale buffer (t %.3f vs %.3f) %.3f (ctrl > %.2f); " +
			"without the horizontal solve %.4f (reported)") % [r[0], A_TOL, r[1], rms_h, stale_t, t1, rs[0], A_CTRL, ru[0]])
	m.queue_free()
	await _settle(2)
