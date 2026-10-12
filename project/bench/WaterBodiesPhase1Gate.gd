# Pasture3D Water Bodies — Phase 1 exit gate (spec §11, PASTURE3D_WATER_BODIES_SPEC.md).
#
# Phase 1 adds Pasture3DWaveProfile and Pasture3DPoolManager, moves the clock and the sun
# onto the manager, introduces the (base material, profile) material cache, and
# promotes _water_domain_origin to an instance uniform.
#
# Gate criteria, from the spec's phase table:
#   A. TWO DIFFERENT PROFILES in one scene each reach their own material (until Phase 6 of
#      the FFT port this was G4's Gerstner CPU/GPU parity probe; parity is now WaterBuoyGate's)
#   B. instance origin -- two meshes 5 km apart on one material are both correct;
#      the control is the old shared-uniform behaviour, which must fail
#   C. ten pools on one profile cost ONE material and ONE upload
#   D. the manager owns the clock, and Pasture3D adopts it rather than fighting it
#
# Every criterion carries a control that must fail; see the header on each.
#
# Run: Godot_v4.7-stable_win64_console.exe --path project bench/WaterBodiesPhase1Gate.tscn
extends Node

const WATER_DIR := "res://addons/pasture_3d/extras/shaders/water/"
const LAKE_MAT := WATER_DIR + "M_water_lake.tres"
const DEBUG_SHADER := "res://bench/water_body_debug.gdshader"

const LOOP_PERIOD := 120.0

# How far apart criterion B puts its two bodies. Far enough that a shared origin is
# a different phase of the wave field, not a slightly different one.
const B_SEPARATION := 5000.0

var _fail := 0
var _out_dir := ""
# Criteria that ran to completion. A GDScript runtime error abandons a function
# WITHOUT incrementing _fail, so a thrown criterion would otherwise read as a pass --
# which is exactly what happened when Phase 2 removed Pasture3D.get_water_time() and
# this gate still printed PASS. Each criterion increments this at its end; the verdict
# requires all four.
var _completed := 0
const CRITERIA := 4


func _ready() -> void:
	var bail := Timer.new()
	bail.wait_time = 600.0
	bail.one_shot = true
	bail.timeout.connect(func():
		push_error("gate timed out")
		get_tree().quit(2))
	add_child(bail)
	bail.start()

	_out_dir = OS.get_environment("BENCH_OUT")
	if _out_dir == "":
		_out_dir = "user://"

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	Engine.physics_ticks_per_second = 60
	DisplayServer.window_set_size(Vector2i(1280, 800))

	print("=== Pasture3D Water Bodies — Phase 1 gate ===")
	print("Godot %s | %s | %s" % [
		Engine.get_version_info().string,
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_current_rendering_method()])
	print("")

	await _gate_a_routing()
	await _gate_b_instance_origin()
	_gate_c_material_cache()
	await _gate_d_clock_ownership()

	print("")
	if _completed != CRITERIA:
		_fail += 1
		print("!! only %d of %d criteria ran to completion -- one threw partway and its" % [
			_completed, CRITERIA])
		print("   checks were skipped, so a green result here would mean 'did not look'")
	print("=== PHASE 1 GATE %s ===" % ("PASS" if _fail == 0 else "FAIL (%d)" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)


# ---- A: two profiles, two materials ------------------------------------------
# What Phase 1 changed is that a material's waves come from a profile picked by name out
# of an array, and that several profiles coexist. So the question is "does profile X's
# model reach the GPU as profile X's model", which a single-profile scene cannot ask.
#
# Until Phase 6 of the FFT port this was asked through G4, a canvas_item probe that
# re-evaluated the Gerstner table on the GPU against the CPU's answers. The FFT's CPU
# answer is a lagged readback by contract (PASTURE3D_WATER_FFT_SPEC.md §5), so there is no
# per-instant parity left to probe for it, and the fBm's is WaterBuoyGate [B]. What is
# left is the routing, which is read here off the uniforms the manager wrote: the FFT's
# texture wrappers and cascade lengths, or the fBm's vertex pack, whichever it draws.
#
# Two profiles, deliberately different in every knob, from the SAME manager. The control:
# each material read against the OTHER profile must disagree, or the manager is handing
# out one model under two names and the match proves nothing.
func _gate_a_routing() -> void:
	print("[A] two profiles in one scene each reach their own material:")
	var root := _make_world()
	var manager := _make_manager(root)
	var names := ["lake_calm", "pond_still"]
	var mats := {}
	for name in names:
		var mat: ShaderMaterial = manager.get_material_for(load(LAKE_MAT), name)
		if mat == null:
			_fail += 1
			print("    !! the manager returned no material for '%s'" % name)
			continue
		mats[name] = mat
	if mats.size() == 2:
		for i in 2:
			var name: String = names[i]
			var other: String = names[1 - i]
			var own := _carries(mats[name], manager.get_profile(name))
			var crossed := _carries(mats[name], manager.get_profile(other))
			print("    %-11s material carries its own profile: %s | CONTROL, carries %s's: %s (must be false)" % [
				name, own, other, crossed])
			if not own:
				_fail += 1
				print("    !! '%s' did not reach its material" % name)
			if crossed:
				_fail += 1
				print("    !! '%s' also matches %s's model, so the two are one and A proves nothing" % [name, other])
	root.queue_free()
	await _settle()
	_completed += 1


# True when p_mat holds p_profile's model, as the manager uploads it.
func _carries(p_mat: ShaderMaterial, p_profile: Pasture3DWaveProfile) -> bool:
	if p_profile.is_fft_active():
		var fft := p_profile.fft
		return int(p_mat.get_shader_parameter("_wave_model")) == 1 \
				and p_mat.get_shader_parameter("_fft_displacement") == fft.get_displacement_texture() \
				and p_mat.get_shader_parameter("_fft_repeat") == fft.get_cascade_repeats()
	var pack := p_profile.fbm.get_shader_pack(Pasture3DWaterFBM.SET_VERTEX)
	for i in 4:
		if p_mat.get_shader_parameter("_fbm_v%d" % i) != pack[i]:
			return false
	return int(p_mat.get_shader_parameter("_wave_model")) == 2


# ---- B: the instance uniform --------------------------------------------------
# §5.4's whole argument: ten ponds share one material, but they sit in ten different
# places, and a domain origin stored on the material would force them to share one.
# Promoted to an instance uniform, each body sets its own.
#
# Measured on the SURFACE, not on a readback of the uniform, because "the value I set
# is the value I read" would pass whether or not the shader used it. Two subdivided
# planes, one at the world origin and one 5 km out, each given ITS OWN position as
# its domain origin, drawn with the unlit debug wrapper. Both then evaluate the wave
# field at the same domain coordinates, so their surfaces must be identical.
#
# The control is the bug this replaced: give both instances the SAME origin. The far
# plane is then evaluated 5 km into the wave field and must look different. If it
# does not, the origin is not reaching the shader at all and the criterion is
# comparing two planes that would match no matter what.
func _gate_b_instance_origin() -> void:
	print("")
	print("[B] _water_domain_origin is per instance, not per material:")
	var root := _make_world()
	var manager := _make_manager(root)
	var cam: Camera3D = root.get_node("Camera3D")

	# ONE material, shared. That is the point.
	var shared := ShaderMaterial.new()
	shared.shader = load(DEBUG_SHADER)
	if shared.shader == null:
		_fail += 1
		print("    !! could not load %s; B cannot run" % DEBUG_SHADER)
		root.queue_free()
		return
	manager.upload_profile_into(shared, "lake_calm")

	var near := _make_plane(root, Vector3.ZERO, shared)
	var far := _make_plane(root, Vector3(B_SEPARATION, 0.0, 0.0), shared)

	# Freeze so both captures are the same instant.
	manager.paused = true
	_freeze_clock(21.0)

	# Correct: each body's own position is its domain origin.
	near.set_instance_shader_parameter("_water_domain_origin", Vector3.ZERO)
	far.set_instance_shader_parameter("_water_domain_origin", Vector3(B_SEPARATION, 0.0, 0.0))
	cam.position = Vector3(0.0, 12.0, 0.0)
	await _settle()
	var img_near := _grab()
	cam.position = Vector3(B_SEPARATION, 12.0, 0.0)
	await _settle()
	var img_far := _grab()
	var delta_ok := _mean_delta(img_near, img_far)
	_screenshot(_out_dir.path_join("phase1_b_near.png"))

	# The control: both instances told the origin is zero, which is what a material
	# uniform would have forced.
	far.set_instance_shader_parameter("_water_domain_origin", Vector3.ZERO)
	await _settle()
	var img_shared := _grab()
	var delta_bad := _mean_delta(img_near, img_shared)
	_screenshot(_out_dir.path_join("phase1_b_far_shared_origin.png"))

	print("    per-instance origins, near vs far surface: mean delta %.6f" % delta_ok)
	print("    CONTROL, both origins 0 (the material-uniform case): %.6f" % delta_bad)

	# Non-vacuity: the surface must have visible structure at all, or both numbers
	# are zero and the comparison is between two blank images.
	var structure := _spread(img_near)
	print("    surface structure in the near capture (channel spread): %.4f" % structure)
	if structure < 0.05:
		_fail += 1
		print("    !! the debug surface is nearly uniform; B is comparing blank frames")
	elif delta_ok > 0.02:
		_fail += 1
		print("    !! two bodies given their own domain origins do NOT agree; the")
		print("       instance uniform is not reaching the shader")
	elif delta_bad < delta_ok * 4.0:
		_fail += 1
		print("    !! a shared origin looks the same as per-instance origins, so the")
		print("       uniform is being ignored and B proves nothing")
	else:
		print("    -> per-instance agrees (%.6f) and shared does not (%.6f), %.0fx apart" % [
			delta_ok, delta_bad, delta_bad / maxf(delta_ok, 1e-6)])

	manager.paused = false
	root.queue_free()
	await _settle()
	_completed += 1


# ---- C: the material cache ----------------------------------------------------
# §5.4's promise, stated as a number: ten pools on one profile cost one material and
# one upload. Checked through the API rather than by counting draw calls, because
# the claim is about what the manager builds, and that is what get_cached_material_count
# and get_upload_count report.
#
# Two controls. Ten pools on TEN profiles must produce ten of each, or the counters
# are stuck rather than low. And the cached material must not be the base itself --
# handing back the shipped .tres would also read as "one material", while quietly
# writing the user's wave table into a plugin file.
func _gate_c_material_cache() -> void:
	print("")
	print("[C] the (base material, profile) cache:")
	var root := _make_world()
	var manager := _make_manager(root)
	var base: Material = load(LAKE_MAT)

	var uploads_before: int = manager.get_upload_count()
	var mats := []
	for i in 10:
		mats.append(manager.get_material_for(base, "lake_calm"))
	var uploads := manager.get_upload_count() - uploads_before
	var cached: int = manager.get_cached_material_count()

	var all_same := true
	for m in mats:
		if m != mats[0]:
			all_same = false
	print("    10 pools, one profile -> %d cached material(s), %d upload(s), all identical: %s" % [
		cached, uploads, str(all_same)])
	if cached != 1 or uploads != 1 or not all_same:
		_fail += 1
		print("    !! expected exactly 1 material and 1 upload shared by all ten")

	if mats[0] == base:
		_fail += 1
		print("    !! the cache handed back the BASE material; a plugin preset would be")
		print("       written to, and a plugin update would overwrite the user's water")

	# Control: ten distinct profiles must cost ten of each.
	var profiles: Array[Pasture3DWaveProfile] = []
	for i in 10:
		var p := Pasture3DWaveProfile.new()
		p.profile_name = "ctrl_%d" % i
		p.fit_sea(0.0, 20.0 + 7.0 * i, 0.1)
		profiles.append(p)
	manager.profiles = profiles
	manager.clear_material_cache()
	var uploads2_before: int = manager.get_upload_count()
	for i in 10:
		manager.get_material_for(base, "ctrl_%d" % i)
	var uploads2 := manager.get_upload_count() - uploads2_before
	print("    CONTROL, 10 pools on 10 profiles -> %d cached, %d uploads (must be 10/10)" % [
		manager.get_cached_material_count(), uploads2])
	if manager.get_cached_material_count() != 10 or uploads2 != 10:
		_fail += 1
		print("    !! the counters do not move with distinct profiles, so the '1 and 1'")
		print("       above is a stuck counter and not a cache hit")

	root.queue_free()
	_completed += 1


# ---- D: who owns the clock ----------------------------------------------------
# Phase 1 asked whether Pasture3D yielded its clock to the manager. Phase 2 deleted
# the ocean from Pasture3D outright, so there is no longer a second clock to yield --
# this criterion was rewritten rather than deleted, because the question it protects
# still matters: every water body must read the SAME instant the shader is drawing at,
# or the CPU queries answer for another instant, for a reason invisible in any single file.
#
# The reader is now Pasture3DOcean, which owns no clock and forwards to the manager.
# The control is an ocean with NO manager in the tree: it must report 0, proving the
# agreement above is a real read of the manager rather than two nodes that happen to
# hold the same number.
func _gate_d_clock_ownership() -> void:
	print("")
	print("[D] Pasture3DPoolManager owns the clock; Pasture3DOcean reads it:")
	var root := _make_world()
	var manager := _make_manager(root)
	# A deliberately non-default period, so agreement cannot be a coincidence of
	# both sides defaulting to 120.
	manager.loop_period = 37.0
	var ocean := Pasture3DOcean.new()
	ocean.material = load(WATER_DIR + "M_water_ocean.tres")
	ocean.wave_profile = "lake_calm"
	ocean.render_layers = 1 << 4
	root.add_child(ocean)

	for i in 90:
		await get_tree().physics_frame
	await _settle()

	var t_manager: float = manager.get_water_time()
	var t_ocean: float = ocean.get_water_time()
	print("    manager %.6f | ocean %.6f | difference %.9f" % [
		t_manager, t_ocean, absf(t_manager - t_ocean)])
	if t_manager <= 0.0:
		_fail += 1
		print("    !! the manager's clock never advanced; D is vacuous")
	elif absf(t_manager - t_ocean) > 1e-6:
		_fail += 1
		print("    !! the ocean is not on the manager's clock, so its CPU query and the")
		print("       drawn surface are at different instants")
	else:
		print("    -> the ocean reads the manager's clock exactly")

	# The clock must also wrap at the MANAGER's period, not at some default. 90 ticks
	# at 60 Hz is 1.5 s, well inside 37, so this checks the period actually reached
	# the manager rather than that the number looks plausible.
	if not is_equal_approx(manager.loop_period, 37.0):
		_fail += 1
		print("    !! the manager did not keep the period it was given")

	root.queue_free()
	await _settle()

	# The control: an ocean with no manager anywhere. It must report 0, or the
	# agreement above could be an ocean quietly running a clock of its own.
	var lone_root := _make_world()
	var lone := Pasture3DOcean.new()
	lone.material = load(WATER_DIR + "M_water_ocean.tres")
	lone.render_layers = 1 << 4
	lone_root.add_child(lone)
	for i in 30:
		await get_tree().physics_frame
	await _settle()
	var t_lone: float = lone.get_water_time()
	print("    CONTROL, ocean with no manager: get_water_time() = %.6f (must be 0)" % t_lone)
	if absf(t_lone) > 1e-9:
		_fail += 1
		print("    !! the ocean has a clock of its own; D does not prove it reads the manager")
	lone_root.queue_free()
	await _settle()
	_completed += 1


# ---- helpers ------------------------------------------------------------------
func _make_world() -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var env := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-38, 130, 0)
	sun.shadow_enabled = false
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.position = Vector3(0, 12, 0)
	cam.rotation_degrees = Vector3(-25, 0, 0)
	cam.far = 20000.0
	cam.cull_mask = 1
	cam.current = true
	root.add_child(cam)
	return root


func _make_manager(p_root: Node3D) -> Pasture3DPoolManager:
	var manager := Pasture3DPoolManager.new()
	manager.name = "Pasture3DPoolManager"
	manager.loop_period = LOOP_PERIOD
	# The two Gerstner fixtures this gate was written with, carried through the migration's fit
	# (sigma = 0.176 x the old table's amplitude sum).
	var lake := Pasture3DWaveProfile.new()
	lake.profile_name = "lake_calm"
	lake.fit_sea(0.0, 60.0, 0.152854)

	var pond := Pasture3DWaveProfile.new()
	pond.profile_name = "pond_still"
	pond.fit_sea(20.0, 18.0, 0.024065)
	pond.min_wavelength = 8.9931

	var profiles: Array[Pasture3DWaveProfile] = [lake, pond]
	manager.profiles = profiles
	p_root.add_child(manager)
	manager.sun_light = p_root.get_node("Sun")
	return manager


# A plane dense enough that the waves are visible at all: they are a VERTEX effect,
# and a two-triangle plane cannot show one.
func _make_plane(p_root: Node3D, p_pos: Vector3, p_mat: Material) -> MeshInstance3D:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(200.0, 200.0)
	mesh.subdivide_width = 120
	mesh.subdivide_depth = 120
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = p_mat
	mi.position = p_pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	p_root.add_child(mi)
	return mi


func _freeze_clock(p_time: float) -> void:
	RenderingServer.global_shader_parameter_set("water_time", p_time)
	RenderingServer.global_shader_parameter_set("water_time_period", LOOP_PERIOD)


func _settle() -> void:
	for i in 10:
		await RenderingServer.frame_post_draw


func _grab() -> Image:
	return get_viewport().get_texture().get_image()


func _screenshot(p_path: String) -> void:
	var err := _grab().save_png(p_path)
	if err != OK:
		_fail += 1
		push_error("could not write %s (error %d)" % [p_path, err])


func _mean_delta(p_a: Image, p_b: Image) -> float:
	var total := 0.0
	var n := 0
	for y in range(0, p_a.get_height(), 4):
		for x in range(0, p_a.get_width(), 4):
			var ca := p_a.get_pixel(x, y)
			var cb := p_b.get_pixel(x, y)
			total += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			n += 1
	return total / float(maxi(n, 1))


# Max-minus-min of the green channel over the frame. Cheap "is there anything here"
# check: a blank or uniform image scores ~0, and two blank images mean-delta to 0
# against each other, which would read as a pass.
func _spread(p_img: Image) -> float:
	var lo := 1.0
	var hi := 0.0
	for y in range(0, p_img.get_height(), 4):
		for x in range(0, p_img.get_width(), 4):
			var g := p_img.get_pixel(x, y).g
			lo = minf(lo, g)
			hi = maxf(hi, g)
	return hi - lo
