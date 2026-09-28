# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gate LT — phase 4b of PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md: the tiled shore distance field (§I).
#
# The spec's proof is "a lake over 25 km bakes". One image cannot: at the shipping 1.5 m texel a 30 km lake
# wants a 20000-texel field, past the 16384 texture limit, and 800 MB of it. Tiled, only tiles the shore
# passes near carry a field, and a tile over a region that is not loaded is not baked at all.
#
# CRITERIA
#   LT1 a 30 km lake bakes, tiled, on the terrain's region grid. Control: one image would have needed more
#       than 16384 texels, so the build could not have passed untiled.
#   LT2 the shader's tiled read (water_shore_tiled, emulated here texel for texel) agrees with the exact
#       polygon distance near the shore, including on tile edges. Control: the same tiles read without
#       their apron (clamped to their own texels) miss at the edges.
#   LT3 a band tile over an indexed-unloaded region is not baked; loading the region bakes it through
#       region_map_changed alone, and unloading drops it. Control: an unindexed location's tile is baked.
#   LT4 a tile left as a constant really is out of range of the shore, apron included, and on the right side.
#       Control: classifying with margin 0 leaves a constant tile inside the range.
#   LT5 the containment mask is capped (spec: O(area) at wave spacing is half a gigabyte here), and
#       contains_point still agrees with the pool's own polygon test, which is the fallback the capped mask
#       defers to. Control: the capped mask alone, without that fallback, disagrees near the shore.
#       (That test is Geometry2D.is_point_in_polygon, float32, and on a lake this size it misplaces points
#       about 0.1 m from the shore -- see _signed_distance. LT5 measures the mask, not that precision.)
#
# Headless: nothing here renders. The fixture's brush is a stand-in with a `terrain`, so no 30 km sculpt.
# Data lives in a per-gate user:// directory, wiped at start.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RegionLakeTileGate.tscn
extends Node

const DIR := "user://region_lake_tile_gate"
const LAKE_MAT := "res://addons/pasture_3d/extras/shaders/water/M_water_lake.tres"
const RS := 256
const R := 15000.0
const E := Vector2i(58, 0) # loaded, the shore crosses it
const N := Vector2i(0, 58) # saved and unloaded, the shore crosses it
const W := Vector2i(-59, 0) # never indexed, the shore crosses it
const TEX_LIMIT := 16384
const TOL := 0.05 # metres: half-float storage plus bilinear over a near-straight shore
const NEAR := 3.0 # metres from the shore: inside the exact band (two 1.5 m texels)

var _fail := 0
const GATES := 5
var _completed := 0
var _terrain
var _pool
var _stats := {}
var _bins := [] # segment indices by angle, for the exact distance
var _orientation := 0.0 # sign of the polygon's area: which side of a segment is inside


func _ready() -> void:
	print("\n=== Region lake tiles (gate LT, streaming phase 4b) ===\n")
	_wipe(DIR)
	_terrain = ClassDB.instantiate("Pasture3D")
	add_child(_terrain)
	_terrain.data_directory = DIR
	var d = _terrain.data
	for loc in [E, N]:
		d.add_region_blank(loc, false)
	d.update_maps()
	d.save_directory(DIR)
	d.unload_region(N, true)

	_pool = _make_lake()
	var t0 := Time.get_ticks_msec()
	_stats = _pool.rebuild()
	print("  (rebuild %d ms: %s)" % [Time.get_ticks_msec() - t0, _stats.get("reason", "")])
	_index_segments()

	_lt1_bakes()
	_lt2_tiled_read()
	_lt3_follows_regions()
	_lt4_constants_out_of_range()
	_lt5_capped_containment()

	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION LAKE TILES PASS" if ok else "REGION LAKE TILES FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


func _lt1_bakes() -> void:
	print("[LT1] a 30 km lake bakes, tiled on the region grid:")
	_check("the build is ok", _stats.get("ok", false))
	_check("it took the clipmapped masked path", _stats.get("masked", false) and _stats.get("clipmap", false))
	_check("the field is tiled", _stats.get("sdf_tiled", false))
	_check("control: one image would need %d texels, past %d" % [_stats.get("field_texels", 0), TEX_LIMIT],
		int(_stats.get("field_texels", 0)) > TEX_LIMIT)
	_check("a tile is a region (%.0f m)" % _pool._tile_size, is_equal_approx(_pool._tile_size, RS * 1.0))
	_check("the grid sits on region boundaries",
		is_zero_approx(fposmod(_pool._tile_origin.x, RS)) and is_zero_approx(fposmod(_pool._tile_origin.y, RS)))
	var band := int(_stats.get("sdf_tiles_band", 0))
	var total := int(_stats.get("sdf_tiles_total", 0))
	_check("band tiles %d are a small part of %d" % [band, total], band > 0 and band * 10 < total)
	_check("baked tiles %d = band minus the one unloaded" % _stats.get("sdf_tiles", 0),
		int(_stats.get("sdf_tiles", 0)) == band - 1)
	print("  (%.1f MB of tiles, where one image would be %.0f MB)" % [_stats.get("sdf_bytes", 0) / 1048576.0,
		pow(float(_stats.get("field_texels", 0)), 2.0) * 2.0 / 1048576.0])
	_completed += 1


func _lt2_tiled_read() -> void:
	print("[LT2] the shader's tiled read agrees with the exact distance near the shore:")
	var pts := PackedVector2Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	# Across tile edges: every third grid line the shore crosses, a hair either side of it.
	var o: Vector2 = _pool._tile_origin
	var ts: float = _pool._tile_size
	var cnt: Vector2i = _pool._tile_count
	for axis in 2:
		for k in range(0, (cnt.x if axis == 0 else cnt.y) + 1, 3):
			var c: float = (o.x if axis == 0 else o.y) + k * ts
			if absf(c) > R - 200.0:
				continue
			var other := sqrt(R * R - c * c)
			for sgn in [-1.0, 1.0]:
				for side in [-0.01, 0.01]:
					for dr in [-2.5, -1.2, 0.0, 1.2, 2.5]:
						var p := Vector2(c + side, sgn * other + sgn * dr) if axis == 0 \
							else Vector2(sgn * other + sgn * dr, c + side)
						pts.append(p)
	var edge_count := pts.size()
	# And anywhere else along the shore.
	for i in 400:
		var a := rng.randf() * TAU
		pts.append(Vector2(cos(a), sin(a)) * (R + rng.randf_range(-NEAR, NEAR)))
	var worst := 0.0
	var worst_ctl := 0.0
	var used := 0
	var used_edge := 0
	for i in pts.size():
		var p := pts[i]
		if _unloaded_tile(p):
			continue
		var exact := _signed_distance(p)
		if absf(exact) > NEAR:
			continue
		used += 1
		if i < edge_count:
			used_edge += 1
		var e := absf(_sample_tiled(p, true) - exact)
		worst = maxf(worst, e)
		worst_ctl = maxf(worst_ctl, absf(_sample_tiled(p, false) - exact))
	_check("%d samples near the shore, %d of them on tile edges" % [used, used_edge], used > 300 and used_edge > 100)
	_check("worst error %.4f m <= %.2f" % [worst, TOL], worst <= TOL)
	_check("control: without the apron the worst is %.3f m > %.2f" % [worst_ctl, TOL], worst_ctl > TOL)
	_completed += 1


func _lt3_follows_regions() -> void:
	print("[LT3] a tile over an unloaded region waits for the region:")
	var d = _terrain.data
	var ie := _tile_index(E)
	var inn := _tile_index(N)
	var iw := _tile_index(W)
	_check("the shore crosses E, N and W (classes %d %d %d)" % [_pool._tile_class[ie], _pool._tile_class[inn],
		_pool._tile_class[iw]], _pool._tile_class[ie] == 1 and _pool._tile_class[inn] == 1 and _pool._tile_class[iw] == 1)
	_check("E (loaded) is baked", _pool._tile_images.has(ie))
	_check("N (indexed, unloaded) is not baked", not _pool._tile_images.has(inn))
	_check("control: W (never indexed) is baked", _pool._tile_images.has(iw))
	var before := int(_pool.get_build_stats().get("sdf_tiles", 0))
	d.load_region(N, DIR, true)
	_check("N loaded: baked, by the signal alone", _pool._tile_images.has(inn))
	_check("  and counted (%d -> %d)" % [before, _pool.get_build_stats().get("sdf_tiles", 0)],
		int(_pool.get_build_stats().get("sdf_tiles", 0)) == before + 1)
	d.unload_region(N, true)
	_check("N unloaded: dropped", not _pool._tile_images.has(inn))
	_check("  and E untouched", _pool._tile_images.has(ie))
	_completed += 1


func _lt4_constants_out_of_range() -> void:
	print("[LT4] a constant tile is out of the field's range, apron included:")
	var s: float = _pool._tile_size / float(_pool._tile_n)
	var need: float = _pool.mask_range + s
	var ring := _poly_ring()
	var r := _constant_violations(_pool._tile_class, ring, need)
	_check("%d constant tiles near the ring checked" % r.x, r.x > 100)
	_check("none within %.1f m of the shore or on the wrong side (%d)" % [need, r.y], r.y == 0)
	var ctl: PackedInt32Array = Pasture3DUtil.classify_shore_tiles(_pool._tile_poly, _pool._tile_origin,
		_pool._tile_size, _pool._tile_count, 0.0)
	var rc := _constant_violations(ctl, ring, need)
	_check("control: margin 0 leaves %d constant tiles in range" % rc.y, rc.y > 0)
	_completed += 1


func _lt5_capped_containment() -> void:
	print("[LT5] the containment mask is capped and containment is still exact:")
	var cells: int = _pool._mask_gw * _pool._mask_gh
	_check("mask %dx%d = %d cells <= cap %d" % [_pool._mask_gw, _pool._mask_gh, cells, _pool.MASK_CAP],
		cells <= _pool.MASK_CAP)
	_check("mask spacing %.2f m is coarser than the wave spacing %.2f m"
		% [_stats.get("mask_spacing", 0.0), _stats.get("spacing", 0.0)],
		float(_stats.get("mask_spacing", 0.0)) > float(_stats.get("spacing", 0.0)))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var poly: PackedVector2Array = _pool.get_polygon()
	var bad := 0
	var bad_ctl := 0
	var n := 0
	var y: float = _pool.global_position.y - 100.0
	for i in 600:
		var a := rng.randf() * TAU
		var rr := R + (rng.randf_range(-20.0, 20.0) if i < 500 else rng.randf_range(-3000.0, 3000.0))
		var p := Vector2(cos(a), sin(a)) * rr
		var exact := Geometry2D.is_point_in_polygon(p, poly)
		n += 1
		if _pool.contains_point(Vector3(p.x, y, p.y)) != exact:
			bad += 1
		if (_pool._cell_state(p) != 0) != exact:
			bad_ctl += 1
	_check("contains_point agrees with the polygon at %d of %d" % [n - bad, n], bad == 0)
	_check("control: the mask alone disagrees at %d" % bad_ctl, bad_ctl > 0)
	_completed += 1


# ---- the emulated shader read ------------------------------------------------------

## water_shore_tiled, in units of metres: the tile map, then a bilinear read of the tile's layer at
## uv = ((g - ti) * n + 1) / (n + 2). p_apron false clamps the read to the tile's own n texels, which is what
## a field baked without the apron would give.
func _sample_tiled(p: Vector2, p_apron: bool) -> float:
	var g: Vector2 = (p - _pool._tile_origin) / _pool._tile_size
	var ti := Vector2i(g.floor())
	var cnt: Vector2i = _pool._tile_count
	if ti.x < 0 or ti.y < 0 or ti.x >= cnt.x or ti.y >= cnt.y:
		return _pool.mask_range
	var i := ti.y * cnt.x + ti.x
	var cls: int = _pool._tile_class[i]
	if cls == -1:
		return -_pool.mask_range
	if cls != 1 or not _pool._tile_images.has(i):
		return _pool.mask_range
	var img: Image = _pool._tile_images[i]
	var n: int = _pool._tile_n
	# Texel-index space, texel k centred on k: uv * (n + 2) - 0.5.
	var c := (g - Vector2(ti)) * float(n) + Vector2(0.5, 0.5)
	if not p_apron:
		c = c.clamp(Vector2(1, 1), Vector2(n, n))
	var x0 := int(floor(c.x))
	var y0 := int(floor(c.y))
	var fx := c.x - x0
	var fy := c.y - y0
	var v00 := _texel(img, x0, y0)
	var v10 := _texel(img, x0 + 1, y0)
	var v01 := _texel(img, x0, y0 + 1)
	var v11 := _texel(img, x0 + 1, y0 + 1)
	var v := lerpf(lerpf(v00, v10, fx), lerpf(v01, v11, fx), fy)
	return (v * 2.0 - 1.0) * _pool.mask_range


func _texel(p_img: Image, x: int, y: int) -> float:
	return p_img.get_pixel(clampi(x, 0, p_img.get_width() - 1), clampi(y, 0, p_img.get_height() - 1)).r


# ---- exact geometry -----------------------------------------------------------------

func _index_segments() -> void:
	_bins.resize(720)
	for b in 720:
		_bins[b] = PackedInt32Array()
	var wp: PackedVector2Array = _pool._tile_poly
	var area := 0.0
	for i in wp.size():
		var a := wp[i]
		var b := wp[(i + 1) % wp.size()]
		area += float(a.x) * b.y - float(b.x) * a.y
		var i0 := _bin_of(a)
		var i1 := _bin_of(b)
		_bins[i0].append(i)
		if i1 != i0:
			_bins[i1].append(i)
	_orientation = signf(area)


func _bin_of(p: Vector2) -> int:
	return int(fposmod(atan2(p.y, p.x), TAU) / TAU * 720.0) % 720


## Signed (inside negative) distance to the tiled field's own world polygon. The nearest segment to a point
## within metres of a 15 km ring is within a bin of it (a bin is 130 m of shore).
##
## The sign is the side of the nearest segment, in doubles, which is exact on this outline because it is
## convex. NOT Geometry2D.is_point_in_polygon: that casts a float32 ray tens of kilometres long and
## misplaces points 0.1 m from this shore, which showed up here as the field having the wrong sign.
func _signed_distance(p: Vector2) -> float:
	var wp: PackedVector2Array = _pool._tile_poly
	var best := INF
	var side := 0.0
	var b0 := _bin_of(p)
	for db in [-1, 0, 1]:
		for i in _bins[(b0 + db + 720) % 720]:
			var a := wp[i]
			var b := wp[(i + 1) % wp.size()]
			var q := Geometry2D.get_closest_point_to_segment(p, a, b)
			var dd := p.distance_to(q)
			if dd < best:
				best = dd
				var ex: float = b.x - a.x
				var ez: float = b.y - a.y
				side = ex * (float(p.y) - a.y) - ez * (float(p.x) - a.x)
	return -best if side * _orientation > 0.0 else best


## The polygon's radial extent: the closest any segment comes to the centre and the farthest vertex.
func _poly_ring() -> Vector2:
	var wp: PackedVector2Array = _pool._tile_poly
	var lo := INF
	var hi := 0.0
	for i in wp.size():
		var q := Geometry2D.get_closest_point_to_segment(Vector2.ZERO, wp[i], wp[(i + 1) % wp.size()])
		lo = minf(lo, q.length())
		hi = maxf(hi, wp[i].length())
	return Vector2(lo, hi)


## (constant tiles checked, violations): a constant tile within p_need of the ring, or on the wrong side of it.
func _constant_violations(p_class: PackedInt32Array, p_ring: Vector2, p_need: float) -> Vector2i:
	var cnt: Vector2i = _pool._tile_count
	var ts: float = _pool._tile_size
	var checked := 0
	var bad := 0
	for i in p_class.size():
		if p_class[i] == 1:
			continue
		var mn: Vector2 = _pool._tile_origin + Vector2(i % cnt.x, i / cnt.x) * ts
		var rect := Rect2(mn, Vector2(ts, ts))
		var near := Vector2(clampf(0.0, rect.position.x, rect.end.x), clampf(0.0, rect.position.y, rect.end.y)).length()
		var far := 0.0
		for c in [rect.position, Vector2(rect.end.x, rect.position.y), Vector2(rect.position.x, rect.end.y), rect.end]:
			far = maxf(far, c.length())
		if near > p_ring.y + ts * 3.0 or far < p_ring.x - ts * 3.0:
			continue # well clear: the interesting tiles are the ring's neighbours
		checked += 1
		if p_class[i] == -1:
			if not (far + p_need <= p_ring.x):
				bad += 1
		elif not (near - p_need >= p_ring.y):
			bad += 1
	return Vector2i(checked, bad)


# ---- fixture ------------------------------------------------------------------------

func _make_lake() -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	root.add_child(sun)
	var m := Pasture3DPoolManager.new()
	m.name = "Pasture3DPoolManager"
	root.add_child(m)
	m.sun_light = sun

	# A stand-in brush: the pool reads its outline from the Path3D and its tile grid from the brush's terrain.
	var brush_script := GDScript.new()
	brush_script.source_code = "extends Node3D\nvar terrain\nfunc is_configured() -> bool:\n\treturn true\n"
	brush_script.reload()
	var brush := Node3D.new()
	brush.set_script(brush_script)
	brush.name = "Brush"
	root.add_child(brush)
	brush.terrain = _terrain
	var path := Path3D.new()
	var c := Curve3D.new()
	c.bake_interval = 50.0
	var k := 64
	var h := 4.0 / 3.0 * tan(PI / (2.0 * k)) * R # the cubic handle that best follows a circle
	for i in k:
		var a := TAU * i / k
		var pos := Vector3(cos(a) * R, 0.0, sin(a) * R)
		var tan_v := Vector3(-sin(a), 0.0, cos(a)) * h
		c.add_point(pos, -tan_v, tan_v)
	c.closed = true
	path.curve = c
	brush.add_child(path)

	var pool := Pasture3DPool.new()
	pool.name = "Lake"
	pool.wave_profile = &"lake_calm"
	pool.material = load(LAKE_MAT)
	pool.underwater_enabled = false
	pool.surface_mode = pool.SurfaceMode.MASKED
	root.add_child(pool)
	pool.source_spline = path
	return pool


func _tile_index(p_loc: Vector2i) -> int:
	var base := Vector2i((_pool._tile_origin / _pool._tile_size).round())
	var cell := p_loc - base
	return cell.y * _pool._tile_count.x + cell.x


func _unloaded_tile(p: Vector2) -> bool:
	var loc := Vector2i((p / (RS * 1.0)).floor())
	return _terrain.data.get_region_index().has_entry(loc) and not _terrain.data.is_region_loaded(loc)


func _check(p_name: String, p_ok: bool) -> void:
	print("  %s  %s" % ["ok  " if p_ok else "FAIL", p_name])
	if not p_ok:
		_fail += 1


func _wipe(p_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(p_dir)
	var da := DirAccess.open(p_dir)
	for f in da.get_files():
		da.remove(f)
