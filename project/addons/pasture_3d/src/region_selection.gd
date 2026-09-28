# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# The region selection and what can be done to it (PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md §G).
#
# One model behind three views: the Regions dock (buttons and the inspector rows), the region gizmo (what is
# drawn) and the viewport input (what a click selects). No class_name: preload it, since a new global class
# needs an editor rescan.
#
# A "known" region is one the terrain has loaded or the region index names. Selection holds locations, not
# regions, so it survives an unload and a reload.
#
# ---- ONLY LOAD LOADS ----
#
# §F: nothing operates on an unloaded region, and only a bake may load one implicitly. So Lock, Set Type and
# Delete skip unloaded regions and say so; they never load one to act on it. Load and Bake Selected are the
# two actions that bring regions in, and Bake Selected puts the loaded set back as it found it.
@tool
extends RefCounted

const ScopedBake := preload("res://addons/pasture_3d/connectors/pasture3d_scoped_bake.gd")
## Pasture3DRegionType.STANDARD_PATH, which is not bound: a region with no type path is Standard.
const STANDARD_PATH := "res://addons/pasture_3d/region_types/standard.tres"

enum { REPLACE, ADD, REMOVE, TOGGLE }
enum { STATE_NONE, STATE_LOADED, STATE_UNLOADED }

signal changed

var terrain
var selected: Array[Vector2i] = []


func _init(p_terrain = null) -> void:
	terrain = p_terrain


func _data():
	return terrain.data if terrain != null and is_instance_valid(terrain) else null


# ---- what exists -----------------------------------------------------------------

## Every region the terrain has loaded or the index names, in row-major order.
func known() -> Array[Vector2i]:
	var d = _data()
	var out: Array[Vector2i] = []
	if d == null:
		return out
	var seen := {}
	for loc: Vector2i in d.get_region_locations():
		seen[loc] = true
	var index = d.get_region_index()
	if index != null:
		for loc: Vector2i in index.get_locations():
			# A region deleted this session is still in the index until the save, but it is not there.
			if not d.is_region_loaded(loc) and d.get_region(loc) != null and d.get_region(loc).is_deleted():
				continue
			seen[loc] = true
	for loc: Vector2i in seen:
		out.append(loc)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	return out


func state(p_loc: Vector2i) -> int:
	var d = _data()
	if d == null:
		return STATE_NONE
	if d.is_region_loaded(p_loc):
		return STATE_LOADED
	var index = d.get_region_index()
	if index != null and index.has_entry(p_loc):
		var r = d.get_region(p_loc)
		if r == null or not r.is_deleted():
			return STATE_UNLOADED
	return STATE_NONE


func location_of(p_world: Vector3) -> Vector2i:
	var rsw: float = float(terrain.get_region_size()) * terrain.get_vertex_spacing()
	return Vector2i(floori(p_world.x / rsw), floori(p_world.z / rsw))


## The known region under a world point, or null.
func region_at(p_world: Vector3) -> Variant:
	if _data() == null:
		return null
	var loc := location_of(p_world)
	return loc if state(loc) != STATE_NONE else null


# ---- selecting -------------------------------------------------------------------

## REPLACE selects only p_loc; ADD adds it; REMOVE drops it; TOGGLE flips it. A location with no region
## clears on REPLACE and is otherwise ignored.
func click(p_loc: Variant, p_mode: int = REPLACE) -> void:
	var next: Array[Vector2i] = selected.duplicate()
	if p_loc == null or state(p_loc) == STATE_NONE:
		if p_mode == REPLACE:
			next.clear()
		_set_selected(next)
		return
	var loc: Vector2i = p_loc
	match p_mode:
		REPLACE:
			next = [loc]
		ADD:
			if not next.has(loc):
				next.append(loc)
		REMOVE:
			next.erase(loc)
		TOGGLE:
			if next.has(loc):
				next.erase(loc)
			else:
				next.append(loc)
	_set_selected(next)


## Every known region in the location rectangle spanned by p_a and p_b, inclusive.
func box(p_a: Vector2i, p_b: Vector2i, p_mode: int = REPLACE) -> void:
	var lo := Vector2i(mini(p_a.x, p_b.x), mini(p_a.y, p_b.y))
	var hi := Vector2i(maxi(p_a.x, p_b.x), maxi(p_a.y, p_b.y))
	var inside: Array[Vector2i] = []
	for loc in known():
		if loc.x >= lo.x and loc.x <= hi.x and loc.y >= lo.y and loc.y <= hi.y:
			inside.append(loc)
	# A ternary's result is an untyped Array, which a typed variable refuses: build it in two steps.
	var next: Array[Vector2i] = []
	if p_mode != REPLACE:
		next = selected.duplicate()
	for loc in inside:
		if p_mode == REMOVE or (p_mode == TOGGLE and next.has(loc)):
			next.erase(loc)
		elif not next.has(loc):
			next.append(loc)
	_set_selected(next)


func clear() -> void:
	_set_selected([])


## Drop selected locations that no longer hold a region (after a delete, an undo, a data reload).
func prune() -> void:
	var next: Array[Vector2i] = []
	for loc in selected:
		if state(loc) != STATE_NONE:
			next.append(loc)
	_set_selected(next)


func _set_selected(p_next: Array[Vector2i]) -> void:
	if p_next == selected:
		return
	selected = p_next
	changed.emit()


# ---- the Region tool's clicks ----------------------------------------------------
#
# The Region tool adds and removes regions, and Ctrl already inverts which (ui.set_active_operation), so
# selection cannot take Ctrl alone as §G's wording has it. Shift is free in this tool: Shift-click toggles,
# Shift-drag adds a box, Shift+Ctrl-drag removes one. Without Shift a press selects wherever adding or
# removing would do nothing: on a region under Add, on empty ground under Remove, and on an unloaded region
# either way.

enum { GESTURE_STROKE, GESTURE_SELECT }


## What a press does. p_state is state() at the press; p_op is the ACTIVE operation (Ctrl already applied).
static func gesture(p_state: int, p_shift: bool, p_op: int) -> int:
	if p_shift:
		return GESTURE_SELECT
	if p_state == STATE_NONE:
		return GESTURE_STROKE if p_op == Pasture3DEditor.ADD else GESTURE_SELECT
	if p_state == STATE_LOADED and p_op == Pasture3DEditor.SUBTRACT:
		return GESTURE_STROKE
	return GESTURE_SELECT


## The selection mode a finished select gesture applies.
static func select_mode(p_shift: bool, p_ctrl: bool, p_drag: bool) -> int:
	if not p_drag:
		return TOGGLE if p_shift else REPLACE
	if p_shift:
		return REMOVE if p_ctrl else ADD
	return REPLACE


# ---- describing ------------------------------------------------------------------

## The region's type: the loaded region's own, or the one its index entry names.
func type_of(p_loc: Vector2i) -> Resource:
	var d = _data()
	if d == null:
		return null
	if d.is_region_loaded(p_loc):
		return d.get_region_type(p_loc)
	var path := str(_entry(p_loc).get("type_path", ""))
	return d.load_region_type(path if not path.is_empty() else STANDARD_PATH)


func _entry(p_loc: Vector2i) -> Dictionary:
	var d = _data()
	var index = d.get_region_index() if d != null else null
	return index.get_entry(p_loc) if index != null and index.has_entry(p_loc) else {}


## What the inspector rows show. `memory_bytes` is what the region's maps hold now; unloaded it is what they
## would hold once loaded (`memory_estimated`), from the index's texel ratio.
func info(p_loc: Vector2i) -> Dictionary:
	var d = _data()
	var st := state(p_loc)
	var out := {"location": p_loc, "state": st, "loaded": st == STATE_LOADED}
	if d == null or st == STATE_NONE:
		return out
	var t = type_of(p_loc)
	out["type_name"] = t.get_type_name() if t != null else "?"
	out["type_color"] = t.get_editor_color() if t != null else Color.WHITE
	var rs: int = terrain.get_region_size()
	if st == STATE_LOADED:
		var r = d.get_region(p_loc)
		out["type_path"] = r.get_type_path()
		out["locked"] = r.is_locked()
		out["texel_ratio"] = r.get_texel_ratio()
		out["dirty"] = r.is_modified()
		out["height_range"] = r.get_height_range()
		var bytes := 0
		for img: Image in [r.get_height_map(), r.get_control_map(), r.get_color_map()]:
			if img != null:
				bytes += img.get_data_size()
		out["memory_bytes"] = bytes
		out["memory_estimated"] = false
	else:
		var e := _entry(p_loc)
		out["type_path"] = str(e.get("type_path", ""))
		out["locked"] = bool(e.get("locked", false))
		out["texel_ratio"] = int(e.get("texel_ratio", 1))
		out["dirty"] = false # an unloaded region is on disk by construction
		out["height_range"] = e.get("height_range", Vector2.ZERO)
		var px: int = rs / maxi(int(out["texel_ratio"]), 1)
		# The maps a loaded region holds: height and control RF, colour RGBA8 with its mipmaps.
		var colour := 0
		var m := px
		while true:
			colour += m * m * 4
			if m == 1:
				break
			m = maxi(m / 2, 1)
		out["memory_bytes"] = px * px * 4 * 2 + colour
		out["memory_estimated"] = true
	var px: int = rs / maxi(int(out["texel_ratio"]), 1)
	out["resolution"] = Vector2i(px, px)
	return out


# ---- actions ---------------------------------------------------------------------
# Each returns {done: [locations], skipped: {location: reason}}. Maps are updated once, at the end.

func _report() -> Dictionary:
	return {"done": [], "skipped": {}}


func load_selected(p_dir: String = "") -> Dictionary:
	var d = _data()
	var rep := _report()
	var dir := p_dir if not p_dir.is_empty() else str(terrain.data_directory)
	for loc in selected:
		if state(loc) != STATE_UNLOADED:
			rep["skipped"][loc] = "already loaded"
			continue
		if d.load_region(loc, dir, false) == OK:
			rep["done"].append(loc)
		else:
			rep["skipped"][loc] = "load failed"
	if not rep["done"].is_empty():
		d.update_maps()
	changed.emit()
	return rep


## Unload saves a dirty region first (phase 0), and that drops its undo history.
func unload_selected() -> Dictionary:
	var d = _data()
	var rep := _report()
	for loc in selected:
		if state(loc) != STATE_LOADED:
			rep["skipped"][loc] = "not loaded"
			continue
		if d.unload_region(loc, false, false) == OK:
			rep["done"].append(loc)
		else:
			rep["skipped"][loc] = "unload failed"
	if not rep["done"].is_empty():
		d.write_region_index() # once, not per region
		d.update_maps()
	changed.emit()
	return rep


func set_locked(p_locked: bool) -> Dictionary:
	var d = _data()
	var rep := _report()
	for loc in selected:
		if state(loc) != STATE_LOADED:
			rep["skipped"][loc] = "not loaded"
			continue
		if d.set_region_locked(loc, p_locked) == OK:
			d.get_region(loc).set_modified(true)
			rep["done"].append(loc)
	changed.emit()
	return rep


## The selected regions a change to p_type would DOWNSAMPLE (discarding detail), which is what the Set Type
## dialog asks about. Unloaded and locked regions are left out: Set Type skips them anyway.
func downsampled_by(p_type: Resource) -> Array[Vector2i]:
	var d = _data()
	var out: Array[Vector2i] = []
	if p_type == null:
		return out
	for loc in selected:
		if state(loc) == STATE_LOADED and not d.is_region_locked(loc) \
				and int(p_type.get_texel_ratio()) > int(d.get_region(loc).get_texel_ratio()):
			out.append(loc)
	return out


func set_type(p_type: Resource) -> Dictionary:
	var d = _data()
	var rep := _report()
	for loc in selected:
		if state(loc) != STATE_LOADED:
			rep["skipped"][loc] = "not loaded"
			continue
		if d.is_region_locked(loc):
			rep["skipped"][loc] = "locked"
			continue
		var err: int = d.set_region_type(loc, p_type, false)
		if err == OK:
			rep["done"].append(loc)
		else:
			rep["skipped"][loc] = error_string(err)
	if not rep["done"].is_empty():
		d.update_maps()
	changed.emit()
	return rep


## Delete is today's Remove Region, run through the editor's own region stroke so it is one undo action.
## p_editor is that Pasture3DEditor; without one (a headless gate) the regions are removed directly.
func delete_selected(p_editor: Object = null) -> Dictionary:
	var d = _data()
	var rep := _report()
	var targets: Array[Vector2i] = []
	for loc in selected:
		if state(loc) != STATE_LOADED:
			rep["skipped"][loc] = "not loaded"
		elif d.is_region_locked(loc):
			rep["skipped"][loc] = "locked"
		else:
			targets.append(loc)
	if not targets.is_empty():
		var rsw: float = float(terrain.get_region_size()) * terrain.get_vertex_spacing()
		if p_editor != null:
			var tool: int = p_editor.get_tool()
			var op: int = p_editor.get_operation()
			p_editor.set_tool(Pasture3DEditor.REGION)
			p_editor.set_operation(Pasture3DEditor.SUBTRACT)
			var first := Vector3((targets[0].x + 0.5) * rsw, 0.0, (targets[0].y + 0.5) * rsw)
			p_editor.start_operation(first)
			for loc in targets:
				p_editor.operate(Vector3((loc.x + 0.5) * rsw, 0.0, (loc.y + 0.5) * rsw), 0.0)
			p_editor.stop_operation()
			p_editor.set_tool(tool)
			p_editor.set_operation(op)
		else:
			for loc in targets:
				d.remove_regionl(loc, false)
			d.update_maps()
		for loc in targets:
			if not d.is_region_loaded(loc):
				rep["done"].append(loc)
			else:
				rep["skipped"][loc] = "not removed"
	prune()
	changed.emit()
	return rep


## Bake Selected: the scoped bake over the selection, loading what it needs and releasing it after (§F).
## Returns the scoped bake's report.
func bake_selected() -> Dictionary:
	var sb = ScopedBake.new(terrain)
	var rep: Dictionary = sb.bake(ScopedBake.Scope.SELECTED, selected)
	changed.emit()
	return rep
