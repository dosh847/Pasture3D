extends Node
## W2 of PASTURE3D_WATER_PRODUCTION_SPEC.md (§2.4), the H2/H3 test: does the mid-distance water shimmer
## (specular aliasing), and does fading by the editor's 4000 m far plane make it worse?
##
## A frozen sea under the editor's far plane (4000 m), panned slowly: a fraction of a pixel per frame.
## Per pixel, the temporal standard deviation of luminance across the pan, averaged per band of rows. A
## pan moves real detail across pixels too, so the measure is relative: the same pan rendered at 4x the
## resolution and box-filtered down (mip 2) is the answer without aliasing. Ratio 1 = no aliasing.
## Arms: fft_fade_distance 2000 m (the default, P-D4) and 0 (the reference: fade by the far plane).
##   Godot --path project --fixed-fps 60 res://bench/WaterShimmerProbe.tscn
## A probe: it measures, it does not gate.

const MATERIAL := "res://addons/pasture_3d/extras/shaders/water/M_water_ocean.tres"
const WIDTH := 800
const HEIGHT := 450
const SS := 4
const PATCH := 4000.0
const SPACING := 2.0
const WARM_FRAMES := 300
const SETTLE_FRAMES := 3
const PAN_FRAMES := 40
# Degrees per frame: 60 deg over 800 px is 0.075 deg/px, so a quarter pixel.
const PAN_STEP := 0.019
const BANDS := 8
const FAR := 4000.0

var _manager: Pasture3DPoolManager
var _vp: SubViewport
var _cam: Camera3D
var _sun: DirectionalLight3D
var _mat: ShaderMaterial


func _ready() -> void:
	print("=== WaterShimmerProbe ===")
	_manager = Pasture3DPoolManager.new()
	add_child(_manager)
	_build()
	for i in WARM_FRAMES:
		await RenderingServer.frame_post_draw
	_manager.paused = true
	_manager.upload_profile_into(_mat, &"ocean_default")
	for i in 4:
		await RenderingServer.frame_post_draw
	print("  N %d, camera far %.0f m, pan %.3f deg/frame over %d frames" % [
		_manager.get_effective_fft_resolution(), FAR, PAN_STEP, PAN_FRAMES])
	var horizon := -1
	for arm in [[2000.0, "fade 2000 m"], [0.0, "fade by far plane"]]:
		_mat.set_shader_parameter("fft_fade_distance", arm[0])
		var lo := await _pan(1)
		var hi := await _pan(SS)
		if horizon < 0:
			horizon = _horizon_row()
		print("  [%s] temporal luminance std, 1x / 4x-supersampled (ratio):" % arm[1])
		var rows := HEIGHT - horizon - 2
		for b in BANDS:
			var y0 := horizon + 2 + rows * b / BANDS
			var y1 := horizon + 2 + rows * (b + 1) / BANDS
			var s_lo := _band_mean(lo, y0, y1)
			var s_hi := _band_mean(hi, y0, y1)
			print("    rows %3d-%3d (%5.0f m): %.4f / %.4f  (%.2f)" % [
				y0, y1, _distance_at(int((y0 + y1) / 2)), s_lo, s_hi, s_lo / max(s_hi, 1e-6)])
	get_tree().quit(0)


## Pans the camera across PAN_FRAMES frames at p_scale times the resolution, and returns the per-pixel
## temporal standard deviation of luminance, at WIDTH x HEIGHT.
func _pan(p_scale: int) -> PackedFloat32Array:
	_vp.size = Vector2i(WIDTH * p_scale, HEIGHT * p_scale)
	var n := WIDTH * HEIGHT
	var sum := PackedFloat32Array()
	var sum2 := PackedFloat32Array()
	sum.resize(n)
	sum2.resize(n)
	for f in PAN_FRAMES:
		_cam.rotation_degrees = Vector3(-10.0, -90.0 + PAN_STEP * f, 0.0)
		for i in SETTLE_FRAMES:
			await RenderingServer.frame_post_draw
		var img := _vp.get_texture().get_image()
		img.convert(Image.FORMAT_RGBF)
		var px: PackedFloat32Array
		if p_scale == 1:
			px = img.get_data().to_float32_array()
		else:
			# Mipmaps are box-filtered: mip log2(scale) is the supersampled frame at WIDTH x HEIGHT.
			img.generate_mipmaps()
			var level := int(round(log(p_scale) / log(2.0)))
			var start := img.get_mipmap_offset(level)
			px = img.get_data().slice(start, start + n * 12).to_float32_array()
		for i in n:
			var l := 0.2126 * px[i * 3] + 0.7152 * px[i * 3 + 1] + 0.0722 * px[i * 3 + 2]
			sum[i] += l
			sum2[i] += l * l
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var m := sum[i] / PAN_FRAMES
		out[i] = sqrt(max(sum2[i] / PAN_FRAMES - m * m, 0.0))
	_vp.size = Vector2i(WIDTH, HEIGHT)
	return out


func _band_mean(p_std: PackedFloat32Array, p_y0: int, p_y1: int) -> float:
	var s := 0.0
	var n := 0
	for y in range(p_y0, p_y1):
		for x in WIDTH:
			s += p_std[y * WIDTH + x]
			n += 1
	return s / max(n, 1)


func _horizon_row() -> int:
	for y in HEIGHT:
		if _cam.project_ray_normal(Vector2(WIDTH * 0.5, y) * float(_vp.size.x) / WIDTH).y < -0.002:
			return y
	return HEIGHT - 1


## Metres to the flat sea along the centre column at screen row p_y.
func _distance_at(p_y: int) -> float:
	var d := _cam.project_ray_normal(Vector2(WIDTH * 0.5, p_y) * float(_vp.size.x) / WIDTH)
	return _cam.position.y / max(-d.y, 1e-4)


func _build() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(WIDTH, HEIGHT)
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)

	var sky_mat := ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = sky_mat
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
	_cam.far = FAR
	_cam.fov = 60.0
	_cam.current = true
	_cam.position = Vector3(0.0, 6.0, 0.0)
	_cam.rotation_degrees = Vector3(-10.0, -90.0, 0.0)
	_vp.add_child(_cam)

	_sun = DirectionalLight3D.new()
	_sun.shadow_enabled = false
	_sun.light_color = Color(1.0, 0.85105, 0.601243)
	_vp.add_child(_sun)
	_manager.sun_light = _sun
	var el := deg_to_rad(25.0)
	var az := deg_to_rad(40.0)
	_sun.look_at_from_position(Vector3(cos(el) * cos(az), sin(el), cos(el) * sin(az)) * 100.0, Vector3.ZERO, Vector3.UP)

	_mat = (load(MATERIAL) as ShaderMaterial).duplicate() as ShaderMaterial
	_manager.upload_profile_into(_mat, &"ocean_default")

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
