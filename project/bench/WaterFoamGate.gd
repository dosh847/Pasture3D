extends Node
## W3 of PASTURE3D_WATER_PRODUCTION_SPEC.md (§2.2): crest foam that reads at every distance and resolution.
##
## The TRUTH is the sea's mean crest, E[clamp(sum of the drawn cascades' foam + offset, 0, 1)], read off
## the simulation's own texels (displacement .a, mip 0) on the same paused frame that is rendered: the
## cascades tile at incommensurate repeats, so the summed foam's distribution is the convolution of each
## cascade's (as WaterFoamCoverageProbe). The RENDER is water_fft_shading_debug's EMISSION.b, the shipped
## crest, top-down through a float viewport, every fade off and the geometry flat; its mean over a view is
## what the sea shows at that view's pixel footprint.
## Criteria, each with a control that must fail:
##   [F] Footprint. At N 1024, whose resolution lift is 0 by definition, the rendered mean crest is within
##       F_TOL of the truth at every view, 100 m to 1600 m across 512 px (20 cm to 3 m a pixel), summed over
##       every sample. Control: fft_foam_footprint off (the reference's clamp of the mipped mean) falls
##       below F_CTRL of the truth at the widest view. Witness: the truth is over MIN_TRUTH.
##   [R] Resolution. At every N, the rendered mean crest at R_VIEW is within R_TOL of 256's: the shipped
##       ocean at 128 looks like it does at 1024. Control: the same seas' truths at the uploaded offset,
##       without the shader's resolution lift, spread by over R_CTRL (max / min).
## Renders, so it runs windowed:
##   Godot --path project --fixed-fps 60 res://bench/WaterFoamGate.tscn
## Every criterion counts its completions; one that throws before asserting reports as missing.

const SHADER := "res://bench/water_fft_shading_debug.gdshader"
const PIXELS := 512
const STRIDE := 2
const VIEWS := [100.0, 400.0, 1600.0]
const R_VIEW := 400.0
const RESOLUTIONS := [256, 128, 512, 1024]
const SEEDS := [0, 101, 202]
const SAMPLES := 2
const WARM_SECONDS := 8.0
const SAMPLE_SECONDS := 0.75
const BINS := 500
const BIN_MAX := 2.5
const MAX_READ := 256
const CRITERIA := 2
const F_TOL := 0.1
const F_CTRL := 0.5
const MIN_TRUTH := 0.01
const R_TOL := 0.1
const R_CTRL := 2.0

var _manager: Pasture3DPoolManager
var _vp: SubViewport
var _cam: Camera3D
var _mesh: MeshInstance3D
var _mat: ShaderMaterial
var _failures := 0
var _completed := 0


func _ready() -> void:
	print("=== WaterFoamGate ===")
	_manager = Pasture3DPoolManager.new()
	add_child(_manager)
	_build()
	await _criterion_f()
	await _criterion_r()
	if _completed != CRITERIA:
		_fail("only %d of %d criteria ran to the end" % [_completed, CRITERIA])
	print("=== WATER FOAM %s (%d failures, %d/%d criteria) ===" % [
		"PASS" if _failures == 0 else "FAIL", _failures, _completed, CRITERIA])
	get_tree().quit(0 if _failures == 0 else 1)


func _fail(p_msg: String) -> void:
	_failures += 1
	printerr("  FAIL ", p_msg)


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["ok  " if p_ok else "FAIL", p_msg])
	if not p_ok:
		_failures += 1


func _criterion_f() -> void:
	print("[F] the rendered crest is the sea's mean crest at every footprint (N 1024)")
	await _set_resolution(1024)
	# A Dictionary, not locals: a lambda captures locals by value, and its += would be lost.
	var acc := {"truth": 0.0, "off": 0.0}
	for v in VIEWS.size():
		acc[v] = 0.0
	await _each_sample(func() -> void:
		acc.truth += _truth(_mat.get_shader_parameter("_fft_foam_offset"))
		for v in VIEWS.size():
			acc[v] += await _rendered(VIEWS[v], true)
		acc.off += await _rendered(VIEWS[-1], false))
	var truth: float = acc.truth
	_check(truth / _sample_count() > MIN_TRUTH, "WITNESS the sea's mean crest %.4f (> %.2f)" % [
		truth / _sample_count(), MIN_TRUTH])
	for v in VIEWS.size():
		var r: float = acc[v] / maxf(truth, 1e-12)
		_check(absf(r - 1.0) < F_TOL, "%4.0f m view (%.2f m/px): rendered / truth %.3f (1 +- %.2f)" % [
			VIEWS[v], VIEWS[v] / PIXELS, r, F_TOL])
	var c: float = acc.off / maxf(truth, 1e-12)
	_check(c < F_CTRL, "CONTROL footprint off, %.0f m view: rendered / truth %.3f (< %.2f)" % [VIEWS[-1], c, F_CTRL])
	_completed += 1


func _criterion_r() -> void:
	print("[R] every resolution shows 256's crest (%.0f m view)" % R_VIEW)
	var rendered := {}
	var bare := {}
	for n in RESOLUTIONS.duplicate():
		await _set_resolution(n)
		var acc := {"r": 0.0, "t": 0.0}
		await _each_sample(func() -> void:
			acc.r += await _rendered(R_VIEW, true)
			acc.t += _truth(_mat.get_shader_parameter("_fft_foam_offset")))
		rendered[n] = acc.r / _sample_count()
		bare[n] = acc.t / _sample_count()
	for n in RESOLUTIONS:
		var rel: float = rendered[n] / maxf(rendered[256], 1e-12)
		_check(absf(rel - 1.0) < R_TOL, "N %4d: rendered mean crest %.4f, %.3f x 256's (1 +- %.2f)" % [
			n, rendered[n], rel, R_TOL])
	var spread: float = bare.values().max() / maxf(bare.values().min(), 1e-12)
	var parts := PackedStringArray()
	for n in RESOLUTIONS:
		parts.append("%d: %.4f" % [n, bare[n]])
	_check(spread > R_CTRL, "CONTROL without the resolution lift, truths %s spread %.2f x (> %.1f)" % [
		", ".join(parts), spread, R_CTRL])
	_completed += 1


func _sample_count() -> int:
	return SEEDS.size() * SAMPLES


func _frames(p_n: int) -> void:
	for i in p_n:
		await RenderingServer.frame_post_draw


func _set_resolution(p_n: int) -> void:
	_manager.fft_resolution = p_n
	await _frames(2)
	if _manager.get_effective_fft_resolution() != p_n:
		_fail("N %d unavailable here (effective %d)" % [p_n, _manager.get_effective_fft_resolution()])


## Runs p_body on every paused sample of every seed.
func _each_sample(p_body: Callable) -> void:
	var prof := _manager.get_profile(&"ocean_default")
	for seed in SEEDS.duplicate():
		prof.fft.seed = seed
		_manager.paused = false
		await _frames(int(WARM_SECONDS * 60.0))
		# A rebuild hands the material a placeholder until a parameter set: rebind after the warm.
		_upload()
		for s in SAMPLES:
			await _frames(int(SAMPLE_SECONDS * 60.0))
			_manager.paused = true
			await _frames(1)
			await p_body.call()
			_manager.paused = false


## The shipped ocean, read with every fade off and the geometry flat, so a pixel is its rest position.
func _upload() -> void:
	_manager.upload_profile_into(_mat, &"ocean_default")
	for p in ["fft_displacement_falloff", "fft_normal_falloff", "fft_foam_falloff"]:
		_mat.set_shader_parameter(p, 0.0)
	_mat.set_shader_parameter("_fft_displaces", Vector4.ZERO)


## The mean rendered crest over a p_view metre square.
func _rendered(p_view: float, p_footprint: bool) -> float:
	_mat.set_shader_parameter("fft_foam_footprint", p_footprint)
	_cam.size = p_view
	var plane := _mesh.mesh as PlaneMesh
	plane.size = Vector2(p_view, p_view) * 1.1
	_mesh.set_instance_shader_parameter("_fft_vertex_spacing", p_view * 1.1 / 64.0)
	await _frames(3)
	var img := _vp.get_texture().get_image()
	var s := 0.0
	var n := 0
	for y in range(0, PIXELS, STRIDE):
		for x in range(0, PIXELS, STRIDE):
			s += img.get_pixel(x, y).b
			n += 1
	_mat.set_shader_parameter("fft_foam_footprint", true)
	return s / n


## The sea's mean crest at p_offset, from the drawn cascades' mip-0 foam on this frame.
func _truth(p_offset: float) -> float:
	var prof := _manager.get_profile(&"ocean_default")
	var rd := RenderingServer.get_rendering_device()
	var rid: RID = prof.fft.get_displacement_texture().texture_rd_rid
	var n := _manager.get_effective_fft_resolution()
	var sum := PackedFloat64Array()
	for c in 4:
		if not (prof.fft.cascade_drawn >> c) & 1:
			continue
		var one := _cascade_histogram(rd.texture_get_data(rid, c), n)
		sum = one if sum.is_empty() else _convolve(sum, one)
	var m := 0.0
	for i in BINS:
		m += sum[i] * clampf((i + 0.5) * BIN_MAX / BINS + p_offset, 0.0, 1.0)
	return m


func _cascade_histogram(p_bytes: PackedByteArray, p_n: int) -> PackedFloat64Array:
	var h := PackedFloat64Array()
	h.resize(BINS)
	var step := maxi(1, p_n / MAX_READ)
	var count := 0
	for y in range(0, p_n, step):
		for x in range(0, p_n, step):
			var f := p_bytes.decode_half((y * p_n + x) * 8 + 6)
			h[clampi(int(f / BIN_MAX * BINS), 0, BINS - 1)] += 1.0
			count += 1
	for i in BINS:
		h[i] /= count
	return h


func _convolve(p_a: PackedFloat64Array, p_b: PackedFloat64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(BINS)
	for i in BINS:
		if p_a[i] == 0.0:
			continue
		for j in BINS - i:
			if p_b[j] != 0.0:
				out[i + j] += p_a[i] * p_b[j]
	return out


func _build() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(PIXELS, PIXELS)
	_vp.own_world_3d = true
	# Float readback, as WaterFFTWiringGate's.
	_vp.use_hdr_2d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.position = Vector3(0.0, 100.0, 0.0)
	_cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_cam.far = 400.0
	_cam.current = true
	_vp.add_child(_cam)
	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER)
	_mesh = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.subdivide_width = 63
	plane.subdivide_depth = 63
	_mesh.mesh = plane
	_mesh.material_override = _mat
	_vp.add_child(_mesh)
	_mesh.set_instance_shader_parameter("_water_domain_origin", Vector3.ZERO)
	_upload()
