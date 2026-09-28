# Gate U — phase 1 of PASTURE3D_BAKE_MEMORY_SPEC.md (M1): Bake All's undo snapshots leave out the regions
# the bake loads.
#
# A region the bake had to load is saved and released before anyone can press Ctrl+Z, the release bumps its
# generation, and a restore skips it. So copying its tiles into the undo snapshots bought nothing and cost a
# gigabyte on a large world. Under test, through the real `bake_all_brushes_now` (not a snapshot call of the
# gate's own):
#   [U1] the snapshots hold no bytes of a region the bake loaded, and do hold the region that was already
#        loaded. Control: `debug_unfiltered_undo` (the pre-M1 behaviour) holds bytes of the loaded ones.
#   [U2] undo still restores the region that was loaded before the bake, byte for byte. Witness: the bake
#        changed it, so the compare can fail. The regions the bake loaded are listed in `not_undoable`.
#   [U3] the manager warns about the regions it could not make undoable. Control: a bake that loads nothing
#        leaves no such warning.
#
# Fixture (region_size 256, vertex_spacing 1): blank ground in R0 R1 R2 along x, and two registered plain
# Mounds, each on its own layer: A straddling R0 | R1, B straddling R1 | R2. Only R0 is loaded when the bake
# starts; the scope is All Regions, so the bake loads R1 and R2.
#
# Data lives in user://region_bake_undo_gate, wiped per build. Nothing touches project/demo.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RegionBakeUndoGate.tscn
extends Node

const ScopedBake := preload("res://addons/pasture_3d/connectors/pasture3d_scoped_bake.gd")

const DIR := "user://region_bake_undo_gate"
const R0 := Vector2i(0, 0)
const R1 := Vector2i(1, 0)
const R2 := Vector2i(2, 0)
const ALL := [R0, R1, R2]
const HALF := 60.0

var _fail := 0
const GATES := 3
var _completed := 0
var _root: Node3D
var _terrain
var _mgr
## Composite heights captured after the pre-bake, before the brushes were edited: what undo must return to.
var _pre := {}


func _ready() -> void:
	print("\n=== Region bake undo (gate U, bake memory phase 1) ===\n")
	await _u1_snapshots_leave_out_loaded_regions()
	await _u2_undo_restores_what_was_loaded()
	await _u3_warning()
	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION BAKE UNDO PASS" if ok else "REGION BAKE UNDO FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


# --- U1 ---------------------------------------------------------------------------------------------------
func _u1_snapshots_leave_out_loaded_regions() -> void:
	print("[U1] the undo snapshots leave out the regions the bake loaded:")
	await _build([R0])
	var rep: Dictionary = _mgr.bake_all_brushes_now()
	var by := _snapshot_bytes_by_region(rep)
	print("    loaded after the bake: %s; snapshot bytes by region: %s" % [
		_terrain.data.get_region_locations(), by])
	_check("the bake ran over both owners", int(rep.get("owners", 0)) == 2)
	_check("the loaded set is handed back (only R0)", _terrain.data.get_region_locations() == [R0])
	_check("R0, loaded before the bake, is in the snapshots", int(by.get(R0, 0)) > 0)
	_check("R1 and R2, loaded for the bake, are not", int(by.get(R1, 0)) == 0 and int(by.get(R2, 0)) == 0)
	await _teardown()
	# Control: the pre-M1 snapshots, through the same path.
	await _build([R0])
	_mgr.debug_unfiltered_undo = true
	var ctrl: Dictionary = _mgr.bake_all_brushes_now()
	var cby := _snapshot_bytes_by_region(ctrl)
	print("    control snapshot bytes by region: %s" % [cby])
	_check("control: unfiltered snapshots hold R1 and R2", int(cby.get(R1, 0)) > 0 and int(cby.get(R2, 0)) > 0)
	await _teardown()
	_completed += 1


# --- U2 ---------------------------------------------------------------------------------------------------
func _u2_undo_restores_what_was_loaded() -> void:
	print("[U2] undo restores the region that was already loaded:")
	await _build([R0])
	var d = _terrain.data
	var rep: Dictionary = _mgr.bake_all_brushes_now()
	var baked_r0: PackedByteArray = _heights(R0)
	_check("witness: the bake changed R0", baked_r0 != _pre[R0])
	var before: Dictionary = rep["undo"]["before"]
	for owner in before:
		_mgr._restore_owner(owner, before[owner])
	_check("undo returns R0 to its pre-bake heights, byte for byte", _heights(R0) == _pre[R0])
	var nu: Array = rep.get("not_undoable", [])
	nu.sort()
	print("    not_undoable: %s" % [nu])
	_check("not_undoable lists exactly R1 and R2", nu == [R1, R2])
	# The limit, stated: R1 was baked, released, and undo did not reach it.
	d.load_region(R1, DIR, false)
	d.update_maps()
	_check("R1 on disk holds the bake, not the pre-bake heights", _heights(R1) != _pre[R1])
	await _teardown()
	_completed += 1


# --- U3 ---------------------------------------------------------------------------------------------------
func _u3_warning() -> void:
	print("[U3] the manager warns about the regions it could not make undoable:")
	await _build([R0])
	_mgr.bake_all_brushes_now()
	var w: PackedStringArray = _mgr._registry_warnings()
	_check("a warning names the 2 regions that cannot be undone", _has_warning(w, "2 cannot be undone"))
	await _teardown()
	# Control: everything loaded, All Loaded scope: the bake loads nothing, so there is nothing to warn about.
	await _build(ALL)
	_mgr.bake_scope = 1
	var rep: Dictionary = _mgr.bake_all_brushes_now()
	var cw: PackedStringArray = _mgr._registry_warnings()
	_check("control: the bake loaded nothing (not_undoable empty)", (rep.get("not_undoable", [1]) as Array).is_empty())
	_check("control: no such warning", not _has_warning(cw, "cannot be undone"))
	await _teardown()
	_completed += 1


# ---- fixture ---------------------------------------------------------------------------------------------

## Fresh terrain, pre-baked with everything loaded and saved, then reduced to `p_loaded`, and the brushes
## edited so the bake has real work to do.
func _build(p_loaded: Array) -> void:
	_wipe_dir()
	_root = Node3D.new()
	add_child(_root)
	_terrain = ClassDB.instantiate("Pasture3D")
	_root.add_child(_terrain)
	_terrain.data_directory = DIR
	var d = _terrain.data
	for loc in ALL:
		d.add_region_blank(loc, false)
	d.update_maps()
	var a = _make_mound("A", Vector3(256, 0, 128))
	var b = _make_mound("B", Vector3(512, 0, 128))
	var pre := ScopedBake.new(_terrain)
	pre.bake(ScopedBake.Scope.ALL_LOADED)
	d.save_directory(DIR)
	_pre.clear()
	for loc in ALL:
		_pre[loc] = _heights(loc)
	for loc: Vector2i in ALL:
		if not p_loaded.has(loc):
			d.unload_region(loc, false)
	d.update_maps()
	# slope_angle, not height: the default Mound is an uncapped cone whose peak never reads `height`.
	a.slope_angle = 38.0
	b.slope_angle = 24.0
	_mgr = Pasture3DSimManager.new()
	_mgr.name = "Sim"
	_root.add_child(_mgr)
	_mgr.terrain = _terrain
	var paths: Array[NodePath] = [_mgr.get_path_to(a), _mgr.get_path_to(b)]
	_mgr.eroding_brushes = paths
	_mgr.bake_scope = 2 # All Regions
	await get_tree().process_frame


func _teardown() -> void:
	_root.queue_free()
	_root = null
	_terrain = null
	_mgr = null
	await get_tree().process_frame
	await get_tree().process_frame


func _make_mound(p_name: String, p_at: Vector3):
	var mound := Pasture3DMound.new()
	mound.name = p_name
	_root.add_child(mound)
	mound.terrain = _terrain
	mound.global_position = p_at
	mound.blend_mode = Pasture3DMound.BlendMode.ADD
	var path := Path3D.new()
	path.name = "Area1"
	var c := Curve3D.new()
	c.add_point(Vector3(-HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, HALF))
	c.add_point(Vector3(-HALF, 0.0, HALF))
	c.closed = true
	path.curve = c
	mound.add_child(path)
	mound.add_new_layer()
	return mound


# ---- helpers ---------------------------------------------------------------------------------------------

## {region: bytes} over both halves of a Bake All report's undo pair.
static func _snapshot_bytes_by_region(p_rep: Dictionary) -> Dictionary:
	var out := {}
	var undo: Dictionary = p_rep.get("undo", {})
	for half in ["before", "after"]:
		var snaps: Dictionary = undo.get(half, {})
		for owner in snaps:
			var snap: Dictionary = snaps[owner]
			for layer_owner in snap:
				var tiles = snap[layer_owner]
				if not (tiles is Dictionary) or String(layer_owner).begins_with("@"):
					continue
				for loc in tiles:
					for coord in tiles[loc]:
						var img: Image = tiles[loc][coord]
						if img != null:
							out[loc] = int(out.get(loc, 0)) + img.get_data().size()
	return out


func _heights(p_loc: Vector2i) -> PackedByteArray:
	var r = _terrain.data.get_region(p_loc)
	return r.get_height_map().get_data() if r != null else PackedByteArray()


static func _has_warning(p_w: PackedStringArray, p_needle: String) -> bool:
	for s in p_w:
		if s.contains(p_needle):
			return true
	return false


func _wipe_dir() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var da := DirAccess.open(DIR)
	for f in da.get_files():
		da.remove(f)


func _check(p_label: String, p_ok: bool) -> void:
	print("    %s %s" % ["ok " if p_ok else "FAIL", p_label])
	if not p_ok:
		_fail += 1
