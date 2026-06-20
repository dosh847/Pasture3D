# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DTerrainBrush — shared base for the spline-driven landscape brushes
# (Pasture3DMound / Pasture3DRidge / Pasture3DTrough). See PASTURE3D_LANDSCAPE_TOOLS_SPEC.md and
# PASTURE3D_TOOL_LAYER_ASSIGNMENT_SPEC.md.
#
# A brush node paints N child Path3D splines into ONE reserved, non-destructive height layer. Tools
# bind to a layer BY NAME: the layer owner_id is "pasture3d_brush:<name>", so two tools that target
# the same name share one layer automatically (create_owned_layer is idempotent by owner). A refresh
# is layer-granular — it repaints every tool bound to the layer — so co-located tools survive each
# other's edits, and re-running is idempotent. Binding is by owner_id, so renaming the layer in the
# Layers dock never breaks the tools pointing at it (the inspector dropdown shows the live name).
#
# GDScript-only: it calls the already-bound C++ Tool API (create_owned_layer / set_height_on_layer /
# add_height_on_layer / clear_layer_in_area / composite_region / update_maps), so no engine rebuild is
# required. On a build without that API it falls back to destructive set_height (works, not idempotent).
@tool
class_name Pasture3DTerrainBrush
extends Node3D

## Map type / blend-mode indices, matching Pasture3DData.MapType and Pasture3DLayer.BlendMode.
## Hardcoded as ints so this script does not hard-depend on the enum bindings.
const PASTURE_3D_MAPTYPE_HEIGHT: int = 0  # Pasture3DData.MapType.TYPE_HEIGHT
const PASTURE_3D_MAPTYPE_CONTROL: int = 1 # Pasture3DData.MapType.TYPE_CONTROL
const PASTURE_3D_MAPTYPE_COLOR: int = 2   # Pasture3DData.MapType.TYPE_COLOR
const BLEND_REPLACE: int = 0 # Pasture3DLayer.BlendMode.REPLACE
const BLEND_ADD: int = 1     # Pasture3DLayer.BlendMode.ADD
const BLEND_MAX: int = 2     # Pasture3DLayer.BlendMode.MAX
const BLEND_MIN: int = 3     # Pasture3DLayer.BlendMode.MIN

## owner_id namespace marking a layer as a brush tool layer (vs hand layers / road-connector layers).
const BRUSH_OWNER_PREFIX: String = "pasture3d_brush:"
## Group every brush node joins so siblings can find each other for layer-granular refresh.
const BRUSH_GROUP: StringName = &"pasture3d_brush"

# Debounce for auto-refresh while dragging spline handles (seconds).
const REFRESH_DELAY: float = 0.1

## The Pasture3D terrain this brush paints into.
@export var terrain: Pasture3D:
	set(value):
		# Leaving a terrain (reparent or an inspector re-assignment): lift our contribution off the old
		# one first — otherwise our baked footprint is stranded on it. `terrain` still holds the old
		# value here, so the detach resolves the old terrain's layer.
		if Engine.is_editor_hint() and value != terrain and is_instance_valid(terrain) and terrain.data != null:
			_detach_from_current()
		terrain = value
		update_configuration_warnings()
		# Rebuild dynamic property hints (e.g. the material/texture dropdown) now that a terrain — and
		# thus its texture list — is known, so they populate without needing to reselect the node.
		notify_property_list_changed()
		_schedule_refresh()

## Re-paint automatically while editing the splines / moving the node.
@export var auto_refresh: bool = true

@export_tool_button("Refresh") var _refresh_btn = _refresh_button
@export_tool_button("Add Spline") var _add_spline_btn = add_spline
## Create a brand-new tool layer named after this node and assign this node to it.
@export_tool_button("Add New Layer") var _add_layer_btn = add_new_layer

@export_group("Surface")
## Keep this brush's spline points glued to the terrain surface while editing (their Y follows the
## ground). Leave off for free vertical control. See PASTURE3D_SPLINE_SURFACE_SNAP_SPEC.md.
@export var snap_to_surface: bool = false:
	set(v):
		snap_to_surface = v
		_schedule_refresh()
## Metres above the surface to sit the snapped points at (0 = on the surface).
@export var surface_offset: float = 0.0:
	set(v):
		surface_offset = v
		if snap_to_surface:
			_schedule_refresh()
## Drop every spline point onto the terrain once, now (works whether or not snap_to_surface is on).
@export_tool_button("Snap Points to Surface") var _snap_btn = snap_points_to_surface

## Stable binding to a tool layer = its owner_id ("pasture3d_brush:<name>"). Persisted (hidden); shown
## in the inspector via the `tool_layer` dropdown (which displays the layer's live name). Empty until
## _ready defaults it to the subclass layer name, so a fresh tool auto-attaches to e.g. "Mounds".
var _layer_owner: String = ""

var _layer_id: int = -1               # Reserved layer index for the current paint; -1 = destructive fallback
var _blend: int = BLEND_REPLACE       # Blend mode used by _paint_height for the current paint
var _last_paint_aabb: Dictionary = {} # spline instance_id -> world AABB last painted (idempotent clear)
var _timer: SceneTreeTimer = null
var _dirty: bool = false
var _full_dirty: bool = false   # A queued refresh needs the whole layer (param/transform/structural change)
var _dirty_splines: Dictionary = {} # Path3D instance_id -> true: splines whose curve changed (partial redraw)
var _clip_aabb: AABB = AABB()   # When non-empty, _paint_* writes only cells inside this world box (dirty-rect)
var _curve_cache: Dictionary = {}   # spline instance_id -> PackedVector3Array of point positions at last bake
var _suspend_auto: bool = false # Blocks auto-refresh while we mutate curves programmatically (undo)
var _ready_done: bool = false   # True once _ready ran — gates re-parent auto-assign off scene-load


func _ready() -> void:
	if _layer_owner == "":
		_layer_owner = BRUSH_OWNER_PREFIX + _default_layer_name()
	add_to_group(BRUSH_GROUP)
	set_notify_transform(true)
	if not child_entered_tree.is_connected(_on_child_changed):
		child_entered_tree.connect(_on_child_changed)
	if not child_exiting_tree.is_connected(_on_child_changed):
		child_exiting_tree.connect(_on_child_changed)
	for s in _get_splines():
		_connect_spline(s)
	# Convenience: when a brush is first added under a Pasture3D (at any depth), auto-target it — but
	# never clobber a terrain the user picked, and only in the editor.
	if Engine.is_editor_hint() and terrain == null:
		var anc := _terrain_ancestor()
		if anc != null:
			terrain = anc
	# Baseline the footprint cache to the loaded poses (without painting) so the first edit of the
	# session clears where a spline WAS, not just where it ends up — no stale flattening trail.
	_seed_cache()
	_ready_done = true
	# A freshly added/duplicated brush may have made an existing brush's curve newly shared — refresh all.
	_refresh_group_warnings()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_schedule_refresh()
	elif what == NOTIFICATION_ENTER_TREE:
		# Re-join the group on every enter (a reparent exits + re-enters the tree, and _ready only runs
		# once) so layer-sharing keeps seeing this brush after it has been moved.
		add_to_group(BRUSH_GROUP)
	elif what == NOTIFICATION_EXIT_TREE:
		remove_from_group(BRUSH_GROUP)
	elif what == NOTIFICATION_PARENTED:
		# Re-parented under a different terrain after creation → follow it. Deferred so the reparent has
		# fully settled (node back in the tree) before we detach/rebind. _ready_done gates this so it
		# never fires during initial scene load (PARENTED precedes _ready then).
		if Engine.is_editor_hint() and _ready_done:
			_auto_assign_terrain.call_deferred()


## Follow a reparent: bind to the nearest Pasture3D ancestor (the setter detaches from the old one).
## Moving the brush out from under any terrain leaves its current target as-is rather than clearing it.
func _auto_assign_terrain() -> void:
	if not Engine.is_editor_hint() or not _ready_done or not is_inside_tree():
		return
	var anc := _terrain_ancestor()
	if anc != null and terrain != anc:
		terrain = anc


## Nearest Pasture3D ancestor (direct parent first), or null. Drives the auto-terrain assignment.
func _terrain_ancestor() -> Pasture3D:
	var n := get_parent()
	while n != null:
		if n is Pasture3D:
			return n
		n = n.get_parent()
	return null


## Lift our contribution off the CURRENT terrain's tool layer, repainting any layer-mates so we don't
## punch a hole in their overlapping footprints. Used before switching terrains. Excludes self from the
## repaint by blanking _layer_owner for the duration (mirrors how _rebind excludes a departing tool).
func _detach_from_current() -> void:
	if not is_configured() or not is_inside_tree():
		return
	var saved_owner := _layer_owner
	_layer_owner = ""
	_refresh_owner(saved_owner, false, _own_footprints())
	_layer_owner = saved_owner
	_last_paint_aabb.clear()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = []
	if not is_instance_valid(terrain):
		warnings.append("Assign a Pasture3D terrain for this brush to paint into.")
	elif not terrain.data or terrain.data.region_locations.size() == 0:
		warnings.append("The Pasture3D terrain has no regions yet — add regions in Pasture3D first.")
	if _get_splines().is_empty():
		warnings.append("Add at least one spline (press Add Spline, or add a Path3D child).")
	var shared := _shared_curve_spline_names()
	if not shared.is_empty():
		warnings.append(("These splines share a Curve3D with another spline, so editing one edits "
			+ "(and re-bakes) them all: %s. Select each Path3D and use the Curve property's dropdown "
			+ "→ Make Unique.") % ", ".join(shared))
	return warnings


## Names of this brush's child splines whose Curve3D is also referenced by another spline anywhere in the
## scene's brushes. Duplicating a brush copies the child Path3D but SHARES its Curve3D by reference, so a
## single edit drives every clone's bake — a silent performance trap. Counts curve instances across every
## brush in the group, then flags ours that appear more than once.
func _shared_curve_spline_names() -> PackedStringArray:
	var out := PackedStringArray()
	if not is_inside_tree():
		return out
	var counts := {}
	for n in get_tree().get_nodes_in_group(BRUSH_GROUP):
		if n is Pasture3DTerrainBrush:
			for s in n._get_splines():
				if s.curve != null:
					var id: int = s.curve.get_instance_id()
					counts[id] = int(counts.get(id, 0)) + 1
	for s in _get_splines():
		if s.curve != null and int(counts.get(s.curve.get_instance_id(), 0)) > 1:
			out.append(String(s.name))
	return out


func is_configured() -> bool:
	return is_instance_valid(terrain) and terrain.data != null


## Splines = direct Path3D children. (A NodePath-list override could be added later.)
func _get_splines() -> Array:
	var out: Array = []
	for c in get_children():
		if c is Path3D:
			out.append(c)
	return out


func _connect_spline(path: Path3D) -> void:
	# React to the Path3D swapping its Curve3D resource itself (Make Unique / assigning a new curve) so we
	# rebind to the new curve and the shared-curve warning re-evaluates. Idempotent (bound Callable compares
	# equal). Connected even when curve is null so a later assignment is caught.
	var pc := _on_path_curve_changed.bind(path)
	if not path.curve_changed.is_connected(pc):
		path.curve_changed.connect(pc)
	if path.curve == null:
		return
	# Bind the owning Path3D so a curve edit schedules a per-spline (dirty-rect) redraw, not a whole-layer
	# one. The bound Callable compares equal across calls (same method + bind), so this stays idempotent.
	var cb := _schedule_spline_refresh.bind(path)
	if not path.curve.changed.is_connected(cb):
		path.curve.changed.connect(cb)


## The Path3D swapped its Curve3D resource (e.g. Make Unique). Rebind to the new curve's change signal,
## re-evaluate the shared-curve warnings across all brushes, and re-bake so the swap takes effect.
func _on_path_curve_changed(path: Path3D) -> void:
	if not is_instance_valid(path):
		return
	_connect_spline(path)
	_refresh_group_warnings()
	_schedule_spline_refresh(path)


func _on_child_changed(node: Node) -> void:
	if node is Path3D:
		_connect_spline(node)
	# Broadcast, not just self: adding/removing a spline can make another brush's curve newly (non-)shared.
	_refresh_group_warnings()
	_schedule_refresh()


## Ask every brush in the scene to re-evaluate its configuration warnings, so the shared-curve warning
## appears/clears on ALL affected brushes at once (e.g. both the duplicate and its original) rather than
## only the one being edited. No-op outside the editor.
func _refresh_group_warnings() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	for n in get_tree().get_nodes_in_group(BRUSH_GROUP):
		if n is Pasture3DTerrainBrush:
			n.update_configuration_warnings()


## ---- Inspector: the tool-layer dropdown (bind by owner_id, display live name) ----

func _get_property_list() -> Array:
	var props: Array = []
	# The real binding: persisted, hidden from the inspector (shown via `tool_layer`).
	props.append({"name": "_layer_owner", "type": TYPE_STRING, "usage": PROPERTY_USAGE_STORAGE})
	props.append({"name": "Layer", "type": TYPE_NIL, "usage": PROPERTY_USAGE_GROUP, "hint_string": ""})
	var names := _brush_layer_names()
	var cur := _layer_display_name()
	if not names.has(cur):
		names.append(cur)
	props.append({
		"name": "tool_layer",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": ",".join(names),
		"usage": PROPERTY_USAGE_EDITOR,
	})
	return props


func _get(property: StringName) -> Variant:
	if property == &"tool_layer":
		return _layer_display_name()
	return null


func _set(property: StringName, value: Variant) -> bool:
	if property == &"tool_layer":
		_assign_layer_by_name(str(value))
		return true
	return false


## Point this tool at the brush layer whose live name is `display_name` (or a new owner for that name).
func _assign_layer_by_name(display_name: String) -> void:
	var owner := _owner_for_layer_name(display_name)
	if owner == "":
		owner = BRUSH_OWNER_PREFIX + display_name
	_set_layer_owner(owner)


## Create a new tool layer named after this node and assign this node to it (de-duplicated so it is
## always a fresh layer rather than silently joining an existing same-named one).
func add_new_layer() -> void:
	_set_layer_owner(BRUSH_OWNER_PREFIX + _unique_brush_layer_name(name))


## Re-bind to a different tool layer: lift our contribution off the old layer, then bake into the new.
func _set_layer_owner(owner: String) -> void:
	if owner == _layer_owner:
		return
	var old := _layer_owner
	_layer_owner = owner
	notify_property_list_changed()
	update_configuration_warnings()
	if Engine.is_editor_hint() and is_inside_tree() and is_configured():
		_rebind(old)


func _rebind(old_owner: String) -> void:
	# Clear our footprint off the OLD layer (we're no longer one of its tools) and repaint whoever is
	# left on it, then bake into the new layer.
	if old_owner != "":
		_refresh_owner(old_owner, false, _own_footprints())
	_last_paint_aabb.clear()
	refresh()


## ---- Refresh scheduling (debounced; defers while a handle is being dragged) ----

## True when auto-refresh may queue work: not mid-programmatic-edit, enabled, in the editor and tree.
func _can_auto_refresh() -> bool:
	return not _suspend_auto and auto_refresh and Engine.is_editor_hint() and is_inside_tree()


## Whole-layer refresh scheduler — for param / transform / structural changes (anything that isn't a
## single spline's curve edit). Marks the queued bake as needing a full repaint.
func _schedule_refresh() -> void:
	if not _can_auto_refresh():
		return
	_full_dirty = true
	_arm_refresh_timer()


## Per-spline scheduler — a single child curve changed, so only its footprint needs reworking. Records
## which spline moved; the bake takes the dirty-rect path unless a full refresh was also queued.
func _schedule_spline_refresh(path: Path3D) -> void:
	if not _can_auto_refresh():
		return
	if is_instance_valid(path):
		_dirty_splines[path.get_instance_id()] = true
	_arm_refresh_timer()


func _arm_refresh_timer() -> void:
	_dirty = true
	if is_instance_valid(_timer):
		return
	_timer = get_tree().create_timer(REFRESH_DELAY)
	_timer.timeout.connect(_on_refresh_timer)


func _on_refresh_timer() -> void:
	_timer = null
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		# Still dragging — repaint once on release rather than every frame (keep accumulated dirty state).
		_arm_refresh_timer()
		return
	if not _dirty:
		return
	_dirty = false
	# Snapshot + clear the queued dirty state up front so a refresh that re-enters scheduling is coherent.
	var full := _full_dirty
	var splines := _dirty_splines
	_full_dirty = false
	_dirty_splines = {}
	if not Engine.is_editor_hint() or not is_configured():
		return
	if full or splines.is_empty():
		_refresh_owner(_layer_owner, false, [])
	else:
		_refresh_owner_rect(_layer_owner, splines)


## ---- The paint cycle (layer-granular: repaint every tool bound to the layer) ----

## The Refresh button. Records an undoable action so Ctrl+Z reverts the bake — needed for the
## auto_refresh-off / manual-bake workflow (and harmless when auto_refresh is on). Auto-refresh and
## property-driven repaints DON'T record their own action: their undoable cause (the spline gizmo edit
## or the inspector property change) re-triggers auto-refresh on undo, so the terrain follows.
func _refresh_button() -> void:
	refresh(true)


func refresh(record_undo: bool = false) -> void:
	if not Engine.is_editor_hint() or not is_configured():
		return
	_refresh_owner(_layer_owner, record_undo, [])


## Refresh a whole tool layer: clear every bound tool's footprints (+ any extras), repaint every bound
## tool's splines, then one GPU push. Sharing means editing one tool must repaint its layer-mates so an
## overlapping mate isn't left wiped (the road-connector partial-refresh hazard); with the O(cells)
## rasteriser each bake is cheap. `extra_clears` lets a rebind also drop a departing tool's footprint.
func _refresh_owner(owner: String, record_undo: bool, extra_clears: Array) -> void:
	if not is_configured():
		return
	var sibs := _tools_on_owner(owner)
	var layer_id := _ensure_layer_for(owner, owner == _layer_owner)
	var can_undo := record_undo and _layers_api_available() and layer_id >= 0
	var ur: EditorUndoRedoManager = _editor_undo() if can_undo else null
	var before: Dictionary = _snapshot_owner(owner) if (ur != null) else {}

	if layer_id >= 0:
		var blend := _layer_blend_for(layer_id)
		for box: AABB in extra_clears:
			if box.size != Vector3.ZERO:
				terrain.data.clear_layer_in_area(layer_id, box)
		for s in sibs:
			for box: AABB in s._own_footprints():
				if box.size != Vector3.ZERO:
					terrain.data.clear_layer_in_area(layer_id, box)
			s._last_paint_aabb.clear()
		# (B) Snap AFTER the clear: with this tool's influence removed and the region recomposited,
		# get_height reads the BASE the points should sit on — not the tool's own ridge — so points
		# can't climb their own contribution on each refresh. Snapping moves Y only, so the footprints
		# just cleared (XZ) stay valid, and unchanged points are skipped (idempotent).
		for s in sibs:
			if s.snap_to_surface:
				s._apply_surface_snap()
		for s in sibs:
			s._paint_into(layer_id, blend)
	else:
		# Fallback: no layers Tool API → destructive writes (no own-layer to clear). Snap against the
		# live surface as a best effort; the non-destructive path above is the supported one.
		for s in sibs:
			if s.snap_to_surface:
				s._apply_surface_snap()
		for s in sibs:
			s._paint_into(-1, _get_blend_mode())

	terrain.data.update_maps(_map_type())

	if ur != null:
		var after := _snapshot_owner(owner)
		ur.create_action("Pasture3D %s Bake" % _spline_basename())
		ur.add_do_method(self, "_restore_owner", owner, after)
		ur.add_undo_method(self, "_restore_owner", owner, before)
		ur.commit_action(false)


## Dirty-rect refresh (Stage 1 partial redraw): one or more of THIS node's splines moved. Rework only the
## box they touched instead of the whole layer. The box = ∪ of each changed spline's previous∪current
## footprint; we clear just that box, then repaint every tool on the layer whose footprint intersects it,
## with each paint CLIPPED to the box. Tools/splines outside the box are untouched. Repainting overlapping
## layer-mates inside the box (not just the moved spline) is what keeps shared cells correct — the same
## reason the full refresh repaints mates. Auto-refresh only (no undo action; the gizmo edit is the
## undoable cause). Falls back to a full refresh when there's no layers Tool API or nothing locatable.
func _refresh_owner_rect(owner: String, changed_ids: Dictionary) -> void:
	if not is_configured():
		return
	var layer_id := _ensure_layer_for(owner, owner == _layer_owner)
	if layer_id < 0:
		# Destructive fallback has no per-area clear — the whole-layer path is the only correct option.
		_refresh_owner(owner, false, [])
		return

	# Union the previous (cached) and current footprint of every changed spline into one world box.
	var dirty := AABB()
	var have := false
	for sid in changed_ids:
		var path := _find_spline_by_id(sid)
		if path != null:
			var curr := _spline_footprint_aabb(path)
			if curr.size != Vector3.ZERO:
				dirty = curr if not have else dirty.merge(curr)
				have = true
		if _last_paint_aabb.has(sid):
			var prev: AABB = _last_paint_aabb[sid]
			if prev.size != Vector3.ZERO:
				dirty = prev if not have else dirty.merge(prev)
				have = true
	if not have:
		# Splines vanished (e.g. removed) — let the full path reconcile the layer.
		_refresh_owner(owner, false, [])
		return

	# CRITICAL: clear_layer_in_area drops WHOLE tiles (tile_size verts) that the box touches, so the area
	# actually cleared is the box grown out to tile boundaries — larger than `dirty`. Clip the repaint to
	# that SAME grown box, or a neighbour's samples in a dropped tile outside `dirty` are erased and never
	# repainted (the far-away "cut"). Tile boundaries sit at world multiples of tile_size * vertex_spacing.
	var clip_box := _snap_aabb_to_tiles(dirty, _layer_tile_world(layer_id))

	var blend := _layer_blend_for(layer_id)
	# Start from a clean edited-flag slate so the targeted update_maps below uploads EXACTLY the regions
	# this bake touches. composite_region sets is_edited but update_maps never clears it, so without this
	# every later partial would re-push every region edited this session (the far-spline slowdown).
	_clear_region_edited_flags()
	terrain.data.clear_layer_in_area(layer_id, clip_box)
	# Re-seat ONLY the points the user actually moved, against the freshly-cleared base inside the box.
	# Snapping every point here is the snap-to-self regression: an unmoved point elsewhere reads terrain
	# the box clear didn't touch (its own ridge) and climbs. A whole-spline / node move instead takes the
	# full-refresh path, which clears everything first and re-snaps all points. Snap is world-Y only, so
	# the XZ box just cleared stays valid.
	if snap_to_surface:
		for sid in changed_ids:
			var sp := _find_spline_by_id(sid)
			if sp != null:
				_apply_surface_snap_points(sp, _moved_point_indices(sp))
	for s in _tools_on_owner(owner):
		if not s._overlaps_box(clip_box):
			continue
		s._clip_aabb = clip_box
		s._paint_into(layer_id, blend)
		s._clip_aabb = AABB()
	# Remember the (possibly snapped) point layout so the next edit only re-snaps what changes again.
	for sid in changed_ids:
		var cp := _find_spline_by_id(sid)
		if cp != null:
			_update_curve_cache(cp)
	# Push only the regions this bake actually edited. (The bound default is all_regions=TRUE, which
	# rebuilds the whole height texture array from every region — the reason a far-away spline was slow.)
	terrain.data.update_maps(_map_type(), false, false)


## Clear the per-region "edited" GPU-push flag on every active region. update_maps(all_regions=false)
## pushes flagged regions but doesn't reset the flag, so the dirty-rect bake clears the slate first and
## lets its own clear/paint re-flag exactly what it touched. Safe to clear globally: the brush's undo uses
## layer-tile snapshots (not this flag), and the editor's sculpt brush sets+clears it within one operation.
func _clear_region_edited_flags() -> void:
	if not terrain or not terrain.data or not terrain.data.has_method("get_region_locations") \
			or not terrain.data.has_method("get_region"):
		return
	for loc in terrain.data.get_region_locations():
		var r = terrain.data.get_region(loc)
		if r and r.has_method("set_edited"):
			r.set_edited(false)


## A direct Path3D child of this node by instance id, or null (e.g. it was removed before the bake ran).
func _find_spline_by_id(id: int) -> Path3D:
	for c in get_children():
		if c is Path3D and c.get_instance_id() == id:
			return c
	return null


## True if any of this node's spline footprints overlaps `box` (XZ; footprint Y spans are nominal). Drives
## which layer-mates a dirty-rect refresh must repaint.
func _overlaps_box(box: AABB) -> bool:
	for s in _get_splines():
		var fp := _spline_footprint_aabb(s)
		if fp.size != Vector3.ZERO and fp.intersects(box):
			return true
	return false


## Grow a world box outward in XZ to the layer's tile grid (multiples of `step`), so it coincides exactly
## with the set of tiles clear_layer_in_area will drop. Y (the nominal footprint span) is left untouched.
func _snap_aabb_to_tiles(box: AABB, step: float) -> AABB:
	if step <= 0.0:
		return box
	var min_x := floorf(box.position.x / step) * step
	var min_z := floorf(box.position.z / step) * step
	var max_x := ceilf((box.position.x + box.size.x) / step) * step
	var max_z := ceilf((box.position.z + box.size.z) / step) * step
	return AABB(Vector3(min_x, box.position.y, min_z), Vector3(max_x - min_x, box.size.y, max_z - min_z))


## World size of one layer tile edge = tile_size (verts) * vertex_spacing. Tile boundaries land on world
## multiples of this (region_size is a multiple of tile_size, so the grid is global with no half-offset).
func _layer_tile_world(layer_id: int) -> float:
	var vs: float = terrain.vertex_spacing if terrain else 1.0
	var layer := _layer_at(layer_id)
	var ts := 64
	if layer and layer.has_method("get_tile_size"):
		ts = layer.get_tile_size()
	return float(ts) * vs


## Paint this node's splines into the given layer (-1 = destructive). Records the per-spline footprint
## cache. Driven by _refresh_owner for self and every layer-mate.
func _paint_into(layer_id: int, blend: int) -> void:
	_layer_id = layer_id
	_blend = blend
	var clipping := _clip_aabb.size != Vector3.ZERO
	for path in _get_splines():
		if not _spline_paintable(path):
			continue
		# Dirty-rect repaint: a spline that doesn't touch the box contributes nothing inside it — skip its
		# whole rasterise (its cached footprint outside the box is untouched and stays valid).
		if clipping and not _spline_footprint_aabb(path).intersects(_clip_aabb):
			continue
		_paint_spline(path)
		if layer_id >= 0:
			_last_paint_aabb[path.get_instance_id()] = _spline_footprint_aabb(path)


## Every brush node bound to `owner` (same terrain). Includes self when `owner` is our binding.
func _tools_on_owner(owner: String) -> Array:
	var out: Array = []
	if is_inside_tree():
		for n in get_tree().get_nodes_in_group(BRUSH_GROUP):
			if n is Pasture3DTerrainBrush and is_instance_valid(n) and n.terrain == terrain and n._layer_owner == owner:
				out.append(n)
	if owner == _layer_owner and not out.has(self):
		out.append(self)
	return out


## Our current + previously-cached spline footprints (cleared off a layer before repaint / on rebind).
func _own_footprints() -> Array:
	var out: Array = []
	for s in _get_splines():
		var a := _spline_footprint_aabb(s)
		if a.size != Vector3.ZERO:
			out.append(a)
	for sid in _last_paint_aabb:
		var b: AABB = _last_paint_aabb[sid]
		if b.size != Vector3.ZERO:
			out.append(b)
	return out


## ---- Layer resolution / identity ----

func _layers_api_available() -> bool:
	return terrain != null and terrain.data != null \
		and terrain.data.has_method("create_owned_layer") and terrain.data.has_method("find_layer_by_owner") \
		and terrain.data.has_method("get_layer_stack") and terrain.data.has_method("composite_region")


## Resolve (or create) the tool layer for `owner`. When `sync_blend`, push this node's blend_mode onto
## the layer so changing blend_mode re-bakes (a shared layer has one blend — last refresher wins).
## Returns the layer index, or -1 on builds/terrains without the layers Tool API (destructive fallback).
func _ensure_layer_for(owner: String, sync_blend: bool) -> int:
	if not terrain or not terrain.data:
		return -1
	var mt := _map_type()
	var nm := owner.trim_prefix(BRUSH_OWNER_PREFIX)
	var id: int = -1
	if terrain.data.has_method("create_owned_layer_typed"):
		id = terrain.data.create_owned_layer_typed(owner, nm, _get_blend_mode(), mt)
	elif mt == PASTURE_3D_MAPTYPE_HEIGHT and terrain.data.has_method("create_owned_layer"):
		id = terrain.data.create_owned_layer(owner, nm, _get_blend_mode())
	if id < 0:
		return -1
	var layer := _layer_at(id)
	# Owner is keyed by name only, so a same-named layer of another map type would be reused — warn.
	if layer and layer.has_method("get_map_type") and layer.get_map_type() != mt:
		push_warning("Pasture3D brush '%s': layer '%s' already exists with a different map type — give this tool a unique layer name." % [name, nm])
	if sync_blend and layer and layer.has_method("get_blend_mode") and layer.get_blend_mode() != _get_blend_mode():
		layer.set_blend_mode(_get_blend_mode())
	return id


func _layer_at(id: int) -> Pasture3DLayer:
	if not terrain or not terrain.data or not terrain.data.has_method("get_layer_stack"):
		return null
	var stack = terrain.data.get_layer_stack()
	return stack.get_layer(id) if stack else null


func _layer_blend_for(id: int) -> int:
	var layer := _layer_at(id)
	return layer.get_blend_mode() if layer else _get_blend_mode()


func _resolve_layer_for(owner: String) -> Pasture3DLayer:
	if not terrain or not terrain.data or not terrain.data.has_method("find_layer_by_owner"):
		return null
	var idx: int = terrain.data.find_layer_by_owner(owner)
	return _layer_at(idx) if idx >= 0 else null


## Every reserved brush tool layer in the stack (owner in the brush namespace).
func _brush_layers() -> Array:
	var out: Array = []
	if not terrain or not terrain.data or not terrain.data.has_method("get_layer_stack"):
		return out
	var stack = terrain.data.get_layer_stack()
	if not stack:
		return out
	for i in range(stack.get_layer_count()):
		var l = stack.get_layer(i)
		# Scope to brush layers of THIS tool's map type so sharing / the dropdown / de-dup don't mix
		# height and control layers (their owners are name-keyed only).
		if l and l.is_reserved() and l.get_owner_id().begins_with(BRUSH_OWNER_PREFIX) and l.get_map_type() == _map_type():
			out.append(l)
	return out


func _brush_layer_names() -> PackedStringArray:
	var out := PackedStringArray()
	for l in _brush_layers():
		out.append(l.get_layer_name())
	return out


func _owner_for_layer_name(display_name: String) -> String:
	for l in _brush_layers():
		if l.get_layer_name() == display_name:
			return l.get_owner_id()
	return ""


## Live display name of the layer we're bound to, or our owner slug if it doesn't exist yet.
func _layer_display_name() -> String:
	for l in _brush_layers():
		if l.get_owner_id() == _layer_owner:
			return l.get_layer_name()
	return _layer_owner.trim_prefix(BRUSH_OWNER_PREFIX)


func _unique_brush_layer_name(base: String) -> String:
	var names := _brush_layer_names()
	if not names.has(base):
		return base
	var i := 2
	while names.has("%s %d" % [base, i]):
		i += 1
	return "%s %d" % [base, i]


## Write one terrain sample. MAX/MIN/REPLACE author the absolute target surface (the layer's blend
## clamps it against what's beneath); ADD applies the signed delta. The per-pixel shape/taper is baked
## into `target`/`delta` by the subclass, so weight stays 1 (the rim eases as target → base). Falls
## back to destructive set_height when no reserved layer is available.
## True when `p` is inside the active dirty-rect clip box (XZ), or always when no clip is set. Lets a
## partial redraw rasterise a spline's full field (needed for correct distances) but only WRITE in the box.
## Max edge is EXCLUSIVE to match the tile-clear's half-open pixel span [min, max): the vertex line on the
## max boundary lives in the next (un-dropped) tile, so painting it would double-add for ADD-blend brushes.
func _clip_contains(p: Vector3) -> bool:
	if _clip_aabb.size == Vector3.ZERO:
		return true
	var lo := _clip_aabb.position
	var hi := lo + _clip_aabb.size
	return p.x >= lo.x and p.x < hi.x and p.z >= lo.z and p.z < hi.z


func _paint_height(world_pos: Vector3, target: float, delta: float) -> void:
	if not _clip_contains(world_pos):
		return
	if _layer_id < 0:
		terrain.data.set_height(world_pos, target)
		return
	if _blend == BLEND_ADD:
		terrain.data.add_height_on_layer(_layer_id, world_pos, delta, 1.0)
	else:
		terrain.data.set_height_on_layer(_layer_id, world_pos, target, 1.0)


## Write a packed control value (texture ids + blend + uv) into the layer. Falls back to the
## destructive set_control path internally when _layer_id is invalid (set_control_on_layer handles it).
func _paint_control(world_pos: Vector3, control: int, weight: float) -> void:
	if not _clip_contains(world_pos):
		return
	terrain.data.set_control_on_layer(_layer_id, world_pos, control, weight)


## Write an albedo+coverage colour into the layer (alpha-over composite).
func _paint_color(world_pos: Vector3, color: Color, weight: float) -> void:
	if not _clip_contains(world_pos):
		return
	terrain.data.set_color_on_layer(_layer_id, world_pos, color, weight)


func _seed_cache() -> void:
	for s in _get_splines():
		var a := _spline_footprint_aabb(s)
		if a.size != Vector3.ZERO:
			_last_paint_aabb[s.get_instance_id()] = a
		_curve_cache[s.get_instance_id()] = _curve_point_array(s)


## ---- Undo / redo (editor only) ----

## The editor's shared undo manager, or null outside the editor / when unavailable.
func _editor_undo() -> EditorUndoRedoManager:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_editor_undo_redo()


## Deep snapshot of a tool layer's tiles (empty Dictionary if no layer yet = the initial state).
func _snapshot_owner(owner: String) -> Dictionary:
	var layer := _resolve_layer_for(owner)
	return _copy_tiles(layer.get_tiles()) if layer else {}


## Restore a tile snapshot into a tool layer, then recomposite + push to GPU. Registered as the do/undo
## method of the bake action; re-resolves the layer by owner each call. Recomposites the UNION of the
## regions the layer covered before and after the swap — recompositing only the layer's current regions
## would leave a region the restore *emptied* still showing the old contribution.
func _restore_owner(owner: String, snapshot: Dictionary) -> void:
	var layer := _resolve_layer_for(owner)
	if not layer or not terrain.data.has_method("composite_region"):
		return
	var regions := {}
	for loc in layer.get_tiles():
		regions[loc] = true
	for loc in snapshot:
		regions[loc] = true
	layer.set_tiles(_copy_tiles(snapshot))
	for loc in regions:
		terrain.data.composite_region(loc, Rect2i(), false)
	terrain.data.update_maps(_map_type())


## Deep copy of the {region_loc -> {tile_coord -> Image}} tile structure. get_tiles/set_tiles share
## the live Images by reference, so we copy each one (copy_from) to keep snapshots immutable.
func _copy_tiles(tiles: Dictionary) -> Dictionary:
	var out := {}
	for loc in tiles:
		var inner: Dictionary = tiles[loc]
		var inner_copy := {}
		for coord in inner:
			var img: Image = inner[coord]
			if img:
				var c := Image.new()
				c.copy_from(img)
				inner_copy[coord] = c
			else:
				inner_copy[coord] = null
		out[loc] = inner_copy
	return out


## Apply a batch of curve-point edits then repaint, as one undo step. `points` = Array of
## [curve: Curve3D, index: int, position: Vector3]. Auto-refresh is suspended during the edits so the
## programmatic set_point_position calls don't queue a second (un-undoable) repaint; we repaint once
## here. Used as the do/undo method of curve operations like Make Descend so the curve change AND the
## terrain following it live in a single, auto_refresh-independent undo action.
func _set_curve_points_and_repaint(points: Array) -> void:
	_suspend_auto = true
	for e in points:
		var c: Curve3D = e[0]
		if c:
			c.set_point_position(e[1], e[2])
	_suspend_auto = false
	if Engine.is_editor_hint() and is_configured():
		refresh()


## ---- Surface snapping (PASTURE3D_SPLINE_SURFACE_SNAP_SPEC.md) ----

## (A) Snap every control point of every child spline onto the terrain (+ surface_offset), as ONE
## undoable action. On-demand via the inspector button; reuses the Make Descend do/undo helper.
func snap_points_to_surface() -> void:
	if not is_configured():
		return
	var edits := _surface_snap_edits()
	var new_pts: Array = edits[1]
	if new_pts.is_empty():
		return
	var ur := _editor_undo()
	if ur:
		ur.create_action("Pasture3D Snap %s to Surface" % _spline_basename())
		ur.add_do_method(self, "_set_curve_points_and_repaint", new_pts)
		ur.add_undo_method(self, "_set_curve_points_and_repaint", edits[0])
		ur.commit_action()
	else:
		_set_curve_points_and_repaint(new_pts)


## (B) Snap points to the surface in place, with no undo action of its own — it runs inside an
## auto-refresh whose undoable cause is the user's gizmo edit. Guarded so the writes don't recurse.
func _apply_surface_snap() -> void:
	if not is_configured():
		return
	var new_pts: Array = _surface_snap_edits()[1]
	if new_pts.is_empty():
		return
	_suspend_auto = true
	for e in new_pts:
		e[0].set_point_position(e[1], e[2])
	_suspend_auto = false


## Snap a specific set of a single spline's points onto the surface (world Y only), in place, no undo
## action. The dirty-rect path uses this to re-seat ONLY the points the user moved — against the base
## inside the freshly-cleared box — instead of re-snapping the whole spline (the snap-to-self regression).
func _apply_surface_snap_points(path: Path3D, indices: PackedInt32Array) -> void:
	if not is_configured() or indices.is_empty():
		return
	var c: Curve3D = path.curve
	if c == null:
		return
	var xf: Transform3D = path.global_transform
	var inv := xf.affine_inverse()
	_suspend_auto = true
	for idx in indices:
		if idx < 0 or idx >= c.point_count:
			continue
		var local := c.get_point_position(idx)
		var world: Vector3 = xf * local
		var h: float = terrain.data.get_height(Vector3(world.x, 0.0, world.z))
		if not is_finite(h):
			continue
		world.y = h + surface_offset
		var new_local: Vector3 = inv * world
		if not new_local.is_equal_approx(local):
			c.set_point_position(idx, new_local)
	_suspend_auto = false


## Local point positions of a spline's curve, for moved-point detection.
func _curve_point_array(path: Path3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var c: Curve3D = path.curve if is_instance_valid(path) else null
	if c == null:
		return out
	for i in range(c.point_count):
		out.append(c.get_point_position(i))
	return out


## Indices of `path`'s curve points that moved since the last bake (vs `_curve_cache`). Returns EVERY
## index when the point count changed (add/remove/insert) or there's no cache yet — so the dirty-rect
## snap falls back to re-seating the whole spline in those cases rather than guessing.
func _moved_point_indices(path: Path3D) -> PackedInt32Array:
	var out := PackedInt32Array()
	var cur := _curve_point_array(path)
	var prev: PackedVector3Array = _curve_cache.get(path.get_instance_id(), PackedVector3Array())
	if prev.size() != cur.size():
		for i in range(cur.size()):
			out.append(i)
		return out
	for i in range(cur.size()):
		if not prev[i].is_equal_approx(cur[i]):
			out.append(i)
	return out


## Record a spline's current point layout as the new baseline for moved-point detection.
func _update_curve_cache(path: Path3D) -> void:
	if is_instance_valid(path):
		_curve_cache[path.get_instance_id()] = _curve_point_array(path)


## Compute the snap edits for every child spline: [old_points, new_points], each an Array of
## [curve, index, local_position]. Snaps in world space (so a transformed brush/Path3D still works);
## points with no region beneath them (get_height returns NaN) are skipped.
func _surface_snap_edits() -> Array:
	var old_pts: Array = []
	var new_pts: Array = []
	for path in _get_splines():
		var c: Curve3D = path.curve
		if c == null:
			continue
		var xf: Transform3D = path.global_transform
		var inv := xf.affine_inverse()
		for i in range(c.point_count):
			var local := c.get_point_position(i)
			var world: Vector3 = xf * local
			var h: float = terrain.data.get_height(Vector3(world.x, 0.0, world.z))
			if not is_finite(h):
				continue
			world.y = h + surface_offset
			var new_local: Vector3 = inv * world
			if new_local.is_equal_approx(local):
				continue
			old_pts.append([c, i, local])
			new_pts.append([c, i, new_local])
	return [old_pts, new_pts]


## ---- Add Spline button ----

func add_spline() -> void:
	var path := Path3D.new()
	path.name = "%s%d" % [_spline_basename(), _get_splines().size() + 1]
	path.curve = _make_starter_curve()
	add_child(path)
	# Reparent under the edited scene so the new node persists when the scene is saved.
	if Engine.is_editor_hint() and is_inside_tree():
		var root := get_tree().edited_scene_root
		if root:
			path.owner = root
	_connect_spline(path)
	refresh()


## ---- Geometry helpers (shared) ----

## Curve baked to a world-space polyline (Path3D transform applied).
func _baked_world_points(path: Path3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	if path.curve == null:
		return out
	var xf := path.global_transform
	for p in path.curve.get_baked_points():
		out.append(xf * p)
	return out


## World footprint of a spline: XZ bounds of its baked points padded by the brush's lateral reach.
## Y is given a wide nominal span; clear_layer_in_area uses XZ only.
func _spline_footprint_aabb(path: Path3D) -> AABB:
	var pts := _baked_world_points(path)
	if pts.is_empty():
		return AABB()
	var mn := Vector2(pts[0].x, pts[0].z)
	var mx := mn
	for p in pts:
		mn.x = minf(mn.x, p.x)
		mn.y = minf(mn.y, p.z)
		mx.x = maxf(mx.x, p.x)
		mx.y = maxf(mx.y, p.z)
	var pad := _padding()
	mn -= Vector2(pad, pad)
	mx += Vector2(pad, pad)
	return AABB(Vector3(mn.x, -10000.0, mn.y), Vector3(mx.x - mn.x, 20000.0, mx.y - mn.y))


## Snap a footprint AABB to the terrain grid → [min_x, max_x, min_z, max_z] (world XZ).
func _snapped_bounds(aabb: AABB, vs: float) -> Array:
	var min_x := floorf(aabb.position.x / vs) * vs
	var min_z := floorf(aabb.position.z / vs) * vs
	var max_x := ceilf((aabb.position.x + aabb.size.x) / vs) * vs
	var max_z := ceilf((aabb.position.z + aabb.size.z) / vs) * vs
	return [min_x, max_x, min_z, max_z]


## Increasing 0→1 ramp from an optional Curve, defaulting to smoothstep.
func _ramp(c: Curve, x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	if c:
		return c.sample_baked(x)
	return smoothstep(0.0, 1.0, x)


## Crest cross-section: 1 at the centre (t=0) falling to 0 at the edge (t=1). Default = rounded cosine.
func _cross(c: Curve, t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	if c:
		return c.sample_baked(t)
	return 0.5 + 0.5 * cos(t * PI)


## ---- Rasterisation acceleration (PASTURE3D_LANDSCAPE_TOOLS_SPEC.md §9 performance) ----
##
## Curve3D bakes at ~0.2 m, so a simple loop becomes 1000s of edges — 5× finer than the 1 m terrain
## grid and the source of the O(cells × edges) freeze. Decimate the baked polyline down to roughly the
## terrain resolution before rasterising; the chamfer distance field below then runs in O(cells).

## Decimate a world-space point list, keeping a point about every `step` metres (drops the dense
## in-between bakes). Used for both closed loops (Mound) and open polylines (Ridge/Trough).
func _decimate(pts: PackedVector2Array, step: float) -> PackedVector2Array:
	var n := pts.size()
	if n < 3:
		return pts
	var out := PackedVector2Array()
	out.append(pts[0])
	var acc := 0.0
	for i in range(1, n):
		acc += pts[i].distance_to(pts[i - 1])
		if acc >= step:
			out.append(pts[i])
			acc = 0.0
	# Always keep the final point so an open polyline reaches its real end.
	if out[out.size() - 1] != pts[n - 1]:
		out.append(pts[n - 1])
	return out


## Two-pass chamfer distance transform, in place. Each cell ends up holding (approximately) the
## Euclidean distance to the nearest zero-seeded cell, in metres (orthogonal step `a`, diagonal `b`).
## O(cells) — replaces the per-pixel-per-edge distance loop. (Refs: chamfer DT / SDF literature.)
func _chamfer(arr: PackedFloat32Array, gw: int, gh: int, a: float, b: float) -> void:
	for iz in range(gh):
		var row := iz * gw
		for ix in range(gw):
			var i := row + ix
			var d := arr[i]
			if iz > 0:
				var up := i - gw
				if arr[up] + a < d:
					d = arr[up] + a
				if ix > 0 and arr[up - 1] + b < d:
					d = arr[up - 1] + b
				if ix < gw - 1 and arr[up + 1] + b < d:
					d = arr[up + 1] + b
			if ix > 0 and arr[i - 1] + a < d:
				d = arr[i - 1] + a
			arr[i] = d
	for iz in range(gh - 1, -1, -1):
		var row := iz * gw
		for ix in range(gw - 1, -1, -1):
			var i := row + ix
			var d := arr[i]
			if iz < gh - 1:
				var dn := i + gw
				if arr[dn] + a < d:
					d = arr[dn] + a
				if ix < gw - 1 and arr[dn + 1] + b < d:
					d = arr[dn + 1] + b
				if ix > 0 and arr[dn - 1] + b < d:
					d = arr[dn - 1] + b
			if ix < gw - 1 and arr[i + 1] + a < d:
				d = arr[i + 1] + a
			arr[i] = d


## Signed distance field of a closed world polygon over a grid: positive inside, negative outside, in
## metres. Returns [PackedFloat32Array field, float max_inside_distance]. Inside is found with one
## scanline fill (O(rows × edges)); both sides get a chamfer DT (O(cells)). The whole thing is O(cells)
## instead of the old O(cells × edges) per-pixel polygon distance.
func _signed_distance_field(poly: PackedVector2Array, min_x: float, min_z: float, vs: float, gw: int, gh: int) -> Array:
	var n := gw * gh
	var pc := poly.size()
	const BIG := 1.0e9
	var inside := PackedByteArray()
	inside.resize(n)
	# Even-odd scanline fill (half-open edge rule avoids double-counting shared vertices).
	for iz in range(gh):
		var zc := min_z + iz * vs
		var xs := PackedFloat32Array()
		for e in range(pc):
			var pa := poly[e]
			var pb := poly[(e + 1) % pc]
			if (pa.y <= zc and pb.y > zc) or (pb.y <= zc and pa.y > zc):
				var tt := (zc - pa.y) / (pb.y - pa.y)
				xs.append(pa.x + tt * (pb.x - pa.x))
		xs.sort()
		var row := iz * gw
		var k := 0
		while k + 1 < xs.size():
			var ix0 := int(ceil((xs[k] - min_x) / vs))
			var ix1 := int(floor((xs[k + 1] - min_x) / vs))
			if ix0 < 0:
				ix0 = 0
			if ix1 > gw - 1:
				ix1 = gw - 1
			for ix in range(ix0, ix1 + 1):
				inside[row + ix] = 1
			k += 2
	var din := PackedFloat32Array()
	var dout := PackedFloat32Array()
	din.resize(n)
	dout.resize(n)
	for i in range(n):
		if inside[i] == 1:
			din[i] = BIG
			dout[i] = 0.0
		else:
			din[i] = 0.0
			dout[i] = BIG
	var diag := vs * 1.4142135624
	_chamfer(din, gw, gh, vs, diag)
	_chamfer(dout, gw, gh, vs, diag)
	var field := PackedFloat32Array()
	field.resize(n)
	var max_inside := 0.0
	for i in range(n):
		if inside[i] == 1:
			field[i] = din[i]
			if din[i] < BIG and din[i] > max_inside:
				max_inside = din[i]
		else:
			field[i] = -dout[i]
	return [field, max_inside]


## Two-pass chamfer that ALSO carries two payload arrays: whenever a neighbour offers a shorter
## distance, copy its payloads too. Turns a distance transform into a nearest-feature transform, so a
## cell ends up with both its distance to the seeds and the seed values of the nearest one. O(cells).
func _chamfer_payload(dist: PackedFloat32Array, p1: PackedFloat32Array, p2: PackedFloat32Array, gw: int, gh: int, a: float, b: float) -> void:
	for iz in range(gh):
		var row := iz * gw
		for ix in range(gw):
			var i := row + ix
			var bd := dist[i]
			var bj := -1
			if iz > 0:
				var up := i - gw
				if dist[up] + a < bd:
					bd = dist[up] + a
					bj = up
				if ix > 0 and dist[up - 1] + b < bd:
					bd = dist[up - 1] + b
					bj = up - 1
				if ix < gw - 1 and dist[up + 1] + b < bd:
					bd = dist[up + 1] + b
					bj = up + 1
			if ix > 0 and dist[i - 1] + a < bd:
				bd = dist[i - 1] + a
				bj = i - 1
			if bj >= 0:
				dist[i] = bd
				p1[i] = p1[bj]
				p2[i] = p2[bj]
	for iz in range(gh - 1, -1, -1):
		var row := iz * gw
		for ix in range(gw - 1, -1, -1):
			var i := row + ix
			var bd := dist[i]
			var bj := -1
			if iz < gh - 1:
				var dn := i + gw
				if dist[dn] + a < bd:
					bd = dist[dn] + a
					bj = dn
				if ix < gw - 1 and dist[dn + 1] + b < bd:
					bd = dist[dn + 1] + b
					bj = dn + 1
				if ix > 0 and dist[dn - 1] + b < bd:
					bd = dist[dn - 1] + b
					bj = dn - 1
			if ix < gw - 1 and dist[i + 1] + a < bd:
				bd = dist[i + 1] + a
				bj = i + 1
			if bj >= 0:
				dist[i] = bd
				p1[i] = p1[bj]
				p2[i] = p2[bj]


## Feature field of a world-space polyline over a grid. Returns
## [lat: PackedFloat32Array, base_y: PackedFloat32Array, along: PackedFloat32Array, total_length: float]:
## per cell, the lateral distance to the polyline (metres), the spline Y at the nearest point, and the
## arc length to it (for end taper). Seeds the cells the polyline passes through then chamfer-propagates
## the nearest-feature values — O(cells), replacing the per-pixel O(segments) closest-point scan.
func _polyline_field(pts: PackedVector3Array, min_x: float, min_z: float, vs: float, gw: int, gh: int) -> Array:
	var n := gw * gh
	const BIG := 1.0e9
	var dist := PackedFloat32Array()
	var base_y := PackedFloat32Array()
	var along := PackedFloat32Array()
	dist.resize(n)
	base_y.resize(n)
	along.resize(n)
	for i in range(n):
		dist[i] = BIG
	var sample := vs * 0.5
	var run := 0.0
	for k in range(pts.size() - 1):
		var a := pts[k]
		var b := pts[k + 1]
		var ax := a.x
		var az := a.z
		var seg := Vector2(b.x - ax, b.z - az).length()
		var along_a := run
		run += seg
		var steps := maxi(1, int(ceil(seg / sample)))
		for s in range(steps + 1):
			var tt := float(s) / float(steps)
			var ix := int(round((ax + (b.x - ax) * tt - min_x) / vs))
			var iz := int(round((az + (b.z - az) * tt - min_z) / vs))
			if ix >= 0 and ix < gw and iz >= 0 and iz < gh:
				var idx := iz * gw + ix
				dist[idx] = 0.0
				base_y[idx] = a.y + (b.y - a.y) * tt
				along[idx] = along_a + seg * tt
	_chamfer_payload(dist, base_y, along, gw, gh, vs, vs * 1.4142135624)
	return [dist, base_y, along, run]


## ---- Virtuals for subclasses ----

func _get_blend_mode() -> int:
	return BLEND_REPLACE


## Map type this brush paints (TYPE_HEIGHT default; Pasture3DSplat returns TYPE_CONTROL). Drives the
## reserved layer's type, update_maps, and which brush layers this tool shares with.
func _map_type() -> int:
	return PASTURE_3D_MAPTYPE_HEIGHT


## Default tool-layer name for a fresh node of this type (e.g. "Mounds"). Used to build _layer_owner.
func _default_layer_name() -> String:
	return "Brush"


func _padding() -> float:
	return 2.0


func _spline_paintable(path: Path3D) -> bool:
	return path.curve != null and path.curve.point_count >= _min_points()


func _min_points() -> int:
	return 2


func _paint_spline(_path: Path3D) -> void:
	push_error("Pasture3DTerrainBrush._paint_spline must be overridden by a subclass.")


func _make_starter_curve() -> Curve3D:
	return Curve3D.new()


func _spline_basename() -> String:
	return "Spline"
