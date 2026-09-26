# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Gate RP — phase 5 of PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md: the region gizmo and panel (§G).
#
# The spec's proof is "selection, bulk actions, and the Set Type confirm dialog". The dock and the viewport
# are thin views over src/region_selection.gd and src/region_gizmo.gd, so this measures those: what is
# known and how it is described, what a click or a box selects, what each action does and refuses, which
# regions the Set Type dialog names, what the gizmo draws, and the Region tool's refusal to add a blank
# region over an unloaded one.
#
# Fixture (region size 256, spacing 1):
#   A (0,0) loaded, Standard, saved
#   B (1,0) saved, then unloaded
#   C (0,1) loaded, Background (1:4), locked, saved
#   D (2,0) loaded, Standard, edited after the save (dirty)
#   E (1,1) saved, then deleted this session (still in the index until the next save)
#
# Headless, user:// data, wiped at start.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/RegionPanelGate.tscn
extends Node

const RegionSelection := preload("res://addons/pasture_3d/src/region_selection.gd")
const RegionGizmo := preload("res://addons/pasture_3d/src/region_gizmo.gd")
const DIR := "user://region_panel_gate"
const BACKGROUND := "res://addons/pasture_3d/region_types/background.tres"
const STANDARD := "res://addons/pasture_3d/region_types/standard.tres"
const RS := 256
const A := Vector2i(0, 0)
const B := Vector2i(1, 0)
const C := Vector2i(0, 1)
const D := Vector2i(2, 0)
const E := Vector2i(1, 1)
const F := Vector2i(3, 0) # added in RP4, loaded Standard
const G := Vector2i(3, 1) # added in RP4, loaded Background
const NOWHERE := Vector2i(5, 5)

var _fail := 0
const GATES := 6
var _completed := 0
var _terrain
var _m: RegionSelection


func _ready() -> void:
	print("\n=== Region gizmo and panel (gate RP, streaming phase 5) ===\n")
	_wipe(DIR)
	_terrain = ClassDB.instantiate("Pasture3D")
	add_child(_terrain)
	_terrain.data_directory = DIR
	var d = _terrain.data
	for loc in [A, B, C, D, E]:
		d.add_region_blank(loc, false)
	d.update_maps()
	d.set_region_type(C, d.load_region_type(BACKGROUND), false)
	d.update_maps()
	d.set_region_locked(C, true)
	d.save_directory(DIR)
	d.unload_region(B, true)
	d.get_region(D).get_height_map().fill(Color(5, 0, 0, 1))
	d.get_region(D).set_modified(true)
	d.remove_regionl(E, true)
	_m = RegionSelection.new(_terrain)

	_rp1_known_and_described()
	_rp2_selecting()
	_rp3_actions()
	_rp4_set_type_confirm()
	_rp5_gizmo()
	_rp6_add_refused_over_unloaded()

	var ok := _fail == 0 and _completed == GATES
	print("\n=== %s (%d failures, %d/%d criteria completed) ===\n"
		% ["REGION PANEL PASS" if ok else "REGION PANEL FAIL", _fail, _completed, GATES])
	get_tree().quit(0 if ok else 1)


func _rp1_known_and_described() -> void:
	print("[RP1] what is known, and how each region is described:")
	var known := _m.known()
	_check("known is A B C D (got %s)" % [known], _same(known, [A, B, C, D]))
	_check("states: A loaded, B unloaded, NOWHERE none",
		_m.state(A) == RegionSelection.STATE_LOADED and _m.state(B) == RegionSelection.STATE_UNLOADED
		and _m.state(NOWHERE) == RegionSelection.STATE_NONE)
	# Control: the index alone still names E, which was deleted this session.
	_check("control: the index still names E", _terrain.data.get_region_index().has_entry(E))
	_check("  but E is not known (state %d)" % _m.state(E), _m.state(E) == RegionSelection.STATE_NONE)
	var ia := _m.info(A)
	var ib := _m.info(B)
	var ic := _m.info(C)
	var id := _m.info(D)
	_check("A: Standard, 256x256, clean, %d B measured" % ia["memory_bytes"], ia["type_name"] == "Standard"
		and ia["resolution"] == Vector2i(RS, RS) and not ia["dirty"] and not ia["memory_estimated"]
		and ia["memory_bytes"] == _maps_bytes(RS))
	_check("C: Background, 64x64, locked, %d B" % ic["memory_bytes"], ic["type_name"] == "Background"
		and ic["resolution"] == Vector2i(RS / 4, RS / 4) and ic["locked"] and ic["memory_bytes"] == _maps_bytes(RS / 4))
	_check("D is dirty", id["dirty"])
	# B is the same type as A, so the estimate from the index must be what A measures.
	_check("B: from the index, estimated %d B == A's measured, not dirty" % ib["memory_bytes"], not ib["loaded"]
		and ib["memory_estimated"] and ib["memory_bytes"] == ia["memory_bytes"] and not ib["dirty"]
		and ib["type_name"] == "Standard")
	_check("colours are the types' (%s vs %s)" % [ia["type_color"], ic["type_color"]],
		ic["type_color"] == _terrain.data.load_region_type(BACKGROUND).get_editor_color() and ia["type_color"] != ic["type_color"])
	_completed += 1


func _rp2_selecting() -> void:
	print("[RP2] clicks, toggles, boxes, and the Region tool's gesture rule:")
	_m.click(A)
	_check("click selects A", _same(_m.selected, [A]))
	_m.click(B, RegionSelection.REPLACE)
	_check("click replaces with B (unloaded is selectable)", _same(_m.selected, [B]))
	_m.click(A, RegionSelection.TOGGLE)
	_check("toggle adds A", _same(_m.selected, [A, B]))
	_m.click(A, RegionSelection.TOGGLE)
	_check("toggle removes A", _same(_m.selected, [B]))
	_m.click(NOWHERE, RegionSelection.TOGGLE)
	_check("toggling empty ground changes nothing", _same(_m.selected, [B]))
	_m.click(NOWHERE, RegionSelection.REPLACE)
	_check("clicking empty ground clears", _m.selected.is_empty())
	_m.box(Vector2i(-1, -1), Vector2i(2, 1))
	_check("box (-1,-1)..(2,1) selects A B C D (%s)" % [_m.selected], _same(_m.selected, [A, B, C, D]))
	# Control: the box spans 12 locations; E and the empty ones are not regions.
	_check("control: the box's rectangle holds 12 locations", 4 * 3 == 12 and _m.selected.size() < 12)
	_m.box(Vector2i(0, 0), Vector2i(0, 1), RegionSelection.REMOVE)
	_check("box remove drops A and C", _same(_m.selected, [B, D]))
	_m.box(Vector2i(0, 1), Vector2i(0, 1), RegionSelection.ADD)
	_check("box add brings C back", _same(_m.selected, [B, C, D]))
	var changed := [0]
	_m.changed.connect(func(): changed[0] += 1)
	_m.box(Vector2i(0, 1), Vector2i(0, 1), RegionSelection.ADD)
	_check("an unchanged selection does not signal", changed[0] == 0)
	_m.clear()
	_check("clear signals once", changed[0] == 1 and _m.selected.is_empty())
	# The gesture rule: select where add/remove would do nothing.
	var ADDOP: int = Pasture3DEditor.ADD
	var SUB: int = Pasture3DEditor.SUBTRACT
	var L := RegionSelection.STATE_LOADED
	var U := RegionSelection.STATE_UNLOADED
	var N := RegionSelection.STATE_NONE
	var S := RegionSelection.GESTURE_SELECT
	var K := RegionSelection.GESTURE_STROKE
	var table := [[L, false, ADDOP, S], [U, false, ADDOP, S], [N, false, ADDOP, K],
		[L, false, SUB, K], [U, false, SUB, S], [N, false, SUB, S], [N, true, ADDOP, S], [L, true, SUB, S]]
	var bad := 0
	for row in table:
		if RegionSelection.gesture(row[0], row[1], row[2]) != row[3]:
			bad += 1
	_check("gesture table (%d rows) holds" % table.size(), bad == 0)
	_check("select modes: click, shift-click, drag, shift-drag, shift+ctrl-drag",
		RegionSelection.select_mode(false, false, false) == RegionSelection.REPLACE
		and RegionSelection.select_mode(true, false, false) == RegionSelection.TOGGLE
		and RegionSelection.select_mode(false, false, true) == RegionSelection.REPLACE
		and RegionSelection.select_mode(true, false, true) == RegionSelection.ADD
		and RegionSelection.select_mode(true, true, true) == RegionSelection.REMOVE)
	_completed += 1


func _rp3_actions() -> void:
	print("[RP3] actions do what they say, and skip what they must not touch:")
	var d = _terrain.data
	_m.box(Vector2i(0, 0), Vector2i(2, 1))
	# Lock: B is unloaded, so it is skipped rather than loaded to be locked.
	var r := _m.set_locked(true)
	_check("lock: A C D done, B skipped as not loaded (%s)" % [r["skipped"]],
		_same(r["done"], [A, C, D]) and r["skipped"].get(B, "") == "not loaded")
	_check("  B is still unloaded", _m.state(B) == RegionSelection.STATE_UNLOADED)
	_m.set_locked(false)
	_m.click(C)
	_m.set_locked(true) # C stays locked for RP4
	# Load: only B needs it.
	_m.box(Vector2i(0, 0), Vector2i(2, 0))
	r = _m.load_selected()
	_check("load: B done, A D skipped (%s)" % [r["skipped"]], _same(r["done"], [B]) and r["skipped"].size() == 2)
	_check("  B loaded", d.is_region_loaded(B))
	# Unload D: dirty, so it is saved on the way out.
	var path := DIR + "/pasture3d_02_00.res"
	var before := FileAccess.get_file_as_bytes(path)
	_m.click(D)
	r = _m.unload_selected()
	var after := FileAccess.get_file_as_bytes(path)
	_check("unload: D done", _same(r["done"], [D]) and _m.state(D) == RegionSelection.STATE_UNLOADED)
	_check("  D's edit was saved (file changed: %d -> %d bytes)" % [before.size(), after.size()], before != after)
	# Control: unloading an unloaded region is refused, not repeated.
	r = _m.unload_selected()
	_check("control: unloading D again is skipped", r["done"].is_empty() and r["skipped"].get(D, "") == "not loaded")
	# Delete through the editor's own region stroke (no plugin here, so no undo is stored).
	var ed = Pasture3DEditor.new()
	ed.set_terrain(_terrain)
	ed.set_tool(Pasture3DEditor.SCULPT)
	ed.set_operation(Pasture3DEditor.ADD)
	_m.box(Vector2i(0, 0), Vector2i(2, 1))
	r = _m.delete_selected(ed)
	_check("delete: A B done, C locked, D not loaded (%s / %s)" % [r["done"], r["skipped"]],
		_same(r["done"], [A, B]) and r["skipped"].get(C, "") == "locked" and r["skipped"].get(D, "") == "not loaded")
	_check("  A and B are gone, the selection pruned to C D (%s)" % [_m.selected],
		not d.is_region_loaded(A) and not d.is_region_loaded(B) and _same(_m.selected, [C, D]))
	_check("  the editor's tool and operation are restored",
		ed.get_tool() == Pasture3DEditor.SCULPT and ed.get_operation() == Pasture3DEditor.ADD)
	# Bake Selected hands the scoped bake the selection as its SELECTED targets.
	_m.click(C)
	var rb := _m.bake_selected()
	_check("bake selected: ok, targets = [C] (%s)" % [rb.get("targets", [])],
		bool(rb.get("ok", false)) and _same(rb.get("targets", []), [C]))
	_m.box(Vector2i(0, 0), Vector2i(2, 1)) # A and B are deleted: C and D
	rb = _m.bake_selected()
	_check("control: selecting D too changes the targets (%s)" % [rb.get("targets", [])], _same(rb.get("targets", []), [C, D]))
	_check("  and the bake left D unloaded", _m.state(D) == RegionSelection.STATE_UNLOADED)
	ed.free()
	_completed += 1


func _rp4_set_type_confirm() -> void:
	print("[RP4] Set Type asks exactly when it would downsample:")
	var d = _terrain.data
	# Fresh: F loaded Standard, G loaded Background, C loaded Background and locked, D unloaded.
	d.add_region_blank(F, false)
	d.add_region_blank(G, false)
	d.update_maps()
	d.set_region_type(G, d.load_region_type(BACKGROUND), true)
	_m.box(Vector2i(0, 0), Vector2i(3, 1))
	var bg = d.load_region_type(BACKGROUND)
	var st = d.load_region_type(STANDARD)
	var down := _m.downsampled_by(bg)
	_check("to Background: only F is downsampled (%s)" % [down], _same(down, [F]))
	_check("control: to Standard nothing is (%s)" % [_m.downsampled_by(st)], _m.downsampled_by(st).is_empty())
	var r := _m.set_type(bg)
	_check("set type: F G done, C locked, D not loaded (%s / %s)" % [r["done"], r["skipped"]],
		_same(r["done"], [F, G]) and r["skipped"].get(C, "") == "locked" and r["skipped"].get(D, "") == "not loaded")
	_check("  F is 1:4 now", d.get_region(F).get_texel_ratio() == 4)
	_check("  and asking again finds nothing to downsample", _m.downsampled_by(bg).is_empty())
	_completed += 1


func _rp5_gizmo() -> void:
	print("[RP5] the gizmo draws each state differently:")
	var d = _terrain.data
	# Now: C loaded Background locked, D unloaded Standard, F G loaded Background.
	_m.click(G)
	var g := RegionGizmo.new()
	var l := g.lines(_m, [Vector2i(0, 0), Vector2i(1, 1)])
	var regs: Dictionary = l["regions"]
	var v: PackedVector3Array = l["vertices"]
	_check("every known region is drawn (%s)" % [regs.keys()], _same(regs.keys(), _m.known()))
	_check("F loaded, unselected: 4 solid edges (%d)" % regs[F]["segments"],
		regs[F]["segments"] == 4 and not regs[F]["dashed"])
	_check("D unloaded: dashed, %d segments" % regs[D]["segments"], regs[D]["dashed"] and regs[D]["segments"] == 4 * RegionGizmo.DASHES)
	_check("C locked: hatched, %d segments" % regs[C]["segments"], regs[C]["hatched"]
		and regs[C]["segments"] == 4 + RegionGizmo.HATCHES * 2 - 1)
	_check("G selected: an inner outline, %d segments" % regs[G]["segments"],
		regs[G]["selected"] and regs[G]["segments"] == 8)
	_check("control: the states' counts all differ", regs[F]["segments"] != regs[D]["segments"]
		and regs[C]["segments"] != regs[F]["segments"])
	var bgc: Color = d.load_region_type(BACKGROUND).get_editor_color()
	print("    F %s, D %s, Background %s" % [regs[F]["color"], regs[D]["color"], bgc])
	_check("tints: F is Background's colour, D Standard's (faded, unloaded)",
		regs[F]["color"] == bgc and regs[D]["color"] != bgc and regs[D]["color"].a < 1.0)
	var total := 0
	for k in regs:
		total += int(regs[k]["segments"])
	_check("the box adds one outline over (0,0)..(1,1): %s" % [l.get("box")],
		v.size() / 2 == total + 4 and l.get("box") == Rect2(0, 0, RS * 2, RS * 2))
	# Every vertex of a region's outline lies inside that region.
	var inside := true
	var at := 0
	for loc in _m.known():
		var n := int(regs[loc]["segments"]) * 2
		var rect := Rect2(Vector2(loc) * RS, Vector2(RS, RS))
		for i in range(at, at + n):
			if not rect.has_point(Vector2(v[i].x, v[i].z)):
				inside = false
		at += n
	_check("each outline stays inside its own region", inside)
	g.detach()
	_completed += 1


func _rp6_add_refused_over_unloaded() -> void:
	print("[RP6] the Region tool will not add a blank region over an unloaded one:")
	var d = _terrain.data
	var ed = Pasture3DEditor.new()
	ed.set_terrain(_terrain)
	ed.set_tool(Pasture3DEditor.REGION)
	ed.set_operation(Pasture3DEditor.ADD)
	var over_d := Vector3((D.x + 0.5) * RS, 0, (D.y + 0.5) * RS)
	ed.start_operation(over_d)
	ed.operate(over_d, 0.0)
	ed.stop_operation()
	_check("D (unloaded) got no blank region", not d.is_region_loaded(D) and _m.state(D) == RegionSelection.STATE_UNLOADED)
	# Control: the same stroke over a location nobody indexed adds one.
	var fresh := Vector2i(4, 0)
	var over_f := Vector3((fresh.x + 0.5) * RS, 0, (fresh.y + 0.5) * RS)
	ed.start_operation(over_f)
	ed.operate(over_f, 0.0)
	ed.stop_operation()
	_check("control: an unindexed location gets one", d.is_region_loaded(fresh))
	# And once D is loaded, adding over it is a no-op, not a blank: its saved edit survives.
	_m.click(D)
	_m.load_selected()
	var h: float = d.get_height(Vector3(over_d.x, 0, over_d.z))
	ed.start_operation(over_d)
	ed.operate(over_d, 0.0)
	ed.stop_operation()
	_check("D loaded keeps its edit (height %.1f)" % h, is_equal_approx(h, 5.0)
		and is_equal_approx(d.get_height(Vector3(over_d.x, 0, over_d.z)), 5.0))
	ed.free()
	_completed += 1


## Height and control RF, colour RGBA8 with mipmaps: what a region at this resolution holds, from Images
## built here rather than the model's own sum.
func _maps_bytes(p_px: int) -> int:
	return (Image.create(p_px, p_px, false, Image.FORMAT_RF).get_data_size() * 2
		+ Image.create(p_px, p_px, true, Image.FORMAT_RGBA8).get_data_size())


func _same(p_a: Array, p_b: Array) -> bool:
	if p_a.size() != p_b.size():
		return false
	for x in p_a:
		if not p_b.has(x):
			return false
	return true


func _check(p_name: String, p_ok: bool) -> void:
	print("  %s  %s" % ["ok  " if p_ok else "FAIL", p_name])
	if not p_ok:
		_fail += 1


func _wipe(p_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(p_dir)
	var da := DirAccess.open(p_dir)
	for f in da.get_files():
		da.remove(f)
