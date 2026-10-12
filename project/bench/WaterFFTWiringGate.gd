extends Node
# Phase 2 of PASTURE3D_WATER_FFT_SPEC.md: the FFT reaches the materials and the screen.
#
# Run windowed under Forward+ (the simulation needs a RenderingDevice):
#   Godot_v4.7-stable_win64_console.exe --path project res://bench/WaterFFTWiringGate.tscn
#
#   [B] Bound before the build. A material handed out by get_material_for() BEFORE the simulation has
#       built its textures -- which is every material at scene load -- renders the FFT once the manager
#       has seen the build (get_fft_rebind_count() >= 1), correlating with the readback as [R] does.
#       Control: a private material uploaded at the same moment and never re-uploaded draws FLAT. That
#       is the bug this guards: Texture2DArrayRD's lazy placeholder is a plain 2D texture, the
#       sampler2DArray binds its default black array instead, and the later texture_replace() never
#       reaches that binding. Only re-setting the parameter does.
#   [W] Wiring. A manager in the FFT model gives its profile a live simulation, and upload_profile_into()
#       writes _wave_model = 1, the simulation's own texture wrappers, its per-cascade repeats, drawn and
#       displacing masks, and its summed foam offset. Control:
#       switched to FBM, the same upload writes _wave_model = 2 and the profile reports inactive.
#   [T] Tick. Over TICK_FRAMES rendered frames the manager dispatches the simulation at least once a
#       frame and the simulation's own update count agrees. Control: in FBM nothing is dispatched.
#   [R] Render. An unlit top-down render of water_body_debug (EMISSION.b = height / 8 + 0.5) correlates
#       with the height the gate rebuilds from the simulation's readback: only the displacing cascades
#       (drawn AND contributing, spec G2/G3), each at its own repeat, trilinear at the mip the vertex stage
#       picks, at the shader's texel convention (domain * N / repeat - 0.5), and at the rest point the
#       horizontal displacement carries onto the pixel. Since R2 the one displacing cascade is short against
#       its 100 m tile, so mip 0 at the rest point no longer approximates what is drawn. Control: the same surface drawn by the fBm branch,
#       against the same prediction, must not correlate. The regression slope is printed, not gated:
#       correlation is what says the field is THIS field; the slope says the encoding survived the
#       viewport, which is the viewport's business.
#   [F] Far-plane displacement fade (PASTURE3D_WATER_REFERENCE_SPEC.md G5). The camera looks straight down
#       from CAM_HEIGHT onto the flat rest sheet, so every rest vertex sits at the same linear view depth
#       and the fade is one number, (1 - CAM_HEIGHT / far)^falloff. The rendered height's spread against the
#       same render at falloff 0 must read that number: 0.75 at far 400, 0.5625 at falloff 2, 0.5 with the
#       far plane moved to 200 (the far plane is read from the projection, not assumed). Control: falloff 0
#       reads 1, and must miss 0.75.
#   [N] Normal strength (L8), normal fade and foam fade (G5), from water_fft_shading_debug, which encodes
#       the fragment's FINAL slope and crest foam. Against the same render with every fade off: strength 2
#       doubles every slope; strength 3 under normal falloff 1 at fade f gives the reference's form, the
#       NORMAL lerped toward up -- slope' = f s / ((1 - f) L + f), L = |(s, 1)| -- with strength applied
#       first. Control: the naive slope * f must miss by several times more. Foam falloff 2 scales the
#       crest by f^2, and the slopes are untouched by it.
#
# Every criterion counts its completions; one that throws before asserting reports as missing.

const CRITERIA: PackedStringArray = ["B", "W", "T", "R", "F", "N"]
const DEBUG_SHADER := "res://bench/water_body_debug.gdshader"
const SHADING_SHADER := "res://bench/water_fft_shading_debug.gdshader"
const CAM_HEIGHT := 100.0
const CAM_FAR := 400.0
const RES := 128
const PATCH := 256.0
const PIXELS := 128
const SPACING := 2.0
const TICK_FRAMES := 10
const SOLVE_ITERATIONS := 4

var _fail := 0
var _seen: Dictionary = {}
var _manager: Pasture3DPoolManager
var _profile: Pasture3DWaveProfile
var _mat: ShaderMaterial
var _vp: SubViewport
var _mesh: MeshInstance3D
var _cam: Camera3D


func _ready() -> void:
	print("=== WaterFFTWiringGate ===")
	if not Pasture3DWaterFFT.is_supported():
		print("  FAIL: no RenderingDevice. Run windowed under Forward+, not --headless.")
		get_tree().quit(1)
		return
	await _run()
	var missing := 0
	for c in CRITERIA:
		if not _seen.has(c):
			missing += 1
			print("  FAIL %s: never reported" % c)
	var ok := _fail == 0 and missing == 0
	print("=== WATER FFT WIRING %s (%d failures, %d/%d criteria reported) ===" % [
			"PASS" if ok else "FAIL", _fail + missing, CRITERIA.size() - missing, CRITERIA.size()])
	get_tree().quit(0 if ok else 1)


func _g(p_value: float) -> String:
	return String.num_scientific(p_value)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_fail += 1


func _frames(p_count: int) -> void:
	for i in p_count:
		await RenderingServer.frame_post_draw


func _run() -> void:
	_profile = Pasture3DWaveProfile.new()
	_profile.profile_name = "gate"
	_manager = Pasture3DPoolManager.new()
	_manager.fft_resolution = RES
	_manager.set_profiles([_profile])
	add_child(_manager)

	_mat = ShaderMaterial.new()
	_mat.shader = load(DEBUG_SHADER)
	# Paused for the whole run: the manager still dispatches every frame (dt 0), so what the draw samples
	# and what the gate reads back are the same frame.
	_manager.paused = true
	# Both taken before the first frame, so before the simulation exists on the GPU.
	var early_base := ShaderMaterial.new()
	early_base.shader = load(DEBUG_SHADER)
	var early_cached: ShaderMaterial = _manager.get_material_for(early_base, &"gate")
	var early_private := ShaderMaterial.new()
	early_private.shader = load(DEBUG_SHADER)
	_manager.upload_profile_into(early_private, &"gate")
	# And DRAWN from the first frame. A material first used after the build binds correctly whatever was
	# uploaded when; the placeholder only sticks to one the renderer has already materialised.
	var pre_vp := _drawn_early([early_cached, early_private])
	_build_view()
	await _frames(3)

	await _criterion_b(early_cached, early_private)
	pre_vp.queue_free()
	await _criterion_w()
	await _criterion_t()
	await _criterion_r()
	await _criterion_f()
	await _criterion_n()


func _build_view() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(PIXELS, PIXELS)
	_vp.own_world_3d = true
	# Float readback: an 8-bit target quantises EMISSION.b to 8/255 m of height.
	_vp.use_hdr_2d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = PATCH
	cam.position = Vector3(0.0, CAM_HEIGHT, 0.0)
	# Looking down -Y, screen-right is +X and screen-up is -Z.
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	cam.far = CAM_FAR
	_cam = cam
	cam.current = true
	_vp.add_child(cam)
	var mi := MeshInstance3D.new()
	_mesh = mi
	var plane := PlaneMesh.new()
	plane.size = Vector2(PATCH + 16.0, PATCH + 16.0)
	plane.subdivide_width = int((PATCH + 16.0) / SPACING) - 1
	plane.subdivide_depth = int((PATCH + 16.0) / SPACING) - 1
	mi.mesh = plane
	mi.material_override = _mat
	_vp.add_child(mi)
	mi.set_instance_shader_parameter("_fft_vertex_spacing", SPACING)


## A separate world that draws each material on its own quad, so they are in use from frame one.
func _drawn_early(p_mats: Array) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(64, 64)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 60.0, 0.0)
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	cam.current = true
	vp.add_child(cam)
	for i in p_mats.size():
		var mi := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(20.0, 20.0)
		plane.subdivide_width = 9
		plane.subdivide_depth = 9
		mi.mesh = plane
		mi.position = Vector3(-12.0 + 24.0 * i, 0.0, 0.0)
		mi.material_override = p_mats[i]
		vp.add_child(mi)
	return vp


# --- [B] bound before the build ---------------------------------------------------------------------

func _render_with(p_mat: Material) -> PackedFloat32Array:
	_mesh.material_override = p_mat
	await _frames(4)
	return _rendered()


func _criterion_b(p_cached: ShaderMaterial, p_private: ShaderMaterial) -> void:
	var rebinds := _manager.get_fft_rebind_count()
	var generation: int = _profile.fft.get_texture_generation()
	var got: PackedFloat32Array = await _render_with(p_cached)
	var pred := _predict()
	var fit := _fit(pred, got)
	var flat: PackedFloat32Array = await _render_with(p_private)
	var flat_sd := sqrt(_variance(flat))
	_mesh.material_override = _mat
	var ok: bool = rebinds >= 1 and generation >= 1 and fit[0] > 0.95 and fit[2] > 0.05 and flat_sd < 0.01
	_check("B", ok, "texture generation %d, rebinds %d (must be >= 1); cached material bound pre-build: correlation %.4f, sd %s m; control, private material never re-uploaded: sd %s m (must stay under 0.01)" % [
			generation, rebinds, fit[0], _g(fit[2]), _g(flat_sd)])


# --- [W] wiring --------------------------------------------------------------------------------------

func _criterion_w() -> void:
	var fft: Pasture3DWaterFFT = _profile.fft
	_manager.wave_model = Pasture3DPoolManager.WAVE_MODEL_FFT
	_manager.upload_profile_into(_mat, &"gate")
	var model_fft: int = _mat.get_shader_parameter("_wave_model")
	var disp_ok: bool = _mat.get_shader_parameter("_fft_displacement") == fft.get_displacement_texture()
	var slope_ok: bool = _mat.get_shader_parameter("_fft_slope") == fft.get_slope_texture()
	var repeat: Vector4 = _mat.get_shader_parameter("_fft_repeat")
	var drawn: Vector4 = _mat.get_shader_parameter("_fft_drawn")
	var displaces: Vector4 = _mat.get_shader_parameter("_fft_displaces")
	var foam_offset: float = _mat.get_shader_parameter("_fft_foam_offset")
	var masks_ok := true
	for i in 4:
		masks_ok = masks_ok and drawn[i] == float((fft.cascade_drawn >> i) & 1) 				and displaces[i] == float((fft.get_displacing_mask() >> i) & 1)
	var live: int = _manager.get_live_fft_count()
	var active: bool = _profile.is_fft_active()
	var res_ok: bool = fft.resolution == RES

	_manager.wave_model = Pasture3DPoolManager.WAVE_MODEL_FBM
	_manager.upload_profile_into(_mat, &"gate")
	var model_ctl: int = _mat.get_shader_parameter("_wave_model")
	var active_ctl: bool = _profile.is_fft_active()
	_manager.wave_model = Pasture3DPoolManager.WAVE_MODEL_FFT
	_manager.upload_profile_into(_mat, &"gate")

	var ok := _manager.is_fft_effective() and active and model_fft == 1 and disp_ok and slope_ok \
			and repeat == fft.get_cascade_repeats() and masks_ok and is_equal_approx(foam_offset, fft.get_foam_offset_sum()) 			and live == 1 and res_ok and model_ctl == 2 and not active_ctl
	_check("W", ok, "FFT: active %s, _wave_model %d, textures %s/%s, repeat %s, drawn %s, displaces %s (masks match %s), foam offset %.3f, live %d, resolution %d; control FBM: _wave_model %d, active %s" % [
			active, model_fft, disp_ok, slope_ok, repeat, drawn, displaces, masks_ok, foam_offset, live, fft.resolution, model_ctl, active_ctl])


# --- [T] tick ----------------------------------------------------------------------------------------

func _criterion_t() -> void:
	var fft: Pasture3DWaterFFT = _profile.fft
	var ticks0 := _manager.get_fft_tick_count()
	var updates0 := fft.get_update_count()
	await _frames(TICK_FRAMES)
	var ticks := _manager.get_fft_tick_count() - ticks0
	var updates := fft.get_update_count() - updates0

	_manager.wave_model = Pasture3DPoolManager.WAVE_MODEL_FBM
	var ctl0 := _manager.get_fft_tick_count()
	await _frames(TICK_FRAMES)
	var ctl := _manager.get_fft_tick_count() - ctl0
	_manager.wave_model = Pasture3DPoolManager.WAVE_MODEL_FFT
	_manager.upload_profile_into(_mat, &"gate")

	var ok := ticks >= TICK_FRAMES - 1 and updates >= ticks and ctl == 0
	_check("T", ok, "%d frames: %d manager ticks, %d simulation updates (both must reach %d); control FBM: %d ticks (must be 0)" % [
			TICK_FRAMES, ticks, updates, TICK_FRAMES - 1, ctl])


# --- [R] render --------------------------------------------------------------------------------------

func _halves(p_bytes: PackedByteArray) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_bytes.size() / 2)
	for i in out.size():
		out[i] = p_bytes.decode_half(i * 2)
	return out


## Bilinear, wrapping, of xyz, at continuous texel coordinate (p_u, p_v) of a p_n square layer.
func _bilinear(p_disp: PackedFloat32Array, p_n: int, p_u: float, p_v: float) -> Vector3:
	var u0 := floori(p_u)
	var v0 := floori(p_v)
	var fu := p_u - float(u0)
	var fv := p_v - float(v0)
	var a := posmod(u0, p_n)
	var b := posmod(u0 + 1, p_n)
	var c := posmod(v0, p_n)
	var d := posmod(v0 + 1, p_n)
	var t00 := _texel(p_disp, (c * p_n + a) * 4)
	var t10 := _texel(p_disp, (c * p_n + b) * 4)
	var t01 := _texel(p_disp, (d * p_n + a) * 4)
	var t11 := _texel(p_disp, (d * p_n + b) * 4)
	return t00.lerp(t10, fu).lerp(t01.lerp(t11, fu), fv)


func _texel(p_disp: PackedFloat32Array, p_i: int) -> Vector3:
	return Vector3(p_disp[p_i], p_disp[p_i + 1], p_disp[p_i + 2])


## Displacement the vertex stage samples at domain p_dom: each displacing cascade at its own repeat,
## trilinear at the shader's lod (water_fft_lod), as textureLod over filter_linear_mipmap reads it.
func _displacement(p_mips: Array, p_repeats: Vector4, p_mask: int, p_dom: Vector2) -> Vector3:
	var sum := Vector3.ZERO
	for c in 4:
		if not (p_mask >> c) & 1:
			continue
		var lod := maxf(log(2.0 * SPACING * float(RES) / p_repeats[c]) / log(2.0), 0.0)
		var m0 := mini(floori(lod), p_mips[c].size() - 1)
		var m1 := mini(m0 + 1, p_mips[c].size() - 1)
		var f := clampf(lod - float(m0), 0.0, 1.0)
		var a := _bilinear_at(p_mips[c][m0], RES >> m0, p_repeats[c], p_dom)
		var b := _bilinear_at(p_mips[c][m1], RES >> m1, p_repeats[c], p_dom)
		sum += a.lerp(b, f)
	return sum


func _bilinear_at(p_disp: PackedFloat32Array, p_n: int, p_repeat: float, p_dom: Vector2) -> Vector3:
	var k := float(p_n) / p_repeat
	return _bilinear(p_disp, p_n, p_dom.x * k - 0.5, p_dom.y * k - 0.5)


## Height the shader should draw at each pixel centre. The vertex at rest point p lands at p + D(p).xz, so
## the surface over pixel x is the one whose rest point solves p + D(p).xz = x: a fixed point, as the
## manager's solve_domain finds it. Only the cascades that displace (drawn AND contributing), each at its
## own repeat and at the mip the vertex stage picks for SPACING, scaled by the far-plane fade (G5).
func _predict(p_mask: int = -1) -> PackedFloat32Array:
	var fft: Pasture3DWaterFFT = _profile.fft
	var repeats := fft.get_cascade_repeats()
	var mask := fft.get_displacing_mask() if p_mask < 0 else p_mask
	# The far-plane fade at the material's default falloff of 1 ([F] measures it on its own): every rest
	# vertex is CAM_HEIGHT deep, so it is one number.
	var fade := 1.0 - CAM_HEIGHT / CAM_FAR
	var mips: Array = []
	for c in 4:
		var chain: Array[PackedFloat32Array] = []
		if (mask >> c) & 1:
			# The full chain, RES down to 1: the simulation builds every level.
			for m in int(log(float(RES)) / log(2.0) + 0.5) + 1:
				chain.append(_halves(fft.read_layer(Pasture3DWaterFFT.OUTPUT_DISPLACEMENT, c, m)))
		mips.append(chain)
	var out := PackedFloat32Array()
	out.resize(PIXELS * PIXELS)
	for py in PIXELS:
		var z := (float(py) + 0.5) / float(PIXELS) * PATCH - PATCH * 0.5
		for px in PIXELS:
			var x := (float(px) + 0.5) / float(PIXELS) * PATCH - PATCH * 0.5
			var target := Vector2(x, z)
			var dom := target
			var d := Vector3.ZERO
			for it in SOLVE_ITERATIONS:
				d = _displacement(mips, repeats, mask, dom) * fade
				dom = target - Vector2(d.x, d.z)
			out[py * PIXELS + px] = _displacement(mips, repeats, mask, dom).y * fade
	return out


## Rendered height per pixel, from EMISSION.b = y / 8 + 0.5.
func _rendered() -> PackedFloat32Array:
	var img := _vp.get_texture().get_image()
	var out := PackedFloat32Array()
	out.resize(PIXELS * PIXELS)
	for py in PIXELS:
		for px in PIXELS:
			out[py * PIXELS + px] = (img.get_pixel(px, py).b - 0.5) * 8.0
	return out


## [correlation, slope of rendered on predicted, rendered stddev].
func _fit(p_pred: PackedFloat32Array, p_got: PackedFloat32Array) -> Array:
	var n := float(p_pred.size())
	var mp := 0.0
	var mg := 0.0
	for i in p_pred.size():
		mp += p_pred[i]
		mg += p_got[i]
	mp /= n
	mg /= n
	var spp := 0.0
	var sgg := 0.0
	var spg := 0.0
	for i in p_pred.size():
		var a := p_pred[i] - mp
		var b := p_got[i] - mg
		spp += a * a
		sgg += b * b
		spg += a * b
	var corr := spg / sqrt(maxf(spp * sgg, 1e-30))
	return [corr, spg / maxf(spp, 1e-30), sqrt(sgg / n)]


func _criterion_r() -> void:
	await _frames(4)
	var got := _rendered()
	var pred := _predict()
	var fit := _fit(pred, got)

	_manager.wave_model = Pasture3DPoolManager.WAVE_MODEL_FBM
	_manager.upload_profile_into(_mat, &"gate")
	await _frames(4)
	var ctl := _fit(pred, _rendered())
	_manager.wave_model = Pasture3DPoolManager.WAVE_MODEL_FFT
	_manager.upload_profile_into(_mat, &"gate")

	var pred_sd := sqrt(_variance(pred))
	var ok: bool = pred_sd > 0.05 and fit[2] > 0.05 and fit[0] > 0.95 and absf(ctl[0]) < 0.5
	_check("R", ok, "%d px: correlation %.4f (must exceed 0.95), slope %.3f, rendered sd %s m vs predicted %s m; control FBM correlation %.4f (must stay under 0.5), sd %s m" % [
			got.size(), fit[0], fit[1], _g(fit[2]), _g(pred_sd), ctl[0], _g(ctl[2])])


func _variance(p_values: PackedFloat32Array) -> float:
	var n := float(p_values.size())
	var m := 0.0
	for v in p_values:
		m += v
	m /= n
	var s := 0.0
	for v in p_values:
		s += (v - m) * (v - m)
	return s / n


# --- [F] displacement fade ---------------------------------------------------------------------------

func _sd_ratio(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	return sqrt(_variance(p_a) / maxf(_variance(p_b), 1e-30))


func _render_falloff(p_falloff: float, p_far: float) -> PackedFloat32Array:
	_mat.set_shader_parameter("fft_displacement_falloff", p_falloff)
	_cam.far = p_far
	await _frames(4)
	return _rendered()


func _criterion_f() -> void:
	_mesh.material_override = _mat
	var off: PackedFloat32Array = await _render_falloff(0.0, CAM_FAR)
	var one: PackedFloat32Array = await _render_falloff(1.0, CAM_FAR)
	var two: PackedFloat32Array = await _render_falloff(2.0, CAM_FAR)
	var near_far: PackedFloat32Array = await _render_falloff(1.0, CAM_FAR * 0.5)
	var ctl: PackedFloat32Array = await _render_falloff(0.0, CAM_FAR * 0.5)
	_cam.far = CAM_FAR
	_mat.set_shader_parameter("fft_displacement_falloff", 1.0)
	var f := 1.0 - CAM_HEIGHT / CAM_FAR
	var f2 := 1.0 - CAM_HEIGHT / (CAM_FAR * 0.5)
	var r1 := _sd_ratio(one, off)
	var r2 := _sd_ratio(two, off)
	var r3 := _sd_ratio(near_far, off)
	var rc := _sd_ratio(ctl, off)
	var tol := 0.03
	var ok: bool = sqrt(_variance(off)) > 0.05 and absf(r1 - f) < tol and absf(r2 - f * f) < tol \
			and absf(r3 - f2) < tol and absf(rc - 1.0) < tol and absf(rc - f) > 3.0 * tol
	_check("F", ok, "height sd vs falloff 0 (%s m): falloff 1 %.4f (want %.4f), falloff 2 %.4f (want %.4f), far %d %.4f (want %.4f), each within %.2f; control falloff 0 at far %d: %.4f (must miss %.4f)" % [
			_g(sqrt(_variance(off))), r1, f, r2, f * f, int(CAM_FAR * 0.5), r3, f2, tol, int(CAM_FAR * 0.5), rc, f])


# --- [N] normal strength, normal fade, foam fade -------------------------------------------------------

## [slope x, slope z, crest] per pixel from the shading readout.
func _shading(p_mat: ShaderMaterial, p_strength: float, p_normal: float, p_foam: float) -> Array:
	p_mat.set_shader_parameter("fft_normal_strength", p_strength)
	p_mat.set_shader_parameter("fft_normal_falloff", p_normal)
	p_mat.set_shader_parameter("fft_foam_falloff", p_foam)
	await _frames(4)
	var img := _vp.get_texture().get_image()
	var sx := PackedFloat32Array()
	var sz := PackedFloat32Array()
	var foam := PackedFloat32Array()
	for py in PIXELS:
		for px in PIXELS:
			var c := img.get_pixel(px, py)
			sx.append((c.r - 0.5) * 8.0)
			sz.append((c.g - 0.5) * 8.0)
			foam.append(c.b)
	return [sx, sz, foam]


func _criterion_n() -> void:
	var dbg := ShaderMaterial.new()
	dbg.shader = load(SHADING_SHADER)
	_manager.upload_profile_into(dbg, &"gate")
	# Foam everywhere on screen, mid-range so the clamp cannot hide the fade: the run is paused, and the
	# simulation accumulates no foam at dt 0. What [N] measures is the fade, not the foam.
	dbg.set_shader_parameter("_fft_foam_offset", 0.5)
	_mesh.material_override = dbg
	var f := 1.0 - CAM_HEIGHT / CAM_FAR

	var base: Array = await _shading(dbg, 1.0, 0.0, 0.0)
	var doubled: Array = await _shading(dbg, 2.0, 0.0, 0.0)
	var faded: Array = await _shading(dbg, 3.0, 1.0, 0.0)
	var foamed: Array = await _shading(dbg, 1.0, 0.0, 2.0)
	_mesh.material_override = _mat

	var n := PIXELS * PIXELS
	var s_rms := 0.0
	var e_double := 0.0
	var e_ref := 0.0
	var e_naive := 0.0
	var e_flat := 0.0
	var foam_sum := 0.0
	var e_foam := 0.0
	for i in n:
		var s := Vector2(base[0][i], base[1][i])
		s_rms += s.length_squared()
		e_double = maxf(e_double, (Vector2(doubled[0][i], doubled[1][i]) - 2.0 * s).length())
		var s3 := 3.0 * s
		var l := sqrt(1.0 + s3.length_squared())
		var want := s3 * (f / ((1.0 - f) * l + f))
		var got := Vector2(faded[0][i], faded[1][i])
		e_ref += (got - want).length_squared()
		e_naive += (got - s3 * f).length_squared()
		e_flat = maxf(e_flat, (Vector2(foamed[0][i], foamed[1][i]) - s).length())
		foam_sum += base[2][i]
		e_foam = maxf(e_foam, absf(foamed[2][i] - base[2][i] * f * f))
	s_rms = sqrt(s_rms / n)
	e_ref = sqrt(e_ref / n)
	e_naive = sqrt(e_naive / n)
	var foam_mean := foam_sum / n
	var tol := 0.01 + 0.01 * s_rms
	var ok: bool = s_rms > 0.05 and e_double < 0.01 * (1.0 + 2.0 * s_rms) and e_ref < tol and e_naive > 3.0 * e_ref \
			and e_flat < 1e-3 and foam_mean > 0.01 and e_foam < 2e-3
	_check("N", ok, "slope rms %.4f; strength 2: max |s - 2 s0| %.5f; strength 3 + normal falloff 1 at fade %.2f: rms error %.5f against the normal lerp (tol %.4f), control slope * f %.5f (must exceed 3x); foam falloff 2: crest mean %.4f, max |c - c0 f^2| %.5f (tol 2e-3), slopes moved %.6f (tol 1e-3)" % [
			s_rms, e_double, f, e_ref, tol, e_naive, foam_mean, e_foam, e_flat])
