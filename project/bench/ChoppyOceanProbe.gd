extends Node
## Wave presets by eye: ocean_default against variants of it, one column each, a row per view (as
## WaterFoamLevelCompare). Made to pick ocean_choppy's knobs. A probe, not a gate.
##   P3D_OUT=<png> [P3D_VARIANTS=<file>] Godot --path project --fixed-fps 60 res://bench/ChoppyOceanProbe.tscn
## P3D_VARIANTS is a str_to_var() Array of [label, {fft property: value}]; "_base" names another built-in
## to start from.
const MATERIAL := "res://addons/pasture_3d/extras/shaders/water/M_water_ocean.tres"
const W := 640
const H := 360
const PATCH := 4000.0
const SPACING := 2.0
const VIEWS := [
	["side_lit", 6.0, -10.0, 25.0, 90.0],
	["close_down", 3.0, -25.0, 35.0, 150.0],
	["high_far", 25.0, -8.0, 30.0, 120.0],
]
var VARIANTS := [
	["default", {}],
	["B wind8 fetch5k", {"spectrum_1/wind_speed": 8.0, "spectrum_2/wind_speed": 8.0, "spectrum_1/fetch": 5000.0, "spectrum_2/fetch": 5000.0,
		"choppiness": 1.5, "foam_lift": 0.35}],
	["C wind12 + detail", {"spectrum_1/wind_speed": 12.0, "spectrum_2/wind_speed": 10.0, "spectrum_1/fetch": 3000.0, "spectrum_2/fetch": 2000.0,
		"spectrum_7/wind_speed": 3.0, "spectrum_8/wind_speed": 3.0, "spectrum_1/swell": 0.5, "spectrum_2/swell": 0.5,
		"choppiness": 1.8, "foam_lift": 0.35}],
	["D C, less swell, more scale", {"spectrum_1/wind_speed": 12.0, "spectrum_2/wind_speed": 10.0, "spectrum_1/fetch": 3000.0, "spectrum_2/fetch": 2000.0,
		"spectrum_7/wind_speed": 3.0, "spectrum_8/wind_speed": 3.0, "spectrum_1/swell": 0.3, "spectrum_2/swell": 0.3,
		"spectrum_1/scale": 0.15, "spectrum_2/scale": 0.1, "choppiness": 2.0, "foam_lift": 0.35}],
]
var _manager: Pasture3DPoolManager
var _vp: SubViewport
var _cam: Camera3D
var _sun: DirectionalLight3D
var _mat: ShaderMaterial

func _ready() -> void:
	var spec = OS.get_environment("P3D_VARIANTS")
	if spec != "":
		VARIANTS = str_to_var(FileAccess.get_file_as_string(spec))
	_manager = Pasture3DPoolManager.new()
	add_child(_manager)
	_build()
	var grid := Image.create(W * VARIANTS.size(), H * VIEWS.size(), false, Image.FORMAT_RGB8)
	var base := _manager.get_builtin_profiles().filter(func(p): return p.profile_name == &"ocean_default")[0] as Pasture3DWaveProfile
	for v in VARIANTS.size():
		var knobs: Dictionary = VARIANTS[v][1]
		var from := base
		if knobs.has("_base"):
			from = _manager.get_builtin_profiles().filter(func(p): return p.profile_name == StringName(knobs["_base"]))[0]
		var prof := from.duplicate(true) as Pasture3DWaveProfile
		prof.profile_name = &"probe"
		for k in knobs:
			if k != "_base":
				prof.fft.set(k, knobs[k])
		var arr: Array[Pasture3DWaveProfile] = [prof]
		_manager.profiles = arr
		_manager.paused = false
		_manager.upload_profile_into(_mat, &"probe")
		for i in 480:
			await RenderingServer.frame_post_draw
		_manager.paused = true
		_manager.upload_profile_into(_mat, &"probe")
		print("%s: amplitude_sum %.3f m, sigma %.3f m, foam offset %.3f" % [VARIANTS[v][0], prof.get_amplitude_sum(), prof.fft.get_height_sigma(), prof.fft.get_foam_offset_sum()])
		for r in VIEWS.size():
			_pose(VIEWS[r])
			for f in 6:
				await RenderingServer.frame_post_draw
			var img := _vp.get_texture().get_image()
			img.convert(Image.FORMAT_RGB8)
			grid.blit_rect(img, Rect2i(0, 0, W, H), Vector2i(v * W, r * H))
	var out := OS.get_environment("P3D_OUT")
	grid.save_png(out)
	get_tree().quit(0)

func _build() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(W, H)
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
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
	_sun.light_color = Color(1.0, 0.85105, 0.601243)
	_vp.add_child(_sun)
	_manager.sun_light = _sun
	_mat = (load(MATERIAL) as ShaderMaterial).duplicate() as ShaderMaterial
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

func _pose(p: Array) -> void:
	_cam.position = Vector3(0.0, p[1], 0.0)
	_cam.rotation_degrees = Vector3(p[2], -90.0, 0.0)
	var el := deg_to_rad(p[3])
	var az := deg_to_rad(p[4])
	_sun.look_at_from_position(Vector3(cos(el) * cos(az), sin(el), cos(el) * sin(az)) * 100.0, Vector3.ZERO, Vector3.UP)
