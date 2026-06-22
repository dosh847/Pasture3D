extends SceneTree
# Automated A/B: bake the SAME mound via the C++ chamfer (gpu_raster_threshold=0) and the GPU analytic
# path (threshold=1), then diff the layer samples. Quantifies the analytic-vs-chamfer delta (spec §7).
# Run (editor MUST be closed to avoid import-cache contention):
#   <godot4.7> --path project --rendering-driver vulkan --script res://addons/pasture_3d/tools/gpu_spike/ab_mound_cli.gd

var _done := false

func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var ok := _run()
	print("[AB] exit_ok=%s" % str(ok))
	return true # quit after the first processed frame (root/tree are ready by now)

func _run() -> bool:
	if not ClassDB.class_exists("Pasture3D"):
		print("[AB] FAIL: Pasture3D class missing — GDExtension not loaded.")
		return false
	var terrain = ClassDB.instantiate("Pasture3D")
	get_root().add_child(terrain)
	terrain.vertex_spacing = 1.0
	terrain.change_region_size(256)
	var data = terrain.data
	if data == null:
		print("[AB] FAIL: terrain.data is null.")
		return false
	print("[AB] gpu_raster_available = ", data.gpu_raster_available())

	data.add_region_blankp(Vector3(100, 0, 100))
	var layer_id: int = data.create_owned_layer("abtest", "ABTest", 0) # 0 = REPLACE
	if layer_id < 0:
		print("[AB] FAIL: create_owned_layer -> %d" % layer_id)
		return false
	data.set_active_layer(layer_id)

	# Geometry: a circle, baked as a dome. relative_to_terrain=false + plane_y=0 + no noise so the stamped
	# value is exactly height*profile — isolating the field (chamfer vs analytic) as the ONLY difference.
	var vs := 1.0
	var gw := 200
	var gh := 200
	var poly := PackedVector2Array()
	var npts := 96
	for i in npts:
		var a := TAU * float(i) / float(npts)
		poly.append(Vector2(100.0 + 80.0 * cos(a), 100.0 + 80.0 * sin(a)))
	var clip := AABB(Vector3(0, -1000, 0), Vector3(gw * vs, 2000.0, gh * vs))
	var params := {
		"min_x": 0.0, "min_z": 0.0, "vs": vs, "gw": gw, "gh": gh,
		"height": 10.0, "capped": false, "invert": false,
		"falloff_width": 0.0, "edge_offset": 0.0,
		"relative_to_terrain": false, "plane_y": 0.0,
		"blend": 0, "composite": false, "noise_strength": 0.0,
	}
	var lut := PackedFloat32Array() # empty => analytic smoothstep default

	# CPU bake
	ProjectSettings.set_setting("pasture_3d/performance/gpu_raster_threshold", 0)
	data.clear_layer_in_area(layer_id, clip, false)
	var t0 := Time.get_ticks_usec()
	data.stamp_mound_loop(layer_id, poly, clip, params, lut)
	var cpu_us := Time.get_ticks_usec() - t0
	var cpu := _sample(data, layer_id, gw, gh, vs)

	# GPU bake
	ProjectSettings.set_setting("pasture_3d/performance/gpu_raster_threshold", 1)
	data.clear_layer_in_area(layer_id, clip, false)
	t0 = Time.get_ticks_usec()
	data.stamp_mound_loop(layer_id, poly, clip, params, lut)
	var gpu_us := Time.get_ticks_usec() - t0
	var gpu := _sample(data, layer_id, gw, gh, vs)

	if cpu.size() != gpu.size() or cpu.is_empty():
		print("[AB] FAIL: sample size mismatch (cpu=%d gpu=%d)." % [cpu.size(), gpu.size()])
		return false

	# Compare only cells covered in BOTH bakes (get_layer_height returns NaN where the layer is uncovered).
	var maxd := 0.0
	var sumd := 0.0
	var cpu_peak := 0.0
	var gpu_peak := 0.0
	var both := 0
	var only_cpu := 0
	var only_gpu := 0
	for i in cpu.size():
		var c: float = cpu[i]
		var g: float = gpu[i]
		var cn := is_nan(c)
		var gn := is_nan(g)
		if cn and gn:
			continue
		if cn != gn:
			# coverage-boundary disagreement (one stamped this cell, the other didn't)
			if gn: only_cpu += 1
			else: only_gpu += 1
			continue
		var d: float = absf(c - g)
		maxd = maxf(maxd, d)
		sumd += d
		cpu_peak = maxf(cpu_peak, c)
		gpu_peak = maxf(gpu_peak, g)
		both += 1
	print("[AB] bake: cpu %.2f ms | gpu %.2f ms" % [cpu_us / 1000.0, gpu_us / 1000.0])
	print("[AB] covered-both=%d  only_cpu=%d  only_gpu=%d  cpu_peak=%.4f gpu_peak=%.4f" % [both, only_cpu, only_gpu, cpu_peak, gpu_peak])
	if both == 0:
		print("[AB] WARN: no overlapping covered cells — harness/setup issue, not a parity result.")
		return false
	print("[AB] max|Δheight|=%.5f m   mean|Δ|=%.6f m   (peak ~%.1f m dome)" % [maxd, sumd / both, cpu_peak])
	print("[AB] RESULT: %s" % ("PASS (analytic≈chamfer within epsilon)" if maxd <= 0.5 else "REVIEW (delta larger than 0.5 m — inspect)"))

	_blend_test(data)
	_plow_test(data)
	_splat_test(data)
	_timing_test(data)
	return true

# Phase 1d: validate the batched control apply for Splat. Bakes a TYPE_CONTROL layer batched
# (composite=false → _apply_control_block) and per-cell (composite=true → set_control_on_layer); the layer
# samples (as_float(ctrl)) must be identical. Batched runs FIRST so both read the same empty region control
# map; preserve_base=false keeps the control word out of the float-NaN range so get_layer_height is exact.
func _splat_test(data) -> void:
	ProjectSettings.set_setting("pasture_3d/performance/gpu_raster_threshold", 0)
	var n := 200
	var clip := AABB(Vector3(0, -1e3, 0), Vector3(float(n), 2e3, float(n)))
	var poly := _circle(100.0, 100.0, 80.0)
	var lut := PackedFloat32Array()
	var mk := func(comp): return {
		"min_x": 0.0, "min_z": 0.0, "vs": 1.0, "gw": n, "gh": n,
		"strength": 1.0, "edge_offset": 0.0, "falloff_width": 0.0, "material": 5,
		"preserve_base": false, "uv_bits": 0, "composite": comp, "noise_strength": 0.0,
	}
	var lb: int = data.create_owned_layer_typed("splat_b", "SplatB", 0, 1) # 1 = TYPE_CONTROL
	var lpc: int = data.create_owned_layer_typed("splat_pc", "SplatPC", 0, 1)
	if lb < 0 or lpc < 0:
		print("[AB] SPLAT: create_owned_layer_typed failed (%d,%d) — SKIP" % [lb, lpc])
		return
	data.stamp_splat_loop(lb, poly, clip, mk.call(false), lut)  # batched first (no composite)
	data.stamp_splat_loop(lpc, poly, clip, mk.call(true), lut)  # per-cell
	var diff := 0
	var checked := 0
	for iz in range(0, n, 3):
		for ix in range(0, n, 3):
			var p := Vector3(float(ix), 0.0, float(iz))
			var a: float = data.get_layer_height(lpc, p)
			var b: float = data.get_layer_height(lb, p)
			if is_nan(a) and is_nan(b):
				continue
			if is_nan(a) != is_nan(b) or a != b:
				diff += 1
			checked += 1
	print("[AB] SPLAT batched-vs-percell: checked=%d  mismatches=%d  RESULT: %s" % [
		checked, diff, "PASS" if diff == 0 else "FAIL"])

# Phase 1c: validate the batched apply for Plow (closed-loop, like Mound). Compares the batched write
# (composite=false → _apply_stamp_block) against the per-cell write (composite=true → _stamp_write); the
# layer SAMPLES must be identical (same field, same value, only the write mechanism differs).
func _plow_test(data) -> void:
	ProjectSettings.set_setting("pasture_3d/performance/gpu_raster_threshold", 0) # plow has no GPU field path
	var n := 200
	var clip := AABB(Vector3(0, -1e3, 0), Vector3(float(n), 2e3, float(n)))
	var poly := _circle(100.0, 100.0, 80.0)
	var src := PackedFloat32Array()
	for i in 16:
		src.append(1.0) # constant source so sv=1 → amp = height_scale*0.5*mask
	var lut := PackedFloat32Array()
	var mk := func(comp): return {
		"min_x": 0.0, "min_z": 0.0, "vs": 1.0, "gw": n, "gh": n,
		"height_scale": 10.0, "height_offset": 0.5, "edge_offset": 0.0, "falloff_width": 0.0,
		"relative_to_terrain": false, "plane_y": 0.0, "blend": 0, "composite": comp,
		"src_strength": 1.0, "tile_size": 16.0, "source": 1, "data_w": 4, "data_h": 4, "noise_strength": 0.0,
	}
	var lpc: int = data.create_owned_layer("plow_pc", "PlowPC", 0)
	var lb: int = data.create_owned_layer("plow_b", "PlowB", 0)
	data.stamp_plow_loop(lpc, poly, clip, mk.call(true), lut, src)  # per-cell write (CPU field)
	data.stamp_plow_loop(lb, poly, clip, mk.call(false), lut, src)  # batched write (CPU field)
	var lg: int = data.create_owned_layer("plow_g", "PlowG", 0)
	ProjectSettings.set_setting("pasture_3d/performance/gpu_raster_threshold", 1) # force GPU field
	data.stamp_plow_loop(lg, poly, clip, mk.call(false), lut, src)  # batched write (GPU field)
	ProjectSettings.set_setting("pasture_3d/performance/gpu_raster_threshold", 0)
	var maxd := 0.0
	var gdmax := 0.0
	var checked := 0
	for iz in range(0, n, 3):
		for ix in range(0, n, 3):
			var p := Vector3(float(ix), 0.0, float(iz))
			var a: float = data.get_layer_height(lpc, p)
			var b: float = data.get_layer_height(lb, p)
			var g: float = data.get_layer_height(lg, p)
			if is_nan(a) and is_nan(b):
				continue
			if is_nan(a) != is_nan(b):
				maxd = 1e9
				continue
			maxd = maxf(maxd, absf(a - b))
			if not is_nan(g) and not is_nan(b):
				gdmax = maxf(gdmax, absf(g - b))
			checked += 1
	print("[AB] PLOW batched-vs-percell: checked=%d  max|Δ|=%.6f  RESULT: %s" % [
		checked, maxd, "PASS" if maxd <= 0.0001 else "FAIL"])
	print("[AB] PLOW gpu-vs-cpu field: max|Δ|=%.5f m  RESULT: %s" % [
		gdmax, "PASS (analytic≈chamfer)" if gdmax <= 1.0 else "REVIEW"])

# Validate the batched apply's same-layer blend: bake A alone, B alone, then A+B with MAX on one layer
# (no clear between) and confirm the combined layer equals the per-cell max — the "overlapping tools on a
# shared layer" case (spec §6). Forces the GPU path so the GPU bake's blend is exercised too.
func _blend_test(data) -> void:
	ProjectSettings.set_setting("pasture_3d/performance/gpu_raster_threshold", 1)
	var n := 200
	var clip := AABB(Vector3(0, -1e3, 0), Vector3(float(n), 2e3, float(n)))
	var la: int = data.create_owned_layer("bt_a", "BT_A", 2)
	var lb: int = data.create_owned_layer("bt_b", "BT_B", 2)
	var lc: int = data.create_owned_layer("bt_c", "BT_C", 2) # 2 = MAX
	var pa := _circle(70.0, 100.0, 55.0)
	var pb := _circle(130.0, 100.0, 55.0)
	var prm := func(h): return {
		"min_x": 0.0, "min_z": 0.0, "vs": 1.0, "gw": n, "gh": n,
		"height": h, "capped": false, "invert": false, "falloff_width": 0.0, "edge_offset": 0.0,
		"relative_to_terrain": false, "plane_y": 0.0, "blend": 2, "composite": false, "noise_strength": 0.0,
	}
	var lut := PackedFloat32Array()
	data.stamp_mound_loop(la, pa, clip, prm.call(10.0), lut) # A alone
	data.stamp_mound_loop(lb, pb, clip, prm.call(7.0), lut)  # B alone
	data.stamp_mound_loop(lc, pa, clip, prm.call(10.0), lut) # A then B on the SAME layer, MAX, no clear
	data.stamp_mound_loop(lc, pb, clip, prm.call(7.0), lut)
	var maxerr := 0.0
	var checked := 0
	for iz in range(0, n, 3):
		for ix in range(0, n, 3):
			var p := Vector3(float(ix), 0.0, float(iz))
			var a: float = data.get_layer_height(la, p)
			var b: float = data.get_layer_height(lb, p)
			var c: float = data.get_layer_height(lc, p)
			var expect: float = _nanmax(a, b)
			if is_nan(expect):
				continue
			if is_nan(c):
				maxerr = 1e9 # combined missing where a/b present
				continue
			maxerr = maxf(maxerr, absf(c - expect))
			checked += 1
	print("[AB] BLEND(MAX) overlap: checked=%d  max|c - max(a,b)|=%.5f  RESULT: %s" % [
		checked, maxerr, "PASS" if maxerr <= 0.001 else "FAIL"])

func _nanmax(a: float, b: float) -> float:
	if is_nan(a):
		return b
	if is_nan(b):
		return a
	return maxf(a, b)

func _circle(cx: float, cz: float, rad: float) -> PackedVector2Array:
	var p := PackedVector2Array()
	for i in 96:
		var ang := TAU * float(i) / 96.0
		p.append(Vector2(cx + rad * cos(ang), cz + rad * sin(ang)))
	return p

# Large-box timing: the regime GPU targets. Cover a big box with regions, bake CPU vs GPU, compare paint.
func _timing_test(data) -> void:
	var vs := 1.0
	var n := 1600 # 1600x1600 = 2.56M cells (~the terrain-spanning regime, single feature)
	var rs := 256
	for rz in range(0, n, rs):
		for rx in range(0, n, rs):
			data.add_region_blankp(Vector3(float(rx) + 1.0, 0.0, float(rz) + 1.0))
	var layer_id: int = data.create_owned_layer("abtime", "ABTime", 0)
	data.set_active_layer(layer_id)
	var poly := PackedVector2Array()
	var c := float(n) * 0.5
	var rad := float(n) * 0.42
	for i in 256:
		var a := TAU * float(i) / 256.0
		poly.append(Vector2(c + rad * cos(a), c + rad * sin(a)))
	var clip := AABB(Vector3(0, -1e4, 0), Vector3(float(n) * vs, 2e4, float(n) * vs))
	var params := {
		"min_x": 0.0, "min_z": 0.0, "vs": vs, "gw": n, "gh": n,
		"height": 20.0, "capped": false, "invert": false,
		"falloff_width": 0.0, "edge_offset": 0.0,
		"relative_to_terrain": false, "plane_y": 0.0,
		"blend": 0, "composite": false, "noise_strength": 0.0,
	}
	var lut := PackedFloat32Array()
	ProjectSettings.set_setting("pasture_3d/performance/gpu_raster_threshold", 0)
	data.clear_layer_in_area(layer_id, clip, false)
	var t0 := Time.get_ticks_usec()
	data.stamp_mound_loop(layer_id, poly, clip, params, lut)
	var cpu_ms := (Time.get_ticks_usec() - t0) / 1000.0
	ProjectSettings.set_setting("pasture_3d/performance/gpu_raster_threshold", 1)
	data.clear_layer_in_area(layer_id, clip, false)
	t0 = Time.get_ticks_usec()
	data.stamp_mound_loop(layer_id, poly, clip, params, lut)
	var gpu_ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("[AB] TIMING %dx%d (%.1fM cells, %d edges): cpu %.1f ms | gpu %.1f ms | speedup %.1fx" % [
		n, n, float(n * n) / 1e6, poly.size(), cpu_ms, gpu_ms, cpu_ms / maxf(gpu_ms, 0.001)])

func _sample(data, layer_id: int, gw: int, gh: int, vs: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var step := 3
	for iz in range(0, gh, step):
		for ix in range(0, gw, step):
			out.append(data.get_layer_height(layer_id, Vector3(float(ix) * vs, 0.0, float(iz) * vs)))
	return out
