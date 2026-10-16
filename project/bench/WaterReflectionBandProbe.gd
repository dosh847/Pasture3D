extends Node
## W2 of PASTURE3D_WATER_PRODUCTION_SPEC.md (§2.4), the H1 test: are the dark streaks in the mid-distance
## band reflections pointing below the horizon, picking up the sky's ground colour?
##
## One frozen sea (M_water_ocean.tres, ocean_default), rendered under three skies that differ ONLY below
## the horizon: the ProceduralSkyMaterial default (brown ground), a red ground, and a ground equal to the
## sky's horizon colour. A pixel whose colour follows the ground is reflecting below the horizon.
## Reports, per band of screen rows, the fraction of water pixels that turned red, and saves the frames.
##   Godot --path project --fixed-fps 60 res://bench/WaterReflectionBandProbe.tscn
## P3D_OUT names the output directory (absolute). A probe: it measures, it does not gate.

const MATERIAL := "res://addons/pasture_3d/extras/shaders/water/M_water_ocean.tres"
const WIDTH := 1600
const HEIGHT := 900
const PATCH := 1200.0
const SPACING := 1.0
const WARM_FRAMES := 300
const SETTLE_FRAMES := 12
const BANDS := 12
# A pixel "turned red" when its red channel rose this much more than its green and blue did.
const RED_DELTA := 0.06
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


func _ready() -> void:
	var out := OS.get_environment("P3D_OUT")
	if out == "":
		out = ProjectSettings.globalize_path("res://bench/")
	DirAccess.make_dir_recursive_absolute(out)
	print("=== WaterReflectionBandProbe -> %s ===" % out)
	_manager = Pasture3DPoolManager.new()
	add_child(_manager)
	_build()
	for i in WARM_FRAMES:
		await RenderingServer.frame_post_draw
	_manager.paused = true
	_manager.upload_profile_into(_mat, &"ocean_default")
	for i in 4:
		await RenderingServer.frame_post_draw
	print("  N %d, water time %.4f s, ProceduralSky ground %s / horizon %s" % [
		_manager.get_effective_fft_resolution(), _manager.get_water_time(), _default_ground_bottom,
		_default_ground_horizon])

	for v in VIEWS:
		_pose(v)
		var frames := {}
		for variant in ["default", "red", "skyground"]:
			_set_ground(variant)
			for i in SETTLE_FRAMES:
				await RenderingServer.frame_post_draw
			var img := _vp.get_texture().get_image()
			img.convert(Image.FORMAT_RGBF)
			frames[variant] = img
			img.save_png(out.path_join("band_%s_%s.png" % [v[0], variant]))
		_report(v[0], frames)
	get_tree().quit(0)


## Per row band: the fraction of water pixels that turned red, and how much brighter the sky-coloured
## ground made them (the ground's share of their colour).
func _report(p_view: String, p_frames: Dictionary) -> void:
	var base: Image = p_frames["default"]
	var red: Image = p_frames["red"]
	var sky: Image = p_frames["skyground"]
	var horizon := _horizon_row(base)
	print("  [%s] horizon at row %d" % [p_view, horizon])
	var rows := HEIGHT - horizon - 2
	var total_red := 0
	var total := 0
	for b in BANDS:
		var y0 := horizon + 2 + rows * b / BANDS
		var y1 := horizon + 2 + rows * (b + 1) / BANDS
		var n := 0
		var turned := 0
		var lift := 0.0
		for y in range(y0, y1, 2):
			for x in range(0, WIDTH, 2):
				var c0 := base.get_pixel(x, y)
				var cr := red.get_pixel(x, y)
				var cs := sky.get_pixel(x, y)
				var dr := (cr.r - c0.r) - 0.5 * ((cr.g - c0.g) + (cr.b - c0.b))
				if dr > RED_DELTA:
					turned += 1
				lift += cs.get_luminance() - c0.get_luminance()
				n += 1
		total_red += turned
		total += n
		print("    rows %3d-%3d: %5.1f%% reflect below the horizon, sky ground lifts luminance %+.3f" % [
			y0, y1, 100.0 * turned / max(n, 1), lift / max(n, 1)])
	print("    all water: %.1f%% reflect below the horizon" % [100.0 * total_red / max(total, 1)])


## The screen row where a ray from the camera first dips below y = 0: the horizon of a flat sea.
func _horizon_row(p_img: Image) -> int:
	for y in HEIGHT:
		if _cam.project_ray_normal(Vector2(WIDTH * 0.5, y)).y < -0.002:
			return y
	return HEIGHT - 1


func _set_ground(p_variant: String) -> void:
	match p_variant:
		"default":
			_sky.ground_bottom_color = _default_ground_bottom
			_sky.ground_horizon_color = _default_ground_horizon
		"red":
			_sky.ground_bottom_color = Color(1, 0, 0)
			_sky.ground_horizon_color = Color(1, 0, 0)
		"skyground":
			_sky.ground_bottom_color = _sky.sky_horizon_color
			_sky.ground_horizon_color = _sky.sky_horizon_color


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
