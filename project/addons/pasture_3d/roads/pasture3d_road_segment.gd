# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadSegment — an override applied to a RANGE OF ARC LENGTH along a road brush's spline:
# "from 400 m to 2400 m this is gravel, and the last 80 m of that is a bridge".
# See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §4.2.
#
# ---- WHY ARC LENGTH, AND WHY A RESOURCE ----
#
# The natural-looking design is one segment per spline INTERVAL, as a scene node — which is what
# godot-road-generator does. Both halves of that were changed here, for four reasons:
#
#   1. Spline point spacing is an authoring convenience, not a geometric unit. A 2 km straight is one
#      point-to-point interval; a fussy corner is six. Nothing about the road agrees with that split.
#   2. Inserting a point SPLITS a segment and orphans whatever was overridden on it — and users insert
#      points constantly. Under arc length, inserting a point in the middle of a gravel stretch leaves
#      the gravel stretch alone, which is the only behaviour anyone expects.
#   3. Mesh chunking has to be free to align to terrain REGIONS (§10) so a road chunk's lifetime matches
#      a region's. If a segment were the chunk, chunk length would be decided by where the artist
#      happened to click.
#   4. Scene nodes do not scale. Hundreds of kilometres of road is thousands of nodes in the tree and in
#      the .tscn. Resources in an array cost a row in the inspector.
#
# So a segment is a Resource in `Pasture3DRoadBrush.segments`, mirroring how the brush already holds its
# `modifiers` — same inspector idiom, same undo behaviour, same bake contract.
#
# It EXTENDS Pasture3DRoadOverrides rather than holding one, because a segment IS an override plus the
# range it applies to. Everything it does not set resolves up the chain to the brush.
@tool
class_name Pasture3DRoadSegment
extends Pasture3DRoadOverrides

## The name on this segment's ROW in the brush's Segments list, so a list of four overrides does not
## read as four identical rows. A view onto `resource_name`, exactly as Pasture3DNode.label is — the
## storage already exists and a second string would only give the two a way to disagree.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var label: String:
	set(v):
		resource_name = v
	get:
		return resource_name

@export_group("Range")
## Start this override AT a spline point, by its number along the road (the order the gizmo numbers
## them, across every spline under the brush). -1 = start at `from_distance` instead.
##
## A picked point FOLLOWS its point: drag it and the range moves with it, round a corner and it still
## starts at the corner. Inserting or removing a point before it renumbers it for you (as one undo).
## Pick one with the "Start at Selected Point" button, after clicking the point in the viewport.
@export var from_point: int = -1:
	set(v):
		from_point = maxi(v, -1)
		notify_property_list_changed()
		emit_changed()

## End this override at a spline point. -1 = end at `to_distance`. See `from_point`.
@export var to_point: int = -1:
	set(v):
		to_point = maxi(v, -1)
		notify_property_list_changed()
		emit_changed()

## Where this override starts, metres along the spline from its beginning. Read-only while `from_point`
## picks the start; it then shows nothing useful, and `start()` is the answer.
@export var from_distance: float = 0.0:
	set(v):
		from_distance = maxf(v, 0.0)
		emit_changed()

## Where it ends, metres along the spline. A range that ends at or before it starts covers nothing and
## is reported by `range_warnings()` rather than silently doing nothing.
@export var to_distance: float = 100.0:
	set(v):
		to_distance = maxf(v, 0.0)
		emit_changed()

## Start the range at the point selected in the viewport on this segment's road.
@export_tool_button("Start at Selected Point") var _start_at_sel_btn = _pick_start
## End the range at the point selected in the viewport on this segment's road.
@export_tool_button("End at Selected Point") var _end_at_sel_btn = _pick_end

@export_group("Structure")
## This stretch is carried on a bridge: the terrain is NOT graded under it, and the alignment is free of
## the ground. It also does more work than it looks — a bridge segment is excluded from intersection
## resolution (§6.3), because an overpass OVERLAPS every road it crosses without meeting any of them.
## Grade separation therefore falls out of this one flag.
@export var is_bridge: bool = false:
	set(v):
		is_bridge = v
		emit_changed()

## Suppress terrain paint over this range, leaving the natural surface. For a ford, or a stretch where
## the road is meant to have been reclaimed.
@export var suppress_paint: bool = false:
	set(v):
		suppress_paint = v
		emit_changed()

## Allow sharp crest jumps without clamping to design-speed vertical acceleration limits (P9f).
@export var allow_airborne_jump: bool = false:
	set(v):
		allow_airborne_jump = v
		emit_changed()

@export_group("Walls")
## The retaining wall for cuts over this range. Empty inherits from the road; a wall with `enabled` off
## switches walls off here. See Pasture3DRoadWall.
@export var cut_wall: Pasture3DRoadWall = null:
	set(v):
		_rewatch_wall(cut_wall, v)
		cut_wall = v
		emit_changed()

## The retaining wall for fills over this range. Empty inherits.
@export var fill_wall: Pasture3DRoadWall = null:
	set(v):
		_rewatch_wall(fill_wall, v)
		fill_wall = v
		emit_changed()


## Follow a wall resource's `changed`: a shared wall edited in the inspector moves this range's ground.
func _rewatch_wall(p_old: Resource, p_new: Resource) -> void:
	if p_old != null and p_old.changed.is_connected(emit_changed):
		p_old.changed.disconnect(emit_changed)
	if p_new != null and not p_new.changed.is_connected(emit_changed):
		p_new.changed.connect(emit_changed)


## The road this segment belongs to, which is what a picked point is resolved against. Set by the brush
## whenever it takes the segment; runtime only. Weak, because the brush holds the segment.
var _road: WeakRef = null


## Tell this segment which road it is on. Called by `Pasture3DRoadBrush` as it takes it.
func bind_road(p_road: Node) -> void:
	_road = weakref(p_road) if p_road != null else null


func _bound_road() -> Node:
	return _road.get_ref() as Node if _road != null else null


## Arc length of a picked point, or NAN when it cannot be resolved (no road yet, index out of range).
func _point_s(p_point: int) -> float:
	var road := _bound_road()
	if road == null or not road.has_method(&"point_arc_length"):
		return NAN
	return float(road.call(&"point_arc_length", p_point))


## Where the range starts, metres along the road: the picked point's arc length when one is picked and
## resolves, else `from_distance`. EVERY reader of the range goes through this pair, never the fields.
func start() -> float:
	if from_point >= 0:
		var s := _point_s(from_point)
		if is_finite(s):
			return s
	return from_distance


## Where the range ends. See `start`.
func end() -> float:
	if to_point >= 0:
		var s := _point_s(to_point)
		if is_finite(s):
			return s
	return to_distance


## Metres this override covers. Zero for a range that ends where it starts.
func length() -> float:
	return maxf(end() - start(), 0.0)


## True when `p_distance` metres along the spline falls inside this segment. Half-open [from, to) so two
## segments that abut at the same distance do not both claim the boundary — the later one wins there,
## which is also the rule `Pasture3DRoadBrush.segment_at` relies on.
func covers(p_distance: float) -> bool:
	return p_distance >= start() and p_distance < end()


## True when this segment's range overlaps `p_other`'s. Overlap is legal — the LAST matching segment in
## the brush's array wins, so a short bridge can sit inside a long gravel stretch — but it is worth
## surfacing, because an accidental overlap looks exactly like a setting that will not take.
func overlaps(p_other: Pasture3DRoadSegment) -> bool:
	if p_other == null:
		return false
	return start() < p_other.end() and p_other.start() < end()


## A distance field is read-only while a point picks that end: editing it would do nothing, silently.
func _validate_property(p_property: Dictionary) -> void:
	var name := String(p_property["name"])
	if (name == "from_distance" and from_point >= 0) or (name == "to_distance" and to_point >= 0):
		p_property["usage"] = int(p_property["usage"]) | PROPERTY_USAGE_READ_ONLY


func _pick_start() -> void:
	_pick_selected(false)


func _pick_end() -> void:
	_pick_selected(true)


func _pick_selected(p_end: bool) -> void:
	var road := _bound_road()
	if road == null or not road.has_method(&"segment_pick_selected_point"):
		push_warning("Pasture3D: this segment is not on a road brush yet.")
		return
	road.call(&"segment_pick_selected_point", self, p_end)


## Problems worth showing on the brush. Not errors: a segment past the end of a shortened spline is a
## normal intermediate state while editing, and deleting it for the user would be worse than saying so.
func range_warnings(p_spline_length: float = NAN) -> PackedStringArray:
	var out := PackedStringArray()
	var nm := resource_name if not resource_name.is_empty() else "Segment"
	for pick in [["from_point", from_point], ["to_point", to_point]]:
		if int(pick[1]) >= 0 and _bound_road() != null and not is_finite(_point_s(int(pick[1]))):
			out.append("Segment '%s' %s %d names no spline point; using the distance instead."
					% [nm, pick[0], pick[1]])
	if length() <= 0.0:
		out.append("Segment '%s' covers no distance (from %.1f m, to %.1f m)." % [nm, start(), end()])
	if is_finite(p_spline_length) and start() >= p_spline_length:
		out.append("Segment '%s' starts at %.1f m, past the end of the spline (%.1f m)."
				% [nm, start(), p_spline_length])
	return out


## The range and the structure flags on top of the override fields the base already signs.
##
## A segment is an override that applies over an arc-length RANGE, so both ends belong in the signature
## as much as the values do: sliding a bridge along the road changes no field value and changes the
## terrain everywhere it moved from and everywhere it moved to.
##
## `label` is deliberately absent — it is PROPERTY_USAGE_EDITOR and a view onto `resource_name`, so it
## moves no vertex and including it would invalidate every cached block on a rename.
func signature() -> Array:
	# The RESOLVED ends: a picked point that moves changes no field of this resource and moves the range.
	return [super.signature(), start(), end(), from_point, to_point, is_bridge, suppress_paint,
			allow_airborne_jump, Pasture3DRoadType.wall_terrain_signature(cut_wall),
			Pasture3DRoadType.wall_terrain_signature(fill_wall)]
