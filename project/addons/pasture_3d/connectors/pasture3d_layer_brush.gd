# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DLayerBrush — a container node that owns one layer and gives it to every height brush beneath it,
# the way a Pasture3DRoadNetwork groups roads. See PASTURE3D_LAYER_BRUSH_SPEC.md.
#
# ---- STAGE 1: THE BASE (phase 3) ----
#
# The Layer's own stack runs over the ground below its base row and writes only the cells it moved into that
# row (`bake_base`), keyed so an unchanged input skips it. Members then bake over it. See "Stage 1" below.
#
# ---- IDENTITY AND MEMBERSHIP ----
#
# Members bake exactly as brushes sharing a free layer always have — the
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
	_ready_flip_check()
	_connect_region_signal()


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


func _supports_modifiers() -> bool:
	return true


## ---- Stage 1: the base (§6.1, phase 3) ------------------------------------------------------------------

## Append only: the int is stored.
enum ExtentMode { WHOLE_TERRAIN, CHILDREN_FOOTPRINTS, WHOLE_REGION }

## Where the Layer's stack runs. Whole Terrain: every region. Children Footprints: the members' outlines,
## feathered over Modifier Margin. In Whole Terrain mode no member edit ever re-solves the base.
@export var extent_mode: ExtentMode = ExtentMode.WHOLE_TERRAIN:
	set(v):
		if extent_mode == v:
			return
		extent_mode = v
		notify_property_list_changed()
		_schedule_refresh()

## The key the base row was last solved under (§6.2). Stored, so a reload skips stage 1 until something changes.
@export_storage var _base_key: String = ""
## The extent the base row was last written over, so the next solve clears it even when the extent shrinks.
@export_storage var _base_box: AABB = AABB()

## Stage 1 solves since this node was created. Gates count re-solves with it; not persisted.
var base_solve_count: int = 0
## "solve", "skip" or "clear" for the last `bake_base`.
var last_base_decision: String = ""
## Cells the last solve held in the base row (moved by at least MODIFIER_MARGIN_EPS).
var base_cell_count: int = 0
## Test hook for LB-A's control: hold every cell the stack produced, not only the moved ones.
var hold_every_cell: bool = false
## Test hook for LB-K's control: key without the below digest.
var key_without_below: bool = false
## Test hook for LB-G's control: run the first-member flip on load as well.
var flip_on_load: bool = false
## Test hook for LB-H's control: build the Footprints profile from member AABBs, not outlines.
var profile_from_aabbs: bool = false


## ---- Whole Region (§7.1, §7.5, phase 3b) ---------------------------------------------------------------

## Region grid coordinates the stack runs over in Whole Region mode. Sorted and de-duplicated on assign.
## Entries naming no existing region stay listed, are ignored, and are named in the configuration warnings.
@export var selected_regions: Array[Vector2i] = []:
	set(v):
		_selection_raw = v.duplicate()
		var seen := {}
		var out: Array[Vector2i] = []
		for r: Vector2i in v:
			if not seen.has(r):
				seen[r] = true
				out.append(r)
		out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
		if out == selected_regions:
			return
		selected_regions = out
		update_configuration_warnings()
		_update_region_overlay()
		if extent_mode == ExtentMode.WHOLE_REGION:
			_schedule_refresh()

## Selected regions the REGION tool removed, so undoing that removal re-selects them (D12). Stored, because the
## undo can come after a save.
@export_storage var _dropped_regions: Array[Vector2i] = []

## Click a region in the viewport to toggle it; drag to paint. Esc or deselecting the node exits.
@export_tool_button("Select Regions") var _select_regions_btn = toggle_select_regions

## True while the viewport Select Regions interaction is active. Not stored.
var select_regions_active: bool = false
signal select_regions_toggled(active: bool)

## The list as assigned, before sorting. Only LB-M's control keys on it.
var _selection_raw: Array = []
var _overlay_selected: bool = false
var _overlay: MeshInstance3D = null
## Test hooks: LB-M key on the unsorted list, LB-M flip from any mode, LB-N profile 1 over the whole extent,
## LB-O never restore a dropped region.
var key_unsorted_selection: bool = false
var flip_any_mode: bool = false
var profile_full_extent: bool = false
var no_dropped_restore: bool = false


func _region_world() -> float:
	return float(terrain.region_size) * terrain.vertex_spacing


## The selected regions that exist, sorted.
func _valid_selection() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if not is_instance_valid(terrain) or terrain.data == null:
		return out
	var locs := {}
	for l: Vector2i in terrain.data.region_locations:
		locs[l] = true
	for r in selected_regions:
		if locs.has(r):
			out.append(r)
	return out


## §7.2 Whole Region: 1 inside the selection, smoothstep 1 -> 0 over the margin outside it. The selection is a
## union of axis-aligned squares, so the distance is exact: no JFA, no approximation.
func _region_profile(p_inp: Dictionary) -> PackedFloat64Array:
	var gw: int = p_inp["gw"]
	var gh: int = p_inp["gh"]
	var vs: float = p_inp["vs"]
	var min_x: float = p_inp["min_x"]
	var min_z: float = p_inp["min_z"]
	var rsw := _region_world()
	var margin := _effective_modifier_margin()
	var sel := _valid_selection()
	var prof := PackedFloat64Array()
	prof.resize(gw * gh)
	for iz in range(gh):
		var z := min_z + iz * vs
		for ix in range(gw):
			var x := min_x + ix * vs
			var d := INF
			for loc in sel:
				# A region owns vertices [origin, origin + size - vs]; the next vertex is its neighbour's.
				var ax := loc.x * rsw
				var az := loc.y * rsw
				var dx := maxf(maxf(ax - x, x - (ax + rsw - vs)), 0.0)
				var dz := maxf(maxf(az - z, z - (az + rsw - vs)), 0.0)
				d = minf(d, sqrt(dx * dx + dz * dz))
				if d <= 0.0:
					break
			var t := 1.0 if d <= 0.0 else (0.0 if margin <= 0.0 else clampf(1.0 - d / margin, 0.0, 1.0))
			prof[iz * gw + ix] = t * t * (3.0 - 2.0 * t)
	return prof


func _connect_region_signal() -> void:
	if is_instance_valid(terrain) and terrain.data != null and not terrain.data.region_map_changed.is_connected(_on_region_map_changed):
		terrain.data.region_map_changed.connect(_on_region_map_changed)


## D12. A selected region that no longer exists is dropped with a warning and remembered; one that comes back
## (the REGION tool's undo) is re-selected. A plain property write, not an undo action of its own.
func _on_region_map_changed() -> void:
	if not is_instance_valid(terrain) or terrain.data == null:
		return
	var locs := {}
	for l: Vector2i in terrain.data.region_locations:
		locs[l] = true
	var keep: Array[Vector2i] = []
	var changed := false
	for r in selected_regions:
		if locs.has(r):
			keep.append(r)
		else:
			if not _dropped_regions.has(r):
				_dropped_regions.append(r)
			push_warning("Pasture3D Layer brush '%s': selected region %s was removed; dropped it from the selection." % [name, r])
			changed = true
	if not no_dropped_restore:
		var still: Array[Vector2i] = []
		for r in _dropped_regions:
			if locs.has(r):
				if not keep.has(r):
					keep.append(r)
					changed = true
			else:
				still.append(r)
		_dropped_regions = still
	if changed:
		selected_regions = keep


func toggle_select_regions() -> void:
	set_select_regions_active(not select_regions_active)


func set_select_regions_active(p_on: bool) -> void:
	if p_on == select_regions_active:
		return
	select_regions_active = p_on
	_update_region_overlay()
	select_regions_toggled.emit(p_on)


## The region tile under a world position, or null where there is no region. Never adds or removes one.
func region_at(p_world: Vector3) -> Variant:
	if not is_instance_valid(terrain) or terrain.data == null or not terrain.data.has_regionp(p_world):
		return null
	var rsw := _region_world()
	return Vector2i(floori(p_world.x / rsw), floori(p_world.z / rsw))


## The selection after painting `p_tiles` to `p_state` (on or off). Pure: assigning it is the caller's undo action.
func painted_selection(p_tiles: Array, p_state: bool) -> Array[Vector2i]:
	var out: Array[Vector2i] = selected_regions.duplicate()
	for t: Vector2i in p_tiles:
		if p_state and not out.has(t):
			out.append(t)
		elif not p_state:
			out.erase(t)
	return out


## ---- Overlay: an INTERNAL child, never saved, shown while the tool is active or the node is selected ----

func set_overlay_selected(p_on: bool) -> void:
	_overlay_selected = p_on
	_update_region_overlay()


func _update_region_overlay() -> void:
	show_region_overlay(selected_regions, null)


## Draw `p_selection` filled and `p_hover` outlined, draped over the surface.
func show_region_overlay(p_selection: Array, p_hover: Variant) -> void:
	var want := Engine.is_editor_hint() and is_inside_tree() and (select_regions_active or _overlay_selected) \
			and extent_mode == ExtentMode.WHOLE_REGION and is_instance_valid(terrain) and terrain.data != null
	if not want:
		if _overlay != null:
			_overlay.visible = false
		return
	if _overlay == null:
		_overlay = MeshInstance3D.new()
		_overlay.top_level = true
		_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.no_depth_test = true
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.vertex_color_use_as_albedo = true
		_overlay.material_override = mat
		add_child(_overlay, false, Node.INTERNAL_MODE_BACK)
	_overlay.global_transform = Transform3D.IDENTITY
	_overlay.visible = true
	var im := ImmediateMesh.new()
	var rsw := _region_world()
	const STEPS := 16
	var fill := Color(0.3, 0.7, 1.0, 0.25)
	if not p_selection.is_empty():
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		for loc: Vector2i in p_selection:
			var o := Vector2(loc.x * rsw, loc.y * rsw)
			var st := rsw / STEPS
			for j in range(STEPS):
				for i in range(STEPS):
					var a := _drape(o + Vector2(i, j) * st)
					var b := _drape(o + Vector2(i + 1, j) * st)
					var c := _drape(o + Vector2(i + 1, j + 1) * st)
					var d := _drape(o + Vector2(i, j + 1) * st)
					for p in [a, b, c, a, c, d]:
						im.surface_set_color(fill)
						im.surface_add_vertex(p)
		im.surface_end()
	if p_hover != null:
		var hv: Vector2i = p_hover
		var o := Vector2(hv.x * rsw, hv.y * rsw)
		var corners := [o, o + Vector2(rsw, 0), o + Vector2(rsw, rsw), o + Vector2(0, rsw), o]
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for k in range(4):
			for s in range(STEPS):
				im.surface_set_color(Color(1.0, 0.9, 0.2, 1.0))
				im.surface_add_vertex(_drape(corners[k].lerp(corners[k + 1], float(s) / STEPS)))
		im.surface_set_color(Color(1.0, 0.9, 0.2, 1.0))
		im.surface_add_vertex(_drape(o))
		im.surface_end()
	_overlay.mesh = im


func _drape(p_xz: Vector2) -> Vector3:
	var h: float = terrain.data.get_height(Vector3(p_xz.x, 0.0, p_xz.y))
	return Vector3(p_xz.x, (h if is_finite(h) else 0.0) + 0.5, p_xz.y)


## First member into an empty Whole Terrain Layer switches it to Children Footprints (D2). Only from Whole
## Terrain, only for the first, and only on a join: `_sync_layer_host` does not call this on load.
func _on_member_joined(_p_member: Node) -> void:
	var from_ok := extent_mode == ExtentMode.WHOLE_TERRAIN or (flip_any_mode and extent_mode != ExtentMode.CHILDREN_FOOTPRINTS)
	if from_ok and member_count() == 1:
		extent_mode = ExtentMode.CHILDREN_FOOTPRINTS


func _ready_flip_check() -> void:
	if flip_on_load and member_count() == 1:
		_on_member_joined(null)


## A Layer bake: stage 1, then every member through the shared-layer bake (which runs stage 1 again and
## finds the key matching). With no members the base still runs (D15).
func bake_layer(p_record_undo: bool = false) -> void:
	if not is_configured():
		return
	var mem := members()
	if not mem.is_empty():
		mem[0]._refresh_owner(layer_owner_id(), p_record_undo, [])
		return
	_clear_region_edited_flags()
	if bake_base():
		terrain.data.update_maps(PASTURE_3D_MAPTYPE_HEIGHT, false, false)


func refresh(record_undo: bool = false) -> void:
	if not Engine.is_editor_hint() or not is_configured():
		return
	bake_layer(record_undo)


## The refresh tick's non-painting branch lands here; a Layer brush has no graph consumers of its own.
func _refresh_consumers() -> void:
	bake_layer(false)


func base_is_stale() -> bool:
	var inp := _base_inputs()
	return not inp.is_empty() and inp["key"] != _base_key


## Run stage 1 when its key changed. True when the base row was rewritten.
func bake_base() -> bool:
	ensure_rows()
	_connect_region_signal()
	var inp := _base_inputs()
	if inp.is_empty():
		return false
	if inp["key"] == _base_key:
		last_base_decision = "skip"
		return false
	var row: int = inp["row"]
	var box: AABB = inp["box"]
	var clear := _base_box
	if box.size.x > 0.0 and box.size.z > 0.0:
		clear = box if clear.size == Vector3.ZERO else clear.merge(box)
	if clear.size != Vector3.ZERO:
		terrain.data.clear_layer_in_area(row, clear, false)
	_base_box = box if box.size.x > 0.0 and box.size.z > 0.0 else AABB()
	_base_key = inp["key"]
	base_cell_count = 0
	if not inp.has("below"):
		last_base_decision = "clear"
	else:
		last_base_decision = "solve"
		base_solve_count += 1
		_solve_base(inp)
	if clear.size != Vector3.ZERO:
		terrain.data.composite_area(clear, false)
	return true


func _solve_base(p_inp: Dictionary) -> void:
	var gw: int = p_inp["gw"]
	var gh: int = p_inp["gh"]
	var n := gw * gh
	var below: PackedFloat32Array = p_inp["below"]
	var stack: Dictionary = p_inp["stack"]
	var amp := PackedFloat64Array()
	amp.resize(n)
	amp.fill(0.0)
	var params := {"min_x": p_inp["min_x"], "min_z": p_inp["min_z"], "vs": p_inp["vs"], "gw": gw, "gh": gh,
			"blend": BLEND_REPLACE, "modifiers": stack["list"], "op_selectors": stack["op_selectors"],
			"need_fields": stack["need_fields"], "need_host_fields": false, "base_below": below}
	var result: PackedFloat32Array = terrain.data.brush_run_stack_on_field(params, below, amp, _base_profile(p_inp))
	# NaN below epsilon (§6.1): the base is absolute REPLACE, so a held cell freezes the ground beneath it.
	var vals := PackedFloat32Array()
	vals.resize(n)
	for i in range(n):
		var r := result[i] if i < result.size() else NAN
		if is_nan(r) or is_nan(below[i]) or (not hold_every_cell and absf(r - below[i]) < MODIFIER_MARGIN_EPS):
			vals[i] = NAN
		else:
			vals[i] = r
			base_cell_count += 1
	if base_cell_count > 0:
		terrain.data.stamp_grid(int(p_inp["row"]), vals, p_inp["min_x"], p_inp["min_z"], p_inp["vs"], gw, gh, BLEND_REPLACE)
	_commit_modifier_caches(stack, p_inp["extent"])


## Everything stage 1 is a function of, and its key (§6.2). Empty when the rows are not there.
func _base_inputs() -> Dictionary:
	var stack := _stack()
	if stack == null:
		return {}
	var row: int = stack.find_layer_by_owner(base_owner_id())
	if row < 0:
		return {}
	var vs: float = terrain.vertex_spacing
	var box := _base_extent(row)
	var inp := {"row": row, "vs": vs, "box": box}
	var h := HashingContext.new()
	h.start(HashingContext.HASH_MD5)
	h.update(("%d|%s" % [extent_mode, str(_modifier_signature())]).to_utf8_buffer())
	if extent_mode == ExtentMode.WHOLE_REGION:
		# The SORTED valid selection (§7.1): a reordered list is the same base.
		h.update(str(_selection_raw if key_unsorted_selection else _valid_selection()).to_utf8_buffer())
	if box.size.x > 0.0 and box.size.z > 0.0:
		var gw := roundi(box.size.x / vs)
		var gh := roundi(box.size.z / vs)
		inp["min_x"] = box.position.x
		inp["min_z"] = box.position.z
		inp["gw"] = gw
		inp["gh"] = gh
		inp["extent"] = _extent_key(box.position.x, box.position.z, vs, gw, gh)
		h.update(str(inp["extent"]).to_utf8_buffer())
		var comp := _compile_modifiers(inp["extent"])
		if int(comp["count"]) > 0:
			inp["stack"] = comp
			var below: PackedFloat32Array = terrain.data.composite_height_below(row, box.position.x, box.position.z, vs, gw, gh)
			inp["below"] = below
			if not key_without_below:
				h.update(below.to_byte_array())
			if extent_mode == ExtentMode.CHILDREN_FOOTPRINTS:
				var paths := _member_paths()
				inp["paths"] = paths
				for p: Pasture3DGraphPath in paths:
					h.update(("%s|%s" % [p.source_label, p.closed]).to_utf8_buffer())
					h.update(p.points.to_byte_array())
	inp["key"] = h.finish().hex_encode()
	return inp


## §7.1. The union of every region, of the members' footprints ⊕ margin, or of the selected regions ⊕ margin.
func _base_extent(p_row: int) -> AABB:
	var out := AABB()
	match extent_mode:
		ExtentMode.WHOLE_REGION:
			var rsw: float = float(terrain.region_size) * terrain.vertex_spacing
			for loc: Vector2i in _valid_selection():
				var r := AABB(Vector3(loc.x * rsw, 0.0, loc.y * rsw), Vector3(rsw, 0.0, rsw))
				out = r if out.size == Vector3.ZERO else out.merge(r)
			# The margin may cross into unselected or missing neighbours; missing ones read NaN below.
			if out.size != Vector3.ZERO:
				out = _snap_aabb_to_tiles(out.grow(_effective_modifier_margin()), _layer_tile_world(p_row))
		ExtentMode.WHOLE_TERRAIN:
			var rs: float = float(terrain.region_size) * terrain.vertex_spacing
			for loc: Vector2i in terrain.data.region_locations:
				var r := AABB(Vector3(loc.x * rs, 0.0, loc.y * rs), Vector3(rs, 0.0, rs))
				out = r if out.size == Vector3.ZERO else out.merge(r)
		ExtentMode.CHILDREN_FOOTPRINTS:
			for mbr in members():
				for fp: AABB in mbr._own_footprints():
					if fp.size != Vector3.ZERO:
						out = fp if out.size == Vector3.ZERO else out.merge(fp)
			if out.size != Vector3.ZERO:
				out = _snap_aabb_to_tiles(out.grow(_effective_modifier_margin()), _layer_tile_world(p_row))
	return out


func _member_paths() -> Array:
	var out: Array = []
	for mbr in members():
		for i in range(mbr.graph_shape_count()):
			var p: Pasture3DGraphPath = mbr.graph_shape_path(i)
			if p.points.size() >= 2:
				out.append(p)
	return out


## §7.2. Whole Terrain: 1. Children Footprints: 1 inside the outline union, smoothstep 1 -> 0 over the margin,
## through the same path mask kernel the graph's shape nodes use.
func _base_profile(p_inp: Dictionary) -> PackedFloat64Array:
	var gw: int = p_inp["gw"]
	var gh: int = p_inp["gh"]
	var n := gw * gh
	var prof := PackedFloat64Array()
	prof.resize(n)
	var vs: float = p_inp["vs"]
	var min_x: float = p_inp["min_x"]
	var min_z: float = p_inp["min_z"]
	if extent_mode == ExtentMode.WHOLE_TERRAIN or profile_full_extent:
		prof.fill(1.0)
		return prof
	if extent_mode == ExtentMode.WHOLE_REGION:
		return _region_profile(p_inp)
	prof.fill(0.0)
	# Cell centres of this rect land on the grid's vertices.
	var rect := Rect2(min_x - vs * 0.5, min_z - vs * 0.5, gw * vs, gh * vs)
	var margin := _effective_modifier_margin()
	if profile_from_aabbs:
		for mbr in members():
			for fp: AABB in mbr._own_footprints():
				for iz in range(gh):
					for ix in range(gw):
						var x := min_x + ix * vs
						var z := min_z + iz * vs
						if x >= fp.position.x and x <= fp.end.x and z >= fp.position.z and z <= fp.end.z:
							prof[iz * gw + ix] = 1.0
		return prof
	for p: Pasture3DGraphPath in p_inp.get("paths", []):
		var m: PackedFloat32Array = Pasture3DUtil.path_mask_grid(p.points, p.half_widths, p.closed, gw, gh, rect, 1.0, margin, false)
		for i in range(mini(n, m.size())):
			if m[i] > prof[i]:
				prof[i] = m[i]
	for i in range(n):
		var t := prof[i]
		prof[i] = t * t * (3.0 - 2.0 * t)
	return prof


const _HIDDEN_BRUSH_PROPERTIES: Array[StringName] = [
	&"corner_radius", &"crease_smoothing", &"snap_to_surface", &"surface_offset", &"_snap_btn",
	&"_add_spline_btn", &"_add_water_btn", &"_add_layer_btn", &"_toggle_tangents_btn", &"_make_unique_btn",
	&"force_gdscript_raster", &"log_bake_timing",
]


func _validate_property(property: Dictionary) -> void:
	super._validate_property(property)
	if StringName(property.name) in _HIDDEN_BRUSH_PROPERTIES:
		property.usage &= ~PROPERTY_USAGE_EDITOR
	# Whole Terrain has nothing beyond it to skirt into (§7.1).
	if property.name == "modifier_margin" and extent_mode == ExtentMode.WHOLE_TERRAIN:
		property.usage &= ~PROPERTY_USAGE_EDITOR
	if property.name in ["selected_regions", "_select_regions_btn"] and extent_mode != ExtentMode.WHOLE_REGION:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func _get_configuration_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if not is_instance_valid(terrain):
		w.append("Place this Layer brush under a Pasture3D terrain (or assign one) so it has a layer to own.")
	elif terrain.data == null or terrain.data.region_locations.size() == 0:
		w.append("The Pasture3D terrain has no regions yet — add regions in Pasture3D first.")
	for v in _violations:
		w.append("Refused: %s" % v["message"])
	if extent_mode == ExtentMode.WHOLE_REGION and is_instance_valid(terrain) and terrain.data != null:
		var valid := _valid_selection()
		if valid.is_empty():
			w.append("Whole Region mode with no regions selected: the stack does not run. Use Select Regions.")
		for r in selected_regions:
			if not valid.has(r):
				w.append("Selected region %s does not exist and is ignored." % r)
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
