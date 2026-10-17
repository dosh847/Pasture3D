extends Node
## W3 of PASTURE3D_WATER_PRODUCTION_SPEC.md (§2.2), for judging by eye: the shipped ocean (M_water_ocean.tres,
## ocean_default) before and after W3, at the default resolution. Before: the reference's bare offsets,
## no resolution lift, the crest the clamp of the mipped mean. After: as shipped. One grid, a row per view,
## before on the left, plus each frame on its own.
##   Godot --path project --fixed-fps 60 res://bench/WaterFoamLevelCompare.tscn
## P3D_OUT names the output directory (absolute). P3D_RES overrides the resolution. A probe, not a gate.

const MATERIAL := "res://addons/pasture_3d/extras/shaders/water/M_water_ocean.tres"
const WIDTH := 960
const HEIGHT := 540
const PATCH := 4000.0
const SPACING := 2.0
const WARM_FRAMES := 480
const SETTLE_FRAMES := 6
# name, camera height, pitch, yaw, sun elevation, sun azimuth (relative to the view), fov
const VIEWS := [
	["side_lit", 6.0, -10.0, 0.0, 25.0, 90.0, 60.0],
	["close_down", 3.0, -25.0, 0.0, 35.0, 150.0, 60.0],
	["high_far", 25.0, -8.0, 0.0, 30.0, 120.0, 60.0],
]
# The resolution lift water_fft_foam_resolution_lift() adds, which "before" takes back out.
const SHADER_LIFTS := {512: 0.13, 256: 0.2, 128: 0.315}

var _manager: Pasture3DPoolManager
var _vp: SubViewport
var _cam: Camera3D
var _sun: DirectionalLight3D
var _mat: ShaderMaterial


func _ready() -> void:
	var out := OS.get_environment("P3D_OUT")
	if out == "":
		out = ProjectSettings.globalize_path("res://bench/")
	DirAccess.make_dir_recursive_absolute(out)
	_manager = Pasture3DPoolManager.new()
	var res := OS.get_environment("P3D_RES")
	if res != "":
		_manager.fft_resolution = int(res)
	add_child(_manager)
	_build()
	for i in WARM_FRAMES:
		await RenderingServer.frame_post_draw
	_manager.paused = true
	_manager.upload_profile_into(_mat, &"ocean_default")
	var fft: Pasture3DWaterFFT = _manager.get_profile(&"ocean_default").fft
	var n := _manager.get_effective_fft_resolution()
	var shipped: float = fft.get_foam_offset_sum()
	var before: float = shipped - fft.foam_lift - SHADER_LIFTS.get(n, 0.0)
	print("=== WaterFoamLevelCompare -> %s: N %d, offset shipped %.3f, before %.3f ===" % [out, n, shipped, before])
	var grid := Image.create(WIDTH * 2, HEIGHT * VIEWS.size(), false, Image.FORMAT_RGB8)
	for v in VIEWS.size():
		_pose(VIEWS[v])
		for side in 2:
			_mat.set_shader_parameter("_fft_foam_offset", before if side == 0 else shipped)
			_mat.set_shader_parameter("fft_foam_footprint", side == 1)
			for f in SETTLE_FRAMES:
				await RenderingServer.frame_post_draw
			var img := _vp.get_texture().get_image()
			img.convert(Image.FORMAT_RGB8)
			img.save_png(out.path_join("foam_%s_%s.png" % [VIEWS[v][0], "before" if side == 0 else "after"]))
			grid.blit_rect(img, Rect2i(0, 0, WIDTH, HEIGHT), Vector2i(side * WIDTH, v * HEIGHT))
	grid.save_png(out.path_join("foam_before_after.png"))
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
	_cam.far = 4000.0
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
