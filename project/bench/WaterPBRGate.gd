extends Node
# Phase 3 of PASTURE3D_WATER_FFT_SPEC.md: Garrett's sun lighting in light().
#
# Run windowed under Forward+:
#   Godot_v4.7-stable_win64_console.exe --path project res://bench/WaterPBRGate.tscn
#
# A flat sheet of water_body.gdshader (an fBm of zero height, detail and foam off, absorption so
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
#       sheet has none. One fBm octave of CREST_WAVELENGTH (drag and speed zero, both sets alike), sampled
#       at its quarter-wavelength crest: height exactly CREST_HEIGHT once the unit mean is scaled out, normal
#       exactly up, slope zero. Low sun ahead, camera 40 deg up:
#       backlit, but far enough off the mirror direction that the sun lobe is ~0 and k1 is a large share
#       of the pixel. (Nearer the mirror the glint swamps k1, and the control margin went to 0.06.)
#       At wave_peak_scatter
#       0 and at K_STRENGTH the pixel matches its own prediction to within TOL. Control: the K_STRENGTH
#       render must miss the k1-free prediction by more than K_MIN_SHARE, so the term is really there.
#   [A] Attenuation. A box shadows the middle of the sheet in the body geometry. The shadowed pixel is
#       under SHADOW_FRACTION of the prediction. Control: the same frame with the light's shadows off
#       must match the prediction -- otherwise "dark" could mean the box is simply in front of the pixel.
#
# R4 of PASTURE3D_WATER_REFERENCE_SPEC.md: the reference's output, ALBEDO 0 and every sun term in
# SPECULAR_LIGHT. The shore foam is the gate's foam source: an unshaded black floor FLOOR_DEPTH under the
# sheet puts every pixel at a known thickness, t / sin(camera elevation) through the orthographic view, so
# the foam is (1 - smoothstep(0, SHORE_DEPTH, thickness)) exactly (foam_tex is its default white).
#   [S] Scatter colour (L5). The body terms are lit in scatter_color: with deep_color set to a decoy, the
#       body-geometry pixel matches the prediction in scatter_color. Control: the same pixel against the
#       prediction in the decoy must miss by over half of itself.
#   [F] Foam is an unlit lerp (L1). Body geometry over the floor: the pixel is foam * foam_color plus
#       (1 - foam) times the water's light. With the sun hidden, it is foam * foam_color alone -- the foam
#       glows in the dark, as the reference's does. Control: the pre-R4 form, the foam lambert-lit by the sun
#       and nothing emitted, must miss the lit pixel by over F_CTRL.
#   [R] Foam roughness (L3). Spec geometry over the floor, foam_roughness_modifier R_MODIFIER: the sun lobe's
#       alpha is sun_roughness + foam * modifier, and the pixel matches that. Control: the prediction at
#       the unmodified alpha must miss by over R_CTRL.
#   [M] Environment map (L4). A cubemap whose +Y face differs from the other five, the sun hidden: the
#       pixel is F(n.v) * +Y * environment_light_strength, the reflected ray being mostly up. Control: the
#       same prediction from any other face's colour misses by over half of itself -- the ray reached the
#       map in WORLD space. Anti-null: with use_environment_map off the pixel is black (this world reflects
#       nothing).
#
# Every criterion counts its completions; one that throws before asserting reports as missing.

const CRITERIA: PackedStringArray = ["E", "K", "A", "S", "F", "R", "M"]
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
const BUBBLE := Color(0.0, 0.151704, 0.133352)
const BUBBLE_DENSITY := 1.0
const CREST_WAVELENGTH := 4000.0
const CREST_HEIGHT := 2.0
const K_STRENGTH := 8.0
const K_MIN_SHARE := 0.2
# deep_color's value while scatter_color does the lighting: it must not reach the pixel.
const DECOY := Color(0.1, 0.7, 0.9)
const FOAM_COLOR := Color(0.85, 0.89, 0.92)
const FLOOR_DEPTH := 0.6
const SHORE_DEPTH := 1.0
const F_CTRL := 0.2
const R_MODIFIER := 0.5
const R_CTRL := 0.1
const ENV_UP := Color8(51, 128, 230)
const ENV_SIDE := Color8(230, 77, 26)
const ENV_STRENGTH := 4.0

var _fail := 0
var _seen: Dictionary = {}
var _vp: SubViewport
var _cam: Camera3D
var _sun: DirectionalLight3D
var _box: MeshInstance3D
var _mat: ShaderMaterial
var _sheet: MeshInstance3D
var _floor: MeshInstance3D


func _ready() -> void:
	print("=== WaterPBRGate ===")
	_build()
	await _criterion_e()
	await _criterion_k()
	await _criterion_a()
	await _criterion_s()
	await _criterion_f()
	await _criterion_r()
	await _criterion_m()
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
	# The fBm branch at zero height: flat, slope zero, crest height zero.
	_set_fbm(mat, 0.0)
	mat.set_shader_parameter("detail_strength", 0.0)
	mat.set_shader_parameter("foam_shore_amount", 0.0)
	mat.set_shader_parameter("absorption", Vector3(100.0, 100.0, 100.0))
	mat.set_shader_parameter("scatter_color", DEEP)
	mat.set_shader_parameter("deep_color", DECOY)
	mat.set_shader_parameter("foam_color", FOAM_COLOR)
	mat.set_shader_parameter("foam_shore_depth", SHORE_DEPTH)
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

	# Opaque, so the depth prepass has it; unshaded black, so nothing of it shows through the water.
	_floor = MeshInstance3D.new()
	var floor_plane := PlaneMesh.new()
	floor_plane.size = Vector2(60.0, 60.0)
	_floor.mesh = floor_plane
	var floor_mat := StandardMaterial3D.new()
	floor_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	floor_mat.albedo_color = Color.BLACK
	_floor.material_override = floor_mat
	_floor.position = Vector3(0.0, -FLOOR_DEPTH, 0.0)
	_floor.visible = false
	_vp.add_child(_floor)


# One octave along +x of CREST_WAVELENGTH, still and undragged, in both sets, whose crest stands p_crest
# metres above rest: the octave peaks at exp(0) = 1 and its mean exp(-1) I0(1) is subtracted, so the
# normalised peak is 1 - unit_mean and `height` scales it to p_crest.
func _set_fbm(p_mat: ShaderMaterial, p_crest: float) -> void:
	var fbm := Pasture3DWaterFBM.new()
	for s in 2:
		fbm.set_knob(s, &"octaves", 1.0)
		fbm.set_knob(s, &"seed", 0.0)
		fbm.set_knob(s, &"frequency", TAU / CREST_WAVELENGTH)
		fbm.set_knob(s, &"speed", 0.0)
		fbm.set_knob(s, &"drag", 0.0)
		fbm.set_knob(s, &"max_peak", 1.0)
		fbm.set_knob(s, &"peak_offset", 1.0)
		fbm.set_knob(s, &"height", p_crest / (1.0 - fbm.get_unit_mean(s)))
	p_mat.set_shader_parameter("_wave_model", 2)
	for s in 2:
		var pack := fbm.get_shader_pack(s)
		for i in 4:
			p_mat.set_shader_parameter("_fbm_%s%d" % ["v" if s == Pasture3DWaterFBM.SET_VERTEX else "f", i], pack[i])


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


func _fresnel(p_n_dot_v: float, p_alpha: float) -> float:
	return clampf(0.020059 + 0.979941 * pow(maxf(1.0 - p_n_dot_v, 0.0), 5.0 * exp(-2.69 * p_alpha))
			/ (1.0 + 22.7 * pow(p_alpha, 1.5)), 0.0, 1.0)


# The reference's output for a level normal, as a white sun of p_energy sees it:
#   (1 - foam) * irr * ((1 - F) * (body * scatter_color + bubbles) + specular) + foam * foam_color.
# p_pi_fold false is the control: the irradiance Godot's LIGHT_COLOR gives with the PI left in. p_k1 is
# wave_peak_scatter times the crest height. p_alpha_add is foam * foam_roughness_modifier. p_lit_foam is the
# pre-R4 control: the foam lambert-lit by the sun instead of emitted.
func _predict(p_to_sun: Vector3, p_to_cam: Vector3, p_energy: float, p_pi_fold: bool,
		p_k1 := 0.0, p_foam := 0.0, p_alpha_add := 0.0, p_body := DEEP, p_lit_foam := false) -> Vector3:
	var n := Vector3.UP
	var l := p_to_sun.normalized()
	var v := p_to_cam.normalized()
	var irr := p_energy * (1.0 if p_pi_fold else PI)
	var h := (l + v).normalized()
	var n_dot_l := clampf(n.dot(l), 0.0, 1.0)
	var a := SUN_ROUGHNESS + p_alpha_add
	var light_mask := _smith(h, l, a)
	var g := 1.0 / (1.0 + _smith(h, v, a) + light_mask)
	var f := _fresnel(n.dot(v), a)
	var up_dot_l := maxf(0.001, clampf(n.dot(l), 0.0, 1.0))
	var ndoth := maxf(1e-4, n.dot(h))
	var n2 := ndoth * ndoth
	var d := exp((n2 - 1.0) / (a * a * n2)) / (PI * a * a * n2 * n2)
	var spec := f * g * d / (4.0 * up_dot_l) * n_dot_l
	var v_dot_n := clampf(v.dot(n), 0.0, 1.0)
	var into_sun := clampf(l.dot(-v), 0.0, 1.0)
	var away := 0.5 - 0.5 * l.dot(n)
	var k1 := p_k1 * pow(into_sun, 4.0) * pow(away, 3.0)
	var body := (VIEW_SCATTER * v_dot_n * v_dot_n + k1) / (1.0 + light_mask) + SHADOW_SCATTER * n_dot_l
	var tint := p_body.srgb_to_linear()
	var bubble := BUBBLE.srgb_to_linear()
	var foam_lin := FOAM_COLOR.srgb_to_linear()
	var out := Vector3.ZERO
	for i in 3:
		var water: float = irr * ((1.0 - f) * (body * tint[i] + BUBBLE_DENSITY * bubble[i]) + spec)
		var foam_term: float = irr * n_dot_l * foam_lin[i] if p_lit_foam else foam_lin[i]
		out[i] = (1.0 - p_foam) * water + p_foam * foam_term
	return out


# The shore foam over the floor, seen from p_to_cam: the orthographic ray crosses FLOOR_DEPTH of water in
# FLOOR_DEPTH / sin(elevation) of view depth.
func _floor_foam(p_to_cam: Vector3) -> float:
	var thickness := FLOOR_DEPTH / p_to_cam.normalized().y
	return clampf(1.0 - smoothstep(0.0, SHORE_DEPTH, thickness), 0.0, 1.0)


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
	_set_fbm(_mat, CREST_HEIGHT)
	_sheet.position = Vector3(crest_x, 0.0, 0.0)
	_pose(to_sun, to_cam, Vector3(crest_x, CREST_HEIGHT, 0.0))
	_sun.light_energy = 0.25
	var results := []
	for strength in [0.0, K_STRENGTH]:
		_mat.set_shader_parameter("wave_peak_scatter", strength)
		results.append(await _sample())
	_mat.set_shader_parameter("wave_peak_scatter", 1.0)
	_set_fbm(_mat, 0.0)
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


func _criterion_s() -> void:
	var to_sun := _dir(35.0, 0.0)
	var to_cam := _dir(60.0, 180.0)
	_pose(to_sun, to_cam)
	_sun.light_energy = 0.25
	var got := await _sample()
	var want := _predict(to_sun, to_cam, 0.25, true)
	var decoy := _predict(to_sun, to_cam, 0.25, true, 0.0, 0.0, 0.0, DECOY)
	var err := _rel_err(got, want)
	var ctrl := _rel_err(got, decoy)
	_check("S", err < TOL and ctrl > 0.5,
			"scatter_color %s, deep_color %s: got %s want %s err %.4f | lit-in-deep_color control err %.3f" % [
				_fmt(DEEP), _fmt(DECOY), _fmt(got), _fmt(want), err, ctrl])


func _criterion_f() -> void:
	var to_sun := _dir(35.0, 0.0)
	var to_cam := _dir(60.0, 180.0)
	var foam := _floor_foam(to_cam)
	_pose(to_sun, to_cam)
	_sun.light_energy = 0.25
	_mat.set_shader_parameter("foam_shore_amount", 1.0)
	_floor.visible = true
	var lit := await _sample()
	_sun.visible = false
	var dark := await _sample()
	_sun.visible = true
	_floor.visible = false
	_mat.set_shader_parameter("foam_shore_amount", 0.0)

	var want := _predict(to_sun, to_cam, 0.25, true, 0.0, foam)
	var want_dark := _predict(to_sun, to_cam, 0.0, true, 0.0, foam)
	var old := _predict(to_sun, to_cam, 0.25, true, 0.0, foam, 0.0, DEEP, true)
	var err := _rel_err(lit, want)
	var err_dark := _rel_err(dark, want_dark)
	var ctrl := _rel_err(lit, old)
	_check("F", foam > 0.1 and err < TOL and err_dark < TOL and ctrl > F_CTRL,
			"foam %.4f | lit got %s want %s err %.4f | sun hidden got %s want foam * foam_color %s err %.4f | lambert-lit foam control err %.3f" % [
				foam, _fmt(lit), _fmt(want), err, _fmt(dark), _fmt(want_dark), err_dark, ctrl])


func _criterion_r() -> void:
	var to_sun := _dir(90.0, 0.0)
	var to_cam := _dir(90.0, 0.0)
	var foam := _floor_foam(to_cam)
	_pose(to_sun, to_cam)
	_sun.light_energy = 0.25
	_mat.set_shader_parameter("foam_shore_amount", 1.0)
	_mat.set_shader_parameter("foam_roughness_modifier", R_MODIFIER)
	_floor.visible = true
	var got := await _sample()
	_floor.visible = false
	_mat.set_shader_parameter("foam_roughness_modifier", 0.0)
	_mat.set_shader_parameter("foam_shore_amount", 0.0)

	var want := _predict(to_sun, to_cam, 0.25, true, 0.0, foam, foam * R_MODIFIER)
	var unmodified := _predict(to_sun, to_cam, 0.25, true, 0.0, foam)
	var err := _rel_err(got, want)
	var ctrl := _rel_err(got, unmodified)
	_check("R", foam > 0.1 and err < TOL and ctrl > R_CTRL,
			"foam %.4f, alpha %.4f: got %s want %s err %.4f | unmodified-alpha control err %.3f" % [
				foam, SUN_ROUGHNESS + foam * R_MODIFIER, _fmt(got), _fmt(want), err, ctrl])


func _criterion_m() -> void:
	var to_cam := _dir(60.0, 180.0)
	var images: Array[Image] = []
	for face in 6:
		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		# Layer order +X, -X, +Y, -Y, +Z, -Z.
		img.fill(ENV_UP if face == 2 else ENV_SIDE)
		images.append(img)
	var cube := Cubemap.new()
	cube.create_from_images(images)
	_pose(_dir(35.0, 0.0), to_cam)
	_sun.visible = false
	_mat.set_shader_parameter("environment_map", cube)
	_mat.set_shader_parameter("environment_light_strength", ENV_STRENGTH)
	var off := await _sample()
	_mat.set_shader_parameter("use_environment_map", true)
	var got := await _sample()
	_mat.set_shader_parameter("use_environment_map", false)
	_sun.visible = true

	var f := _fresnel(to_cam.normalized().y, SUN_ROUGHNESS)
	var up := ENV_UP.srgb_to_linear()
	var side := ENV_SIDE.srgb_to_linear()
	var want := Vector3(up.r, up.g, up.b) * (f * ENV_STRENGTH)
	var wrong := Vector3(side.r, side.g, side.b) * (f * ENV_STRENGTH)
	var err := _rel_err(got, want)
	var ctrl := _rel_err(got, wrong)
	var off_sum := off.r + off.g + off.b
	_check("M", err < TOL and ctrl > 0.5 and off_sum < 1e-4,
			"F %.4f: got %s want F * +Y * strength %s err %.4f | other-face control err %.3f | map off %s" % [
				f, _fmt(got), _fmt(want), err, ctrl, _fmt(off)])
