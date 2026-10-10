extends Node
# Phase 4 of PASTURE3D_WATER_FFT_SPEC.md: the fBm fallback.
#
# Three runs, because three renderers are the point:
#   windowed Forward+      Godot_v4.7-stable_win64_console.exe --path project res://bench/WaterFBMGate.tscn
#   headless               ... --headless --path project res://bench/WaterFBMGate.tscn
#   windowed Compatibility ... --rendering-method gl_compatibility --path project res://bench/WaterFBMGate.tscn
# Each runs the criteria its renderer can see and says which mode it was.
#
#   [H] Fallback (no RenderingDevice: headless, Compatibility). A manager left on its default (PROJECT, which
#       asks for FFT) draws fBm: effective model FBM, is_wave_model_fallback(), the profile's fBm active,
#       and a material it uploads into carries _wave_model 2 and the profile's pack. Controls: an explicit
#       GERSTNER manager is not a fallback and uploads 0; an explicit FBM manager draws fBm and is not a
#       fallback either -- so the flag means "the device was missing", not "fBm is drawn".
#   [F] Shape. A sheet meshed every 0.25 m, seen straight down through WATER_DEBUG_SURFACE (blue = height,
#       red = the vertex normal's x), every pixel centre on a vertex, the material filled by the manager's
#       own upload. Each pixel is predicted by _fbm(), the shader's arithmetic in GDScript. The relative RMS
#       error of height and normal must be under F_TOL. Controls, each a deliberate one-term break of the
#       prediction that must miss by over F_CTRL: the drag removed, and the speed quantisation removed.
#   [D] Mean. The rendered surface's mean height over the frame and four instants is within D_TOL x height
#       of zero. Control: the same render with the pack's unit mean zeroed (the reference's uncorrected
#       surface) sits over D_CTRL x height above it.
#   [L] Loop. water_time 0 and water_time = period render the same surface (relative RMS < L_TOL).
#       Control: the same two instants with water_time_period set to 97 s -- the speeds quantise to the
#       wrong loop -- differ by over L_CTRL.
#   [N] Normals reach the lit surface. The shipped water_body shader, lit by one sun, fBm vs a flat Gerstner
#       table: the fBm frame's luminance spread is over N_RATIO x the flat one's. This is the fragment set
#       (water_fbm with p_drag_by_frequency), which [F] cannot see, and on Compatibility it is the only proof
#       that the lit variant compiles.
#   [P] Project setting (Forward+ only: elsewhere FFT is not reachable to switch from). A manager in the
#       tree on PROJECT follows pasture_3d/water/wave_model when it is written at runtime, both ways, with
#       no call on the manager: the effective model, the profile, and a cached material's _wave_model.
#
# Every criterion counts its completions; one that throws before asserting reports as missing.

const SHADER := "res://addons/pasture_3d/extras/shaders/water/water_body.gdshader"
const INC := "res://addons/pasture_3d/extras/shaders/water/"
const PIXELS := 64
const VIEW := 64.0
const SPACING := 0.25
const PERIOD := 120.0
const T_SHAPE := 61.7
const HEIGHT := 2.0
const LAMBDA0 := 16.0
const F_TOL := 0.03
const F_TOL_LDR := 0.12
const F_CTRL := 0.3
const D_TOL := 0.08
const D_CTRL := 0.3
const L_TOL := 0.01
const L_CTRL := 0.3
const N_RATIO := 10.0

var _fail := 0
var _seen: Dictionary = {}
var _criteria: PackedStringArray = []
var _mode := ""
var _vp: SubViewport
var _cam: Camera3D
var _sun: DirectionalLight3D
var _sheet: MeshInstance3D
var _debug_shader: Shader
var _manager: Pasture3DPoolManager
var _profile: Pasture3DWaveProfile
var _pack: PackedVector4Array


func _ready() -> void:
	var headless := DisplayServer.get_name() == "headless"
	var device := RenderingServer.get_rendering_device() != null
	if headless:
		_mode = "headless"
		_criteria = ["H"]
	elif not device:
		_mode = "compatibility"
		_criteria = ["H", "F", "N"]
	else:
		_mode = "forward+"
		_criteria = ["F", "D", "L", "N", "P"]
	print("=== WaterFBMGate (%s) ===" % _mode)
	_make_profile()
	if _criteria.has("H"):
		_criterion_h()
	if not headless:
		_build_view()
		_manager = _make_manager(Pasture3DPoolManager.WAVE_MODEL_FBM)
		if _criteria.has("F"):
			await _criterion_f()
		if _criteria.has("D"):
			await _criterion_d()
		if _criteria.has("L"):
			await _criterion_l()
		if _criteria.has("N"):
			await _criterion_n()
		_manager.free()
		if _criteria.has("P"):
			await _criterion_p()
	var missing := 0
	for c in _criteria:
		if not _seen.has(c):
			missing += 1
			print("  FAIL %s: never reported" % c)
	var ok := _fail == 0 and missing == 0
	print("=== WATER FBM %s (%s: %d failures, %d/%d criteria reported) ===" % [
			"PASS" if ok else "FAIL", _mode, _fail + missing, _criteria.size() - missing, _criteria.size()])
	get_tree().quit(0 if ok else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_fail += 1


# An AUTHORED fBm, so the numbers under test are the gate's and not the Gerstner derivation's.
func _make_profile() -> void:
	_profile = Pasture3DWaveProfile.new()
	_profile.profile_name = &"fbm_gate"
	var fbm := Pasture3DWaterFBM.new()
	for s in 2:
		fbm.set_knob(s, &"frequency", TAU / LAMBDA0)
		fbm.set_knob(s, &"seed", 0.4)
		fbm.set_knob(s, &"speed", 2.0)
	fbm.set_knob(Pasture3DWaterFBM.SET_VERTEX, &"height", HEIGHT)
	fbm.set_knob(Pasture3DWaterFBM.SET_FRAGMENT, &"height", HEIGHT)
	_profile.fbm = fbm
	_pack = fbm.get_shader_pack(Pasture3DWaterFBM.SET_VERTEX)


func _make_manager(p_model: int) -> Pasture3DPoolManager:
	var m := Pasture3DPoolManager.new()
	m.loop_period = PERIOD
	m.profiles = [_profile]
	m.wave_model = p_model
	return m


func _criterion_h() -> void:
	var details := PackedStringArray()
	var ok := true
	var rows := [
		["PROJECT (asks FFT)", Pasture3DPoolManager.WAVE_MODEL_PROJECT, Pasture3DPoolManager.WAVE_MODEL_FBM, true, 2],
		["GERSTNER control", Pasture3DPoolManager.WAVE_MODEL_GERSTNER, Pasture3DPoolManager.WAVE_MODEL_GERSTNER, false, 0],
		["FBM control", Pasture3DPoolManager.WAVE_MODEL_FBM, Pasture3DPoolManager.WAVE_MODEL_FBM, false, 2],
	]
	for row in rows:
		var m := _make_manager(row[1])
		var mat := ShaderMaterial.new()
		mat.shader = load(SHADER)
		m.upload_profile_into(mat, &"fbm_gate")
		var eff: int = m.get_effective_wave_model()
		var fb: bool = m.is_wave_model_fallback()
		var uploaded: int = mat.get_shader_parameter("_wave_model")
		var v1: Variant = mat.get_shader_parameter("_fbm_v1")
		var pack_ok: bool = row[4] != 2 or (v1 is Vector4 and (v1 as Vector4).is_equal_approx(_pack[1]))
		var fbm_active := _profile.is_fbm_active()
		var row_ok: bool = eff == row[2] and fb == row[3] and uploaded == row[4] and pack_ok \
				and fbm_active == (row[4] == 2)
		ok = ok and row_ok
		details.append("%s: effective %d fallback %s _wave_model %d pack %s fbm_active %s amplitude_sum %.3f -> %s" % [
				row[0], eff, fb, uploaded, pack_ok, fbm_active, _profile.get_amplitude_sum(),
				"ok" if row_ok else "WRONG"])
		m.free()
	# Information, not a criterion: what an UNAUTHORED profile derives from the Gerstner defaults.
	var derived := Pasture3DWaveProfile.new()
	var dfbm := derived.fbm
	details.append("derived from Gerstner defaults (amplitude sum %.3f m, length_max %.1f m): frequency %.4f rad/m, speed %.3f rad/s, vertex height %.3f m, sigma %.3f m (target %.3f), bound %.3f m" % [
			_gerstner_sum(derived), derived.length_max,
			dfbm.get_knob(0, &"frequency"), dfbm.get_knob(0, &"speed"), dfbm.get_knob(0, &"height"),
			dfbm.get_height_sigma(), 0.176 * _gerstner_sum(derived), dfbm.get_displacement_bound()])
	_check("H", ok, "\n      " + "\n      ".join(details))


func _gerstner_sum(p_profile: Pasture3DWaveProfile) -> float:
	var sum := 0.0
	for w in p_profile.get_shader_table():
		sum += w.z
	return sum


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

	_sun = DirectionalLight3D.new()
	_sun.shadow_enabled = false
	_sun.visible = false
	_vp.add_child(_sun)

	# Two metres of margin past the view on every side, and an even number of SPACING-wide cells, so that
	# every pixel centre (-31.5 .. 31.5) is a vertex.
	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	var size := VIEW + 4.0
	plane.size = Vector2(size, size)
	plane.subdivide_width = int(size / SPACING) - 1
	plane.subdivide_depth = int(size / SPACING) - 1
	mi.mesh = plane
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sheet = mi
	_vp.add_child(mi)
	mi.set_instance_shader_parameter(&"_fft_vertex_spacing", SPACING)

	var code := "shader_type spatial;\n"
	code += "render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform;\n"
	code += "#define WATER_WAVE_COUNT 4\n#define WATER_DEBUG_SURFACE\n"
	for f in ["water_common", "water_waves", "water_surface", "water_shading"]:
		code += "#include \"%s%s.gdshaderinc\"\n" % [INC, f]
	_debug_shader = Shader.new()
	_debug_shader.code = code
	RenderingServer.global_shader_parameter_set("water_time_period", PERIOD)


func _debug_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _debug_shader
	_manager.upload_profile_into(mat, &"fbm_gate")
	return mat


func _render(p_mat: Material, p_time: float, p_period := PERIOD) -> Image:
	_sheet.material_override = p_mat
	RenderingServer.global_shader_parameter_set("water_time", p_time)
	RenderingServer.global_shader_parameter_set("water_time_period", p_period)
	for i in 6:
		await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	# An 8-bit target (Compatibility without HDR 2D) holds sRGB; the debug channels are linear.
	if img.get_format() == Image.FORMAT_RGBA8 or img.get_format() == Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGBAF)
		for y in img.get_height():
			for x in img.get_width():
				img.set_pixel(x, y, img.get_pixel(x, y).srgb_to_linear())
	return img


func _is_ldr() -> bool:
	return _mode == "compatibility"


# Height in metres and the vertex normal's x, from WATER_DEBUG_SURFACE's EMISSION.
func _decode(p_img: Image) -> Array:
	var h := PackedFloat64Array()
	var nx := PackedFloat64Array()
	for j in PIXELS:
		for i in PIXELS:
			var c := p_img.get_pixel(i, j)
			h.append((c.b - 0.5) * 8.0)
			nx.append(c.r * 2.0 - 1.0)
	return [h, nx]


func _pixel_xz(p_i: int, p_j: int) -> Vector2:
	return Vector2(-VIEW * 0.5 + p_i + 0.5, -VIEW * 0.5 + p_j + 0.5)


# water_fbm() in water_waves.gdshaderinc, line for line. p_drag and p_quantise are the controls' breaks.
func _fbm(p_dom: Vector2, p: PackedVector4Array, p_spacing: float, p_min_samples: float, p_drag_by_f: bool,
		p_time: float, p_period: float, p_drag := true, p_quantise := true) -> Vector3:
	var seed := p[0].x
	var k0 := maxf(p[0].z, 1e-6)
	var f := 1.0
	var a := p[1].x
	var speed := p[1].z
	var q := p_dom * k0
	var h := 0.0
	var n := Vector2.ZERO
	var min_length := maxf(p_spacing, 1e-6) * p_min_samples
	for i in int(p[3].z):
		var w := clampf(TAU / (k0 * f * min_length) - 1.0, 0.0, 1.0)
		if w <= 0.0 and p[0].w >= 1.0:
			break
		var d := Vector2(cos(seed), sin(seed))
		var rate := speed
		if p_quantise:
			var period := maxf(p_period, 1e-3)
			rate = roundf(speed * period / TAU) * (TAU / period)
		var x := d.dot(q) * f + p_time * rate
		var wave := a * exp(p[2].z * sin(x) - p[2].w)
		var dwave := p[2].z * wave * cos(x)
		h += w * (wave - a * p[3].y)
		n += (w * f * dwave) * d
		if p_drag:
			q -= d * (w * dwave * a * p[2].x * (f if p_drag_by_f else 1.0))
		f *= p[0].w
		a *= p[1].y
		speed *= p[1].w
		seed += p[0].y
	var scale := p[2].y / maxf(p[3].x, 1e-6)
	return Vector3(h * scale, n.x * scale * k0, n.y * scale * k0)


func _predict(p_time: float, p_period: float, p_drag := true, p_quantise := true) -> Array:
	var h := PackedFloat64Array()
	var nx := PackedFloat64Array()
	for j in PIXELS:
		for i in PIXELS:
			var s := _fbm(_pixel_xz(i, j), _pack, SPACING, 4.0, false, p_time, p_period, p_drag, p_quantise)
			h.append(s.x)
			nx.append((Vector3(-s.y, 1.0, -s.z).normalized()).x)
	return [h, nx]


func _mean(p: PackedFloat64Array) -> float:
	var s := 0.0
	for v in p:
		s += v
	return s / maxf(p.size(), 1)


func _rms_dev(p: PackedFloat64Array) -> float:
	var m := _mean(p)
	var s := 0.0
	for v in p:
		s += (v - m) * (v - m)
	return sqrt(s / maxf(p.size(), 1))


# RMS of (p_got - p_want) over the RMS spread of p_want.
func _rel_rms(p_got: PackedFloat64Array, p_want: PackedFloat64Array) -> float:
	var s := 0.0
	for k in p_got.size():
		s += (p_got[k] - p_want[k]) * (p_got[k] - p_want[k])
	return sqrt(s / maxf(p_got.size(), 1)) / maxf(_rms_dev(p_want), 1e-9)


func _criterion_f() -> void:
	var mat := _debug_material()
	var got := _decode(await _render(mat, T_SHAPE))
	var want := _predict(T_SHAPE, PERIOD)
	var no_drag := _predict(T_SHAPE, PERIOD, false)
	var no_quant := _predict(T_SHAPE, PERIOD, true, false)
	var tol := F_TOL_LDR if _is_ldr() else F_TOL
	var err_h := _rel_rms(got[0], want[0])
	var err_n := _rel_rms(got[1], want[1])
	var ctrl_drag := _rel_rms(got[0], no_drag[0])
	var ctrl_quant := _rel_rms(got[0], no_quant[0])
	var spread := _rms_dev(got[0])
	_check("F", err_h < tol and err_n < tol and ctrl_drag > F_CTRL and ctrl_quant > F_CTRL and spread > 0.05,
			"height rms %.3f m (predicted %.3f), rel err %.4f | normal.x rel err %.4f | tol %.2f | controls: no drag %.3f, no quantisation %.3f (need > %.1f)" % [
				spread, _rms_dev(want[0]), err_h, err_n, tol, ctrl_drag, ctrl_quant, F_CTRL])


func _criterion_d() -> void:
	var mat := _debug_material()
	var raw := _debug_material()
	var p3: Vector4 = _pack[3]
	raw.set_shader_parameter(&"_fbm_v3", Vector4(p3.x, 0.0, p3.z, p3.w))
	var means := [0.0, 0.0]
	var times := [3.1, 17.9, 44.2, 90.6]
	for t in times:
		means[0] += _mean(_decode(await _render(mat, t))[0]) / times.size()
		means[1] += _mean(_decode(await _render(raw, t))[0]) / times.size()
	var predicted_raw := HEIGHT * p3.y
	_check("D", absf(means[0]) < D_TOL * HEIGHT and means[1] > D_CTRL * HEIGHT,
			"mean height %.4f m (tol %.3f) | uncorrected control %.4f m (closed form %.4f, need > %.3f)" % [
				means[0], D_TOL * HEIGHT, means[1], predicted_raw, D_CTRL * HEIGHT])


func _criterion_l() -> void:
	var mat := _debug_material()
	var a: PackedFloat64Array = _decode(await _render(mat, 0.0))[0]
	var b: PackedFloat64Array = _decode(await _render(mat, PERIOD))[0]
	var ca: PackedFloat64Array = _decode(await _render(mat, 0.0, 97.0))[0]
	var cb: PackedFloat64Array = _decode(await _render(mat, PERIOD, 97.0))[0]
	var seam := _rel_rms(b, a)
	var ctrl := _rel_rms(cb, ca)
	_check("L", seam < L_TOL and ctrl > L_CTRL,
			"t=0 vs t=%.0f s: rel rms %.5f (tol %.3f) | period 97 s control %.3f (need > %.1f)" % [
				PERIOD, seam, L_TOL, ctrl, L_CTRL])


func _lit_material(p_model: int) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER)
	mat.set_shader_parameter("detail_strength", 0.0)
	mat.set_shader_parameter("foam_shore_amount", 0.0)
	mat.set_shader_parameter("absorption", Vector3(100.0, 100.0, 100.0))
	if p_model == Pasture3DPoolManager.WAVE_MODEL_FBM:
		_manager.upload_profile_into(mat, &"fbm_gate")
	else:
		var flat := PackedVector4Array()
		for i in 8:
			flat.append(Vector4(1.0, 0.0, 0.0, 100.0))
		mat.set_shader_parameter("_waves", flat)
		mat.set_shader_parameter("wave_steepness", 0.0)
	return mat


func _luma_spread(p_img: Image) -> Array:
	var l := PackedFloat64Array()
	for j in PIXELS:
		for i in PIXELS:
			var c := p_img.get_pixel(i, j)
			l.append(0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b)
	return [_mean(l), _rms_dev(l)]


func _criterion_n() -> void:
	_sun.visible = true
	_sun.light_energy = 0.25
	var to_sun := Vector3(cos(deg_to_rad(35.0)), sin(deg_to_rad(35.0)), 0.0)
	_sun.look_at_from_position(to_sun * 50.0, Vector3.ZERO, Vector3.UP)
	# The camera stays straight down: a tilted orthographic view runs off the sheet, and the background's
	# edge then IS the spread, in both arms alike.
	var fbm := _luma_spread(await _render(_lit_material(Pasture3DPoolManager.WAVE_MODEL_FBM), T_SHAPE))
	var flat := _luma_spread(await _render(_lit_material(Pasture3DPoolManager.WAVE_MODEL_GERSTNER), T_SHAPE))
	_sun.visible = false
	var ratio: float = fbm[1] / maxf(flat[1], 1e-6)
	_check("N", fbm[0] > 1e-3 and ratio > N_RATIO,
			"fBm lit mean %.4f spread %.5f | flat control mean %.4f spread %.6f | ratio %.1f (need > %.0f)" % [
				fbm[0], fbm[1], flat[0], flat[1], ratio, N_RATIO])


func _criterion_p() -> void:
	var setting := "pasture_3d/water/wave_model"
	var before: Variant = ProjectSettings.get_setting(setting, 0)
	ProjectSettings.set_setting(setting, 0)
	var m := _make_manager(Pasture3DPoolManager.WAVE_MODEL_PROJECT)
	add_child(m)
	var base := ShaderMaterial.new()
	base.shader = load(SHADER)
	var cached: ShaderMaterial = m.get_material_for(base, &"fbm_gate")
	var states := []
	for value in [0, 1, 0]:
		ProjectSettings.set_setting(setting, value)
		for i in 4:
			await get_tree().process_frame
		states.append([value, m.get_effective_wave_model(), _profile.get_active_model(),
				int(cached.get_shader_parameter("_wave_model"))])
	ProjectSettings.set_setting(setting, before)
	m.queue_free()
	var want := [
		[0, Pasture3DPoolManager.WAVE_MODEL_FFT, Pasture3DWaveProfile.MODEL_FFT, 1],
		[1, Pasture3DPoolManager.WAVE_MODEL_FBM, Pasture3DWaveProfile.MODEL_FBM, 2],
		[0, Pasture3DPoolManager.WAVE_MODEL_FFT, Pasture3DWaveProfile.MODEL_FFT, 1],
	]
	var details := PackedStringArray()
	for k in states.size():
		details.append("setting %d -> effective %d, profile %d, material _wave_model %d (want %s)" % [
				states[k][0], states[k][1], states[k][2], states[k][3], str(want[k])])
	_check("P", states == want, "\n      " + "\n      ".join(details))
