# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gate RL — phase 2b of PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md: the layer stack on coarse regions.
#
# Spec §E: "a layer tile over a Background region is stored at that region's resolution. Brushes and graphs
# still evaluate at full resolution and are downsampled on write (box filter)." Each criterion is measured on
# what the system produced -- the layer's tiles, the composited region map, a real editor stroke, a reload --
# with a control that fails. The box oracle is written here, independently of the C++: width 4 centred on the
# lattice vertex, half weight on the two end vertices, clamped to the region, NaN taps left out.
#
# Data lives in a per-gate user:// directory, wiped at start.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/RegionLayerGate.tscn
extends Node

const DIR := "user://region_layer_gate"
const RS := 256
const R := 4
const M := RS / R
const A := Vector2i(0, 0) # Background from the start
const B := Vector2i(1, 0)
const D := Vector2i(1, 1) # converted with layers on it
const E := Vector2i(2, 0) # Standard control for the stroke
const BACKGROUND_PATH := "res://addons/pasture_3d/region_types/background.tres"
const STANDARD_PATH := "res://addons/pasture_3d/region_types/standard.tres"
const ADD := 1
const MAX := 2 # (and REPLACE is 0)

var _fail := 0
const GATES := 9
var _completed := 0
var _terrain
var _ov := -1 # ADD overlay, owned
var _disk := -1 # MAX overlay, owned
var _user := -1 # ADD overlay, hand-paintable


func _ready() -> void:
	print("\n=== Layers on coarse regions (gate RL, streaming phase 2b) ===\n")
	_wipe(DIR)
	_terrain = ClassDB.instantiate("Pasture3D")
	add_child(_terrain)
	_terrain.data_directory = DIR
	var d = _terrain.data
	for loc in [A, B, Vector2i(0, 1), D, E]:
		d.add_region_blank(loc, false)
	d.update_maps()
	for loc in [A, B, Vector2i(0, 1), D, E]:
		_fill_pattern(loc)
	d.update_maps(3, true, false)
	d.ensure_layer_stack()
	_ov = d.create_owned_layer("gate/ov", "Ov", ADD)
	_disk = d.create_owned_layer("gate/disk", "Disk", MAX)
	d.save_directory(DIR)

	_rl1_base_tile_at_region_resolution()
	_rl2_batched_write_is_box_filtered()
	_rl3_footprint_is_the_lattice_vertex()
	_rl4_clear_keeps_the_rest_of_a_coarse_tile()
	_rl5_conversion_keeps_the_layers()
	_rl6_hand_stroke_through_a_layer()
	_rl7_round_trip()
	_rl8_height_below_on_a_coarse_region()
	_rl9_export_is_full_size()

	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION LAYERS PASS" if ok else "REGION LAYERS FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


# --- RL1: converting with a stack gives the Base a tile at the region's resolution -------------------------
func _rl1_base_tile_at_region_resolution() -> void:
	print("[RL1] base tile at region resolution:")
	var d = _terrain.data
	var err: int = d.set_region_type(A, load(BACKGROUND_PATH))
	_check("A converted (%d)" % err, err == OK)
	var base = _layer(0)
	var t: Image = base.get_tile(A, Vector2i.ZERO)
	_check("A's Base tile is %dx%d (got %s)" % [M, M, t.get_size() if t else "none"], t != null and t.get_size() == Vector2i(M, M))
	_check("A's tile edge is %d (got %d)" % [M, base.get_region_tile_size(A)], base.get_region_tile_size(A) == M)
	_check("A's map is the Base (max %.6f)" % _max_diff(_img(t), _img(d.get_region(A).get_height_map())),
		_max_diff(_img(t), _img(d.get_region(A).get_height_map())) < 1e-6)
	_check("control: B's Base tile is %d" % RS, base.get_tile(B, Vector2i.ZERO).get_width() == RS)
	_completed += 1


# --- RL2: a full-resolution write lands box-filtered --------------------------------------------------------
func _rl2_batched_write_is_box_filtered() -> void:
	print("[RL2] batched write is box-filtered:")
	var d = _terrain.data
	var q := PackedFloat32Array()
	q.resize(RS * RS)
	for z in RS:
		for x in RS:
			q[z * RS + x] = sin(x * 1.1) * 2.0 + cos(z * 0.7) * 1.5 + x * 0.01
	var base_before := _img(d.get_region(A).get_height_map())
	d.stamp_grid(_ov, q, 0.0, 0.0, 1.0, RS, RS, ADD)
	var ov = _layer(_ov)
	_check("the overlay tile is %d wide (got %d)" % [M, ov.get_tile(A, Vector2i.ZERO).get_width()], ov.get_tile(A, Vector2i.ZERO).get_width() == M)
	var oracle := _box(q, RS, 0, 0)
	var got := PackedFloat32Array()
	got.resize(M * M)
	var decim := PackedFloat32Array()
	decim.resize(M * M)
	for j in M:
		for i in M:
			got[j * M + i] = ov.get_value(A, Vector2i(i, j))
			decim[j * M + i] = q[(j * R) * RS + i * R]
	_check("texels match the box oracle (max %.6f)" % _max_diff(got, oracle), _max_diff(got, oracle) < 1e-5)
	_check("control: decimation differs (max %.3f)" % _max_diff(got, decim), _max_diff(got, decim) > 0.1)
	_check("control: the map is untouched before compositing", _max_diff(_img(d.get_region(A).get_height_map()), base_before) == 0.0)
	d.composite_region(A, Rect2i(), false)
	var want := PackedFloat32Array()
	want.resize(M * M)
	for k in M * M:
		want[k] = base_before[k] + oracle[k]
	_check("composited map = Base + overlay (max %.6f)" % _max_diff(_img(d.get_region(A).get_height_map()), want),
		_max_diff(_img(d.get_region(A).get_height_map()), want) < 1e-4)
	_completed += 1


# --- RL3: the footprint is decided at the lattice vertex; edge texels renormalise ----------------------------
func _rl3_footprint_is_the_lattice_vertex() -> void:
	print("[RL3] footprint at the lattice vertex:")
	var d = _terrain.data
	var disk := _disk_vals(Vector2(128.0, 128.0), 40.0, 3.0)
	d.stamp_grid(_disk, disk, 0.0, 0.0, 1.0, RS, RS, MAX)
	d.composite_region(A, Rect2i(), false)
	var dl = _layer(_disk)
	var wrong := 0
	var bad_value := 0
	var edge := 0
	for j in M:
		for i in M:
			var inside: bool = not is_nan(disk[(j * R) * RS + i * R])
			var covered: bool = dl.get_weight(A, Vector2i(i, j)) > 0.0
			if inside != covered:
				wrong += 1
			if covered:
				if absf(dl.get_value(A, Vector2i(i, j)) - 3.0) > 1e-6:
					bad_value += 1
				if _kernel_has_nan(disk, i, j):
					edge += 1
	_check("covered texels = texels whose vertex is in the disk (%d wrong)" % wrong, wrong == 0)
	_check("every covered texel is exactly 3 (%d off)" % bad_value, bad_value == 0)
	_check("control: %d edge texels had NaN taps (renormalisation was exercised)" % edge, edge > 10)
	_completed += 1


# --- RL4: clearing an area on a coarse region keeps the rest of its tile ------------------------------------
func _rl4_clear_keeps_the_rest_of_a_coarse_tile() -> void:
	print("[RL4] clear keeps the rest of a coarse tile:")
	var d = _terrain.data
	d.stamp_grid(_disk, _disk_vals(Vector2(40.0, 40.0), 10.0, 5.0), 0.0, 0.0, 1.0, RS, RS, MAX)
	d.composite_region(A, Rect2i(), false)
	var dl = _layer(_disk)
	var f2_before := _count(dl, A, Vector2(40, 40), 10.0)
	var f1_before := _count(dl, A, Vector2(128, 128), 40.0)
	_check("two features in one tile (%d, %d texels)" % [f1_before, f2_before], f1_before > 0 and f2_before > 0 and dl.get_region_tile_count(A) == 1)
	# Control: dropping whole tiles (the Standard-region rule) loses the second feature. Both are re-stamped
	# after, which is deterministic, so the real clear starts from the same state.
	dl.clear_tiles_in_rect(A, Rect2i(22, 22, 20, 20))
	_check("control: whole-tile clear loses feature 2 (%d left)" % _count(dl, A, Vector2(40, 40), 10.0), _count(dl, A, Vector2(40, 40), 10.0) == 0)
	d.stamp_grid(_disk, _disk_vals(Vector2(128.0, 128.0), 40.0, 3.0), 0.0, 0.0, 1.0, RS, RS, MAX)
	d.stamp_grid(_disk, _disk_vals(Vector2(40.0, 40.0), 10.0, 5.0), 0.0, 0.0, 1.0, RS, RS, MAX)
	_check("control: re-stamped to the same counts", _count(dl, A, Vector2(40, 40), 10.0) == f2_before and _count(dl, A, Vector2(128, 128), 40.0) == f1_before)
	d.clear_layer_in_area(_disk, AABB(Vector3(84, -1000, 84), Vector3(88, 2000, 88)), true)
	_check("feature 1 cleared (%d left)" % _count(dl, A, Vector2(128, 128), 40.0), _count(dl, A, Vector2(128, 128), 40.0) == 0)
	_check("feature 2 kept (%d of %d)" % [_count(dl, A, Vector2(40, 40), 10.0), f2_before], _count(dl, A, Vector2(40, 40), 10.0) == f2_before)
	_completed += 1


# --- RL5: converting a region with layers keeps them, resampled ----------------------------------------------
func _rl5_conversion_keeps_the_layers() -> void:
	print("[RL5] conversion keeps the layers:")
	var d = _terrain.data
	var q := PackedFloat32Array()
	q.resize(RS * RS)
	for z in RS:
		for x in RS:
			q[z * RS + x] = cos(x * 0.9) * 2.5 + sin(z * 1.3)
	d.stamp_grid(_ov, q, float(RS), float(RS), 1.0, RS, RS, ADD)
	d.composite_region(D, Rect2i(), false)
	var ov = _layer(_ov)
	var fine := _img(d.get_region(D).get_height_map())
	var base_fine := _img(_layer(0).get_tile(D, Vector2i.ZERO))
	_check("control: D's composite carries the overlay (max %.3f)" % _max_diff(fine, base_fine), _max_diff(fine, base_fine) > 1.0)
	var err: int = d.set_region_type(D, load(BACKGROUND_PATH))
	_check("D converted (%d)" % err, err == OK)
	var coarse := _img(d.get_region(D).get_height_map())
	var want := _box(fine, RS, 0, 0)
	var base_only := _box(base_fine, RS, 0, 0)
	_check("the overlay survived at %d wide" % M, ov.has_region(D) and ov.get_tile(D, Vector2i.ZERO).get_width() == M)
	_check("D = box of its old composite (max %.6f)" % _max_diff(coarse, want), _max_diff(coarse, want) < 1e-3)
	_check("control: discarding the overlay would differ (max %.3f)" % _max_diff(coarse, base_only), _max_diff(coarse, base_only) > 0.5)
	# Back to Standard: tiles return at the layer's own tile size, and the lattice vertices keep their values.
	err = d.set_region_type(D, load(STANDARD_PATH))
	var back := _img(d.get_region(D).get_height_map())
	var worst := 0.0
	for j in M:
		for i in M:
			worst = maxf(worst, absf(back[(j * R) * RS + i * R] - coarse[j * M + i]))
	_check("refined (%d): D is %d again with %d overlay tiles" % [err, RS, ov.get_region_tile_count(D)],
		err == OK and d.get_region(D).get_height_map().get_width() == RS and ov.get_region_tile_count(D) == (RS / 64) * (RS / 64))
	_check("lattice vertices keep their coarse values (max %.6f)" % worst, worst < 1e-4)
	_completed += 1


# --- RL6: a hand stroke through a user layer on a coarse region ----------------------------------------------
func _rl6_hand_stroke_through_a_layer() -> void:
	print("[RL6] hand stroke through a layer:")
	var d = _terrain.data
	# REPLACE: a sculpt stroke authors the height it computed, so an ADD layer would count the ground twice.
	_user = d.layer_add("User", 0)
	d.set_active_layer(_user)
	var plugin := _StubPlugin.new()
	add_child(plugin)
	_terrain.set_plugin(plugin)
	var ed := Pasture3DEditor.new()
	ed.set_terrain(_terrain)
	ed.set_brush_data(_brush_data())
	ed.set_tool(Pasture3DEditor.SCULPT)
	ed.set_operation(Pasture3DEditor.ADD)
	var a0 := _img(d.get_region(A).get_height_map())
	var e0 := _img(d.get_region(E).get_height_map())
	_stroke(ed, Vector3(200.5, 0, 200.5))
	var refused_a: Dictionary = ed.get_stroke_refusals()
	_stroke(ed, Vector3(2 * RS + 200.5, 0, 200.5))
	var da := _max_rise(_img(d.get_region(A).get_height_map()), a0)
	var de := _max_rise(_img(d.get_region(E).get_height_map()), e0)
	var ul = _layer(_user)
	_check("not refused (%s)" % refused_a, refused_a.is_empty())
	_check("the stroke wrote the user layer's coarse tile (%d texels)" % _covered(ul, A), _covered(ul, A) > 0 and _covered(ul, A) <= 9 and ul.get_tile(A, Vector2i.ZERO).get_width() == M)
	_check("A rose as much as Standard E did (%.4f vs %.4f)" % [da, de], de > 0.5 and absf(da - de) < 1e-4)
	ul.set_visible(false)
	d.composite_region(A, Rect2i(), false)
	_check("control: hiding the layer returns A (max %.6f)" % _max_diff(_img(d.get_region(A).get_height_map()), a0),
		_max_diff(_img(d.get_region(A).get_height_map()), a0) < 1e-5)
	ul.set_visible(true)
	d.composite_region(A, Rect2i(), false)
	ed.free()
	_completed += 1


# --- RL7: a coarse region's layer slices survive save, unload and load --------------------------------------
func _rl7_round_trip() -> void:
	print("[RL7] round trip:")
	var d = _terrain.data
	d.save_directory(DIR)
	var map_before: PackedByteArray = d.get_region(A).get_height_map().get_data()
	var tiles_before := {}
	for id in [0, _ov, _disk, _user]:
		tiles_before[id] = _tile_bytes(_layer(id), A)
	d.unload_region(A)
	_check("control: unloading evicts A's tiles", not _layer(_ov).has_region(A))
	var err: int = d.load_region(A, DIR)
	_check("reloaded (%d)" % err, err == OK)
	var same := true
	for id in tiles_before:
		if _tile_bytes(_layer(id), A) != tiles_before[id]:
			print("    layer %d differs" % id)
			same = false
	_check("every layer's A tiles are byte-identical", same)
	_check("A's map is byte-identical", d.get_region(A).get_height_map().get_data() == map_before)
	_check("tile edges restored (%d)" % _layer(_ov).get_region_tile_size(A), _layer(_ov).get_region_tile_size(A) == M and _layer(0).get_region_tile_size(A) == M)
	_completed += 1


# --- RL8: sampling below a layer on a coarse region interpolates the lattice ---------------------------------
func _rl8_height_below_on_a_coarse_region() -> void:
	print("[RL8] height below on a coarse region:")
	var d = _terrain.data
	var below: PackedFloat32Array = d.composite_height_below(_ov, 0.0, 0.0, 1.0, RS, RS)
	var base := _img(_layer(0).get_tile(A, Vector2i.ZERO))
	var e := 0.0
	var e_stair := 0.0
	for z in RS:
		for x in RS:
			var jx := x / R
			var jz := z / R
			var tx := float(x - jx * R) / R
			var tz := float(z - jz * R) / R
			var h00 := base[jz * M + jx]
			var h10 := base[jz * M + mini(jx + 1, M - 1)]
			var h01 := base[mini(jz + 1, M - 1) * M + jx]
			var h11 := base[mini(jz + 1, M - 1) * M + mini(jx + 1, M - 1)]
			var want := lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)
			e = maxf(e, absf(below[z * RS + x] - want))
			e_stair = maxf(e_stair, absf(below[z * RS + x] - h00))
	_check("below = the Base's lattice, bilinear (max %.6f)" % e, e < 1e-4)
	_check("control: a staircase differs (max %.3f)" % e_stair, e_stair > 0.1)
	var pt: float = d.get_height_below(_ov, Vector3(101.0, 0, 57.0))
	_check("the point query agrees (%.4f vs %.4f)" % [pt, below[57 * RS + 101]], absf(pt - below[57 * RS + 101]) < 1e-4)
	_completed += 1


# --- RL9: export writes a coarse region at full size ---------------------------------------------------------
func _rl9_export_is_full_size() -> void:
	print("[RL9] export is full size:")
	var d = _terrain.data
	var img: Image = d.layered_to_image(0, Rect2i(0, 0, RS, RS))
	var worst := 0.0
	for p in [Vector2i(0, 0), Vector2i(3, 7), Vector2i(128, 129), Vector2i(250, 11), Vector2i(255, 200)]:
		worst = maxf(worst, absf(img.get_pixelv(p).r - d.get_height_at_vertex(p)))
	_check("A exports as the surface get_height answers (max %.6f)" % worst, img.get_width() == RS and worst < 1e-5)
	_check("control: A's own map is %d wide" % M, d.get_region(A).get_height_map().get_width() == M)
	_completed += 1


# --- helpers ---------------------------------------------------------------------------------------------

func _box(p_fine: PackedFloat32Array, p_w: int, p_ox: int, p_oz: int) -> PackedFloat32Array:
	var half := R / 2
	var out := PackedFloat32Array()
	out.resize(M * M)
	for jy in M:
		for jx in M:
			var sum := 0.0
			var ws := 0.0
			for dy in range(-half, half + 1):
				var wy := 0.5 if absi(dy) == half else 1.0
				var y := clampi(jy * R + dy, 0, RS - 1)
				for dx in range(-half, half + 1):
					var wx := 0.5 if absi(dx) == half else 1.0
					var x := clampi(jx * R + dx, 0, RS - 1)
					var v := p_fine[(p_oz + y) * p_w + p_ox + x]
					if not is_nan(v):
						sum += wx * wy * v
						ws += wx * wy
			out[jy * M + jx] = sum / ws if ws > 0.0 else NAN
	return out


func _kernel_has_nan(p_vals: PackedFloat32Array, p_i: int, p_j: int) -> bool:
	for dy in range(-R / 2, R / 2 + 1):
		for dx in range(-R / 2, R / 2 + 1):
			var x := clampi(p_i * R + dx, 0, RS - 1)
			var y := clampi(p_j * R + dy, 0, RS - 1)
			if is_nan(p_vals[y * RS + x]):
				return true
	return false


func _disk_vals(p_c: Vector2, p_r: float, p_v: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(RS * RS)
	for z in RS:
		for x in RS:
			out[z * RS + x] = p_v if Vector2(x, z).distance_to(p_c) <= p_r else NAN
	return out


func _count(p_layer, p_loc: Vector2i, p_c: Vector2, p_r: float) -> int:
	var n := 0
	for j in M:
		for i in M:
			if Vector2(i * R, j * R).distance_to(p_c) <= p_r and p_layer.get_weight(p_loc, Vector2i(i, j)) > 0.0:
				n += 1
	return n


func _covered(p_layer, p_loc: Vector2i) -> int:
	var n := 0
	for j in M:
		for i in M:
			if p_layer.get_weight(p_loc, Vector2i(i, j)) > 0.0:
				n += 1
	return n


func _tile_bytes(p_layer, p_loc: Vector2i) -> Dictionary:
	var out := {}
	var tiles: Dictionary = p_layer.get_tiles().get(p_loc, {})
	for c in tiles:
		out[c] = (tiles[c] as Image).get_data()
	return out


func _layer(p_id: int):
	return _terrain.data.get_layer_stack().get_layer(p_id)


func _fill_pattern(p_loc: Vector2i) -> void:
	var img: Image = _terrain.data.get_region(p_loc).get_height_map()
	var k := float(p_loc.x * 3 + p_loc.y * 7 + 1)
	for y in RS:
		for x in RS:
			img.set_pixel(x, y, Color(sin(x * 0.9 + k) * 3.0 + cos(y * 1.3 - k) * 2.0 + x * 0.05 + y * 0.02 * k, 0, 0, 1))
	_terrain.data.get_region(p_loc).set_modified(true)
	_terrain.data.get_region(p_loc).calc_height_range()


func _img(p_img: Image) -> PackedFloat32Array:
	if p_img == null:
		return PackedFloat32Array()
	return p_img.get_data().to_float32_array()


func _max_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var m := 0.0
	for i in p_a.size():
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


func _max_rise(p_after: PackedFloat32Array, p_before: PackedFloat32Array) -> float:
	var m := 0.0
	for i in p_after.size():
		m = maxf(m, p_after[i] - p_before[i])
	return m


func _stroke(p_editor, p_at: Vector3) -> void:
	p_editor.start_operation(p_at)
	p_editor.operate(p_at, 0.0)
	p_editor.stop_operation()


func _brush_data() -> Dictionary:
	var img := Image.create(16, 16, false, Image.FORMAT_RF)
	img.fill(Color(1.0, 0.0, 0.0, 1.0))
	var tex := ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	return {
		"brush": [img, tex],
		"brush_image": img, "brush_image_size": Vector2i(16, 16),
		"size": 8.0, "strength": 100.0, "gamma": 1.0,
		"height": 0.0, "color": Color.WHITE, "roughness": 0.5,
		"enable_texture": true, "texture_filter": false, "margin": 0, "asset_id": 0,
		"slope": Vector2(0.0, 90.0), "enable_angle": false, "dynamic_angle": false, "angle": 0.0,
		"enable_scale": false, "scale": 0.0,
		"modifier_alt": false, "modifier_ctrl": false, "modifier_shift": false,
		"mouse_pressure": 1.0, "brush_spin_speed": 0.0, "align_to_view": false,
		"gradient_points": PackedVector3Array(), "auto_regions": false,
	}


func _check(p_name: String, p_ok: bool) -> void:
	print("  %s  %s" % ["ok  " if p_ok else "FAIL", p_name])
	if not p_ok:
		_fail += 1


func _wipe(p_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(p_dir)
	var da := DirAccess.open(p_dir)
	for f in da.get_files():
		da.remove(f)


## Stands in for the editor plugin: Pasture3DEditor dereferences plugin.ui during a stroke.
class _StubPlugin extends Node:
	var ui: Node = Node.new()

	func flash_region_warning(_loc: Vector2i, _reason: String) -> void:
		pass
