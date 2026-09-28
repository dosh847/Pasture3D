# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RegionLoadStateGate — which regions a terrain loads when its scene opens (2026-09-27).
#
# The editor reopens with the regions that were loaded when the region index was last written: each entry
# records `loaded`, unload writes it false, a dock Load (RegionSelection.load_selected) writes it true. A
# running game ignores that record: with `region_loading` Auto it starts from the index alone when a
# Pasture3DStreamer drives the terrain, and loads everything when none does.
#
# The editor rule is `Pasture3D.restores_region_state()`, which is `Engine.is_editor_hint()` or a debug flag
# only gates set; this headless gate sets the flag, since a headless run is never the editor.
#
# Fixture: region size 64, regions (0..3, 0) flat at 10 + x, built and saved by one terrain.
#
#   [U] unload 1 and 3, reopen with the editor rule: 0 and 2 load, 1 and 3 stay indexed and unloaded, and
#       region 0 reads its own height. Control: the same files opened as a game (All) load all four, so the
#       files are there and the record is what kept them out
#   [L] a dock Load of 1 is remembered on reopen. Control: 3 loaded with data.load_region alone (no index
#       write) is not, so the dock's write is what carried it
#   [O] an entry with no `loaded` key (an index from an older build) reads as loaded. Control: [U]'s reopen,
#       where the key said false
#   [G] a game ignores the record: Auto with no streamer loads all four. Auto with an enabled streamer, as a
#       CHILD of the terrain and as a LATER SIBLING (neither has entered the tree when the terrain loads), and
#       Streamed with none, load nothing. Controls: a disabled streamer and All with a streamer load all four
#   [W] the terrain warns that a game will load every region when no streamer drives it (Auto). Controls: no
#       warning with a streamer child, or with region_loading All
#
# Headless. user:// data, wiped at start.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RegionLoadStateGate.tscn
extends Node

const DIR := "user://region_load_state_gate"
const RS := 64
const ROW := [0, 1, 2, 3]
const CRITERIA := 5

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("\n=== RegionLoadStateGate ===\n")
	_wipe(DIR)
	await _build_fixture()
	for f in [_u, _l, _o, _g, _w]:
		await f.call()
	if _ran != CRITERIA:
		_check("completed", false, "%d of %d criteria ran" % [_ran, CRITERIA])
	var ok := _fail == 0 and _ran == CRITERIA
	print("\n=== REGION LOAD STATE %s (%d failures, %d/%d criteria completed) ===\n"
			% ["PASS" if ok else "FAIL", _fail, _ran, CRITERIA])
	get_tree().quit(0 if ok else 1)


func _check(p_label: String, p_ok: bool, p_detail: String) -> void:
	print("  %s %s: %s" % ["PASS" if p_ok else "FAIL", p_label, p_detail])
	if not p_ok:
		_fail += 1


func _frames(p_n: int) -> void:
	for i in p_n:
		await get_tree().process_frame


func _wipe(p_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(p_dir)
	var da := DirAccess.open(p_dir)
	for f in da.get_files():
		da.remove(f)


func _build_fixture() -> void:
	var b := Pasture3D.new()
	b.region_loading = Pasture3D.REGION_LOADING_ALL
	add_child(b)
	await _frames(2)
	b.change_region_size(RS)
	b.data_directory = DIR
	var d := b.data
	for x in ROW:
		var r = d.add_region_blank(Vector2i(x, 0), false)
		r.get_height_map().fill(Color(10 + x, 0, 0, 1))
	d.update_maps()
	d.calc_height_range(true)
	d.save_directory(DIR)
	b.queue_free()
	await _frames(2)


## A terrain that loads DIR as the editor would (the restore rule) or as a game with `p_mode`. The directory is
## set before it enters the tree, as a scene does, so the load happens on entering.
func _open(p_editor: bool, p_mode: int = Pasture3D.REGION_LOADING_ALL, p_parent: Node = null) -> Pasture3D:
	var t := Pasture3D.new()
	t.set_debug_restore_region_state(p_editor)
	t.region_loading = p_mode
	t.data_directory = DIR
	if p_parent != null:
		p_parent.add_child(t)
	else:
		add_child(t)
	return t


func _loaded(p_t: Pasture3D) -> Array:
	var out := []
	for x in ROW:
		if p_t.data.is_region_loaded(Vector2i(x, 0)):
			out.append(x)
	return out


func _close(p_node: Node) -> void:
	p_node.get_parent().remove_child(p_node)
	p_node.free()
	await _frames(1)


func _u() -> void:
	var t := _open(true)
	await _frames(1)
	var before := _loaded(t)
	for x in [1, 3]:
		t.data.unload_region(Vector2i(x, 0), true, true)
	await _close(t)
	t = _open(true)
	await _frames(1)
	var after := _loaded(t)
	var idx = t.data.get_region_index()
	var indexed := idx.has_entry(Vector2i(1, 0)) and idx.has_entry(Vector2i(3, 0))
	var h: float = t.data.get_height(Vector3(10, 0, 10))
	await _close(t)
	var game := _open(false, Pasture3D.REGION_LOADING_ALL)
	await _frames(1)
	var control := _loaded(game)
	await _close(game)
	_check("[U] unloaded regions stay unloaded", before == ROW and after == [0, 2] and indexed
			and absf(h - 10.0) < 1e-4 and control == ROW,
			"first open %s, after unloading 1 and 3 reopens %s (want [0, 2]); 1 and 3 indexed %s; region 0 height %.3f"
			% [before, after, indexed, h] + " | control (game, All): %s" % [control])
	_ran += 1


func _l() -> void:
	var t := _open(true)
	await _frames(1)
	var sel = preload("res://addons/pasture_3d/src/region_selection.gd").new(t)
	sel.selected = [Vector2i(1, 0)] as Array[Vector2i]
	var rep: Dictionary = sel.load_selected()
	# Control: loaded without the index write the dock does.
	var direct: int = t.data.load_region(Vector2i(3, 0), DIR, true)
	var mid := _loaded(t)
	await _close(t)
	t = _open(true)
	await _frames(1)
	var after := _loaded(t)
	await _close(t)
	_check("[L] a dock Load is remembered", rep["done"].size() == 1 and direct == OK and mid == ROW
			and after == [0, 1, 2],
			"dock loaded %s, direct load of 3 -> %d, loaded before closing %s, reopens %s (want [0, 1, 2]: 3 was"
			% [rep["done"], direct, mid, after] + " not written)")
	_ran += 1


func _o() -> void:
	# Strip the key from region 3's entry (currently recorded unloaded) and write the index back.
	var t := _open(true)
	await _frames(1)
	var idx = t.data.get_region_index()
	var entries: Dictionary = idx.get_entries().duplicate()
	var e: Dictionary = entries[Vector2i(3, 0)].duplicate()
	var had_false := e.has("loaded") and not bool(e["loaded"])
	e.erase("loaded")
	entries[Vector2i(3, 0)] = e
	idx.set_entries(entries)
	t.data.write_region_index()
	await _close(t)
	t = _open(true)
	await _frames(1)
	var after := _loaded(t)
	await _close(t)
	_check("[O] an entry without the key loads", had_false and after == ROW,
			"region 3 was recorded unloaded %s; with the key removed it reopens %s (want all four)"
			% [had_false, after])
	_ran += 1


## A scene-shaped fixture: a root holding the terrain and, optionally, a streamer as the terrain's child or
## as a sibling after it, all built before the root enters the tree.
func _game(p_mode: int, p_where: String, p_enabled: bool = true) -> Array:
	var root := Node.new()
	var t := Pasture3D.new()
	t.region_loading = p_mode
	t.data_directory = DIR
	root.add_child(t)
	if p_where != "":
		var s = ClassDB.instantiate("Pasture3DStreamer")
		s.enabled = p_enabled
		if p_where == "child":
			t.add_child(s)
		else:
			s.terrain = t
			root.add_child(s)
	add_child(root)
	# Read on entering, before any frame: the load is synchronous, and a streamer's first tick with no sources
	# (none exist headless) releases everything, which would make All look like Streamed.
	var out := _loaded(t)
	var idx_n: int = t.data.get_region_index().get_locations().size()
	await _close(root)
	return [out, idx_n]


func _g() -> void:
	# Mark 1 unloaded in the record so "a game ignores it" can fail.
	var e := _open(true)
	await _frames(1)
	e.data.unload_region(Vector2i(1, 0), true, true)
	await _close(e)
	var auto_none: Array = await _game(Pasture3D.REGION_LOADING_AUTO, "")
	var auto_child: Array = await _game(Pasture3D.REGION_LOADING_AUTO, "child")
	var auto_sib: Array = await _game(Pasture3D.REGION_LOADING_AUTO, "sibling")
	var streamed: Array = await _game(Pasture3D.REGION_LOADING_STREAMED, "")
	var disabled: Array = await _game(Pasture3D.REGION_LOADING_AUTO, "sibling", false)
	var all_s: Array = await _game(Pasture3D.REGION_LOADING_ALL, "child")
	var ok: bool = auto_none[0] == ROW and auto_child[0].is_empty() and auto_sib[0].is_empty() \
			and streamed[0].is_empty() and auto_child[1] == ROW.size() and auto_sib[1] == ROW.size()
	var controls: bool = disabled[0] == ROW and all_s[0] == ROW
	_check("[G] a game streams or loads all", ok and controls,
			("Auto, no streamer %s; Auto, streamer child %s / later sibling %s (index %d / %d); Streamed %s"
			+ " | controls: disabled streamer %s, All with streamer %s")
			% [auto_none[0], auto_child[0], auto_sib[0], auto_child[1], auto_sib[1], streamed[0],
					disabled[0], all_s[0]])
	_ran += 1


func _warns(p_mode: int, p_streamer: bool) -> bool:
	var root := Node.new()
	var t := Pasture3D.new()
	t.region_loading = p_mode
	t.data_directory = DIR
	root.add_child(t)
	if p_streamer:
		t.add_child(ClassDB.instantiate("Pasture3DStreamer"))
	add_child(root)
	var hit := str(t.get_region_loading_warning()).begins_with("No Pasture3DStreamer")
	await _close(root)
	return hit


func _w() -> void:
	var none: bool = await _warns(Pasture3D.REGION_LOADING_AUTO, false)
	var with_s: bool = await _warns(Pasture3D.REGION_LOADING_AUTO, true)
	var all_mode: bool = await _warns(Pasture3D.REGION_LOADING_ALL, false)
	_check("[W] no-streamer warning", none and not with_s and not all_mode,
			"Auto without a streamer warns %s | controls: with a streamer %s, All %s" % [none, with_s, all_mode])
	_ran += 1
