extends Node
## W2 of PASTURE3D_WATER_PRODUCTION_SPEC.md (§2.4): the mid-distance band of dark streaks was reflections
## pointing below the horizon, picking up the sky's ground colour (H1, WaterReflectionBandProbe).
## reflection_min_elevation bends the shading normal so no reflection dips below that elevation.
##
## A pixel reflects below the horizon when its colour follows the sky's GROUND: each frame is rendered
## twice, with the ProceduralSky default ground and with a red one, and a pixel that turned red counts.
## Criteria, each with a control that must fail:
##   [B] With the default bend, under 2% of the water reflects below the horizon in every view.
##       Control: reflection_min_elevation = -90 (the bend off, as the reference) shows over 10%.
##   [U] The bend changes only the pixels that reflect below the horizon: bent to 0 degrees, at least 95%
##       of the pixels it changes follow the sky's ground with the bend off. Control: a 60 degree bend
##       changes mostly pixels that do not.
## Renders, so it runs windowed:
##   Godot --path project --fixed-fps 60 res://bench/WaterHorizonBendGate.tscn

const MATERIAL := "res://addons/pasture_3d/extras/shaders/water/M_water_ocean.tres"
const WIDTH := 800
const HEIGHT := 450
const PATCH := 1200.0
const SPACING := 1.0
const WARM_FRAMES := 300
const SETTLE_FRAMES := 12
const CRITERIA := 2
# A pixel "turned red" when its red channel rose this much more than its green and blue did.
const RED_DELTA := 0.06
const BEND_MAX_BELOW := 0.02
const NO_BEND_MIN_BELOW := 0.10
# A pixel changed when a channel moved more than this, in linear RGB.
const SAME_TOL := 2.0 / 255.0
# name, camera height, pitch, yaw, sun elevation, sun azimuth (relative to the view), fov
const VIEWS := [
	["horizon_into_sun", 6.0, -8.0, 0.0, 14.0, 10.0, 60.0],
	["glitter_close", 4.0, -18.0, 0.0, 22.0, 0.0, 40.0],
	["side_lit", 6.0, -10.0, 0.0, 25.0, 90.0, 60.0],
]

var _manager: Pasture3DPoolManager
var _vp: SubViewport
var _cam: Camera3D
var _sun: DirectionalLight3D
var _mat: ShaderMaterial
var _sky: ProceduralSkyMaterial
var _default_ground_bottom: Color
var _default_ground_horizon: Color
var _default_bend: float
var _failures := 0
var _completed := 0


func _ready() -> void:
	print("=== WaterHorizonBendGate ===")
	_manager = Pasture3DPoolManager.new()
	add_child(_manager)
	_build()
	for i in WARM_FRAMES:
		await RenderingServer.frame_post_draw
	_manager.paused = true
	_manager.upload_profile_into(_mat, &"ocean_default")
	for i in 4:
		await RenderingServer.frame_post_draw
	print("  N %d, water time %.4f s, default bend %.1f deg" % [
		_manager.get_effective_fft_resolution(), _manager.get_water_time(), _default_bend])
	await _criterion_b()
	await _criterion_u()
	if _completed != CRITERIA:
		_fail("only %d of %d criteria ran to the end" % [_completed, CRITERIA])
	print("=== WATER HORIZON BEND %s (%d failures, %d/%d criteria) ===" % [
		"PASS" if _failures == 0 else "FAIL", _failures, _completed, CRITERIA])
	get_tree().quit(0 if _failures == 0 else 1)


func _fail(p_msg: String) -> void:
	_failures += 1
	printerr("  FAIL ", p_msg)


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["ok  " if p_ok else "FAIL", p_msg])
	if not p_ok:
		_failures += 1


func _criterion_b() -> void:
	print("[B] the default bend keeps reflections above the horizon")
	for v in VIEWS:
		_pose(v)
		_mat.set_shader_parameter("reflection_min_elevation", _default_bend)
		var below := await _below_fraction()
		_check(below < BEND_MAX_BELOW, "%s: %.1f%% reflect below the horizon (< %.0f%%)" % [
			v[0], 100.0 * below, 100.0 * BEND_MAX_BELOW])
		_mat.set_shader_parameter("reflection_min_elevation", -90.0)
		var off := await _below_fraction()
		_check(off > NO_BEND_MIN_BELOW, "CONTROL %s, bend off: %.1f%% reflect below the horizon (> %.0f%%)" % [
			v[0], 100.0 * off, 100.0 * NO_BEND_MIN_BELOW])
	_mat.set_shader_parameter("reflection_min_elevation", _default_bend)
	_completed += 1


## Even a steep view down has a few near facets tilted far enough to reflect below the horizon, so
## "changes nothing" is the wrong claim; "changes only the pixels that reflect below it" is the right one.
## A bend to 0 degrees makes that exact: a changed pixel must follow the sky's ground with the bend off.
func _criterion_u() -> void:
	print("[U] the bend changes only the pixels that reflect below the horizon")
	_pose(VIEWS[1])
	_mat.set_shader_parameter("reflection_min_elevation", -90.0)
	_set_ground(false)
	var off := await _frame()
	_set_ground(true)
	var off_red := await _frame()
	_set_ground(false)
	_mat.set_shader_parameter("reflection_min_elevation", 0.0)
	var zero := await _frame()
	_mat.set_shader_parameter("reflection_min_elevation", 60.0)
	var steep := await _frame()
	_mat.set_shader_parameter("reflection_min_elevation", _default_bend)
	var z := _changed_follow_ground(off, zero, off_red)
	_check(z.x > 100, "WITNESS bend to 0 deg changes %d px (> 100)" % z.x)
	_check(z.y >= 0.95, "%.1f%% of the changed pixels reflect below the horizon (>= 95%%)" % [100.0 * z.y])
	var s := _changed_follow_ground(off, steep, off_red)
	_check(s.y < 0.5, "CONTROL a 60 deg bend: only %.1f%% of its %d changed pixels reflect below (< 50%%)" % [
		100.0 * s.y, s.x])
	_completed += 1


## (pixels changed between two frames, the fraction of those whose colour follows the ground in p_red).
func _changed_follow_ground(p_a: Image, p_b: Image, p_red: Image) -> Vector2:
	var changed := 0
	var follow := 0
	for y in range(0, HEIGHT, 2):
		for x in range(0, WIDTH, 2):
			var a := p_a.get_pixel(x, y)
			var b := p_b.get_pixel(x, y)
			if max(absf(a.r - b.r), max(absf(a.g - b.g), absf(a.b - b.b))) <= SAME_TOL:
				continue
			changed += 1
			var r := p_red.get_pixel(x, y)
			if (r.r - a.r) - 0.5 * ((r.g - a.g) + (r.b - a.b)) > SAME_TOL:
				follow += 1
	return Vector2(changed, float(follow) / max(changed, 1))


## The fraction of water pixels (below the flat-sea horizon) whose colour follows the sky's ground.
func _below_fraction() -> float:
	_set_ground(false)
	var base := await _frame()
	_set_ground(true)
	var red := await _frame()
	_set_ground(false)
	var horizon := _horizon_row()
	var n := 0
	var turned := 0
	for y in range(horizon + 2, HEIGHT, 2):
		for x in range(0, WIDTH, 2):
			var c0 := base.get_pixel(x, y)
			var cr := red.get_pixel(x, y)
			if (cr.r - c0.r) - 0.5 * ((cr.g - c0.g) + (cr.b - c0.b)) > RED_DELTA:
				turned += 1
			n += 1
	return float(turned) / max(n, 1)


func _frame() -> Image:
	for i in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBF)
	return img


## The screen row where a ray from the camera first dips below y = 0: the horizon of a flat sea.
func _horizon_row() -> int:
	for y in HEIGHT:
		if _cam.project_ray_normal(Vector2(WIDTH * 0.5, y)).y < -0.002:
			return y
	return HEIGHT - 1


func _set_ground(p_red: bool) -> void:
	_sky.ground_bottom_color = Color(1, 0, 0) if p_red else _default_ground_bottom
	_sky.ground_horizon_color = Color(1, 0, 0) if p_red else _default_ground_horizon


func _build() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(WIDTH, HEIGHT)
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)

	_sky = ProceduralSkyMaterial.new()
	_default_ground_bottom = _sky.ground_bottom_color
	_default_ground_horizon = _sky.ground_horizon_color
	var sky := Sky.new()
	sky.sky_material = _sky
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)

	_cam = Camera3D.new()
	_cam.far = 2000.0
	_cam.current = true
	_vp.add_child(_cam)

	_sun = DirectionalLight3D.new()
	_sun.shadow_enabled = false
	_sun.light_color = Color(1.0, 0.85105, 0.601243)
	_vp.add_child(_sun)
	_manager.sun_light = _sun

	_mat = (load(MATERIAL) as ShaderMaterial).duplicate() as ShaderMaterial
	_manager.upload_profile_into(_mat, &"ocean_default")
	# The shipped default, read from the shader so the gate follows it.
	_default_bend = RenderingServer.shader_get_parameter_default(_mat.shader.get_rid(), &"reflection_min_elevation")
	if _mat.get_shader_parameter("reflection_min_elevation") != null:
		_default_bend = _mat.get_shader_parameter("reflection_min_elevation")

	var mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(PATCH, PATCH)
	plane.subdivide_width = int(PATCH / SPACING) - 1
	plane.subdivide_depth = int(PATCH / SPACING) - 1
	mesh.mesh = plane
	mesh.material_override = _mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.position = Vector3(PATCH * 0.5 - 30.0, 0.0, 0.0)
	_vp.add_child(mesh)
	mesh.set_instance_shader_parameter("_fft_vertex_spacing", SPACING)
	mesh.set_instance_shader_parameter("_water_domain_origin", Vector3.ZERO)


func _pose(p_view: Array) -> void:
	_cam.fov = p_view[6]
	_cam.position = Vector3(0.0, p_view[1], 0.0)
	_cam.rotation_degrees = Vector3(p_view[2], -90.0 + p_view[3], 0.0)
	var el := deg_to_rad(p_view[4])
	var az := deg_to_rad(p_view[5])
	var to_sun := Vector3(cos(el) * cos(az), sin(el), cos(el) * sin(az))
	_sun.look_at_from_position(to_sun * 100.0, Vector3.ZERO, Vector3.UP)
