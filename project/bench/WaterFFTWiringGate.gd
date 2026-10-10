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
#       writes _wave_model = 1, the simulation's own texture wrappers and its cascade lengths. Control:
#       switched to FBM, the same upload writes _wave_model = 2 and the profile reports inactive.
#   [T] Tick. Over TICK_FRAMES rendered frames the manager dispatches the simulation at least once a
#       frame and the simulation's own update count agrees. Control: in FBM nothing is dispatched.
#   [R] Render. An unlit top-down render of water_body_debug (EMISSION.b = height / 8 + 0.5) correlates
#       with the height the gate rebuilds from the simulation's readback, bilinear, at the shader's own
#       texel convention (domain * N / L - 0.5). Control: the same surface drawn by the fBm branch,
#       against the same prediction, must not correlate. The regression slope is printed, not gated:
#       correlation is what says the field is THIS field; the slope says the encoding survived the
#       viewport, which is the viewport's business.
#
# Every criterion counts its completions; one that throws before asserting reports as missing.

const CRITERIA: PackedStringArray = ["B", "W", "T", "R"]
const DEBUG_SHADER := "res://bench/water_body_debug.gdshader"
const RES := 128
const PATCH := 256.0
const PIXELS := 128
const SPACING := 2.0
const TICK_FRAMES := 10

var _fail := 0
var _seen: Dictionary = {}
var _manager: Pasture3DPoolManager
var _profile: Pasture3DWaveProfile
var _mat: ShaderMaterial
var _vp: SubViewport
var _mesh: MeshInstance3D


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
	cam.position = Vector3(0.0, 100.0, 0.0)
	# Looking down -Y, screen-right is +X and screen-up is -Z.
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	cam.far = 400.0
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
	var lengths: Vector4 = _mat.get_shader_parameter("_fft_lengths")
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
			and lengths == fft.cascade_lengths and live == 1 and res_ok and model_ctl == 2 and not active_ctl
	_check("W", ok, "FFT: active %s, _wave_model %d, textures %s/%s, lengths %s, live %d, resolution %d; control FBM: _wave_model %d, active %s" % [
			active, model_fft, disp_ok, slope_ok, lengths, live, fft.resolution, model_ctl, active_ctl])


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


## Bilinear, wrapping, of the y channel, at continuous texel coordinate (p_u, p_v).
func _bilinear_y(p_disp: PackedFloat32Array, p_n: int, p_u: float, p_v: float) -> float:
	var u0 := floori(p_u)
	var v0 := floori(p_v)
	var fu := p_u - float(u0)
	var fv := p_v - float(v0)
	var a := posmod(u0, p_n)
	var b := posmod(u0 + 1, p_n)
	var c := posmod(v0, p_n)
	var d := posmod(v0 + 1, p_n)
	var h00 := p_disp[(c * p_n + a) * 4 + 1]
	var h10 := p_disp[(c * p_n + b) * 4 + 1]
	var h01 := p_disp[(d * p_n + a) * 4 + 1]
	var h11 := p_disp[(d * p_n + b) * 4 + 1]
	return lerpf(lerpf(h00, h10, fu), lerpf(h01, h11, fu), fv)


## Height the shader should draw at each pixel centre, from the simulation's mip 0.
func _predict() -> PackedFloat32Array:
	var fft: Pasture3DWaterFFT = _profile.fft
	var lengths := fft.cascade_lengths
	var layers: Array[PackedFloat32Array] = []
	for c in 4:
		layers.append(_halves(fft.read_layer(Pasture3DWaterFFT.OUTPUT_DISPLACEMENT, c, 0)))
	var out := PackedFloat32Array()
	out.resize(PIXELS * PIXELS)
	for py in PIXELS:
		var z := (float(py) + 0.5) / float(PIXELS) * PATCH - PATCH * 0.5
		for px in PIXELS:
			var x := (float(px) + 0.5) / float(PIXELS) * PATCH - PATCH * 0.5
			var h := 0.0
			for c in 4:
				var k := float(RES) / lengths[c]
				h += _bilinear_y(layers[c], RES, x * k - 0.5, z * k - 0.5)
			out[py * PIXELS + px] = h
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
