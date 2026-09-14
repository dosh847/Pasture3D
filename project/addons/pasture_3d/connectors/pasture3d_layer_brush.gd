# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DLayerBrush — a container node that owns one layer and gives it to every height brush beneath it,
# the way a Pasture3DRoadNetwork groups roads. See PASTURE3D_LAYER_BRUSH_SPEC.md.
#
# ---- PHASE 1: IDENTITY AND MEMBERSHIP ----
#
# No modifier stack yet (phase 3). Members bake exactly as brushes sharing a free layer always have — the
# sibling repaint in `_refresh_owner` already makes a layer's bake layer-granular. What this node adds is
# WHICH layer that is, and the refusal (in `Pasture3DTerrainBrush._layer_owner_allowed`) to let a member be
# anywhere else.
#
# ---- TWO ROWS, SHOWN AS ONE ----
#
# The node owns a BASE row (`<uid>#base`, REPLACE) directly beneath its MAIN row (`<uid>`). Members paint the
# main row. The base row is where phase 3's stack result will live: members read "the ground below their
# layer", so a result in the row beneath reaches every snap and every below-reading modifier through the read
# they already make. Phase 1 creates, names, pairs and removes both rows; the base stays empty.
#
# The Layers dock lists the pair as ONE row and applies every action to both (§8.4). The unit and
# shown-row logic lives here as static functions, so the dock and the gate run the same code.
#
# ---- IDENTITY ----
#
# The owner id is a uid, not the name: renaming the node renames the rows and never rebinds a member. A
# duplicated node carries the uid it was copied from, so `_claim_unique_uid` gives the copy a fresh one.
@tool
@icon("res://addons/pasture_3d/icons/brush_terrain.svg")
class_name Pasture3DLayerBrush
extends Pasture3DTerrainBrush

const LAYER_BASE_SUFFIX: String = "#base"
## Every Layer brush, so a duplicate can find the node whose uid it copied.
const LAYER_GROUP: StringName = &"pasture3d_layer_brush"
## Refusals kept for the configuration warnings. A record of attempts, not of a broken state: a refused
## assignment leaves the scene unchanged, so there is nothing to fix and no reason to keep every one.
const MAX_VIOLATIONS: int = 5

## The stable half of the owner id. Generated once and never derived from the name (§3.1).
@export_storage var _layer_uid: String = ""

## Refused assignments naming this Layer brush: {node, owner, message, time}. Not persisted.
var _violations: Array = []
var _rename_queued: bool = false
## The rows a delete took off the stack, as [[layer, index], ...] ascending, so undoing the delete puts the
## SAME layer objects back where they were. Exact rather than rebuilt: the tiles come back with them.
var _removed_rows: Array = []
## Delete detection is editor-only: at runtime a Layer brush leaving the tree is a scene being unloaded, and
## taking its rows with it would alter the terrain a game is still showing. Gates turn this on.
var detect_delete_headless: bool = false


func _init() -> void:
	super()
	if _layer_uid == "":
		_layer_uid = _new_uid()


func _ready() -> void:
	_claim_unique_uid()
	add_to_group(LAYER_GROUP)
	super()
	if not renamed.is_connected(_queue_rename_sync):
		renamed.connect(_queue_rename_sync)
	adopt_members()
	_sync_row_names()


func _notification(what: int) -> void:
	# The base class's _notification runs too (GDScript calls every level); this only adds the delete check.
	if what == NOTIFICATION_EXIT_TREE:
		if _ready_done and (Engine.is_editor_hint() or detect_delete_headless):
			_check_deleted.call_deferred()
	elif what == NOTIFICATION_ENTER_TREE:
		if not _removed_rows.is_empty():
			_restore_rows()


static func _new_uid() -> String:
	return "%x" % absi(ResourceUID.create_id())


## The owner id of the MAIN row, which every member stores in `_layer_owner`.
func layer_owner_id() -> String:
	return LAYER_BRUSH_OWNER_PREFIX + _layer_uid


## The owner id of the BASE row, directly beneath the main row.
func base_owner_id() -> String:
	return layer_owner_id() + LAYER_BASE_SUFFIX


## ---- Brush hooks ----------------------------------------------------------------------------------------

## The Layer brush draws nothing of its own. Answering false keeps it out of every sibling set, hides the
## brush-only Layer dropdown, and stops `_ensure_layer_for` making a row under the base class's naming.
func _paints() -> bool:
	return false


func _wants_own_splines() -> bool:
	return false


func _default_layer_name() -> String:
	return "Layer"


func _layer_brush_refusal_reason() -> String:
	return "A Layer brush is not a member of another; a nested Layer brush owns its own layer."


const _HIDDEN_BRUSH_PROPERTIES: Array[StringName] = [
	&"corner_radius", &"crease_smoothing", &"snap_to_surface", &"surface_offset", &"_snap_btn",
	&"_add_spline_btn", &"_add_water_btn", &"_add_layer_btn", &"_toggle_tangents_btn", &"_make_unique_btn",
	&"force_gdscript_raster", &"log_bake_timing",
]


func _validate_property(property: Dictionary) -> void:
	super._validate_property(property)
	if StringName(property.name) in _HIDDEN_BRUSH_PROPERTIES:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func _get_configuration_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if not is_instance_valid(terrain):
		w.append("Place this Layer brush under a Pasture3D terrain (or assign one) so it has a layer to own.")
	elif terrain.data == null or terrain.data.region_locations.size() == 0:
		w.append("The Pasture3D terrain has no regions yet — add regions in Pasture3D first.")
	for v in _violations:
		w.append("Refused: %s" % v["message"])
	return w


## ---- Rows -----------------------------------------------------------------------------------------------

func _stack() -> Pasture3DLayerStack:
	if not is_instance_valid(terrain) or terrain.data == null or not terrain.data.has_layer_stack():
		return null
	return terrain.data.get_layer_stack()


func _row_for(p_owner: String) -> Pasture3DLayer:
	var stack := _stack()
	if stack == null:
		return null
	var idx: int = stack.find_layer_by_owner(p_owner)
	return stack.get_layer(idx) if idx >= 0 else null


## Create (or bind to) both rows, then make sure the base sits directly beneath the main row. Idempotent:
## `create_owned_layer_typed` returns an existing owner's row, so a reload and every member bake can call it.
func ensure_rows() -> void:
	if not is_instance_valid(terrain) or terrain.data == null or not terrain.data.has_method("create_owned_layer_typed"):
		return
	var d: Pasture3DData = terrain.data
	var existed: bool = d.find_layer_by_owner(layer_owner_id()) >= 0 and d.find_layer_by_owner(base_owner_id()) >= 0
	# Base first: `add_layer` appends, so a fresh pair is created already adjacent and in the right order.
	if d.create_owned_layer_typed(base_owner_id(), str(name), BLEND_REPLACE, PASTURE_3D_MAPTYPE_HEIGHT) < 0:
		return
	if d.create_owned_layer_typed(layer_owner_id(), str(name), BLEND_REPLACE, PASTURE_3D_MAPTYPE_HEIGHT) < 0:
		return
	_repair_pair(existed)


## Stage 2 (phase 3) reads the base as "the row beneath the main row", so adjacency is an invariant. A script
## `move_layer` or an older scene can still break it; put the base back and say so.
func _repair_pair(p_warn: bool) -> void:
	var stack := _stack()
	if stack == null:
		return
	var b: int = stack.find_layer_by_owner(base_owner_id())
	var m: int = stack.find_layer_by_owner(layer_owner_id())
	if b < 0 or m < 0 or b == m - 1:
		return
	if p_warn:
		push_warning("Pasture3D Layer brush '%s': its base row was separated from its layer row; moved it back beneath." % name)
	# Removing b first shifts m down when b is below it, so the insert index differs by side.
	terrain.data.layer_move(b, m - 1 if b < m else m)


func _queue_rename_sync() -> void:
	if _rename_queued:
		return
	_rename_queued = true
	_sync_row_names.call_deferred()


## Name both rows after the node. Deferred from `renamed` so a rename in progress finishes first. On a
## collision with any other row the NODE is renamed to a de-duplicated name (D5): the node name is the truth,
## so the two must match, and it is the node the user can see being renamed.
func _sync_row_names() -> void:
	_rename_queued = false
	var stack := _stack()
	if stack == null:
		return
	var want := str(name)
	if _row_name_taken(want):
		var unique := _unique_row_name(want)
		push_warning("Pasture3D Layer brush: a layer named '%s' already exists; renamed this node to '%s'." % [want, unique])
		name = unique # fires `renamed` again; that sync finds the name free
		want = str(name)
	var changed := false
	for owner in [base_owner_id(), layer_owner_id()]:
		var l := _row_for(owner)
		if l != null and l.get_layer_name() != want:
			l.set_layer_name(want)
			changed = true
	if changed:
		terrain.data.emit_signal("layers_changed")
	for mbr in members():
		mbr._update_label_text()


func _row_name_taken(p_name: String) -> bool:
	var stack := _stack()
	if stack == null:
		return false
	var mine := layer_owner_id()
	for i in range(stack.get_layer_count()):
		var l := stack.get_layer(i)
		if l != null and l.get_owner_id().get_slice("#", 0) != mine and l.get_layer_name() == p_name:
			return true
	return false


func _unique_row_name(p_base: String) -> String:
	var n := 2
	while _row_name_taken("%s %d" % [p_base, n]):
		n += 1
	return "%s %d" % [p_base, n]


## ---- Members ---------------------------------------------------------------------------------------------

## Every brush whose nearest Layer brush ancestor is this one and which may join (§4.1). Derived from the
## tree on every call; nothing about membership is stored except each member's `_layer_owner`.
func members() -> Array:
	var out: Array = []
	if not is_inside_tree():
		return out
	for n in get_tree().get_nodes_in_group(BRUSH_GROUP):
		if n != self and is_instance_valid(n) and is_ancestor_of(n) and n._hosted_by() == self:
			out.append(n)
	return out


func member_count() -> int:
	return members().size()


## Bring every member's binding in line with the tree. Run on ready (children are ready before their parent,
## so a member that synced first may still hold a uid this node has since replaced) and after a duplicate.
func adopt_members() -> void:
	ensure_rows()
	for mbr in members():
		mbr._sync_layer_host()


func _note_violation(p_node: Node, p_owner: String, p_message: String) -> void:
	_violations.append({
		"node": str(p_node.get_path()) if p_node.is_inside_tree() else str(p_node.name),
		"owner": p_owner, "message": p_message, "time": Time.get_ticks_msec(),
	})
	while _violations.size() > MAX_VIOLATIONS:
		_violations.pop_front()
	update_configuration_warnings()


func violations() -> Array:
	return _violations.duplicate()


## A duplicate carries the uid it was copied from; the later arrival takes a fresh one and re-adopts.
func _claim_unique_uid() -> void:
	if not is_inside_tree():
		return
	for n in get_tree().get_nodes_in_group(LAYER_GROUP):
		if n != self and is_instance_valid(n) and n._layer_uid == _layer_uid:
			_layer_uid = _new_uid()
			return


## ---- Delete and undo (D6) ----------------------------------------------------------------------------------

## Deferred from EXIT_TREE, because only a frame later can a delete be told from its look-alikes. A reparent
## is back in the tree by then. A scene-tab switch leaves this node under a scene root that is still open.
## What remains is a subtree removed from its scene: the editor keeps it for undo, and its rows go now.
func _check_deleted() -> void:
	if is_inside_tree() or not _removed_rows.is_empty():
		return
	var top: Node = self
	while top.get_parent() != null:
		top = top.get_parent()
	if top != self and _is_open_scene_root(top):
		return
	_remove_rows()


func _is_open_scene_root(p_node: Node) -> bool:
	if not Engine.is_editor_hint():
		return false
	if EditorInterface.has_method("get_open_scene_roots"):
		return p_node in EditorInterface.get_open_scene_roots()
	return p_node.scene_file_path != ""


## Every row this node owns: the pair and any `owner#…` row a later phase affiliates with it.
func _owned_row_indices() -> PackedInt32Array:
	var out := PackedInt32Array()
	var stack := _stack()
	if stack == null:
		return out
	var mine := layer_owner_id()
	for i in range(stack.get_layer_count()):
		var l := stack.get_layer(i)
		if l != null and l.get_owner_id().get_slice("#", 0) == mine:
			out.append(i)
	return out


func _remove_rows() -> void:
	var stack := _stack()
	if stack == null:
		return
	var idxs := _owned_row_indices()
	if idxs.is_empty():
		return
	var layers: Array = stack.get_layers().duplicate()
	var regions := {}
	_removed_rows.clear()
	for i in idxs:
		_removed_rows.append([layers[i], i])
		for loc in layers[i].get_region_locations():
			regions[loc] = true
	for k in range(idxs.size() - 1, -1, -1):
		layers.remove_at(idxs[k])
	_swap_layers(stack, layers, regions)


func _restore_rows() -> void:
	var stack := _stack()
	if stack == null:
		return
	var layers: Array = stack.get_layers().duplicate()
	var regions := {}
	for entry in _removed_rows:
		layers.insert(mini(int(entry[1]), layers.size()), entry[0])
		for loc in entry[0].get_region_locations():
			regions[loc] = true
	_removed_rows.clear()
	_swap_layers(stack, layers, regions)


func _swap_layers(p_stack: Pasture3DLayerStack, p_layers: Array, p_regions: Dictionary) -> void:
	var active: int = p_stack.get_active_layer()
	p_stack.set_layers(p_layers)
	p_stack.set_active_layer(clampi(active, 0, p_layers.size() - 1))
	for loc in p_regions:
		terrain.data.composite_region(loc, Rect2i(), false)
	# Full push: a whole-row swap is the same risk class as a bake undo (see `_restore_owner`).
	terrain.data.update_maps()
	terrain.data.emit_signal("layers_changed")


## ---- The dock's view of a pair (§8.4). Static, so the gate tests the code the dock runs. ------------------

## The main owner of the Layer brush pair a row belongs to, or "" for any other row.
static func pair_owner_of(p_layer: Pasture3DLayer) -> String:
	if p_layer == null:
		return ""
	var oid: String = p_layer.get_owner_id()
	return oid.get_slice("#", 0) if oid.begins_with(LAYER_BRUSH_OWNER_PREFIX) else ""


## Movement units, bottom to top, as [first, last] index ranges. A Layer brush's adjacent rows are one unit;
## every other row is its own. Index 0 (the terrain's Base) is always alone.
static func stack_units(p_stack: Pasture3DLayerStack) -> Array:
	var out: Array = []
	var n: int = p_stack.get_layer_count()
	var i := 0
	while i < n:
		var j := i
		var po := pair_owner_of(p_stack.get_layer(i))
		if i > 0 and po != "":
			while j + 1 < n and pair_owner_of(p_stack.get_layer(j + 1)) == po:
				j += 1
		out.append([i, j])
		i = j + 1
	return out


static func unit_index_of(p_units: Array, p_idx: int) -> int:
	for u in range(p_units.size()):
		if p_idx >= int(p_units[u][0]) and p_idx <= int(p_units[u][1]):
			return u
	return -1


## Every row in `p_idx`'s unit — what a dock action on the shown row must also reach.
static func unit_rows(p_stack: Pasture3DLayerStack, p_idx: int) -> PackedInt32Array:
	var units := stack_units(p_stack)
	var u := unit_index_of(units, p_idx)
	var out := PackedInt32Array()
	if u < 0:
		return out
	for r in range(int(units[u][0]), int(units[u][1]) + 1):
		out.append(r)
	return out


## The row the dock lists for a unit. A pair shows its base row while its Layer brush has no members and its
## main row once it has any. `p_member_counts` maps main owner -> member count; an owner absent from it has
## no Layer brush node, and shows main (with the dock's orphan badge).
static func shown_row(p_stack: Pasture3DLayerStack, p_unit: Array, p_member_counts: Dictionary) -> int:
	var a := int(p_unit[0])
	var b := int(p_unit[1])
	if a == b:
		return a
	var po := pair_owner_of(p_stack.get_layer(a))
	var base_i := -1
	var main_i := -1
	for k in range(a, b + 1):
		var oid: String = p_stack.get_layer(k).get_owner_id()
		if oid == po:
			main_i = k
		elif oid == po + LAYER_BASE_SUFFIX:
			base_i = k
	if main_i < 0:
		return b
	if base_i >= 0 and p_member_counts.has(po) and int(p_member_counts[po]) == 0:
		return base_i
	return main_i


## `layer_move` steps that swap `p_idx`'s unit with its neighbour unit in direction `p_dir` (+1 up, -1 down).
## Empty when it cannot move: the Base, or already at that end.
static func unit_move_steps(p_stack: Pasture3DLayerStack, p_idx: int, p_dir: int) -> Array:
	var units := stack_units(p_stack)
	var u := unit_index_of(units, p_idx)
	var v := u + p_dir
	if u <= 0 or v <= 0 or v >= units.size():
		return []
	var order: Array = units.duplicate()
	order[u] = units[v]
	order[v] = units[u]
	return _steps_for_unit_order(p_stack, units, order)


## `layer_move` steps that move `p_from`'s unit into the slot of `p_to`'s unit — drag-and-drop. It lands above
## the target when dragged up and below it when dragged down, as a single-row `move_layer` does.
static func unit_drop_steps(p_stack: Pasture3DLayerStack, p_from: int, p_to: int) -> Array:
	var units := stack_units(p_stack)
	var u := unit_index_of(units, p_from)
	var v := unit_index_of(units, p_to)
	if u <= 0 or v <= 0 or u == v:
		return []
	var order: Array = units.duplicate()
	var moving = order[u]
	order.remove_at(u)
	order.insert(v, moving)
	return _steps_for_unit_order(p_stack, units, order)


static func _steps_for_unit_order(p_stack: Pasture3DLayerStack, _p_units: Array, p_order: Array) -> Array:
	var current: Array = range(p_stack.get_layer_count())
	var target: Array = []
	for unit in p_order:
		for r in range(int(unit[0]), int(unit[1]) + 1):
			target.append(r)
	return steps_to_order(current, target)


## Single-element moves (`remove_at` then `insert`, exactly `Pasture3DLayerStack.move_layer`) that turn
## `p_current` into `p_target`. Positions below t are settled before t is, so every step moves an item down to t.
static func steps_to_order(p_current: Array, p_target: Array) -> Array:
	var cur := p_current.duplicate()
	var steps: Array = []
	for t in range(p_target.size()):
		var f := cur.find(p_target[t])
		if f != t:
			steps.append([f, t])
			var item = cur[f]
			cur.remove_at(f)
			cur.insert(t, item)
	return steps


## Apply `p_steps` through `Pasture3DData.layer_move` (which recomposites), or undo them. The inverse of
## move(f, t) is move(t, f), and the inverses must run in REVERSE order: replaying them forward brings a pair
## back swapped.
static func apply_steps(p_data: Pasture3DData, p_steps: Array, p_inverse: bool = false) -> void:
	if p_inverse:
		for i in range(p_steps.size() - 1, -1, -1):
			p_data.layer_move(int(p_steps[i][1]), int(p_steps[i][0]))
	else:
		for s in p_steps:
			p_data.layer_move(int(s[0]), int(s[1]))
