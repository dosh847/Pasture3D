extends Node
## Visual comparison of fft_resolution 256 against 1024 (PASTURE3D_WATER_PRODUCTION_SPEC.md P-D1).
##
## Renders the shipped ocean material (M_water_ocean.tres, ocean_default) under a procedural sky, from a few
## fixed cameras, and saves PNGs. Run once per resolution with --fixed-fps 60, so both runs reach the same
## water time on the same frame:
##   P3D_N=256  Godot --path project --fixed-fps 60 res://bench/WaterResolutionCompare.tscn
##   P3D_N=1024 Godot --path project --fixed-fps 60 res://bench/WaterResolutionCompare.tscn
## P3D_OUT names the output directory (absolute). Not a gate: it asserts nothing.

const MATERIAL := "res://addons/pasture_3d/extras/shaders/water/M_water_ocean.tres"
const WIDTH := 1600
const HEIGHT := 900
const PATCH := 1200.0
const SPACING := 1.0
const WARM_FRAMES := 300
# name, camera height, pitch, yaw, sun elevation, sun azimuth (relative to the view), fov
const VIEWS := [
	["horizon_into_sun", 6.0, -8.0, 0.0, 14.0, 10.0, 60.0],
	["near_down", 3.0, -40.0, 0.0, 35.0, 120.0, 60.0],
	["wide_sun_behind", 20.0, -15.0, 0.0, 35.0, 180.0, 60.0],
	["glitter_close", 4.0, -18.0, 0.0, 22.0, 0.0, 40.0],
]

var _manager: Pasture3DPoolManager
var _vp: SubViewport
var _cam: Camera3D
var _sun: DirectionalLight3D
var _mat: ShaderMaterial


func _ready() -> void:
	var n := int(OS.get_environment("P3D_N")) if OS.get_environment("P3D_N") != "" else 256
	var out := OS.get_environment("P3D_OUT")
	if out == "":
		out = ProjectSettings.globalize_path("res://bench/")
	DirAccess.make_dir_recursive_absolute(out)
	print("=== WaterResolutionCompare N=%d -> %s ===" % [n, out])

	_manager = Pasture3DPoolManager.new()
	_manager.fft_resolution = n
	add_child(_manager)
	_build()
	for i in WARM_FRAMES:
		await RenderingServer.frame_post_draw
	_manager.paused = true
	_manager.upload_profile_into(_mat, &"ocean_default")
	for i in 4:
		await RenderingServer.frame_post_draw
	print("  effective N %d, water time %.4f s" % [_manager.get_effective_fft_resolution(), _manager.get_water_time()])
	for v in VIEWS:
		_pose(v)
		for i in 6:
			await RenderingServer.frame_post_draw
		var img := _vp.get_texture().get_image()
		var path: String = out.path_join("%s_N%d.png" % [v[0], n])
		img.save_png(path)
		print("  saved ", path)
	get_tree().quit(0)


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
	# The camera looks along +x; yaw and the sun's azimuth are measured from there.
	_cam.fov = p_view[6]
	_cam.position = Vector3(0.0, p_view[1], 0.0)
	_cam.rotation_degrees = Vector3(p_view[2], -90.0 + p_view[3], 0.0)
	var el := deg_to_rad(p_view[4])
	var az := deg_to_rad(p_view[5])
	var to_sun := Vector3(cos(el) * cos(az), sin(el), cos(el) * sin(az))
	_sun.look_at_from_position(to_sun * 100.0, Vector3.ZERO, Vector3.UP)
