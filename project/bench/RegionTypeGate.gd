# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gate RT — phase 2a of PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md: region types, per-region texel_ratio
# in the CPU data paths, the feature toggles and region lock.
#
# The spec's proofs: height queries on a ratio-4 region match the downsampled oracle; the toggles actually
# remove collision and instances; locked regions refuse strokes. Each is measured on what the system
# produced (a physics raycast, the region's instance dictionary, the heights after a real editor stroke),
# never on this gate's own call, and each carries a control that fails.
#
# The oracle is written here, independently of the C++: a box of width 4 centred on each lattice vertex
# (half weight on the two end vertices, clamped to the region), and bilinear interpolation on that lattice
# whose far corners are the neighbours' vertices. Its controls are the two plausible wrong answers:
# decimation (take every 4th texel) and a staircase (the texel at or before, no interpolation).
#
# Data lives in a per-gate user:// directory, wiped at start.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/RegionTypeGate.tscn
extends Node

const DIR := "user://region_type_gate"
const RS := 256
const A := Vector2i(0, 0)
const B := Vector2i(1, 0)
const C := Vector2i(0, 1)
const D := Vector2i(1, 1)
const E := Vector2i(2, 0)
const BACKGROUND_PATH := "res://addons/pasture_3d/region_types/background.tres" # Pasture3DRegionType::BACKGROUND_PATH

var _fail := 0
const GATES := 8
var _completed := 0
var _terrain
var _coarse_keep: Pasture3DRegionType # ratio 4, collision ON, instances KEPT
var _flat_nosculpt: Pasture3DRegionType # ratio 1, not sculptable
var _background: Pasture3DRegionType


func _ready() -> void:
	print("\n=== Region types (gate RT, streaming phase 2a) ===\n")
	_wipe(DIR)
	_coarse_keep = Pasture3DRegionType.new()
	_coarse_keep.type_name = "CoarseKeep"
	_coarse_keep.texel_ratio = 4
	ResourceSaver.save(_coarse_keep, DIR + "/coarse_keep.tres")
	_coarse_keep = ResourceLoader.load(DIR + "/coarse_keep.tres", "", ResourceLoader.CACHE_MODE_REPLACE)
	_flat_nosculpt = Pasture3DRegionType.new()
	_flat_nosculpt.type_name = "NoSculpt"
	_flat_nosculpt.sculptable = false
	ResourceSaver.save(_flat_nosculpt, DIR + "/no_sculpt.tres")
	_flat_nosculpt = ResourceLoader.load(DIR + "/no_sculpt.tres", "", ResourceLoader.CACHE_MODE_REPLACE)

	_terrain = ClassDB.instantiate("Pasture3D")
	add_child(_terrain)
	_terrain.data_directory = DIR
	var d = _terrain.data
	for loc in [A, B, C, D, E]:
		d.add_region_blank(loc, false)
	d.update_maps()
	for loc in [A, B, C, D, E]:
		_fill_pattern(loc)
	d.update_maps(3, true, false)
	d.save_directory(DIR)
	_background = d.load_region_type(BACKGROUND_PATH)

	_rt1_types_resolve()
	_rt2_heights_match_the_oracle()
	_rt3_coarse_region_round_trips()
	_rt4_upload_is_one_layer_per_type()
	await _rt5_collision_toggle()
	_rt6_instancer_toggle()
	_rt7_locked_regions_refuse()
	_rt8_coarse_stroke_applies_once()

	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION TYPES PASS" if ok else "REGION TYPES FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


# --- RT1: types resolve; a region without a path is Standard; a mismatch is flagged ----------------------
func _rt1_types_resolve() -> void:
	print("[RT1] types resolve:")
	var d = _terrain.data
	var std: Pasture3DRegionType = d.load_region_type("")
	_check("'' is Standard, ratio 1 (got %s, %d)" % [std.type_name, std.texel_ratio], std.type_name == "Standard" and std.texel_ratio == 1)
	_check("built-in Background: ratio 4, no collision, drops instances",
		_background != null and _background.texel_ratio == 4 and not _background.collision
		and _background.instancer_mode == Pasture3DRegionType.INSTANCER_DROP)
	_check("a legacy region reads as Standard", d.get_region_type(A).type_name == "Standard")
	_check("a missing type path falls back to Standard", d.load_region_type("res://nope/missing.tres").texel_ratio == 1)
	_check("unsaved type refused", d.set_region_type(E, Pasture3DRegionType.new()) == ERR_FILE_BAD_PATH)
	# Mismatch: point E at Background without converting it.
	d.get_region(E).set_type_path(BACKGROUND_PATH)
	_check("a ratio-1 region typed Background is mismatched", d.is_region_type_mismatched(E))
	_check("control: an untouched region is not", not d.is_region_type_mismatched(B))
	d.get_region(E).set_type_path("")
	_completed += 1


# --- RT2: a ratio-4 region answers the downsampled oracle --------------------------------------------------
func _rt2_heights_match_the_oracle() -> void:
	print("[RT2] ratio-4 heights match the oracle:")
	var d = _terrain.data
	var fine := _heights(A) # before conversion
	var nb := {B: _heights(B), C: _heights(C), D: _heights(D)}
	var err: int = d.set_region_type(A, _background)
	_check("set_region_type OK (%d)" % err, err == OK)
	var r = d.get_region(A)
	_check("ratio 4, map 64x64 (got %d, %s)" % [r.get_texel_ratio(), r.get_height_map().get_size()],
		r.get_texel_ratio() == 4 and r.get_height_map().get_size() == Vector2i(64, 64))

	var oracle := _box_downsample(fine, 4)
	var decimated := PackedFloat32Array()
	decimated.resize(64 * 64)
	for j in 64:
		for i in 64:
			decimated[j * 64 + i] = fine[(j * 4) * RS + i * 4]
	var coarse := _heights_img(r.get_height_map())
	var e_texel := _max_diff(coarse, oracle)
	var e_decim := _max_diff(coarse, decimated)
	_check("texels match the box oracle (max %.6f)" % e_texel, e_texel < 1e-4)
	_check("control: decimation differs (max %.3f)" % e_decim, e_decim > 0.1)

	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var e_q := 0.0
	var e_stair := 0.0
	var n := 0
	for k in 600:
		# Bias a third of the samples into the last lattice cell, where the neighbours are read.
		var x := rng.randf_range(0.0, 255.999) if k % 3 else rng.randf_range(252.0, 255.999)
		var z := rng.randf_range(0.0, 255.999) if k % 5 else rng.randf_range(252.0, 255.999)
		var got: float = d.get_height(Vector3(x, 0, z))
		var want := _oracle_height(oracle, nb, x, z)
		var stair := oracle[mini(int(z / 4.0), 63) * 64 + mini(int(x / 4.0), 63)]
		e_q = maxf(e_q, absf(got - want))
		e_stair = maxf(e_stair, absf(got - stair))
		n += 1
	_check("%d get_height queries match the oracle (max %.6f)" % [n, e_q], e_q < 1e-3)
	_check("control: a staircase read differs (max %.3f)" % e_stair, e_stair > 0.1)
	# Within 0.01 of a vertex, get_height snaps to the NEAREST vertex, not the one at or before.
	var snap: float = d.get_height(Vector3(8.0 - 0.005, 0, 12.0))
	_check("a position just short of a vertex answers that vertex (%.4f vs %.4f)" % [snap, oracle[3 * 64 + 2]],
		absf(snap - oracle[3 * 64 + 2]) < 1e-4)
	# get_height_at_vertex on a lattice vertex is the texel itself.
	_check("a lattice vertex is its texel", absf(d.get_height_at_vertex(Vector2i(8, 12)) - oracle[3 * 64 + 2]) < 1e-5)
	_completed += 1


# --- RT3: the coarse region saves, unloads and reloads as itself ------------------------------------------
func _rt3_coarse_region_round_trips() -> void:
	print("[RT3] coarse region round-trips:")
	var d = _terrain.data
	var before: PackedByteArray = d.get_region(A).get_height_map().get_data()
	d.save_directory(DIR)
	var entry: Dictionary = d.get_region_index().get_entry(A)
	_check("index entry records ratio 4 and the type path", entry.get("texel_ratio", 0) == 4
		and entry.get("type_path", "") == BACKGROUND_PATH)
	d.unload_region(A)
	var err: int = d.load_region(A, DIR)
	var r = d.get_region(A)
	_check("reloaded (%d)" % err, err == OK and r != null)
	_check("still ratio 4 and Background", r.get_texel_ratio() == 4 and d.get_region_type(A).type_name == "Background")
	_check("height bytes identical", r.get_height_map().get_data() == before)
	_check("not mismatched", not d.is_region_type_mismatched(A))
	_check("control: a Standard region's map is 256", d.get_region(B).get_height_map().get_width() == RS)
	_completed += 1


# --- RT4: a coarse region uploads through the full-size arrays, one layer per type --------------------------
func _rt4_upload_is_one_layer_per_type() -> void:
	print("[RT4] coarse upload:")
	var d = _terrain.data
	d.reset_upload_stats()
	d.set_region_type(C, _coarse_keep)
	var s: Dictionary = d.get_upload_stats()
	_check("retype uploads 3 layers, creates 0 arrays (got %d, %d)" % [s.layer_uploads, s.array_creates], s.layer_uploads == 3 and s.array_creates == 0)
	var slot: int = d.get_region_id(C)
	var up: Image = d.get_height_maps()[slot]
	_check("the uploaded layer is full size (%s)" % up.get_size(), up.get_size() == Vector2i(RS, RS))
	var worst := 0.0
	for p in [Vector2i(0, 0), Vector2i(37, 91), Vector2i(255, 255), Vector2i(128, 3)]:
		worst = maxf(worst, absf(up.get_pixelv(p).r - d.get_height_at_vertex(C * RS + p)))
	_check("it samples what the CPU answers (max %.6f)" % worst, worst < 1e-5)
	_completed += 1


# --- RT5: collision follows the type ------------------------------------------------------------------------
func _rt5_collision_toggle() -> void:
	print("[RT5] collision toggle:")
	var d = _terrain.data
	_terrain.collision_mode = 3 # FULL_GAME
	await _physics(3)
	# A is Background (collision off), C is CoarseKeep (ratio 4, collision on), B is Standard.
	var hit_a := _ray(Vector3(100.0, 0, 60.0))
	var hit_b := _ray(Vector3(RS + 100.0, 0, 60.0))
	var hit_c := _ray(Vector3(100.0, 0, RS + 60.0))
	_check("Background A has no collision", hit_a.is_empty())
	_check("control: Standard B collides at its height (%s vs %.3f)" % [_hy(hit_b), d.get_height(Vector3(RS + 100.0, 0, 60.0))],
		not hit_b.is_empty() and absf(hit_b.position.y - d.get_height(Vector3(RS + 100.0, 0, 60.0))) < 0.05)
	_check("coarse C with collision on collides at its interpolated height (%s vs %.3f)" % [_hy(hit_c), d.get_height(Vector3(100.0, 0, RS + 60.0))],
		not hit_c.is_empty() and absf(hit_c.position.y - d.get_height(Vector3(100.0, 0, RS + 60.0))) < 0.05)
	_terrain.collision_mode = 0
	await _physics(1)
	_completed += 1


# --- RT6: a DROP type clears instances and refuses new ones; KEEP keeps them --------------------------------
func _rt6_instancer_toggle() -> void:
	print("[RT6] instancer toggle:")
	var d = _terrain.data
	var inst = _terrain.instancer
	for loc in [B, D]:
		var xf: Array[Transform3D] = [Transform3D(Basis(), Vector3(10, 0, 10)), Transform3D(Basis(), Vector3(50, 0, 70))]
		inst.append_location(loc, 0, xf, PackedColorArray([Color.WHITE, Color.WHITE]), false)
	_check("B and D hold instances", _instance_count(B) == 2 and _instance_count(D) == 2)
	d.set_region_type(B, _background)
	_check("B retyped Background (DROP) holds none (got %d)" % _instance_count(B), _instance_count(B) == 0)
	var xf2: Array[Transform3D] = [Transform3D(Basis(), Vector3(20, 0, 20))]
	inst.append_location(B, 0, xf2, PackedColorArray([Color.WHITE]), false)
	_check("B refuses new instances (got %d)" % _instance_count(B), _instance_count(B) == 0)
	d.set_region_type(D, _coarse_keep)
	_check("control: D retyped a KEEP type still holds 2 (got %d)" % _instance_count(D), _instance_count(D) == 2)
	_completed += 1


# --- RT7: locked regions refuse strokes and retyping -------------------------------------------------------
func _rt7_locked_regions_refuse() -> void:
	print("[RT7] lock refuses:")
	var d = _terrain.data
	var plugin := _StubPlugin.new()
	add_child(plugin)
	_terrain.set_plugin(plugin)
	var ed := Pasture3DEditor.new()
	ed.set_terrain(_terrain)
	ed.set_brush_data(_brush_data())
	ed.set_tool(Pasture3DEditor.SCULPT)
	ed.set_operation(Pasture3DEditor.ADD)
	var at := Vector3(2 * RS + 100.5, 0, 100.5) # region E, Standard
	d.set_region_locked(E, true)
	var before := _heights(E)
	_stroke(ed, at)
	_check("locked E unchanged", _max_diff(_heights(E), before) == 0.0)
	_check("the refusal is reported as 'locked' (%s)" % ed.get_stroke_refusals(), ed.get_stroke_refusals().get(E, "") == "locked")
	_check("retyping locked E refused", d.set_region_type(E, _background) == ERR_LOCKED and d.get_region(E).get_texel_ratio() == 1)
	d.set_region_locked(E, false)
	_stroke(ed, at)
	var moved := _max_diff(_heights(E), before)
	_check("control: unlocked E moves (max %.3f)" % moved, moved > 0.5)
	_check("control: nothing refused", ed.get_stroke_refusals().is_empty())
	# A type that is not sculptable refuses the same stroke.
	d.set_region_type(E, _flat_nosculpt)
	before = _heights(E)
	_stroke(ed, at)
	_check("NoSculpt E unchanged", _max_diff(_heights(E), before) == 0.0)
	_check("reported as not sculptable (%s)" % ed.get_stroke_refusals().get(E, ""), String(ed.get_stroke_refusals().get(E, "")).contains("not sculptable"))
	ed.free()
	_completed += 1


# --- RT8: a stroke on a coarse region applies once per texel ------------------------------------------------
func _rt8_coarse_stroke_applies_once() -> void:
	print("[RT8] coarse stroke applies once per texel:")
	var d = _terrain.data
	var ed := Pasture3DEditor.new()
	ed.set_terrain(_terrain)
	ed.set_brush_data(_brush_data())
	ed.set_tool(Pasture3DEditor.SCULPT)
	ed.set_operation(Pasture3DEditor.ADD)
	# C is CoarseKeep: ratio 4, sculptable.
	var before := _heights_img(d.get_region(C).get_height_map())
	_stroke(ed, Vector3(100.5, 0, RS + 100.5))
	var after := _heights_img(d.get_region(C).get_height_map())
	var max_d := 0.0
	var touched := 0
	for i in after.size():
		var dd := after[i] - before[i]
		max_d = maxf(max_d, dd)
		if dd > 1e-6:
			touched += 1
	print("    refusals: %s" % ed.get_stroke_refusals())
	_check("texels moved (%d)" % touched, touched > 0)
	_check("each by exactly one application (max %.4f, want 1.0)" % max_d, absf(max_d - 1.0) < 1e-4)
	# Control: an 8 m brush over ratio 4 covers about 2x2 texels, not the 8x8 a fine walk would touch.
	_check("control: about 4 texels, not 64 (got %d)" % touched, touched >= 2 and touched <= 9)
	ed.free()
	_completed += 1


# --- oracle ----------------------------------------------------------------------------------------------

func _box_downsample(p_fine: PackedFloat32Array, p_r: int) -> PackedFloat32Array:
	var m := RS / p_r
	var half := p_r / 2
	var out := PackedFloat32Array()
	out.resize(m * m)
	for jy in m:
		for jx in m:
			var sum := 0.0
			for dy in range(-half, half + 1):
				var wy := 0.5 if absi(dy) == half else 1.0
				var y := clampi(jy * p_r + dy, 0, RS - 1)
				for dx in range(-half, half + 1):
					var wx := 0.5 if absi(dx) == half else 1.0
					var x := clampi(jx * p_r + dx, 0, RS - 1)
					sum += wx * wy * p_fine[y * RS + x]
			out[jy * m + jx] = sum / float(p_r * p_r)
	return out


## The surface is bilinear over fine vertices, as the renderer draws it. A vertex inside region A is bilinear
## on A's 64-texel lattice, whose corners past the far edge are the neighbours' vertices; a vertex past the
## far edge is the neighbour's own fine vertex, so the last fine cell meets the neighbour without a crack.
func _oracle_height(p_coarse: PackedFloat32Array, p_nb: Dictionary, p_x: float, p_z: float) -> float:
	var vx := int(floor(p_x))
	var vz := int(floor(p_z))
	var tx := p_x - vx
	var tz := p_z - vz
	var h00 := _vertex(p_coarse, p_nb, vx, vz)
	var h10 := _vertex(p_coarse, p_nb, vx + 1, vz)
	var h01 := _vertex(p_coarse, p_nb, vx, vz + 1)
	var h11 := _vertex(p_coarse, p_nb, vx + 1, vz + 1)
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


func _vertex(p_coarse: PackedFloat32Array, p_nb: Dictionary, p_gx: int, p_gz: int) -> float:
	if p_gx >= RS or p_gz >= RS:
		var loc := Vector2i(p_gx / RS, p_gz / RS)
		var nb: PackedFloat32Array = p_nb[loc]
		return nb[(p_gz - loc.y * RS) * RS + (p_gx - loc.x * RS)]
	var ix := p_gx / 4
	var iz := p_gz / 4
	var tx := (p_gx - ix * 4) / 4.0
	var tz := (p_gz - iz * 4) / 4.0
	return lerpf(lerpf(_corner(p_coarse, p_nb, ix, iz), _corner(p_coarse, p_nb, ix + 1, iz), tx),
		lerpf(_corner(p_coarse, p_nb, ix, iz + 1), _corner(p_coarse, p_nb, ix + 1, iz + 1), tx), tz)


func _corner(p_coarse: PackedFloat32Array, p_nb: Dictionary, p_ix: int, p_iz: int) -> float:
	if p_ix < 64 and p_iz < 64:
		return p_coarse[p_iz * 64 + p_ix]
	return _vertex(p_coarse, p_nb, p_ix * 4, p_iz * 4)


# --- helpers ---------------------------------------------------------------------------------------------

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
	return _heights_img(_terrain.data.get_region(p_loc).get_height_map())


func _heights_img(p_img: Image) -> PackedFloat32Array:
	return p_img.get_data().to_float32_array()


func _max_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size():
		return INF
	var m := 0.0
	for i in p_a.size():
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


func _instance_count(p_loc: Vector2i) -> int:
	var n := 0
	var inst: Dictionary = _terrain.data.get_region(p_loc).get_instances()
	for mesh_id in inst:
		for cell in inst[mesh_id]:
			n += inst[mesh_id][cell][0].size()
	return n


func _ray(p_at: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(p_at + Vector3(0, 500, 0), p_at - Vector3(0, 500, 0))
	return _terrain.get_world_3d().direct_space_state.intersect_ray(q)


func _hy(p_hit: Dictionary) -> String:
	return "miss" if p_hit.is_empty() else "%.3f" % p_hit.position.y


func _physics(p_n: int) -> void:
	for i in p_n:
		await get_tree().physics_frame


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
	var refused: Array = []

	func flash_region_warning(p_loc: Vector2i, p_reason: String) -> void:
		refused.append([p_loc, p_reason])
