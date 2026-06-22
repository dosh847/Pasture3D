extends SceneTree
# Smoke test for the ridge/trough flank redesign (PASTURE3D_RIDGE_TROUGH_FLANK_SPEC.md §9). Drives the
# native C++ rasterisers directly with a constructed `base_below` grid (the ground the flank drapes onto),
# isolating the new two-reference cross-section math. Run (editor closed):
#   <godot4.7> --headless --path project --script res://addons/pasture_3d/tools/gpu_spike/flank_test_cli.gd

const N := 100         # grid is NxN cells, vs=1
const VS := 1.0
var _done := false
var _pass := 0
var _fail := 0

func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	print("[FLANK] DONE  pass=%d fail=%d  RESULT: %s" % [_pass, _fail, "PASS" if _fail == 0 else "FAIL"])
	return true

func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok: _pass += 1
	else: _fail += 1
	print("[FLANK] %s %s  %s" % ["OK  " if ok else "FAIL", name, detail])

func _run() -> void:
	if not ClassDB.class_exists("Pasture3D"):
		_check("class", false, "Pasture3D missing — GDExtension not loaded"); return
	var terrain = ClassDB.instantiate("Pasture3D")
	get_root().add_child(terrain)
	terrain.vertex_spacing = VS
	terrain.change_region_size(256)
	var data = terrain.data
	data.add_region_blankp(Vector3(float(N) * 0.5, 0.0, float(N) * 0.5))
	if not data.has_method("stamp_ridge_line"):
		_check("native", false, "stamp_ridge_line not bound — old build"); return

	_ridge_drape_flat(data)
	_ridge_drape_slope(data)
	_ridge_slope_angle(data)
	_ridge_width_curve(data)
	_trough_carve(data)
	_ab_oracle()

# Flat ground 0, spline crest at Y=10, crest_height 0, fixed width 15. Expect: peak == 10 at the
# centreline, monotonic descent to ~0 at the skirt (NO flat shelf at 10 — the old bug).
func _ridge_drape_flat(data) -> void:
	var lid: int = data.create_owned_layer("rflat", "RFlat", 2) # MAX
	var clip := _clip()
	var base := _flat(0.0)
	var pts := _line_z(50.0, 20.0, 80.0, 10.0) # crest line along x at z=50, Y=10
	var params := _ridge_params(0.0, 15.0, 0, 30.0, true)
	params["base_below"] = base
	data.clear_layer_in_area(lid, clip, false)
	data.stamp_ridge_line(lid, pts, clip, params, _cos_lut())
	var peak: float = _h(data, lid, 50, 50)
	var mid: float = _h(data, lid, 50, 50 + 7)  # ~halfway out the flank
	var skirt: float = _h(data, lid, 50, 50 + 14) # near the edge
	_check("ridge.drape_flat peak==10", absf(peak - 10.0) < 0.3, "peak=%.3f" % peak)
	_check("ridge.drape_flat no shelf (mid<peak)", mid < peak - 1.0 and mid > 0.5, "mid=%.3f" % mid)
	_check("ridge.drape_flat skirt->ground", not is_nan(skirt) and skirt < 2.0, "skirt=%.3f" % skirt)

# Sloped ground (rises +0.2/cell in x), same crest at Y=10. The skirt must meet the LOCAL ground, not a
# flat plane: a skirt cell's height should be close to that cell's base_below.
func _ridge_drape_slope(data) -> void:
	var lid: int = data.create_owned_layer("rslope", "RSlope", 2)
	var clip := _clip()
	var base := _rampx(0.2) # ground = 0.2*x
	var pts := _line_z(50.0, 20.0, 80.0, 10.0)
	var params := _ridge_params(0.0, 15.0, 0, 30.0, true)
	params["base_below"] = base
	data.clear_layer_in_area(lid, clip, false)
	data.stamp_ridge_line(lid, pts, clip, params, _cos_lut())
	# A skirt cell at x=50, z=50+14: local ground = 0.2*50 = 10.0; skirt height should approach it.
	var skirt: float = _h(data, lid, 50, 50 + 14)
	var local_ground := 0.2 * 50.0
	_check("ridge.drape_slope skirt meets local ground", not is_nan(skirt) and absf(skirt - local_ground) < 2.0,
		"skirt=%.3f local_ground=%.3f" % [skirt, local_ground])

# Slope-angle mode: crest 10 above flat ground, angle 45deg (tan=1) => reach ~10m, capped by width=40.
# Verify the flank stops near 10m, not at width 40.
func _ridge_slope_angle(data) -> void:
	var lid: int = data.create_owned_layer("rangle", "RAngle", 2)
	var clip := _clip()
	var base := _flat(0.0)
	var pts := _line_z(50.0, 20.0, 80.0, 10.0)
	var params := _ridge_params(0.0, 40.0, 1, 45.0, true) # mode=1 SLOPE_ANGLE, 45deg, big width cap
	params["base_below"] = base
	data.clear_layer_in_area(lid, clip, false)
	data.stamp_ridge_line(lid, pts, clip, params, _cos_lut())
	# Flank reach (cells with a real ridge height) — angle 45deg over a 10 m crest reaches ~10 m laterally
	# (cosine profile drops below 0.5 m a touch sooner), well below the 40 m width cap.
	var reach := _reach_at(data, lid, 50)
	_check("ridge.slope_angle reach ~8-10 (capped<40)", reach >= 5 and reach <= 12, "reach=%d cells" % reach)

# Width curve: triangular (0 at ends, 1 mid). The footprint half-width near the spline ENDS should be far
# smaller than near the MIDDLE.
func _ridge_width_curve(data) -> void:
	var lid: int = data.create_owned_layer("rwc", "RWC", 2)
	var clip := _clip()
	var base := _flat(0.0)
	var pts := _line_z(50.0, 20.0, 80.0, 10.0) # spline spans x in [20,80]
	var params := _ridge_params(0.0, 15.0, 0, 30.0, true)
	params["base_below"] = base
	params["width_lut"] = _triangle_lut()
	data.clear_layer_in_area(lid, clip, false)
	data.stamp_ridge_line(lid, pts, clip, params, _cos_lut())
	var w_mid := _reach_at(data, lid, 50)  # middle of spline (t~0.5)
	var w_end := _reach_at(data, lid, 23)  # near start (t~0.05)
	_check("ridge.width_curve mid wider than end", w_mid > w_end + 4, "w_mid=%d w_end=%d" % [w_mid, w_end])

# Trough: flat ground 0, follow spline at Y=0, depth=5 => bed -5, banks rise to 0. MIN blend.
func _trough_carve(data) -> void:
	if not data.has_method("stamp_trough_line"):
		_check("trough.native", false, "not bound"); return
	var lid: int = data.create_owned_layer("tcarve", "TCarve", 3) # MIN
	var clip := _clip()
	var base := _flat(0.0)
	var pts := _line_z(50.0, 20.0, 80.0, 0.0) # bed line at Y=0
	var params := {
		"min_x": 0.0, "min_z": 0.0, "vs": VS, "gw": N, "gh": N,
		"bed_half_width": 4.0, "bank_width": 10.0, "falloff": 0.0,
		"depth": 5.0, "flat_bed": true, "follow_spline_height": true,
		"flank_mode": 0, "slope_tan": tan(deg_to_rad(30.0)),
		"blend": 3, "composite": false, "noise_strength": 0.0, "noise": null,
		"base_below": base,
	}
	data.clear_layer_in_area(lid, clip, false)
	data.stamp_trough_line(lid, pts, clip, params, _smooth_lut())
	var bed: float = _h(data, lid, 50, 50)        # centreline bed
	var bank: float = _h(data, lid, 50, 50 + 13)  # near bank top (bed4+bank10=14)
	_check("trough.carve bed==-5", absf(bed - (-5.0)) < 0.3, "bed=%.3f" % bed)
	_check("trough.carve bank rises to ground", not is_nan(bank) and bank > -1.5 and bank <= 0.05, "bank=%.3f" % bank)

# A/B oracle: bake the SAME ridge via the native C++ path and the GDScript reference (force_gdscript_
# raster). Uses a FRESH terrain so no earlier test layers sit below and pollute the GDScript path's
# _base_height_below; the GDScript layer is created FIRST (lowest) so the native bake above it doesn't
# either. The blank region reads height 0, so both drape onto ground 0 — match within chamfer tolerance.
func _ab_oracle() -> void:
	var terrain = ClassDB.instantiate("Pasture3D")
	get_root().add_child(terrain)
	terrain.vertex_spacing = VS
	terrain.change_region_size(256)
	var data = terrain.data
	data.add_region_blankp(Vector3(float(N) * 0.5, 0.0, float(N) * 0.5))
	var clip := _clip()
	var pts := _line_z(50.0, 20.0, 80.0, 10.0)

	# GDScript layer first (lowest non-base) so nothing painted sits below it.
	var ridge = Pasture3DRidge.new()
	terrain.add_child(ridge)
	ridge.terrain = terrain
	ridge.force_gdscript_raster = true
	ridge.follow_spline_height = true
	ridge.crest_height = 0.0
	ridge.width = 15.0
	ridge.falloff = 0.0
	ridge.flank_mode = Pasture3DRidge.FlankMode.FIXED_WIDTH
	var path := Path3D.new()
	var c := Curve3D.new()
	c.add_point(Vector3(20.0, 10.0, 50.0))
	c.add_point(Vector3(80.0, 10.0, 50.0))
	path.curve = c
	ridge.add_child(path)
	var gd_lid: int = data.create_owned_layer("ab_gd", "ABGd", 2)
	ridge._layer_id = gd_lid
	ridge._blend = 2 # MAX
	data.clear_layer_in_area(gd_lid, clip, false)
	ridge._paint_spline(path)

	# Native layer created AFTER (sits above), baked with an explicit flat-0 base so both see ground 0.
	var native_lid: int = data.create_owned_layer("ab_native", "ABNative", 2)
	var np := _ridge_params(0.0, 15.0, 0, 30.0, true)
	np["base_below"] = _flat(0.0)
	data.clear_layer_in_area(native_lid, clip, false)
	data.stamp_ridge_line(native_lid, pts, clip, np, _cos_lut())

	var maxd := 0.0
	var both := 0
	for d in range(-15, 16):
		for x in [30, 50, 70]:
			var a := _h(data, native_lid, x, 50 + d)
			var b := _h(data, gd_lid, x, 50 + d)
			if is_nan(a) or is_nan(b):
				continue
			maxd = maxf(maxd, absf(a - b))
			both += 1
	_check("ab_oracle native≈gdscript", both > 50 and maxd < 0.6, "checked=%d max|Δ|=%.4f" % [both, maxd])
	ridge.queue_free()

# --- helpers ---
func _ridge_params(crest: float, width: float, mode: int, angle_deg: float, follow: bool) -> Dictionary:
	return {
		"min_x": 0.0, "min_z": 0.0, "vs": VS, "gw": N, "gh": N,
		"crest_height": crest, "width": width, "falloff": 0.0,
		"invert": false, "follow_spline_height": follow,
		"flank_mode": mode, "slope_tan": tan(deg_to_rad(angle_deg)),
		"blend": 2, "composite": false, "noise_strength": 0.0, "noise": null,
	}

func _clip() -> AABB:
	return AABB(Vector3(0, -1e4, 0), Vector3(float(N) * VS, 2e4, float(N) * VS))

func _flat(y: float) -> PackedFloat32Array:
	var a := PackedFloat32Array(); a.resize(N * N)
	a.fill(y); return a

func _rampx(slope: float) -> PackedFloat32Array:
	var a := PackedFloat32Array(); a.resize(N * N)
	for iz in N:
		for ix in N:
			a[iz * N + ix] = slope * float(ix)
	return a

func _line_z(z: float, x0: float, x1: float, y: float) -> PackedVector3Array:
	return PackedVector3Array([Vector3(x0, y, z), Vector3(x1, y, z)])

func _cos_lut() -> PackedFloat32Array: # _ridge_cross default: 0.5+0.5*cos(t*PI), 1 at t=0 -> 0 at t=1
	var l := PackedFloat32Array(); l.resize(256)
	for i in 256: l[i] = 0.5 + 0.5 * cos(float(i) / 255.0 * PI)
	return l

func _smooth_lut() -> PackedFloat32Array: # bank_profile default smoothstep, 0->1
	var l := PackedFloat32Array(); l.resize(256)
	for i in 256:
		var t := float(i) / 255.0
		l[i] = t * t * (3.0 - 2.0 * t)
	return l

func _triangle_lut() -> PackedFloat32Array: # 0 at ends, 1 in the middle
	var l := PackedFloat32Array(); l.resize(256)
	for i in 256:
		var t := float(i) / 255.0
		l[i] = 1.0 - absf(t - 0.5) * 2.0
	return l

func _h(data, lid: int, ix: int, iz: int) -> float:
	return data.get_layer_height(lid, Vector3(float(ix) * VS, 0.0, float(iz) * VS))

# Furthest cell from the centreline (z=50) at column ix where the flank is still a real ridge (>0.5 m).
# (get_layer_height returns 0.0 for uncovered cells sharing a tile with covered ones, so NaN is unreliable
# as a footprint test — use a height threshold instead.)
func _reach_at(data, lid: int, ix: int) -> int:
	var r := 0
	for d in range(1, 40):
		var h := _h(data, lid, ix, 50 + d)
		if not is_nan(h) and h > 0.5:
			r = d
	return r
