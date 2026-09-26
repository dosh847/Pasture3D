# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gate RS — phase 3 of PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md, the CPU half: the seam stitch, the
# coarse arrays' size, and the region map encoding. The rendered half (no crack on screen, vertex collapse,
# the VRAM counter) needs a window: RegionSeamRenderProbe.
#
# The stitch oracle is written here from the spec, not from _stitch_region: where a Standard region's -x
# (-z) neighbour is ratio 4, its first column (row) equals the authored texel at every 4th texel and the
# straight line between those in between, the last segment ending on the next region's origin. Its
# controls: the authored column is NOT that line (else the check is vacuous), and a region whose coarser
# neighbour is on its +x side is left alone.
#
# Data lives in a per-gate user:// directory, wiped at start.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/RegionSeamGate.tscn
extends Node

const DIR := "user://region_seam_gate"
const RS := 256
const W := Vector2i(-1, 0)
const A := Vector2i(0, 0) # Background, ratio 4
const B := Vector2i(1, 0) # east of A: column 0 stitched
const C := Vector2i(0, 1) # south of A: row 0 stitched
const D := Vector2i(1, 1) # its origin ends B's and C's last segments
const E := Vector2i(2, 0) # east of B (Standard): never stitched
const BACKGROUND_PATH := "res://addons/pasture_3d/region_types/background.tres"

var _fail := 0
const GATES := 5
var _completed := 0
var _terrain
var _authored := {} # loc -> PackedFloat32Array, before A was converted


func _ready() -> void:
	print("\n=== Region seams (gate RS, streaming phase 3) ===\n")
	_wipe(DIR)
	_terrain = ClassDB.instantiate("Pasture3D")
	add_child(_terrain)
	_terrain.data_directory = DIR
	var d = _terrain.data
	for loc in [W, A, B, C, D, E]:
		d.add_region_blank(loc, false)
	d.update_maps()
	for loc in [W, A, B, C, D, E]:
		_fill_pattern(loc)
	d.update_maps(3, true, false)
	d.save_directory(DIR)
	for loc in [W, A, B, C, D, E]:
		_authored[loc] = _heights(loc)
	var err: int = d.set_region_type(A, d.load_region_type(BACKGROUND_PATH))
	_check("set A to Background (%d)" % err, err == OK)

	_rs1_stitch_follows_the_lattice()
	_rs2_toggle_off_leaves_the_edge()
	_rs3_unloaded_neighbour_restitches_from_the_index()
	_rs4_coarse_layer_is_a_sixteenth()
	_rs5_region_map_encoding()

	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION SEAMS PASS" if ok else "REGION SEAMS FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


# --- RS1: B's column 0 and C's row 0 follow A's lattice; W's last column keeps its detail ------------------
func _rs1_stitch_follows_the_lattice() -> void:
	print("[RS1] the stitch follows the coarse lattice:")
	var d = _terrain.data
	var d_origin: float = _authored[D][0]
	for pair in [[B, 0], [C, 1]]:
		var loc: Vector2i = pair[0]
		var axis: int = pair[1]
		var got := _edge(_heights(loc), axis, 0)
		var authored := _edge(_authored[loc], axis, 0)
		var want := _stitched(authored, d_origin)
		_check("%s edge matches the oracle (max %.6f)" % [loc, _max_diff(got, want)], _max_diff(got, want) < 1e-5)
		_check("control: %s authored edge is not the line (max %.3f)" % [loc, _max_diff(authored, want)],
			_max_diff(authored, want) > 0.5)
		var lattice_ok := true
		for k in range(0, RS, 4):
			lattice_ok = lattice_ok and got[k] == authored[k]
		_check("%s lattice texels unchanged" % loc, lattice_ok)
		var second := _max_diff(_edge(_heights(loc), axis, 1), _edge(_authored[loc], axis, 1))
		_check("%s second line unchanged (max %.6f)" % [loc, second], second == 0.0)
	_check("control: W (coarse neighbour on its +x) is untouched", _max_diff(_heights(W), _authored[W]) == 0.0)
	_check("control: E (Standard -x neighbour) is untouched", _max_diff(_heights(E), _authored[E]) == 0.0)
	_check("B is modified (the stitch will be saved)", d.get_region(B).is_modified())
	_completed += 1


# --- RS2: with the stitch off, an edit to the edge stays as authored -------------------------------------
func _rs2_toggle_off_leaves_the_edge() -> void:
	print("[RS2] the toggle:")
	var d = _terrain.data
	d.set_seam_stitch_enabled(false)
	_restore_edge(B, 0)
	d.update_maps(0, false)
	var off := _max_diff(_edge(_heights(B), 0, 0), _edge(_authored[B], 0, 0))
	_check("off: B's edited column stays authored (max %.6f)" % off, off == 0.0)
	d.set_seam_stitch_enabled(true)
	_restore_edge(B, 0)
	d.update_maps(0, false)
	var on := _max_diff(_edge(_heights(B), 0, 0), _stitched(_edge(_authored[B], 0, 0), _authored[D][0]))
	_check("control: on, the same edit is stitched (max %.6f)" % on, on < 1e-5)
	_completed += 1


# --- RS3: A unloaded, an edit to B restitches from the index's ratio; D unloaded holds its segment ---------
func _rs3_unloaded_neighbour_restitches_from_the_index() -> void:
	print("[RS3] unloaded neighbours:")
	var d = _terrain.data
	d.save_directory(DIR)
	var before := _edge(_heights(B), 0, 0)
	_check("unload A OK", d.unload_region(A) == OK)
	_check("A is indexed at ratio 4", int(d.get_region_index().get_entry(A).get("texel_ratio", 0)) == 4)
	var kept := _max_diff(_edge(_heights(B), 0, 0), before)
	_check("unloading A leaves B's edge (max %.6f)" % kept, kept == 0.0)
	_restore_edge(B, 0)
	d.update_maps(0, false)
	var re := _max_diff(_edge(_heights(B), 0, 0), _stitched(_edge(_authored[B], 0, 0), _authored[D][0]))
	_check("an edit to B restitches from the index (max %.6f)" % re, re < 1e-5)
	# E's -x neighbour is B, Standard: an edit there is the control that the ratio, not the edit, decides.
	var e_img: Image = d.get_region(E).get_height_map()
	e_img.set_pixel(0, 1, Color(99.0, 0, 0, 1))
	d.get_region(E).set_edited(true)
	d.update_maps(0, false)
	_check("control: E's edit beside a Standard region is kept", is_equal_approx(e_img.get_pixel(0, 1).r, 99.0))
	# D unloaded but indexed: B's last segment (z 253..255) keeps what it was stitched to.
	d.save_directory(DIR)
	_check("unload D OK", d.unload_region(D) == OK)
	var b_img: Image = d.get_region(B).get_height_map()
	var last := [b_img.get_pixel(0, 253).r, b_img.get_pixel(0, 254).r, b_img.get_pixel(0, 255).r]
	_restore_edge(B, 0)
	d.update_maps(0, false)
	var held := true
	for j in 3:
		held = held and b_img.get_pixel(0, 253 + j).r == _authored[B][(253 + j) * RS]
	var mid := _max_diff(_edge(_heights(B), 0, 0).slice(0, 252), _stitched(_edge(_authored[B], 0, 0), 0.0).slice(0, 252))
	_check("the last segment is skipped while D is unloaded (was %s)" % [last], held)
	_check("the rest is restitched (max %.6f)" % mid, mid < 1e-5)
	_check("load A, D OK", d.load_region(A, DIR) == OK and d.load_region(D, DIR) == OK)
	_completed += 1


# --- RS4: a ratio-4 layer is 1/16 of a Standard one -------------------------------------------------------
func _rs4_coarse_layer_is_a_sixteenth() -> void:
	print("[RS4] coarse layer size:")
	var d = _terrain.data
	d.update_maps()
	var s: Dictionary = d.get_upload_stats()
	var fine: int = s.get("fine_layer_bytes", 0)
	var coarse: int = s.get("coarse_layer_bytes", 0)
	var ratio := float(fine) / maxf(coarse, 1.0)
	print("    fine %d B, coarse %d B, ratio %.3f, store ratio %d" % [fine, coarse, ratio, s.get("coarse_store_ratio", 0)])
	_check("both pools have arrays", fine > 0 and coarse > 0)
	_check("fine / coarse is 16 within 2%% (%.3f)" % ratio, absf(ratio - 16.0) < 0.32)
	var layer: Image = d.get_coarse_maps(0)[Pasture3DData.region_id_slot(d.get_region_id(A))]
	_check("A's coarse height layer is 64x64 (got %s)" % layer.get_size(), layer.get_size() == Vector2i(64, 64))
	# Control: a ratio-2 region moves the coarse arrays to ratio 2, so every coarse layer costs 1/4.
	var r2 := Pasture3DRegionType.new()
	r2.type_name = "Half"
	r2.texel_ratio = 2
	ResourceSaver.save(r2, DIR + "/half.tres")
	r2 = ResourceLoader.load(DIR + "/half.tres", "", ResourceLoader.CACHE_MODE_REPLACE)
	d.set_region_type(E, r2)
	s = d.get_upload_stats()
	var ratio2 := float(s.get("fine_layer_bytes", 0)) / maxf(s.get("coarse_layer_bytes", 0), 1.0)
	_check("control: with a ratio-2 region it is 4 (%.3f, store %d)" % [ratio2, s.get("coarse_store_ratio", 0)],
		absf(ratio2 - 4.0) < 0.08 and s.get("coarse_store_ratio", 0) == 2)
	_completed += 1


# --- RS5: the region map encoding ----------------------------------------------------------------------
func _rs5_region_map_encoding() -> void:
	print("[RS5] region map encoding:")
	var d = _terrain.data
	var ok := true
	for slot in [0, 1, 4095]:
		for shift in [0, 1, 2, 4]:
			for collapse in [false, true]:
				for color_only in [false, true]:
					var v: int = Pasture3DData.region_map_encode(slot, shift, collapse, color_only)
					var id: int = Pasture3DData.region_map_decode(v)
					ok = ok and v != 0 and (v < 0) == (shift > 0) and Pasture3DData.region_id_slot(id) == slot
					ok = ok and Pasture3DData.region_id_is_coarse(id) == (shift > 0)
					# A float32 texel holds it exactly (the RF region map).
					ok = ok and int(PackedFloat32Array([float(v)])[0]) == v
	_check("round trip: slot, sign, and float32 exact", ok)
	_check("0 decodes to no region", Pasture3DData.region_map_decode(0) == -1 and Pasture3DData.region_id_slot(-1) == -1)
	var map: PackedInt32Array = d.get_region_map()
	var va: int = map[Pasture3DData.get_region_map_index(A)]
	var vb: int = map[Pasture3DData.get_region_map_index(B)]
	var slot_a: int = Pasture3DData.region_id_slot(Pasture3DData.region_map_decode(va))
	_check("A is coarse, in the coarse pool (value %d)" % va, va < 0 and d.get_coarse_slot_locations()[slot_a] == A)
	_check("A's flags: shift 2, collapse, colour only", va == Pasture3DData.region_map_encode(slot_a, 2, true, true))
	_check("control: B is Standard, in the fine pool (value %d)" % vb,
		vb > 0 and d.get_slot_locations()[Pasture3DData.region_id_slot(Pasture3DData.region_map_decode(vb))] == B)
	_completed += 1


# --- helpers -------------------------------------------------------------------------------------------
func _stitched(p_authored: PackedFloat32Array, p_next_origin: float) -> PackedFloat32Array:
	var out := p_authored.duplicate()
	for k0 in range(0, RS, 4):
		var a := p_authored[k0]
		var b := p_authored[k0 + 4] if k0 + 4 < RS else p_next_origin
		for j in range(1, 4):
			out[k0 + j] = lerpf(a, b, j / 4.0)
	return out


# The line of texels at depth p_depth along the edge on axis p_axis (0: column p_depth, 1: row p_depth).
func _edge(p_h: PackedFloat32Array, p_axis: int, p_depth: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(RS)
	for k in RS:
		out[k] = p_h[k * RS + p_depth] if p_axis == 0 else p_h[p_depth * RS + k]
	return out


func _restore_edge(p_loc: Vector2i, p_axis: int) -> void:
	var img: Image = _terrain.data.get_region(p_loc).get_height_map()
	var h: PackedFloat32Array = _authored[p_loc]
	for k in RS:
		var px := Vector2i(0, k) if p_axis == 0 else Vector2i(k, 0)
		img.set_pixelv(px, Color(h[px.y * RS + px.x], 0, 0, 1))
	_terrain.data.get_region(p_loc).set_edited(true)
	_terrain.data.get_region(p_loc).set_modified(true)


func _fill_pattern(p_loc: Vector2i) -> void:
	var img: Image = _terrain.data.get_region(p_loc).get_height_map()
	var k := float(p_loc.x * 3 + p_loc.y * 7 + 1)
	for y in RS:
		for x in RS:
			var h := sin(x * 0.9 + k) * 3.0 + cos(y * 1.3 - k) * 2.0 + x * 0.05 + y * 0.02 * k
			img.set_pixel(x, y, Color(h, 0, 0, 1))
	_terrain.data.get_region(p_loc).set_modified(true)
	_terrain.data.get_region(p_loc).calc_height_range()


func _heights(p_loc: Vector2i) -> PackedFloat32Array:
	return _terrain.data.get_region(p_loc).get_height_map().get_data().to_float32_array()


func _max_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in p_a.size():
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


func _check(p_name: String, p_ok: bool) -> void:
	print("  %s  %s" % ["ok  " if p_ok else "FAIL", p_name])
	if not p_ok:
		_fail += 1


func _wipe(p_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(p_dir)
	var da := DirAccess.open(p_dir)
	for f in da.get_files():
		da.remove(f)
