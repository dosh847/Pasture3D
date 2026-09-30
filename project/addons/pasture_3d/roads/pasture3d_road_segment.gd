# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadSegment — an override applied to the stretch of road BETWEEN TWO SPLINE POINTS: "from point
# 5 to point 27 this is a dirt road". See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §4.2.
#
# ---- WHY POINTS, WHY STILL ARC LENGTH UNDERNEATH, AND WHY A RESOURCE ----
#
# The range is AUTHORED as two picked points and RESOLVED to arc length every time it is read (`start` /
# `end`), so everything downstream still works in metres along the plan. It used to be authored in metres
# too (`from_distance` / `to_distance`); those were removed, because a number of metres does not follow the
# road when a point is dragged and nobody can see where 400 m is. Points are picked in the viewport and
# follow their point. The earlier objection to point ranges -- inserting a point orphans the override --
# is answered by renumbering the picks on every insert and remove (`_editor_points_shifted`).
#
# It is not one segment per spline INTERVAL, as a scene node, which is what godot-road-generator does:
#
#   1. Spline point spacing is an authoring convenience, not a geometric unit. A segment spans as many
#      intervals as it needs, and several can overlap.
#   2. Mesh chunking has to be free to align to terrain REGIONS (§10) so a road chunk's lifetime matches
#      a region's. If a segment were the chunk, chunk length would be decided by where the artist
#      happened to click.
#   3. Scene nodes do not scale. Hundreds of kilometres of road is thousands of nodes in the tree and in
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
## One end of this override: a spline point, by its number along the road (the order the gizmo numbers
## them, across every spline under the brush). -1 = the START of the road.
##
## The segment covers the road BETWEEN its two points, whichever comes first, so picking the end before
## the start is fine. A picked point FOLLOWS its point: drag it and the range moves with it, round a corner
## and it still starts at the corner. Inserting or removing a point renumbers it for you (as one undo).
## Pick one with the "Start at Selected Point" button, after clicking the point in the viewport.
@export var from_point: int = -1:
	set(v):
		from_point = maxi(v, -1)
		emit_changed()

## The other end: a spline point. -1 = the END of the road. See `from_point`. With neither picked the
## segment covers nothing, so a freshly added one changes no road until it is given a point.
@export var to_point: int = -1:
	set(v):
		to_point = maxi(v, -1)
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


## Where the range starts, metres along the road: the nearer of the two ends. EVERY reader of the range
## goes through `start` / `end`, never the fields.
func start() -> float:
	return _range().x


## Where the range ends: the further of the two ends. See `start`.
func end() -> float:
	return _range().y


## The covered range, ordered. (0, 0) -- covering nothing -- when no point is picked, when a pick names
## no point on the road, or when the segment is on no road yet. Not NaN: every consumer bsearches it.
func _range() -> Vector2:
	if from_point < 0 and to_point < 0:
		return Vector2.ZERO
	var road := _bound_road()
	if road == null or not road.has_method(&"total_arc_length"):
		return Vector2.ZERO
	var a := 0.0 if from_point < 0 else _point_s(from_point)
	var b := float(road.call(&"total_arc_length")) if to_point < 0 else _point_s(to_point)
	if not is_finite(a) or not is_finite(b):
		return Vector2.ZERO
	return Vector2(minf(a, b), maxf(a, b))


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
	if from_point < 0 and to_point < 0:
		out.append("Segment '%s' has no points picked, so it covers nothing." % nm)
		return out
	var unresolved := false
	for pick in [["from_point", from_point], ["to_point", to_point]]:
		if int(pick[1]) >= 0 and _bound_road() != null and not is_finite(_point_s(int(pick[1]))):
			out.append("Segment '%s' %s %d names no spline point, so it covers nothing." % [nm, pick[0], pick[1]])
			unresolved = true
	if not unresolved and _bound_road() != null and length() <= 0.0:
		out.append("Segment '%s' starts and ends at the same place, so it covers nothing." % nm)
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
