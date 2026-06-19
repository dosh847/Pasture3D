# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DTerrainBrush — shared base for the spline-driven landscape brushes
# (Pasture3DMound / Pasture3DRidge / Pasture3DTrough). See PASTURE3D_LANDSCAPE_TOOLS_SPEC.md.
#
# A brush node owns ONE reserved, non-destructive height layer and N child Path3D splines that all
# share the node's shape settings. On a refresh it clears the footprint it last painted and repaints
# every spline, so re-running is idempotent and hand-sculpting underneath survives. This is the same
# layer/idempotency contract RoadPastureConnector uses (PASTURE3D_LAYERS_GUIDE.md §8); the plumbing
# is factored here and each subclass implements only `_paint_spline()` plus its own shape exports.
#
# GDScript-only: it calls the already-bound C++ Tool API (create_owned_layer / set_height_on_layer /
# add_height_on_layer / clear_layer_in_area / update_maps), so no engine rebuild is required. On a
# build without that API it falls back to destructive set_height (still works, not idempotent).
@tool
class_name Pasture3DTerrainBrush
extends Node3D

## Map type / blend-mode indices, matching Pasture3DData.MapType and Pasture3DLayer.BlendMode.
## Hardcoded as ints so this script does not hard-depend on the enum bindings.
const PASTURE_3D_MAPTYPE_HEIGHT: int = 0 # Pasture3DData.MapType.TYPE_HEIGHT
const BLEND_REPLACE: int = 0 # Pasture3DLayer.BlendMode.REPLACE
const BLEND_ADD: int = 1     # Pasture3DLayer.BlendMode.ADD
const BLEND_MAX: int = 2     # Pasture3DLayer.BlendMode.MAX
const BLEND_MIN: int = 3     # Pasture3DLayer.BlendMode.MIN

# Debounce for auto-refresh while dragging spline handles (seconds).
const REFRESH_DELAY: float = 0.1

## The Pasture3D terrain this brush paints into.
@export var terrain: Pasture3D:
	set(value):
		terrain = value
		update_configuration_warnings()
		_schedule_refresh()

## Re-paint automatically while editing the splines / moving the node.
@export var auto_refresh: bool = true

## Name of the reserved non-destructive layer this brush renders into. Subclasses set a default in
## _init (e.g. "Mounds"). Painting here keeps hand-sculpting beneath and makes re-runs idempotent.
@export var target_layer_name: String = ""

@export_tool_button("Refresh") var _refresh_btn = _refresh_button
@export_tool_button("Add Spline") var _add_spline_btn = add_spline

var _layer_id: int = -1               # Reserved layer index; -1 = none (destructive fallback)
var _blend: int = BLEND_REPLACE       # Cached from _get_blend_mode() at layer creation
var _last_paint_aabb: Dictionary = {} # spline instance_id -> world AABB last painted (idempotent clear)
var _timer: SceneTreeTimer = null
var _dirty: bool = false
var _suspend_auto: bool = false # Blocks auto-refresh while we mutate curves programmatically (undo)


func _ready() -> void:
	set_notify_transform(true)
	if not child_entered_tree.is_connected(_on_child_changed):
		child_entered_tree.connect(_on_child_changed)
	if not child_exiting_tree.is_connected(_on_child_changed):
		child_exiting_tree.connect(_on_child_changed)
	for s in _get_splines():
		_connect_spline(s)
	# Baseline the footprint cache to the loaded poses (without painting) so the first edit of the
	# session clears where a spline WAS, not just where it ends up — no stale flattening trail.
	_seed_cache()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_schedule_refresh()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = []
	if not is_instance_valid(terrain):
		warnings.append("Assign a Pasture3D terrain for this brush to paint into.")
	elif not terrain.data or terrain.data.region_locations.size() == 0:
		warnings.append("The Pasture3D terrain has no regions yet — add regions in Pasture3D first.")
	if _get_splines().is_empty():
		warnings.append("Add at least one spline (press Add Spline, or add a Path3D child).")
	return warnings


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
	if path.curve and not path.curve.changed.is_connected(_schedule_refresh):
		path.curve.changed.connect(_schedule_refresh)


func _on_child_changed(node: Node) -> void:
	if node is Path3D:
		_connect_spline(node)
	update_configuration_warnings()
	_schedule_refresh()


## ---- Refresh scheduling (debounced; defers while a handle is being dragged) ----

func _schedule_refresh() -> void:
	if _suspend_auto or not auto_refresh or not Engine.is_editor_hint() or not is_inside_tree():
		return
	_dirty = true
	if is_instance_valid(_timer):
		return
	_timer = get_tree().create_timer(REFRESH_DELAY)
	_timer.timeout.connect(_on_refresh_timer)


func _on_refresh_timer() -> void:
	_timer = null
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		# Still dragging — repaint once on release rather than every frame.
		_schedule_refresh()
		return
	if _dirty:
		_dirty = false
		refresh()


## ---- The paint cycle: clear last footprint(s), repaint every spline, push to GPU once ----

## The Refresh button. Records an undoable action so Ctrl+Z reverts the bake — needed for the
## auto_refresh-off / manual-bake workflow (and harmless when auto_refresh is on). Auto-refresh and
## property-driven repaints DON'T record their own action: their undoable cause (the spline gizmo
## edit or the inspector property change) re-triggers auto-refresh on undo, so the terrain follows.
func _refresh_button() -> void:
	refresh(true)


func refresh(record_undo: bool = false) -> void:
	if not Engine.is_editor_hint() or not is_configured():
		return
	var ur: EditorUndoRedoManager = _editor_undo() if record_undo else null
	var can_undo := ur != null and terrain.data.has_method("find_layer_by_owner") \
		and terrain.data.has_method("get_layer_stack") and terrain.data.has_method("recomposite_layer")
	var before: Dictionary = _snapshot_layer() if can_undo else {}
	_do_paint()
	if can_undo:
		var after := _snapshot_layer()
		# Already painted, so commit without re-executing the do method (execute = false).
		ur.create_action("Pasture3D %s Bake" % _spline_basename())
		ur.add_do_method(self, "_restore_layer", after)
		ur.add_undo_method(self, "_restore_layer", before)
		ur.commit_action(false)


func _do_paint() -> void:
	var have_layer := _ensure_layer()
	var splines := _get_splines()

	# Idempotent clear: drop every footprint we currently occupy AND every footprint we painted last
	# time (cached), so a moved/edited/removed spline leaves no stale flattening behind. Each box is
	# cleared separately (not merged) to avoid wiping a large swath between an old and a new pose; we
	# repaint ALL of the node's splines afterwards anyway, so any co-located sibling is restored.
	if have_layer:
		for s in splines:
			var a := _spline_footprint_aabb(s)
			if a.size != Vector3.ZERO:
				terrain.data.clear_layer_in_area(_layer_id, a)
		for sid in _last_paint_aabb:
			var b: AABB = _last_paint_aabb[sid]
			if b.size != Vector3.ZERO:
				terrain.data.clear_layer_in_area(_layer_id, b)
		_last_paint_aabb.clear()

	for s in splines:
		if not _spline_paintable(s):
			continue
		_paint_spline(s)
		if have_layer:
			_last_paint_aabb[s.get_instance_id()] = _spline_footprint_aabb(s)

	terrain.data.update_maps(PASTURE_3D_MAPTYPE_HEIGHT)


## Resolve (or create) our reserved layer. Returns false on terrains/builds without the layers Tool
## API, in which case callers fall back to destructive set_height so the brush keeps working.
func _ensure_layer() -> bool:
	_layer_id = -1
	_blend = _get_blend_mode()
	if not terrain or not terrain.data:
		return false
	if not terrain.data.has_method("create_owned_layer"):
		return false
	_layer_id = terrain.data.create_owned_layer(_owner_id(), target_layer_name, _blend)
	if _layer_id < 0:
		return false
	_sync_layer_blend()
	return true


## create_owned_layer only sets the blend mode when the layer is first created (it is idempotent by
## owner_id and returns the existing layer unchanged). Re-apply the export so changing blend_mode in
## the inspector takes effect. The subsequent repaint composites with the new blend.
func _sync_layer_blend() -> void:
	var layer := _resolve_layer()
	if layer and layer.has_method("get_blend_mode") and layer.get_blend_mode() != _blend:
		layer.set_blend_mode(_blend)


## Stable id identifying this brush's reserved layer across refreshes and reloads.
func _owner_id() -> String:
	return str(get_path())


## Write one terrain sample. MAX/MIN/REPLACE author the absolute target surface (the layer's blend
## clamps it against what's beneath); ADD applies the signed delta. The per-pixel shape/taper is baked
## into `target`/`delta` by the subclass, so weight stays 1 (the rim eases as target → base). Falls
## back to destructive set_height when no reserved layer is available.
func _paint_height(world_pos: Vector3, target: float, delta: float) -> void:
	if _layer_id < 0:
		terrain.data.set_height(world_pos, target)
		return
	if _blend == BLEND_ADD:
		terrain.data.add_height_on_layer(_layer_id, world_pos, delta, 1.0)
	else:
		terrain.data.set_height_on_layer(_layer_id, world_pos, target, 1.0)


func _seed_cache() -> void:
	for s in _get_splines():
		var a := _spline_footprint_aabb(s)
		if a.size != Vector3.ZERO:
			_last_paint_aabb[s.get_instance_id()] = a


## ---- Undo / redo (editor only) ----

## The editor's shared undo manager, or null outside the editor / when unavailable.
func _editor_undo() -> EditorUndoRedoManager:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_editor_undo_redo()


## Resolve our reserved layer object (by owner id, so it survives index shifts), or null.
func _resolve_layer() -> Pasture3DLayer:
	if not terrain or not terrain.data:
		return null
	if not terrain.data.has_method("find_layer_by_owner") or not terrain.data.has_method("get_layer_stack"):
		return null
	var idx: int = terrain.data.find_layer_by_owner(_owner_id())
	if idx < 0:
		return null
	var stack = terrain.data.get_layer_stack()
	return stack.get_layer(idx) if stack else null


## Deep snapshot of the reserved layer's tiles (empty Dictionary if no layer yet = the initial state).
func _snapshot_layer() -> Dictionary:
	var layer := _resolve_layer()
	return _copy_tiles(layer.get_tiles()) if layer else {}


## Restore a tile snapshot into the reserved layer, then recomposite + push to GPU. Registered as the
## do/undo method of the bake action; re-resolves the layer each call so it is robust to index shifts.
## We recomposite the UNION of the regions the layer covered before and after the swap — recompositing
## only the layer's current regions would leave a region that the restore *emptied* still showing the
## old contribution (it re-seeds from the base and re-applies every layer for each region).
func _restore_layer(snapshot: Dictionary) -> void:
	var layer := _resolve_layer()
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
	terrain.data.update_maps(PASTURE_3D_MAPTYPE_HEIGHT)


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
		_do_paint()


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


func _distance_point_to_segment_2d(p: Vector2, a: Vector2, b: Vector2) -> float:
	var v := b - a
	var len_sq := v.length_squared()
	if is_zero_approx(len_sq):
		return p.distance_to(a)
	var t := clampf((p - a).dot(v) / len_sq, 0.0, 1.0)
	return p.distance_to(a + t * v)


## Minimum distance from a point to any edge of a closed polygon (wraps last → first).
func _distance_to_polygon_boundary_2d(point: Vector2, polygon: PackedVector2Array) -> float:
	var n := polygon.size()
	if n < 2:
		return INF
	var min_dist := INF
	for i in range(n):
		var d := _distance_point_to_segment_2d(point, polygon[i], polygon[(i + 1) % n])
		min_dist = minf(min_dist, d)
	return min_dist


## Nearest point on a world polyline to an XZ query point. Returns [lateral_dist, sampled_y, along_dist].
func _nearest_on_polyline(pt: Vector2, pts: PackedVector3Array, cum: PackedFloat32Array) -> Array:
	var best := INF
	var best_y := 0.0
	var best_along := 0.0
	for i in range(pts.size() - 1):
		var a := pts[i]
		var b := pts[i + 1]
		var a2 := Vector2(a.x, a.z)
		var b2 := Vector2(b.x, b.z)
		var v := b2 - a2
		var len_sq := v.length_squared()
		var t := 0.0
		if len_sq > 0.0:
			t = clampf((pt - a2).dot(v) / len_sq, 0.0, 1.0)
		var d := pt.distance_to(a2 + v * t)
		if d < best:
			best = d
			best_y = lerpf(a.y, b.y, t)
			best_along = cum[i] + t * sqrt(len_sq)
	return [best, best_y, best_along]


func _cumulative_lengths(pts: PackedVector3Array) -> PackedFloat32Array:
	var cum := PackedFloat32Array()
	cum.resize(pts.size())
	if pts.is_empty():
		return cum
	cum[0] = 0.0
	for i in range(1, pts.size()):
		var a := Vector2(pts[i - 1].x, pts[i - 1].z)
		var b := Vector2(pts[i].x, pts[i].z)
		cum[i] = cum[i - 1] + a.distance_to(b)
	return cum


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


## ---- Virtuals for subclasses ----

func _get_blend_mode() -> int:
	return BLEND_REPLACE


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
