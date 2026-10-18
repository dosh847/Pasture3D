extends Node
## Wave speed by eye: a short clip of each variant of a built-in, from a standing eye height, saved as
## JPEG frames for a side-by-side player (frames are real time: one kept every STRIDE frames at
## --fixed-fps 60). Made to slow lake_calm and pond_still. A probe, not a gate.
##   P3D_OUT=<dir> P3D_VARIANTS=<file> Godot --path project --fixed-fps 60 res://bench/CalmWaterProbe.tscn
## P3D_VARIANTS is a str_to_var() Array of [label, {key: value}]. Keys:
##   "_base"        the built-in to start from (default lake_calm)
##   "_material"    the material to draw with (default M_water_lake.tres)
##   "x:<knob>"     multiply that spectrum knob on all eight spectra
##   "x:<knob>:a,b" ...on spectra a and b only (1-based, as the spectrum_N/ properties)
##   anything else  an FFT property, set as given
## Writes <dir>/<variant index>_<frame>.jpg and prints each variant's height and median period.
const W := 480
const H := 270
const PATCH := 200.0
const SPACING := 0.25
const FRAMES := 60
const STRIDE := 4
const WARMUP := 240
var _manager: Pasture3DPoolManager
var _vp: SubViewport
var _cam: Camera3D
var _sun: DirectionalLight3D
var _mesh: MeshInstance3D


func _ready() -> void:
	var variants: Array = str_to_var(FileAccess.get_file_as_string(OS.get_environment("P3D_VARIANTS")))
	var out := OS.get_environment("P3D_OUT")
	DirAccess.make_dir_recursive_absolute(out)
	_manager = Pasture3DPoolManager.new()
	add_child(_manager)
	_build()
	for v in variants.size():
		var knobs: Dictionary = variants[v][1]
		var base_name := StringName(knobs.get("_base", "lake_calm"))
		var from: Pasture3DWaveProfile = _manager.get_builtin_profiles().filter(
				func(p): return p.profile_name == base_name)[0]
		var prof := from.duplicate(true) as Pasture3DWaveProfile
		prof.profile_name = &"probe"
		for k: String in knobs:
			if k.begins_with("_"):
				continue
			if k.begins_with("x:"):
				var parts := k.split(":")
				var which: Array = range(1, 9)
				if parts.size() > 2:
					which = Array(parts[2].split(",")).map(func(s): return int(s))
				for i in which:
					var key := "spectrum_%d/%s" % [i, parts[1]]
					prof.fft.set(key, float(prof.fft.get(key)) * float(knobs[k]))
			else:
				prof.fft.set(k, knobs[k])
		var mat := (load(knobs.get("_material", "res://addons/pasture_3d/extras/shaders/water/M_water_lake.tres"))
				as ShaderMaterial).duplicate() as ShaderMaterial
		_mesh.material_override = mat
		var arr: Array[Pasture3DWaveProfile] = [prof]
		_manager.profiles = arr
		_manager.paused = false
		_manager.upload_profile_into(mat, &"probe")
		var l50 := prof.fft.get_variance_wavelength(0.5)
		print("%d %s: sigma %.4f m, L50 %.2f m (T %.2f s)" % [v, variants[v][0], prof.fft.get_height_sigma(), l50,
				sqrt(TAU * l50 / 9.81)])
		for i in WARMUP:
			await RenderingServer.frame_post_draw
		# Again: bound before the FFT's textures exist, the material keeps the placeholder (black, flat).
		_manager.upload_profile_into(mat, &"probe")
		for f in FRAMES * STRIDE:
			await RenderingServer.frame_post_draw
			if f % STRIDE == 0:
				var img := _vp.get_texture().get_image()
				img.convert(Image.FORMAT_RGB8)
				img.save_jpg("%s/%d_%03d.jpg" % [out, v, f / STRIDE], 0.85)
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
	_cam.far = 1000.0
	_cam.current = true
	_cam.position = Vector3(0.0, 1.7, 0.0)
	_cam.rotation_degrees = Vector3(-14.0, -90.0, 0.0)
	_vp.add_child(_cam)
	_sun = DirectionalLight3D.new()
	_sun.light_color = Color(1.0, 0.85105, 0.601243)
	_vp.add_child(_sun)
	_sun.look_at_from_position(Vector3(cos(deg_to_rad(25.0)) * cos(deg_to_rad(80.0)), sin(deg_to_rad(25.0)),
			cos(deg_to_rad(25.0)) * sin(deg_to_rad(80.0))) * 100.0, Vector3.ZERO, Vector3.UP)
	_manager.sun_light = _sun
	_mesh = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(PATCH, PATCH)
	plane.subdivide_width = int(PATCH / SPACING) - 1
	plane.subdivide_depth = int(PATCH / SPACING) - 1
	_mesh.mesh = plane
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh.position = Vector3(PATCH * 0.5 - 2.0, 0.0, 0.0)
	_vp.add_child(_mesh)
	_mesh.set_instance_shader_parameter("_fft_vertex_spacing", SPACING)
	_mesh.set_instance_shader_parameter("_water_domain_origin", Vector3.ZERO)
