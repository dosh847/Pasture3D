extends Node
# R6 of PASTURE3D_WATER_REFERENCE_SPEC.md: the pixel A/B against GarrettGunnell/Water's NEW_LIGHTING fp().
#
# Run windowed under Forward+:
#   Godot_v4.7-stable_win64_console.exe --path project res://bench/WaterReferenceABGate.tscn
#
# The shipped Garrett instance -- M_water_ocean.tres's values on the ocean's open-water path
# (water_ref_lit.gdshader), the manager's ocean_default profile, a sun of SUN_LIGHT_COLOR -- is rendered
# over live FFT waves in a world with no sky, ambient or reflections, linear tonemap, float readback. The
# same frame is read back again, one input a pass (water_ref_inputs.gdshader): the cascades' summed slope,
# foam and height, RAW, the view direction, the fade depth and the rest position. ref_fp() is the
# reference's fragment transcribed from FFTWater.shader, fed those inputs and the reference scene's
# lighting values (REF_*), spelled here and nowhere else: so the pixel can match only if our shading AND
# the shipped material's values are the reference's. The environment map is a cubemap of one colour, so
# its term is exact whatever the reflected ray.
#
#   [D] Depth. Our fade depth is the reference's, 1 - Linear01Depth = 1 - z_eye / F, z_eye taken from the
#       REST position the readout returns. F is fitted, not assumed: Godot's reversed-Z projection is built
#       in float32, and 0.5 ((f + n) / (f - n) - 1) cancels, so the depth buffer -- and the fade, which reads
#       the same matrix -- ends a little short of the nominal far (1997.33 m of 2000 at near 0.05). The fade
#       reaching 0 where Godot stops drawing is the reference's meaning. So: F within FAR_REL of the camera's
#       far, and every pixel within D_TOL of 1 - z_eye / F. Control: the same fitted from the distance
#       instead of z_eye must leave a residual over D_CTRL.
#   [A] The A/B, per view. VIEWS lists them: the reference's own settings looking into a low sun (the
#       glitter path, and the crest scatter k1 backlit), the sun behind the camera, and an exercised view
#       off the scene's values -- normal strength 2, foam_roughness_modifier 0.5, a 150 m far plane so both
#       fades bite -- since a term at its scene value of 0 or 1 cannot show it is wired. Per water pixel,
#       err = max over rgb of |got - want| / (|want| + ERR_FLOOR); the view passes with its P99 under TOL
#       and its worst pixel under MAX_TOL. Every L-row of spec §3.3 that R1-R5 ported is broken in turn in
#       ref_fp() and must FAIL the view as a render would: its P99 err over CTRL_FACTOR x TOL, or its worst
#       pixel over CTRL_FACTOR x MAX_TOL -- the gate would catch a shader with that break. The
#       controls are scored over every water pixel, since a break is caught wherever it shows. The
#       scene's foam offset makes no foam on this sea (raw foam peaks near -0.14), so the exercised view
#       lifts _fft_foam_offset by FOAM_LIFT on both materials, and carries the three foam breaks.
#         colours  -- the reference's colours read as sRGB-authored and linearised. FFTWater.cs passes them
#                     with SetVector, which does not convert, so the shader sees the typed numbers.
#         sun      -- the light colour taken as the irradiance, with Godot's linearisation left out.
#         L1       -- the foam lambert-lit by the sun, not an unlit lerp.
#         L2       -- the crest multiplied by foam_tex (a constant FOAM_TEX_GREY here).
#         L3       -- the foam roughness modifier left out (exercised view).
#         L4       -- no environment term.
#         L5       -- the body lit in deep_color instead of scatter_color.
#         L8       -- normal strength 1 (exercised view).
#         G5       -- no normal or foam fade (exercised view).
#   Anti-null: each view must have at least MIN_WATER water pixels, the exercised view MIN_FOAM foamy ones,
#   and the sun lobe (specular over the body) must reach MIN_GLINT pixels in the view into the sun.
#
# Every criterion counts its completions; one that throws before asserting reports as missing.

const CRITERIA: PackedStringArray = ["D", "A"]
const LIT_SHADER := "res://bench/water_ref_lit.gdshader"
const INPUT_SHADER := "res://bench/water_ref_inputs.gdshader"
const MATERIAL := "res://addons/pasture_3d/extras/shaders/water/M_water_ocean.tres"
const WIDTH := 192
const HEIGHT := 108
const FOV := 60.0
const SPACING := 1.0
const PATCH := 600.0
# Frames the simulation runs before the pause, so the foam has accumulated somewhere.
const WARM_FRAMES := 240
const TOL := 3e-3
const MAX_TOL := 3e-2
const ERR_FLOOR := 2e-3
const CTRL_FACTOR := 3.0
const D_TOL := 1e-5
const D_CTRL := 1e-4
const FAR_REL := 2e-3
const FOAM_LIFT := 0.75
const MIN_WATER := 5000
const MIN_FOAM := 100
const MIN_GLINT := 50
const FOAMY := 0.05

# The reference scene's lighting (spec §2), as its shader receives them: SetVector passes the numbers through.
const REF_SUN := Vector3(1.0, 0.694, 0.32)
const REF_SCATTER := Vector3(0.016, 0.0736, 0.16)
const REF_BUBBLE := Vector3(0.0, 0.02, 0.016)
const REF_FOAM := Vector3(0.6, 0.5568, 0.492)
const REF_ROUGHNESS := 0.075
const REF_FOAM_ROUGHNESS := 0.0
const REF_HEIGHT_MODIFIER := 1.0
const REF_WAVE_PEAK := 1.0
const REF_SCATTER_STRENGTH := 1.0
const REF_SHADOW_STRENGTH := 0.5
const REF_BUBBLE_DENSITY := 1.0
const REF_ENV_STRENGTH := 0.5
const REF_NORMAL_STRENGTH := 1.0
const REF_NORMAL_ATTEN := 1.0
const REF_FOAM_ATTEN := 1.0

# The light that IS the reference's irradiance, as PASTURE3D_WATER_GUIDE.md tells a user to set it: REF_SUN
# sRGB-encoded, since Godot linearises a light's colour.
const SUN_LIGHT_COLOR := Color(1.0, 0.85105, 0.601243)
# White: 255 decodes to exactly 1, where a mid value carries the GPU's sRGB decode (a 0.3% channel bias at
# 90/255). PBR [M] already gates the map's colour and direction.
const ENV_COLOR := Color8(255, 255, 255)
const FOAM_TEX_GREY := 0.5
const EXERCISE_STRENGTH := 2.0
const EXERCISE_FOAM_ROUGHNESS := 0.5

# name, sun elevation/azimuth (deg), camera pitch (deg), camera height, far, exercised
const VIEWS := [
	["into the sun", 12.0, 0.0, -10.0, 6.0, 2000.0, false],
	["sun behind", 35.0, 180.0, -14.0, 6.0, 2000.0, false],
	["exercised", 25.0, 30.0, -16.0, 6.0, 150.0, true],
]

enum In { SX, SZ, FOAM, HEIGHT, VX, VY, VZ, DEPTH, DX, DZ }
const IN_COUNT := 10

var _fail := 0
var _seen: Dictionary = {}
var _manager: Pasture3DPoolManager
var _vp: SubViewport
var _cam: Camera3D
var _sun: DirectionalLight3D
var _mesh: MeshInstance3D
var _lit: ShaderMaterial
var _inputs: ShaderMaterial
var _deep_lin: Vector3
var _sun_typed: Vector3
var _scene_foam_offset: Variant = null


func _ready() -> void:
	print("=== WaterReferenceABGate ===")
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
	print("=== WATER REFERENCE A/B %s (%d failures, %d/%d criteria reported) ===" % [
			"PASS" if ok else "FAIL", _fail + missing, CRITERIA.size() - missing, CRITERIA.size()])
	get_tree().quit(0 if ok else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_seen[p_name] = true
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_fail += 1


func _frames(p_count: int) -> void:
	for i in p_count:
		await RenderingServer.frame_post_draw


func _run() -> void:
	_manager = Pasture3DPoolManager.new()
	add_child(_manager)
	_build()
	await _frames(WARM_FRAMES)
	_manager.paused = true
	# Again, now the simulation exists: a material the renderer drew before the FFT textures were built
	# keeps their black placeholder (a flat sea) until a parameter set rebinds it.
	_manager.upload_profile_into(_lit, &"ocean_default")
	_manager.upload_profile_into(_inputs, &"ocean_default")
	await _frames(4)

	var depth_rows := PackedStringArray()
	var depth_ok := true
	var depth_done := 0
	var ab_rows := PackedStringArray()
	var ab_ok := true
	var ab_done := 0
	for v in VIEWS:
		var exercised: bool = v[6]
		_set_exercised(exercised)
		_pose(v)
		var inputs: Array = await _read_inputs()
		var lit: Image = await _read_lit()
		var d: Array = _criterion_d_view(v, inputs)
		depth_ok = depth_ok and d[0]
		depth_rows.append(d[1])
		depth_done += 1
		var a: Array = _criterion_a_view(v, inputs, lit)
		ab_ok = ab_ok and a[0]
		ab_rows.append(a[1])
		ab_done += 1
	_set_exercised(false)
	_check("D", depth_ok and depth_done == VIEWS.size(), "\n      " + "\n      ".join(depth_rows))
	_check("A", ab_ok and ab_done == VIEWS.size(), "\n      " + "\n      ".join(ab_rows))


func _build() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(WIDTH, HEIGHT)
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
	_cam.fov = FOV
	_cam.current = true
	_vp.add_child(_cam)

	_sun = DirectionalLight3D.new()
	_sun.shadow_enabled = false
	_sun.light_color = SUN_LIGHT_COLOR
	_sun.light_energy = 1.0
	_vp.add_child(_sun)
	var typed := SUN_LIGHT_COLOR
	_sun_typed = Vector3(typed.r, typed.g, typed.b)

	var images: Array[Image] = []
	for face in 6:
		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(ENV_COLOR)
		images.append(img)
	var cube := Cubemap.new()
	cube.create_from_images(images)
	var grey := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	grey.fill(Color(FOAM_TEX_GREY, FOAM_TEX_GREY, FOAM_TEX_GREY))

	# The shipped instance, on the open-water path.
	_lit = (load(MATERIAL) as ShaderMaterial).duplicate() as ShaderMaterial
	_lit.shader = load(LIT_SHADER)
	_lit.set_shader_parameter("use_environment_map", true)
	_lit.set_shader_parameter("environment_map", cube)
	_lit.set_shader_parameter("foam_tex", ImageTexture.create_from_image(grey))
	var deep: Variant = _lit.get_shader_parameter("deep_color")
	var deep_c: Color = deep if deep is Color else Color(deep.x, deep.y, deep.z)
	deep_c = deep_c.srgb_to_linear()
	_deep_lin = Vector3(deep_c.r, deep_c.g, deep_c.b)
	_inputs = (load(MATERIAL) as ShaderMaterial).duplicate() as ShaderMaterial
	_inputs.shader = load(INPUT_SHADER)
	_manager.upload_profile_into(_lit, &"ocean_default")
	_manager.upload_profile_into(_inputs, &"ocean_default")

	_mesh = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(PATCH, PATCH)
	plane.subdivide_width = int(PATCH / SPACING) - 1
	plane.subdivide_depth = int(PATCH / SPACING) - 1
	_mesh.mesh = plane
	_mesh.material_override = _lit
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The camera looks along +x from x = 0, so the sheet sits ahead of it.
	_mesh.position = Vector3(PATCH * 0.5 - 20.0, 0.0, 0.0)
	_vp.add_child(_mesh)
	_mesh.set_instance_shader_parameter("_fft_vertex_spacing", SPACING)
	_mesh.set_instance_shader_parameter("_water_domain_origin", Vector3.ZERO)


func _set_exercised(p_on: bool) -> void:
	if _scene_foam_offset == null:
		_scene_foam_offset = _lit.get_shader_parameter("_fft_foam_offset")
	for m in [_lit, _inputs]:
		m.set_shader_parameter("_fft_foam_offset", _scene_foam_offset + (FOAM_LIFT if p_on else 0.0))
		m.set_shader_parameter("fft_normal_strength", EXERCISE_STRENGTH if p_on else REF_NORMAL_STRENGTH)
		m.set_shader_parameter("foam_roughness_modifier", EXERCISE_FOAM_ROUGHNESS if p_on else REF_FOAM_ROUGHNESS)


func _dir(p_elevation_deg: float, p_azimuth_deg: float) -> Vector3:
	var e := deg_to_rad(p_elevation_deg)
	var a := deg_to_rad(p_azimuth_deg)
	return Vector3(cos(e) * cos(a), sin(e), cos(e) * sin(a))


func _pose(p_view: Array) -> void:
	var to_sun := _dir(p_view[1], p_view[2])
	_sun.look_at_from_position(to_sun * 50.0, Vector3.ZERO, Vector3.UP)
	_cam.far = p_view[5]
	_cam.position = Vector3(0.0, p_view[4], 0.0)
	# Looking along +x, pitched down.
	_cam.rotation_degrees = Vector3(p_view[3], -90.0, 0.0)


func _to_sun() -> Vector3:
	return _sun.global_transform.basis.z.normalized()


# Each input as float64 per pixel, from its own pass with the sun hidden.
func _read_inputs() -> Array:
	_sun.visible = false
	_mesh.material_override = _inputs
	var out := []
	for i in IN_COUNT:
		_inputs.set_shader_parameter("_debug_ref_value", i)
		await _frames(4)
		var img := _vp.get_texture().get_image()
		var vals := PackedFloat64Array()
		vals.resize(WIDTH * HEIGHT)
		for y in HEIGHT:
			for x in WIDTH:
				var c := img.get_pixel(x, y)
				var u := float(c.r) + float(c.g) / 256.0 + float(c.b) / 65536.0
				vals[y * WIDTH + x] = _decode(i, u)
		out.append(vals)
	_sun.visible = true
	_mesh.material_override = _lit
	return out


func _decode(p_in: int, p_u: float) -> float:
	match p_in:
		In.SX, In.SZ:
			return (p_u - 0.5) * 16.0
		In.FOAM:
			return p_u * 8.0 - 2.0
		In.HEIGHT:
			return (p_u - 0.5) * 32.0
		In.VX, In.VY, In.VZ:
			return (p_u - 0.5) * 4.0
		In.DEPTH:
			return p_u
		_:
			return (p_u - 0.5) * 8192.0


func _read_lit() -> Image:
	_mesh.material_override = _lit
	await _frames(4)
	return _vp.get_texture().get_image()


func _is_water(p_in: Array, p_i: int) -> bool:
	var v := Vector3(p_in[In.VX][p_i], p_in[In.VY][p_i], p_in[In.VZ][p_i])
	return absf(v.length() - 1.0) < 1e-3


# The reference's depth for a pixel: 1 - Linear01Depth of its REST position, z_eye / far.
func _ref_depth(p_in: Array, p_i: int, p_far: float, p_euclid := false) -> float:
	var rest := Vector3(p_in[In.DX][p_i], 0.0, p_in[In.DZ][p_i])
	var eye := _cam.global_transform.affine_inverse() * rest
	var z := eye.length() if p_euclid else -eye.z
	return 1.0 - z / p_far


# Least squares through the origin of (1 - depth) against z: F = sum z^2 / sum z (1 - depth). Returns
# [F, max residual].
func _fit_far(p_z: PackedFloat64Array, p_depth: PackedFloat64Array) -> Array:
	var zz := 0.0
	var zd := 0.0
	for i in p_z.size():
		zz += p_z[i] * p_z[i]
		zd += p_z[i] * (1.0 - p_depth[i])
	var far := zz / maxf(zd, 1e-12)
	var worst := 0.0
	for i in p_z.size():
		worst = maxf(worst, absf(p_depth[i] - (1.0 - p_z[i] / far)))
	return [far, worst]


func _criterion_d_view(p_view: Array, p_in: Array) -> Array:
	var far: float = p_view[5]
	var view := _cam.global_transform.affine_inverse()
	var z_eye := PackedFloat64Array()
	var dist := PackedFloat64Array()
	var ours := PackedFloat64Array()
	for i in WIDTH * HEIGHT:
		if not _is_water(p_in, i):
			continue
		var d: float = p_in[In.DEPTH][i]
		# The fade clamps at 0 past the far plane, where the line no longer holds.
		if d <= 0.0:
			continue
		var eye := view * Vector3(p_in[In.DX][i], 0.0, p_in[In.DZ][i])
		z_eye.append(-eye.z)
		dist.append(eye.length())
		ours.append(d)
	var fit: Array = _fit_far(z_eye, ours)
	var ctrl: Array = _fit_far(dist, ours)
	var far_err := absf(fit[0] / far - 1.0)
	var ok: bool = ours.size() >= MIN_WATER and far_err < FAR_REL and fit[1] < D_TOL and ctrl[1] > D_CTRL
	return [ok, "%s (far %.0f): %d px, fitted far %.3f (off it by %s, tol %s), max |depth - (1 - z_eye / F)| %s (tol %s) | CONTROL from distance: residual %s (must exceed %s) -> %s" % [
			p_view[0], far, ours.size(), fit[0], String.num_scientific(far_err), String.num_scientific(FAR_REL),
			String.num_scientific(fit[1]),
			String.num_scientific(D_TOL), String.num_scientific(ctrl[1]), String.num_scientific(D_CTRL),
			"ok" if ok else "WRONG"]]


func _smith(p_h: Vector3, p_s: Vector3, p_a: float) -> float:
	var hdots := maxf(0.001, clampf(p_h.dot(p_s), 0.0, 1.0))
	var a := hdots / (p_a * sqrt(1.0 - hdots * hdots))
	var a2 := a * a
	return (1.0 - 1.259 * a + 0.396 * a2) / (3.535 * a + 2.181 * a2) if a < 1.6 else 0.0


func _beckmann(p_ndoth: float, p_a: float) -> float:
	var arg := (p_ndoth * p_ndoth - 1.0) / (p_a * p_a * p_ndoth * p_ndoth)
	return exp(arg) / (PI * p_a * p_a * p_ndoth * p_ndoth * p_ndoth * p_ndoth)


func _lin(p_v: Vector3) -> Vector3:
	var c := Color(p_v.x, p_v.y, p_v.z).srgb_to_linear()
	return Vector3(c.r, c.g, c.b)


# FFTWater.shader's fp(), NEW_LIGHTING, from `slopes *= _NormalStrength` on. p_break names one departure
# to apply instead ("" for none); returns [rgb, specular luminance, body luminance].
func ref_fp(p_in: Array, p_i: int, p_far: float, p_exercised: bool, p_break: String) -> Array:
	var sun := REF_SUN
	var scatter_c := REF_SCATTER
	var bubble_c := REF_BUBBLE
	var foam_c := REF_FOAM
	if p_break == "colours":
		sun = _lin(REF_SUN)
		scatter_c = _lin(REF_SCATTER)
		bubble_c = _lin(REF_BUBBLE)
		foam_c = _lin(REF_FOAM)
	elif p_break == "sun":
		sun = _sun_typed
	elif p_break == "L5":
		scatter_c = _deep_lin
	var normal_strength := EXERCISE_STRENGTH if p_exercised and p_break != "L8" else REF_NORMAL_STRENGTH
	var foam_rough := EXERCISE_FOAM_ROUGHNESS if p_exercised and p_break != "L3" else REF_FOAM_ROUGHNESS

	var light_dir := _to_sun()
	var view_dir := Vector3(p_in[In.VX][p_i], p_in[In.VY][p_i], p_in[In.VZ][p_i]).normalized()
	var halfway := (light_dir + view_dir).normalized()
	var depth := 1.0 if p_break == "G5" else _ref_depth(p_in, p_i, p_far)

	var slopes := Vector2(p_in[In.SX][p_i], p_in[In.SZ][p_i]) * normal_strength
	var foam := lerpf(0.0, clampf(p_in[In.FOAM][p_i], 0.0, 1.0), pow(depth, REF_FOAM_ATTEN))
	if p_break == "L2":
		foam *= FOAM_TEX_GREY

	var macro := Vector3.UP
	var meso := Vector3(-slopes.x, 1.0, -slopes.y).normalized()
	meso = Vector3.UP.lerp(meso, pow(clampf(depth, 0.0, 1.0), REF_NORMAL_ATTEN)).normalized()
	var n_dot_l := clampf(meso.dot(light_dir), 0.0, 1.0)
	var a := REF_ROUGHNESS + foam * foam_rough
	var ndoth := maxf(0.0001, meso.dot(halfway))
	var view_mask := _smith(halfway, view_dir, a)
	var light_mask := _smith(halfway, light_dir, a)
	var g := 1.0 / (1.0 + view_mask + light_mask)
	var eta := 1.33
	var r := ((eta - 1.0) * (eta - 1.0)) / ((eta + 1.0) * (eta + 1.0))
	var numerator := pow(1.0 - meso.dot(view_dir), 5.0 * exp(-2.69 * a))
	var f := clampf(r + (1.0 - r) * numerator / (1.0 + 22.7 * pow(a, 1.5)), 0.0, 1.0)
	var spec_scale := f * g * _beckmann(ndoth, a) / (4.0 * maxf(0.001, clampf(macro.dot(light_dir), 0.0, 1.0))) \
			* clampf(meso.dot(light_dir), 0.0, 1.0)
	var env := Vector3.ZERO
	if p_break != "L4":
		var e := ENV_COLOR.srgb_to_linear()
		env = Vector3(e.r, e.g, e.b) * REF_ENV_STRENGTH
	var h := maxf(0.0, p_in[In.HEIGHT][p_i]) * REF_HEIGHT_MODIFIER
	var k1 := REF_WAVE_PEAK * h * pow(clampf(light_dir.dot(-view_dir), 0.0, 1.0), 4.0) \
			* pow(0.5 - 0.5 * light_dir.dot(meso), 3.0)
	var k2 := REF_SCATTER_STRENGTH * pow(clampf(view_dir.dot(meso), 0.0, 1.0), 2.0)
	var k3 := REF_SHADOW_STRENGTH * n_dot_l
	var k4 := REF_BUBBLE_DENSITY

	var out := Vector3.ZERO
	var spec_lum := 0.0
	var body_lum := 0.0
	for c in 3:
		var scatter: float = (k1 + k2) * scatter_c[c] * sun[c] / (1.0 + light_mask) \
				+ k3 * scatter_c[c] * sun[c] + k4 * bubble_c[c] * sun[c]
		var specular: float = sun[c] * spec_scale
		var o := maxf(0.0, (1.0 - f) * scatter + specular + f * env[c])
		var foam_term: float = foam_c[c]
		if p_break == "L1":
			foam_term = foam_c[c] * sun[c] * n_dot_l
		out[c] = lerpf(o, foam_term, clampf(foam, 0.0, 1.0))
		spec_lum += specular
		body_lum += (1.0 - f) * scatter
	return [out, spec_lum, body_lum, foam]


func _err(p_got: Color, p_want: Vector3) -> float:
	var worst := 0.0
	for c in 3:
		worst = maxf(worst, absf(p_got[c] - p_want[c]) / (absf(p_want[c]) + ERR_FLOOR))
	return worst


func _quantile(p_values: PackedFloat64Array, p_q: float) -> float:
	if p_values.is_empty():
		return INF
	var sorted := p_values.duplicate()
	sorted.sort()
	return sorted[clampi(int(p_q * (sorted.size() - 1)), 0, sorted.size() - 1)]


func _criterion_a_view(p_view: Array, p_in: Array, p_lit: Image) -> Array:
	var far: float = p_view[5]
	var exercised: bool = p_view[6]
	var breaks := ["colours", "sun", "L4", "L5"]
	if exercised:
		breaks.append_array(["L1", "L2", "L3", "L8", "G5"])
	var errs := PackedFloat64Array()
	var ctrl_errs := {}
	for b in breaks:
		ctrl_errs[b] = PackedFloat64Array()
	var foamy := 0
	var glints := 0
	var worst_i := -1
	var worst := 0.0
	for i in WIDTH * HEIGHT:
		if not _is_water(p_in, i):
			continue
		var got := p_lit.get_pixel(i % WIDTH, i / WIDTH)
		var want: Array = ref_fp(p_in, i, far, exercised, "")
		var e := _err(got, want[0])
		errs.append(e)
		if e > worst:
			worst = e
			worst_i = i
		if want[3] > FOAMY:
			foamy += 1
		if want[1] > want[2]:
			glints += 1
		for b in breaks:
			ctrl_errs[b].append(_err(got, ref_fp(p_in, i, far, exercised, b)[0]))
	var p50 := _quantile(errs, 0.5)
	var p99 := _quantile(errs, 0.99)
	var ok := errs.size() >= MIN_WATER and p99 < TOL and worst < MAX_TOL
	if exercised:
		ok = ok and foamy >= MIN_FOAM
	if p_view[0] == "into the sun":
		ok = ok and glints >= MIN_GLINT
	var ctrl_parts := PackedStringArray()
	for b in breaks:
		var c99 := _quantile(ctrl_errs[b], 0.99)
		var cmax := _quantile(ctrl_errs[b], 1.0)
		var bite: bool = c99 > CTRL_FACTOR * TOL or cmax > CTRL_FACTOR * MAX_TOL
		ok = ok and bite
		ctrl_parts.append("%s %.3f/%.3f%s" % [b, c99, cmax, "" if bite else " (NOT CAUGHT)"])
	var worst_note := ""
	if worst_i >= 0:
		var g := p_lit.get_pixel(worst_i % WIDTH, worst_i / WIDTH)
		var w: Vector3 = ref_fp(p_in, worst_i, far, exercised, "")[0]
		worst_note = " at (%d, %d) got (%.5f %.5f %.5f) want (%.5f %.5f %.5f)" % [
				worst_i % WIDTH, worst_i / WIDTH, g.r, g.g, g.b, w.x, w.y, w.z]
	return [ok, "%s: %d water px, %d foamy, %d glint | err p50 %s p99 %s (tol %s) max %s (tol %s)%s | CONTROLS, p99/max err (must exceed %.3f or %.2f): %s -> %s" % [
			p_view[0], errs.size(), foamy, glints, String.num_scientific(p50), String.num_scientific(p99),
			String.num_scientific(TOL), String.num_scientific(worst), String.num_scientific(MAX_TOL), worst_note,
			CTRL_FACTOR * TOL, CTRL_FACTOR * MAX_TOL, ", ".join(ctrl_parts), "ok" if ok else "WRONG"]]
