extends RefCounted
# Phase 0 — RenderingDevice de-risk spike for PASTURE3D_BRUSH_GPU_RASTER_SPEC.md (§7, §8).
# Proves a LOCAL RenderingDevice compute dispatch + readback runs in this context (CLI or editor),
# fills an R32F texture with a known pattern, verifies correctness, and measures dispatch vs readback
# latency across box sizes up to the measured terrain-spanning benchmark (2240x2496).
#
# No Pasture3D dependency — this isolates the "does local RD compute+readback work at all" question.

# GLSL compute source (RDShaderSource path: no "#[compute]" header; stage set explicitly in code).
const GLSL := """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) restrict writeonly uniform image2D out_tex;

layout(push_constant, std430) uniform Params {
	uint width;
	uint height;
	uint pad0;
	uint pad1;
} pc;

void main() {
	uint x = gl_GlobalInvocationID.x;
	uint y = gl_GlobalInvocationID.y;
	if (x >= pc.width || y >= pc.height) { return; }
	// Deterministic, exactly representable in float32 for our box sizes (< 2^24 cells).
	float val = float(x + y * pc.width);
	imageStore(out_tex, ivec2(int(x), int(y)), vec4(val, 0.0, 0.0, 0.0));
}
"""

# Box sizes to profile: powers of two up to 2048, plus the real terrain-spanning benchmark.
const SIZES := [
	Vector2i(64, 64),
	Vector2i(128, 128),
	Vector2i(256, 256),
	Vector2i(512, 512),
	Vector2i(1024, 1024),
	Vector2i(2048, 2048),
	Vector2i(2240, 2496), # the §7 MoundDigValleyFloor benchmark box (in cells, vs=1 assumed)
]

const ITERS := 6 # per size; we report the MIN (least-noisy) dispatch/readback time.

func run_all(log_fn: Callable) -> Dictionary:
	var result := {"ok": false, "rd_ok": false, "rows": [], "summary": ""}

	log_fn.call("=== Pasture3D GPU Phase 0: RenderingDevice compute+readback spike ===")

	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		log_fn.call("[FAIL] create_local_rendering_device() returned null.")
		log_fn.call("       => No local RenderingDevice in this context. If this is the EDITOR, GPU path")
		log_fn.call("          is not viable here; per spec Phase 0, STOP and keep the C++ path.")
		result.summary = "No local RenderingDevice."
		return result
	result.rd_ok = true
	log_fn.call("[ok] local RenderingDevice created.")
	if rd.has_method("get_device_name"):
		log_fn.call("     GPU: %s" % rd.get_device_name())

	# --- Compile the compute shader from source (tests glslang availability in this build) ---
	var t_compile := Time.get_ticks_usec()
	var src := RDShaderSource.new()
	src.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, GLSL)
	var spirv := rd.shader_compile_spirv_from_source(src)
	var cerr := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if cerr != "":
		log_fn.call("[FAIL] compute shader compile error:\n" + cerr)
		result.summary = "Shader compile failed."
		rd.free()
		return result
	var shader := rd.shader_create_from_spirv(spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	var compile_ms := (Time.get_ticks_usec() - t_compile) / 1000.0
	log_fn.call("[ok] shader compiled + pipeline created in %.2f ms (one-time, amortised)." % compile_ms)

	log_fn.call("")
	log_fn.call("  %-12s %6s %12s %12s %12s   %s" % ["box", "MPix", "dispatch_ms", "readback_ms", "total_ms", "verify"])
	log_fn.call("  " + "-".repeat(74))

	var all_ok := true
	for sz in SIZES:
		var w: int = sz.x
		var h: int = sz.y
		var best_dispatch := 1.0e30
		var best_readback := 1.0e30
		var verify_ok := false
		var verify_msg := ""
		for i in ITERS:
			var r := _bake_once(rd, shader, pipeline, w, h)
			best_dispatch = min(best_dispatch, r.dispatch_us)
			best_readback = min(best_readback, r.readback_us)
			# Verify once (cheap sampled check) on the first iteration.
			if i == 0:
				var v := _verify(r.data, w, h)
				verify_ok = v.ok
				verify_msg = v.msg
		if not verify_ok:
			all_ok = false
		var mpix := (float(w) * float(h)) / 1.0e6
		var disp_ms := best_dispatch / 1000.0
		var read_ms := best_readback / 1000.0
		var total_ms := disp_ms + read_ms
		result.rows.append({
			"w": w, "h": h, "mpix": mpix,
			"dispatch_ms": disp_ms, "readback_ms": read_ms, "total_ms": total_ms,
			"verify_ok": verify_ok,
		})
		log_fn.call("  %-12s %6.2f %12.3f %12.3f %12.3f   %s" % [
			"%dx%d" % [w, h], mpix, disp_ms, read_ms, total_ms,
			"PASS" if verify_ok else ("FAIL " + verify_msg),
		])

	log_fn.call("  " + "-".repeat(74))

	# Cleanup.
	rd.free_rid(pipeline)
	rd.free_rid(shader)
	rd.free()

	result.ok = all_ok
	# Headline: the terrain-spanning row vs the §7 CPU baseline (paint 1631 ms).
	var big = result.rows.back() if not result.rows.is_empty() else null
	if all_ok and big != null:
		result.summary = "PASS. Terrain box %dx%d: dispatch %.2f ms + readback %.2f ms = %.2f ms (CPU paint baseline was 1631 ms)." % [
			big.w, big.h, big.dispatch_ms, big.readback_ms, big.total_ms,
		]
	elif not result.ok:
		result.summary = "Compute ran but verification FAILED on at least one size."
	log_fn.call("")
	log_fn.call("RESULT: " + result.summary)
	return result


func _bake_once(rd: RenderingDevice, shader: RID, pipeline: RID, w: int, h: int) -> Dictionary:
	# Output storage texture (R32F).
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.width = w
	fmt.height = h
	fmt.depth = 1
	fmt.array_layers = 1
	fmt.mipmaps = 1
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var tex := rd.texture_create(fmt, RDTextureView.new(), [])

	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = 0
	u.add_id(tex)
	var uset := rd.uniform_set_create([u], shader, 0)

	var push := PackedInt32Array([w, h, 0, 0]).to_byte_array()

	var t0 := Time.get_ticks_usec()
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	var gx := (w + 7) / 8
	var gy := (h + 7) / 8
	rd.compute_list_dispatch(cl, gx, gy, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var t1 := Time.get_ticks_usec()
	var data := rd.texture_get_data(tex, 0)
	var t2 := Time.get_ticks_usec()

	rd.free_rid(uset)
	rd.free_rid(tex)
	return {
		"dispatch_us": float(t1 - t0),
		"readback_us": float(t2 - t1),
		"data": data,
	}


# Sampled correctness check: array length + a deterministic spread of cells (corners, edges, interior).
func _verify(data: PackedByteArray, w: int, h: int) -> Dictionary:
	var expected_bytes := w * h * 4
	if data.size() != expected_bytes:
		return {"ok": false, "msg": "len %d != %d (row padding?)" % [data.size(), expected_bytes]}
	var f := data.to_float32_array()
	var samples: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(w - 1, 0), Vector2i(0, h - 1), Vector2i(w - 1, h - 1),
		Vector2i(w / 2, h / 2), Vector2i(w / 3, h / 7), Vector2i(w - 1, h / 2),
	]
	# Add a deterministic spread.
	var n := 256
	for i in n:
		var x := (i * 2654435761) % w
		var y := (i * 40503 + 7) % h
		samples.append(Vector2i(x, y))
	for s in samples:
		var idx := s.y * w + s.x
		var got := f[idx]
		var exp := float(s.x + s.y * w)
		if absf(got - exp) > 0.5:
			return {"ok": false, "msg": "px(%d,%d) got %f exp %f" % [s.x, s.y, got, exp]}
	return {"ok": true, "msg": ""}
