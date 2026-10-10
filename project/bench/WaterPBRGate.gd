extends Node
# Phase 3 of PASTURE3D_WATER_FFT_SPEC.md: Garrett's sun lighting in light().
#
# Run windowed under Forward+:
#   Godot_v4.7-stable_win64_console.exe --path project res://bench/WaterPBRGate.tscn
#
# A flat sheet of water_body.gdshader (a wave table of zero amplitude, detail and foam off, absorption so
# high the depth fade is opaque) under one white DirectionalLight3D, in a world with no sky, no ambient
# and no reflections, linear tonemap, float readback. The only light on the pixel is light()'s, so the
# pixel can be predicted exactly: _predict() is the shader's arithmetic in GDScript.
#
#   [E] Energy. Two geometries, each predicted to within TOL:
#         spec  -- sun and camera overhead: the Beckmann peak, D = 1 / (pi a^2), G = 1, F = R.
#         body  -- sun 35 deg up, camera 60 deg up on the far side: off the lobe, so the pixel is the
#                  (1 - F) body terms k2 and k3 and the bubble term k4.
#       Control: the same prediction without the divide by PI must miss by over half of itself (it is PI x
#       the pixel, so 1 - 1/PI = 0.68 when the shader is right) in both. That is
#       the silent error this pins -- Godot's LIGHT_COLOR is colour * energy * PI, measured, not assumed.
#       Anti-null: doubling the light's energy doubles the pixel to within TOL, so what is being
#       predicted is the light's contribution and not a constant that happens to land near it.
#   [K] Crest scatter (k1). The only term [E] cannot see, because it scales with crest height and a flat
#       sheet has none. One Gerstner wave of CREST_WAVELENGTH, sampled at its quarter-wavelength crest:
#       height exactly CREST_HEIGHT, normal exactly up, slope zero. Low sun ahead, camera 40 deg up:
#       backlit, but far enough off the mirror direction that the sun lobe is ~0 and k1 is a large share
#       of the pixel. (Nearer the mirror the glint swamps k1, and the control margin went to 0.06.)
#       At wave_peak_scatter
#       0 and at K_STRENGTH the pixel matches its own prediction to within TOL. Control: the K_STRENGTH
#       render must miss the k1-free prediction by more than K_MIN_SHARE, so the term is really there.
#   [A] Attenuation. A box shadows the middle of the sheet in the body geometry. The shadowed pixel is
#       under SHADOW_FRACTION of the prediction. Control: the same frame with the light's shadows off
#       must match the prediction -- otherwise "dark" could mean the box is simply in front of the pixel.
#
# Every criterion counts its completions; one that throws before asserting reports as missing.

const CRITERIA: PackedStringArray = ["E", "K", "A"]
const SHADER := "res://addons/pasture_3d/extras/shaders/water/water_body.gdshader"
const PIXELS := 32
const TOL := 0.02
const SHADOW_FRACTION := 0.05
# sRGB, as an artist would type it into the source_color uniform. The prediction linearises it.
const DEEP := Color(0.5, 0.4, 0.3)
# The shader's own defaults, which the gate leaves alone so that it tests the shipped values.
const SUN_ROUGHNESS := 0.075
const VIEW_SCATTER := 1.0
const SHADOW_SCATTER := 0.5
const BUBBLE := Color(0.0, 0.02, 0.016)
const BUBBLE_DENSITY := 1.0
const CREST_WAVELENGTH := 4000.0
const CREST_HEIGHT := 2.0
const K_STRENGTH := 8.0
const K_MIN_SHARE := 0.2

var _fail := 0
var _seen: Dictionary = {}
var _vp: SubViewport
var _cam: Camera3D
var _sun: DirectionalLight3D
var _box: MeshInstance3D
var _mat: ShaderMaterial
var _sheet: MeshInstance3D


func _ready() -> void:
	print("=== WaterPBRGate ===")
	_build()
	await _criterion_e()
	await _criterion_k()
	await _criterion_a()
	var missing := 0
	for c in CRITERIA:
		if not _seen.has(c):
			missing += 1
			print("  FAIL %s: never reported" % c)
	var ok := _fail == 0 and missing == 0
	print("=== WATER PBR %s (%d failures, %d/%d criteria reported) ===" % [
			"PASS" if ok else "FAIL", _fail + missing, CRITERIA.size() - missing, CRITERIA.size()])
	get_tree().quit(0 if ok else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_fail += 1


func _build() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(PIXELS, PIXELS)
	_vp.own_world_3d = true
	_vp.use_hdr_2d = true
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
	_cam.size = 10.0
	_cam.far = 200.0
	_cam.current = true
	_vp.add_child(_cam)

	_sun = DirectionalLight3D.new()
	_sun.shadow_enabled = false
	_vp.add_child(_sun)

	# The crest criterion needs a known phase: no manager drives the clock here, but nothing should.
	RenderingServer.global_shader_parameter_set("water_time", 0.0)
	var mat := ShaderMaterial.new()
	_mat = mat
	mat.shader = load(SHADER)
	# w > 0 keeps the shader off its compile-time fallback table; zero amplitude keeps the sheet flat.
	var waves := PackedVector4Array()
	for i in 8:
		waves.append(Vector4(1.0, 0.0, 0.0, 100.0))
	mat.set_shader_parameter("_waves", waves)
	mat.set_shader_parameter("wave_steepness", 0.0)
	mat.set_shader_parameter("detail_strength", 0.0)
	mat.set_shader_parameter("foam_shore_amount", 0.0)
	mat.set_shader_parameter("absorption", Vector3(100.0, 100.0, 100.0))
	mat.set_shader_parameter("deep_color", DEEP)
	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60.0, 60.0)
	plane.subdivide_width = 29
	plane.subdivide_depth = 29
	mi.mesh = plane
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sheet = mi
	_vp.add_child(mi)

	_box = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(4.0, 4.0, 4.0)
	_box.mesh = box
	_box.visible = false
	_vp.add_child(_box)


func _dir(p_elevation_deg: float, p_azimuth_deg: float) -> Vector3:
	var e := deg_to_rad(p_elevation_deg)
	var a := deg_to_rad(p_azimuth_deg)
	return Vector3(cos(e) * cos(a), sin(e), cos(e) * sin(a))


# Points the sun's light along -p_to_sun and the camera along -p_to_cam, both at p_at.
func _pose(p_to_sun: Vector3, p_to_cam: Vector3, p_at := Vector3.ZERO) -> void:
	var hint := Vector3.FORWARD if absf(p_to_sun.y) > 0.99 else Vector3.UP
	_sun.look_at_from_position(p_at + p_to_sun * 50.0, p_at, hint)
	hint = Vector3.FORWARD if absf(p_to_cam.y) > 0.99 else Vector3.UP
	_cam.look_at_from_position(p_at + p_to_cam * 50.0, p_at, hint)


func _sample() -> Color:
	for i in 6:
		await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	var sum := Color(0, 0, 0, 0)
	var c := PIXELS / 2
	for y in range(c - 1, c + 1):
		for x in range(c - 1, c + 1):
			sum += img.get_pixel(x, y)
	return sum / 4.0


func _smith(p_h: Vector3, p_s: Vector3, p_alpha: float) -> float:
	var h_dot_s := maxf(0.001, clampf(p_h.dot(p_s), 0.0, 1.0))
	var a := h_dot_s / (p_alpha * sqrt(maxf(1.0 - h_dot_s * h_dot_s, 1e-12)))
	return (1.0 - 1.259 * a + 0.396 * a * a) / (3.535 * a + 2.181 * a * a) if a < 1.6 else 0.0


# light() for a level normal and no foam, as a white sun of p_energy sees it. p_pi_fold false is the
# control: the irradiance Godot's LIGHT_COLOR gives with the PI left in. p_k1 is wave_peak_scatter times
# the crest height.
func _predict(p_to_sun: Vector3, p_to_cam: Vector3, p_energy: float, p_pi_fold: bool,
		p_k1 := 0.0) -> Vector3:
	var n := Vector3.UP
	var l := p_to_sun.normalized()
	var v := p_to_cam.normalized()
	var irr := p_energy * (1.0 if p_pi_fold else PI)
	var h := (l + v).normalized()
	var n_dot_l := clampf(n.dot(l), 0.0, 1.0)
	var a := SUN_ROUGHNESS
	var light_mask := _smith(h, l, a)
	var g := 1.0 / (1.0 + _smith(h, v, a) + light_mask)
	var f := clampf(0.020059 + 0.979941 * pow(maxf(1.0 - n.dot(v), 0.0), 5.0 * exp(-2.69 * a))
			/ (1.0 + 22.7 * pow(a, 1.5)), 0.0, 1.0)
	var up_dot_l := maxf(0.001, clampf(n.dot(l), 0.0, 1.0))
	var ndoth := maxf(1e-4, n.dot(h))
	var n2 := ndoth * ndoth
	var d := exp((n2 - 1.0) / (a * a * n2)) / (PI * a * a * n2 * n2)
	var spec := irr * f * g * d / (4.0 * up_dot_l) * n_dot_l
	var v_dot_n := clampf(v.dot(n), 0.0, 1.0)
	var into_sun := clampf(l.dot(-v), 0.0, 1.0)
	var away := 0.5 - 0.5 * l.dot(n)
	var k1 := p_k1 * pow(into_sun, 4.0) * pow(away, 3.0)
	var body := (VIEW_SCATTER * v_dot_n * v_dot_n + k1) / (1.0 + light_mask) + SHADOW_SCATTER * n_dot_l
	var deep := DEEP.srgb_to_linear()
	var bubble := BUBBLE.srgb_to_linear()
	var out := Vector3.ZERO
	for i in 3:
		out[i] = spec + irr * (1.0 - f) * (body * deep[i] + BUBBLE_DENSITY * bubble[i])
	return out


func _rel_err(p_got: Color, p_want: Vector3) -> float:
	var worst := 0.0
	for i in 3:
		worst = maxf(worst, absf(p_got[i] - p_want[i]) / maxf(p_want[i], 1e-6))
	return worst


func _fmt(p_c: Variant) -> String:
	return "(%.4f %.4f %.4f)" % [p_c[0], p_c[1], p_c[2]]


func _criterion_e() -> void:
	var geoms := [
		["spec", _dir(90.0, 0.0), _dir(90.0, 0.0)],
		["body", _dir(35.0, 0.0), _dir(60.0, 180.0)],
	]
	var all_ok := true
	var details := PackedStringArray()
	for gm in geoms:
		_pose(gm[1], gm[2])
		_sun.light_energy = 0.25
		var got := await _sample()
		var want := _predict(gm[1], gm[2], 0.25, true)
		var unfolded := _predict(gm[1], gm[2], 0.25, false)
		var err := _rel_err(got, want)
		var ctrl := _rel_err(got, unfolded)
		_sun.light_energy = 0.5
		var got2 := await _sample()
		var ratio := (got2.r + got2.g + got2.b) / maxf(got.r + got.g + got.b, 1e-9)
		var ok := err < TOL and ctrl > 0.5 and absf(ratio - 2.0) < 2.0 * TOL and got.g > 0.01
		all_ok = all_ok and ok
		details.append("%s got %s want %s err %.4f | no-PI control err %.3f | 2x energy ratio %.4f" % [
				gm[0], _fmt(got), _fmt(want), err, ctrl, ratio])
	_check("E", all_ok, "\n      " + "\n      ".join(details))


func _criterion_k() -> void:
	var to_sun := _dir(5.0, 0.0)
	var to_cam := _dir(40.0, 180.0)
	var crest_x := CREST_WAVELENGTH * 0.25
	var waves := PackedVector4Array()
	waves.append(Vector4(1.0, 0.0, CREST_HEIGHT, CREST_WAVELENGTH))
	for i in 7:
		waves.append(Vector4(1.0, 0.0, 0.0, 100.0))
	_mat.set_shader_parameter("_waves", waves)
	_sheet.position = Vector3(crest_x, 0.0, 0.0)
	_pose(to_sun, to_cam, Vector3(crest_x, CREST_HEIGHT, 0.0))
	_sun.light_energy = 0.25
	var results := []
	for strength in [0.0, K_STRENGTH]:
		_mat.set_shader_parameter("wave_peak_scatter", strength)
		results.append(await _sample())
	_mat.set_shader_parameter("wave_peak_scatter", 1.0)
	var flat := PackedVector4Array()
	for i in 8:
		flat.append(Vector4(1.0, 0.0, 0.0, 100.0))
	_mat.set_shader_parameter("_waves", flat)
	_sheet.position = Vector3.ZERO

	var want0 := _predict(to_sun, to_cam, 0.25, true)
	var want_k := _predict(to_sun, to_cam, 0.25, true, K_STRENGTH * CREST_HEIGHT)
	var err0 := _rel_err(results[0], want0)
	var err_k := _rel_err(results[1], want_k)
	var ctrl := _rel_err(results[1], want0)
	_check("K", err0 < TOL and err_k < TOL and ctrl > K_MIN_SHARE,
			"k1 off got %s want %s err %.4f | k1 %.0f got %s want %s err %.4f | k1-free control err %.3f" % [
				_fmt(results[0]), _fmt(want0), err0, K_STRENGTH, _fmt(results[1]), _fmt(want_k), err_k, ctrl])


func _criterion_a() -> void:
	var to_sun := _dir(35.0, 0.0)
	var to_cam := _dir(60.0, 180.0)
	_pose(to_sun, to_cam)
	_sun.light_energy = 0.25
	# Up the sun's ray from the origin, so the box's shadow lands on the sampled pixel and the box itself
	# sits on the far side from the camera.
	_box.position = to_sun * 10.0
	_box.visible = true
	_sun.shadow_enabled = true
	var shadowed := await _sample()
	_sun.shadow_enabled = false
	var unshadowed := await _sample()
	_box.visible = false
	var want := _predict(to_sun, to_cam, 0.25, true)
	var lum_want := want.x + want.y + want.z
	var frac := (shadowed.r + shadowed.g + shadowed.b) / lum_want
	var ctrl_err := _rel_err(unshadowed, want)
	_check("A", frac < SHADOW_FRACTION and ctrl_err < TOL,
			"shadowed %s = %.4f of predicted | shadows-off control %s err %.4f" % [
				_fmt(shadowed), frac, _fmt(unshadowed), ctrl_err])
