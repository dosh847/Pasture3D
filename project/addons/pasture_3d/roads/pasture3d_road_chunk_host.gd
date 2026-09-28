# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadChunkHost — the node side of TIER MID (§10). Owns one road's ribbon chunks, swaps their
# LOD by distance, and hides them entirely once tier FAR is enough.
#
# ---- WHY HIDING IS THE INTERESTING PART ----
#
# The road is painted into the terrain already (P5a), so beyond `far_distance` this host has nothing to
# add: it hides its chunks and the road is still there, still the right shape, still the right surface,
# because it IS the terrain. That is the one transition in the whole LOD chain with nothing to pop —
# and it only works in that direction. A system whose farthest tier were "a coarser mesh" would have to
# fade something out over something else; this one just stops drawing.
#
# ---- A HOST, NOT A MESHER ----
#
# Every number comes from Pasture3DRoadMesher, which is a pure kernel and is where the gate looks. This
# file allocates resources, parents nodes and reads a camera — the parts that need a scene tree and
# therefore cannot be gated headlessly. Keeping the split sharp is what lets the seam contract be
# checked at all.
#
# ---- LOD IS A MESH SWAP, NEVER A REBUILD ----
#
# §10's design-to note: a chunk carries all its LOD meshes as one resource, built once at bake. Choosing
# a tier is then an assignment, which is why `_process` can afford to run every frame and why a fast car
# crossing three LOD bands does not stall.
@tool
class_name Pasture3DRoadChunkHost
extends Node3D

## Distance in metres at which each LOD takes over. Beyond the last, the chunk is hidden and the painted
## terrain is the road. Ascending; the count need not match LOD_LEVELS.
@export var lod_distances: PackedFloat32Array = PackedFloat32Array([60.0, 140.0, 300.0]):
	set(v):
		lod_distances = v
		_dirty_lod = true

## Beyond this, no ribbon at all — tier FAR carries the road. 0 disables hiding, which is for looking at
## the mesh rather than for shipping.
@export var far_distance: float = 600.0:
	set(v):
		far_distance = v
		_dirty_lod = true

## Dead band on every threshold, metres. A tier or a hide only changes once the distance is this far
## PAST the line, so a camera parked on a threshold does not flip the mesh every frame.
##
## Needed because the thresholds are hard comparisons over a distance that jitters: an orbiting or
## hand-held camera crosses a line dozens of times a second, and each crossing is a mesh swap. The
## symptom is a ribbon that flickers, which reads as the chunks failing to build rather than as the
## comparison being exact.
@export var lod_hysteresis: float = 12.0

## Metres the ribbon rides above the graded ground. Exposed for tuning on unusual terrain scales, not
## for turning off — see Pasture3DRoadMesher.DEPTH_LIFT for why coplanar is not an option.
@export var depth_lift: float = Pasture3DRoadMesher.DEPTH_LIFT

## Give each chunk a collider on the carriageway.
##
## ---- WHAT THIS IS AND IS NOT FOR ----
##
## NOT the driving surface. The road went through the HEIGHTMAP (P2), so the terrain's own collision
## already is the road: a vehicle is supported by the graded ground whether this is on or off, and
## turning it on adds nothing to hold the car up. What it adds is IDENTITY — a raycast that answers "am
## I on tarmac or on grass", on its own physics layer, without sampling the control map and decoding a
## texture id. Off by default, because a road that does not need the question asked should not pay for
## the shapes.
@export var collision_enabled: bool = false

## Physics layer and mask for those colliders. Layer 2 by default so a road query cannot be confused
## with a terrain query, and mask 0 because these shapes answer questions — nothing needs to collide
## WITH them.
@export_flags_3d_physics var collision_layer: int = 2
@export_flags_3d_physics var collision_mask: int = 0

## Draw lane markings on the carriageway (§10, P5c).
## The coarsest LOD lane markings are drawn at. Tier NEAR only (§10, and §2.5 of the junction paint
## spec): a stripe is a few centimetres wide, it is unreadable by tier MID, and beyond tier FAR the road
## is terrain paint with no mesh to put it on. Not an @export, because it is not a preference -- it is
## the tier the markings BELONG to, and a marking drawn at MID is overdraw nobody can see.
const MARKINGS_MAX_LOD: int = 0

@export var markings_enabled: bool = true

## Material for the painted stripes. Left null, markings are built and drawn untextured — visible, but
## not white, which reads as a bug rather than as a missing material.
@export var markings_material: Material = null

## Place the road type's verge props through the terrain's instancer (§10, P5c).
@export var props_enabled: bool = true

## Chunks, each `{node: MeshInstance3D, centre: Vector3, meshes: Array[ArrayMesh], lod: int}`.
var _chunks: Array = []
var _dirty_lod: bool = true
var _report: bool = false
var _hidden: int = 0
var _nearest: float = INF

## Shapes built by the last rebuild.
##
## Counted and REPORTED because a road collider is otherwise invisible: these hosts are not owned by the
## edited scene, so Godot draws no CollisionShape3D gizmo for them and the viewport looks exactly the
## same whether the shapes exist or not. Turning the setting on and seeing nothing change is the whole
## problem — so the host says the number out loud, and Debug > Visible Collision Shapes shows them when
## the game runs.
var _colliders: int = 0
var _last_digest: String = ""
var last_rebuilt: bool = false

## Cached pick geometry for the editor gizmo. See `pick_meshes`.
var _pick_meshes: Array[TriangleMesh] = []
var _pick_digest: String = ""

## Apron chunks and content digests for junction surface caching.
var _apron_chunks: Dictionary = {}
var _apron_digests: Dictionary = {}

## The retaining walls a batter height cap leaves standing (Pasture3DRoadType.cut_wall_height /
## fill_wall_height). One node for the whole road, OUTSIDE `_chunks`: a wall is built from the graded
## TERRAIN as well as the alignment, so it has its own digest, and a ribbon rebuild must not drop it.
var _walls: MeshInstance3D = null
var _walls_digest: int = 0
## How many wall faces and caps the last build emitted, as quads. What a gate reads.
var wall_quads: int = 0

## Metres a wall face is sunk below the ground it stands on, so a grid step or a later bake of the ground
## beside it never shows a gap under the wall.
const WALL_EMBED: float = 1.0
## Height a wall must actually stand before one is drawn. The grader leaves ground alone past the wall
## run; where that ground happens to sit within this of the wall top there is no face to build.
const WALL_MIN_FACE: float = 0.05


func _ready() -> void:
	set_process(true)


## Rebuild every chunk for `p_brush`. Called at the end of a bake, from the network, so the whole
## network re-chunks in one pass and in a defined order.
##
## Returns the number of chunks built. Zero is the normal answer for a road with no alignment yet or no
## surface material, not an error.
func rebuild(p_brush: Pasture3DRoadBrush) -> int:
	if p_brush == null:
		_clear()
		_clear_walls()
		_last_digest = ""
		last_rebuilt = false
		return 0
	var run := p_brush.build_run()
	if run.is_empty():
		_clear()
		_clear_walls()
		_last_digest = ""
		last_rebuilt = false
		_why(p_brush, "the road has no solved alignment yet (build_run is empty)")
		return 0
	var t: Pasture3DRoadType = p_brush.resolved_road_type()
	if t == null:
		_clear()
		_clear_walls()
		_last_digest = ""
		last_rebuilt = false
		_why(p_brush, "the road has no road type")
		return 0
	# Before the ribbon's early return, and whatever the surface mode: the walls stand on the TERRAIN,
	# which the ribbon digest does not see, and a draped road needs its walls as much as a meshed one.
	_rebuild_walls(p_brush, run, t)

	# ---- WHAT THE SKIP DIGEST OWES, AND WHY IT IS A LIST OF VALUES ----
	#
	# This used to identify the road type by `str(t.get_instance_id())`. An instance id does not change
	# when the resource's PROPERTIES change, and nothing else here covered the cross-section either —
	# `alignment_digest()` hashes plan points, ds, drape, max_grade, design_speed and pins, which is every
	# input to the VERTICAL solve and none to the cross-section. So the digest was stable across exactly
	# the edits that change the mesh: lane_count, lane_width, shoulder_width, crown, surface_material. The
	# terrain re-graded to the new carriageway and the ribbon kept the old width until something unrelated
	# perturbed the alignment.
	#
	# It names the mesher's inputs one at a time, rather than hashing every exported property of the road
	# type, and that is the point rather than an economy. A generic hash would also churn on properties
	# the ribbon never reads — max_grade, the physics surface_id — forcing a full mesh rebuild on every
	# vertical-only edit, which is the cost this cache exists to avoid. Listing them means adding an input
	# to the mesher is a change that visibly has to be made here too.
	#
	# `_region_metres` rather than `terrain.region_size`: chunk_spans cuts on region boundaries, and the
	# boundary it actually cuts on is region_size * vertex_spacing, so the metres are the mesh input and
	# the region count alone would miss a vertex_spacing change.
	#
	# The cross-section terms come through `half_width(resolved_lane_count())` rather than by reading
	# lane_width and lane_count separately, so this digest and the brush's `road_content_signature` share
	# ONE reading of the road type's geometry. They are still two lists, deliberately: the mesher reads
	# surface_material and depth_lift, which move no terrain vertex, and the height bake reads the batters
	# and max_grade, which move no ribbon vertex. Collapsing them into one would make each rebuild on the
	# other's edits — the churn the paragraph above exists to avoid.
	var digest := "%s|%s|%.4f|%s|%s|%s|%.4f|%.4f|%.4f|%d|%.4f|%.4f|%s|%s|%s|%.4f|%.4f|%.4f|%d|%d|%.4f|%.4f|%.4f|%.4f|%s|%s|%.4f|%.4f|%.4f|%.4f" % [
		p_brush.alignment_digest(),
		p_brush.junction_digest(),
		depth_lift,
		str(collision_enabled),
		str(markings_enabled),
		str(props_enabled),
		t.half_width(p_brush.resolved_lane_count()),
		t.shoulder_width,
		t.crown,
		t.crown_mode,
		t.max_superelevation,
		_region_metres(p_brush),
		str(t.surface_material.get_instance_id()) if t.surface_material != null else "",
		_segments_bridge_signature(p_brush),
		str(t.terminus_apron_enabled),
		t.terminus_apron_length,
		t.terminus_apron_drop,
		t.terminus_apron_roundness,
		t.default_left_kerb,
		t.default_right_kerb,
		t.kerb_width,
		t.kerb_height,
		t.kerb_rumble_pitch,
		t.kerb_rumble_depth,
		_segments_kerb_signature(p_brush),
		str(t.curve_widening_enabled),
		t.curve_widening_factor,
		t.curve_widening_max,
		t.mountain_banking_cap,
		t.hairpin_grade_compensation,
	]
	if not _chunks.is_empty() and _last_digest == digest:
		last_rebuilt = false
		return _chunks.size()

	_clear()
	_last_digest = digest
	last_rebuilt = true
	var plan: PackedVector2Array = run["plan"]
	var cum: PackedFloat32Array = run["cum"]
	var alignment: Pasture3DRoadAlignment = run["alignment"]
	var half: float = run["half_width"]
	var shoulder: float = t.shoulder_width
	var crown: float = t.crown

	var region := _region_metres(p_brush)
	var skips := p_brush.junction_skips()
	var extra_cuts := PackedFloat32Array()
	for seg: Pasture3DRoadSegment in p_brush._live_segments():
		if seg.left_kerb != Pasture3DRoadType.KerbType.INHERIT or seg.right_kerb != Pasture3DRoadType.KerbType.INHERIT or seg.is_bridge:
			extra_cuts.append(seg.start())
			extra_cuts.append(seg.end())
	var spans := Pasture3DRoadMesher.chunk_spans(plan, cum, region, skips, extra_cuts)
	if spans.is_empty():
		_why(p_brush, "no spans left: %.1f m of road, %.0f m regions, %d junction footprint(s)"
				% [cum[cum.size() - 1] if cum.size() > 0 else 0.0, region, skips.size()])
		return 0

	# When in TERRAIN_DRAPED mode, skip building ribbon meshes and ribbon colliders.
	# The road is purely graded and painted into the terrain heightfield.
	if t.surface_mode == Pasture3DRoadType.SurfaceMode.TERRAIN_DRAPED:
		_clear()
		_last_digest = digest
		last_rebuilt = true
		if props_enabled:
			var prop_transforms: Array = []
			for span in spans:
				prop_transforms.append_array(_prop_transforms(t, plan, cum, alignment, float(span[0]), float(span[1]), crown))
			_place_props(p_brush, t, prop_transforms)
		else:
			_place_props(p_brush, t, [])
		return 0

	var rejected := 0
	var prop_transforms: Array = []
	var surf_info: Pasture3DSurfaceInfo = t.get_surface_info()
	for span in spans:
		var meshes: Array = []
		var empty := false
		var mid := (float(span[0]) + float(span[1])) * 0.5
		var l_kerb: int = p_brush.left_kerb_at(mid)
		var r_kerb: int = p_brush.right_kerb_at(mid)
		var span_half := half
		if t != null and t.curve_widening_enabled and alignment != null:
			var k_mid: float = alignment.curvature_at(mid)
			span_half += clampf(t.curve_widening_factor * absf(k_mid), 0.0, t.curve_widening_max)
		for lod in Pasture3DRoadMesher.LOD_LEVELS:
			var arrays := Pasture3DRoadMesher.build_chunk(plan, cum, alignment, float(span[0]),
					float(span[1]), span_half, shoulder, crown, lod, depth_lift, false,
					t.crown_mode, t.max_superelevation,
					l_kerb, r_kerb, t.kerb_width, t.kerb_height, t.kerb_rumble_pitch, t.kerb_rumble_depth)
			if arrays.is_empty():
				empty = true
				break
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			if t.surface_material != null:
				mesh.surface_set_material(0, t.surface_material)
			meshes.append(mesh)
		if empty:
			rejected += 1
			continue
		var mi := MeshInstance3D.new()
		mi.name = "Chunk_%.0f" % float(span[0])
		mi.mesh = meshes[0]
		# The ribbon is authored in WORLD space by the mesher, so the host must not add a transform of
		# its own on top of it. A host that inherited the brush's transform would move the mesh and leave
		# the graded ground where it was.
		mi.top_level = true
		add_child(mi)
		var is_bridge_span: bool = p_brush.is_bridge_at(mid)
		var should_collide: bool = collision_enabled or is_bridge_span
		if should_collide:
			_add_collider(mi, plan, cum, alignment, float(span[0]), float(span[1]), span_half, shoulder, crown, surf_info,
					t.crown_mode, t.max_superelevation,
					l_kerb, r_kerb, t.kerb_width, t.kerb_height, t.kerb_rumble_pitch, t.kerb_rumble_depth)
		var markings: MeshInstance3D = null
		if markings_enabled:
			markings = _add_markings(mi, p_brush, plan, cum, alignment, float(span[0]), float(span[1]),
					crown)
		if props_enabled:
			prop_transforms.append_array(_prop_transforms(t, plan, cum, alignment, float(span[0]),
					float(span[1]), crown))
		var at := Pasture3DRoadGrader.plan_point_at(plan, cum, mid)
		_chunks.append({
			"node": mi,
			"centre": Vector3(at.x, alignment.height_at(mid), at.y),
			# The chunk's own extent, which is what distance is measured to. See `_distance_to`.
			"bounds": (meshes[0] as ArrayMesh).get_aabb(),
			"meshes": meshes,
			"lod": 0,
			# Hidden as the chunk coarsens -- see `MARKINGS_MAX_LOD`. Carried on the chunk rather than
			# found by name at LOD time: a `get_node` per chunk per frame, to answer a question the
			# build already knew.
			"markings": markings,
		})

	if t.terminus_apron_enabled and not spans.is_empty():
		var total_s: float = cum[cum.size() - 1] if cum.size() > 0 else 0.0
		var has_start_junction := false
		var has_end_junction := false
		for skip in skips:
			if float(skip[0]) <= 0.5:
				has_start_junction = true
			if float(skip[1]) >= total_s - 0.5:
				has_end_junction = true

		if not has_start_junction:
			var start_arrays := Pasture3DRoadMesher.build_terminus_apron(
					plan, cum, alignment, 0.0, half, shoulder, crown, true,
					t.terminus_apron_length, t.terminus_apron_drop, 4, depth_lift,
					t.crown_mode, t.max_superelevation, t.terminus_apron_roundness)
			if not start_arrays.is_empty():
				var mesh := ArrayMesh.new()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, start_arrays)
				if t.surface_material != null:
					mesh.surface_set_material(0, t.surface_material)
				var mi := MeshInstance3D.new()
				mi.name = "TerminusApron_Start"
				mi.mesh = mesh
				mi.top_level = true
				add_child(mi)
				if collision_enabled:
					var col_arrays := Pasture3DRoadMesher.build_terminus_apron(
							plan, cum, alignment, 0.0, half, shoulder, crown, true,
							t.terminus_apron_length, t.terminus_apron_drop, 4, 0.0,
							t.crown_mode, t.max_superelevation, t.terminus_apron_roundness)
					if not col_arrays.is_empty():
						_collider_from(mi, col_arrays, surf_info)
				var at0 := Pasture3DRoadGrader.plan_point_at(plan, cum, 0.0)
				_chunks.append({
					"node": mi,
					"centre": Vector3(at0.x, alignment.height_at(0.0), at0.y),
					"bounds": mesh.get_aabb(),
					"meshes": [mesh, mesh, mesh, mesh],
					"lod": 0,
					"markings": null,
				})

		if not has_end_junction:
			var end_arrays := Pasture3DRoadMesher.build_terminus_apron(
					plan, cum, alignment, total_s, half, shoulder, crown, false,
					t.terminus_apron_length, t.terminus_apron_drop, 4, depth_lift,
					t.crown_mode, t.max_superelevation, t.terminus_apron_roundness)
			if not end_arrays.is_empty():
				var mesh := ArrayMesh.new()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, end_arrays)
				if t.surface_material != null:
					mesh.surface_set_material(0, t.surface_material)
				var mi := MeshInstance3D.new()
				mi.name = "TerminusApron_End"
				mi.mesh = mesh
				mi.top_level = true
				add_child(mi)
				if collision_enabled:
					var col_arrays := Pasture3DRoadMesher.build_terminus_apron(
							plan, cum, alignment, total_s, half, shoulder, crown, false,
							t.terminus_apron_length, t.terminus_apron_drop, 4, 0.0,
							t.crown_mode, t.max_superelevation, t.terminus_apron_roundness)
					if not col_arrays.is_empty():
						_collider_from(mi, col_arrays, surf_info)
				var at_end := Pasture3DRoadGrader.plan_point_at(plan, cum, total_s)
				_chunks.append({
					"node": mi,
					"centre": Vector3(at_end.x, alignment.height_at(total_s), at_end.y),
					"bounds": mesh.get_aabb(),
					"meshes": [mesh, mesh, mesh, mesh],
					"lod": 0,
					"markings": null,
				})

	# Called even when props are OFF, with nothing to place: it clears the instancer by mesh id first, so
	# switching props off removes the ones already out there. Skipping the call entirely would leave a
	# verge full of props that no longer has a setting saying they should be there.
	_place_props(p_brush, t, prop_transforms if props_enabled else [])
	_dirty_lod = true
	_report = true
	if _chunks.is_empty():
		_why(p_brush, "%d span(s) were found but every one failed to mesh" % rejected)
	return _chunks.size()


## One chunk's collider, as a child of the chunk so it is culled, hidden and freed with it.
##
## Built at lift ZERO, and that is the whole subtlety: the ribbon is lifted DEPTH_LIFT above the ground
## so it cannot z-fight with the surface it was graded into, but a COLLIDER lifted by the same amount is
## a road that sits two centimetres above itself. A wheel rests on it early, a raycast looking for the
## ground hits the road before the terrain, and "on the road" and "on the ground" stop being the same
## height. The lift is a rendering fix; collision has no z-fighting to fix.
##
## LOD 0 only. A collider that changed shape with camera distance would move the ground under a car
## parked at the edge of a threshold.
func _add_collider(p_parent: Node3D, p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_from: float, p_to: float, p_half: float,
		p_shoulder: float, p_crown: float, p_surface_info: Pasture3DSurfaceInfo = null,
		p_crown_mode: int = 0, p_max_bank: float = 0.0,
		p_left_kerb: int = 0, p_right_kerb: int = 0,
		p_kerb_width: float = 0.8, p_kerb_height: float = 0.08,
		p_kerb_rumble_pitch: float = 0.4, p_kerb_rumble_depth: float = 0.02) -> void:
	var arrays := Pasture3DRoadMesher.build_chunk(p_plan, p_cum, p_alignment, p_from, p_to, p_half,
			p_shoulder, p_crown, 0, 0.0, false, p_crown_mode, p_max_bank,
			p_left_kerb, p_right_kerb, p_kerb_width, p_kerb_height, p_kerb_rumble_pitch, p_kerb_rumble_depth)
	if arrays.is_empty():
		return
	_collider_from(p_parent, arrays, p_surface_info)


## A trimesh body over one surface's triangles, on the road physics layer.
##
## Takes ARRAYS rather than building its own, so the apron and the ribbon get colliders from the same
## code and cannot disagree about the layer, the shape type or the winding.
func _collider_from(p_parent: Node3D, p_arrays: Array, p_surface_info: Pasture3DSurfaceInfo = null) -> void:
	var faces := PackedVector3Array()
	var verts: PackedVector3Array = p_arrays[Mesh.ARRAY_VERTEX]
	for i: int in p_arrays[Mesh.ARRAY_INDEX]:
		faces.append(verts[i])
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var body := StaticBody3D.new()
	body.name = "Collision"
	_colliders += 1
	body.collision_layer = collision_layer
	body.collision_mask = collision_mask
	if p_surface_info != null:
		var pm := PhysicsMaterial.new()
		pm.friction = p_surface_info.friction_longitudinal
		pm.bounce = 0.0
		body.physics_material_override = pm
		body.set_meta(&"pasture3d_surface", p_surface_info)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	p_parent.add_child(body)


## One chunk's lane markings, as a child of the chunk for the same reason the collider is.
##
## The stripe plan is resolved at the START of the span rather than once per road: `resolved_lanes` and
## `resolved_one_way` both take a distance, so a road that gains a lane part way along gains a lane line
## there too. Resolving once for the whole road would draw the first chunk's cross-section over all of it.
func _add_markings(p_parent: Node3D, p_brush: Pasture3DRoadBrush, p_plan: PackedVector2Array,
		p_cum: PackedFloat32Array, p_alignment: Pasture3DRoadAlignment, p_from: float, p_to: float,
		p_crown: float) -> MeshInstance3D:
	var t: Pasture3DRoadType = p_brush.resolved_road_type()
	if t == null:
		return null
	var stripes := Pasture3DRoadMarkings.plan(p_brush.resolved_lanes(p_from), t.divider_type,
			p_brush.resolved_one_way(p_from))
	var arrays := Pasture3DRoadMarkings.build(p_plan, p_cum, p_alignment, stripes, p_from, p_to,
			p_crown, 2.0, depth_lift)
	if arrays.is_empty():
		return null
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if markings_material != null:
		mesh.surface_set_material(0, markings_material)
	var mi := MeshInstance3D.new()
	mi.name = "Markings"
	mi.mesh = mesh
	p_parent.add_child(mi)
	return mi


## The transforms for one span's verge props. Nothing is placed here — they are accumulated across the
## whole road and handed over in one call, because the instancer is cleared per mesh id and a per-span
## hand-off would leave only the last span's props standing.
func _prop_transforms(p_type: Pasture3DRoadType, p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_from: float, p_to: float, p_crown: float) -> Array:
	if p_type == null or p_type.prop_mesh_id < 0:
		return []
	if p_type.prop_both_sides:
		return Pasture3DRoadProps.place_both(p_plan, p_cum, p_alignment, p_from, p_to,
				p_type.prop_offset, p_type.prop_spacing, p_crown)
	return Pasture3DRoadProps.place(p_plan, p_cum, p_alignment, p_from, p_to, p_type.prop_offset,
			p_type.prop_spacing, p_crown)


## Hand the road's props to the terrain's instancer, which keys multimeshes by region location — so road
## props stream with terrain regions and need no streaming code of their own (§10).
##
## Cleared by mesh id before placing, for the reason the paint pass clears before painting: nothing else
## removes them, so moving a road would leave its old guardrail standing in a field. The cost is that a
## road sharing a mesh id with another road clears that road's props too — which is why the clear is
## here, once per rebuild, rather than per span.
func _place_props(p_brush: Pasture3DRoadBrush, p_type: Pasture3DRoadType, p_transforms: Array) -> void:
	if p_type == null or p_type.prop_mesh_id < 0 or p_brush == null or p_brush.terrain == null:
		return
	var inst = p_brush.terrain.get_instancer()
	if inst == null:
		return
	inst.clear_by_mesh(p_type.prop_mesh_id)
	if p_transforms.is_empty():
		return
	inst.add_transforms(p_type.prop_mesh_id, p_transforms, PackedColorArray(), true)


## Build one apron per junction. `p_aprons` is prepared by the network, each entry
## `{center, radius, plan, cum, alignment, crown, material}` — the host does no lookups of its own.
##
## Hosted here rather than on a road's own host because a junction belongs to no single road: it is where
## several stop being separate. Put on the network's host, it is rebuilt once per resolve instead of once
## per participant, and there is no question of which road owns it.
##
## Each apron carries one mesh repeated across the LOD slots. A footprint of a few dozen triangles has nothing
## worth decimating, and sharing the resource costs nothing — what it buys is that aprons go through the
## same distance culling and the same far-hide as everything else, with no second code path.
## Stable, hashable digest of one apron's geometry, markings, and display parameters.
func _apron_digest(a: Dictionary, p_lift: float) -> String:
	if a.has("_cached_digest"):
		var cd: Dictionary = a["_cached_digest"]
		if cd.get("lift") == p_lift and cd.get("col") == collision_enabled and cd.get("marks") == markings_enabled and cd.get("col_lay") == collision_layer and cd.get("col_mask") == collision_mask:
			return cd.get("digest", "")

	var parts: Array = []
	var c: Vector2 = a.get("center", Vector2.ZERO)
	parts.append("%.3f,%.3f" % [c.x, c.y])
	parts.append("%.3f" % float(a.get("center_h", 0.0)))
	parts.append("%.3f" % p_lift)
	parts.append(str(collision_enabled))
	if collision_enabled:
		parts.append(str(collision_layer))
		parts.append(str(collision_mask))
	parts.append(str(markings_enabled))
	var mat: Material = a.get("material")
	parts.append(str(mat.get_instance_id()) if mat != null else "0")
	var mmat: Material = markings_material
	parts.append(str(mmat.get_instance_id()) if mmat != null else "0")
	var b: PackedVector2Array = a.get("boundary", PackedVector2Array())
	parts.append(str(b.size()))
	for pt in b:
		parts.append("%.3f,%.3f" % [pt.x, pt.y])
	var h: PackedFloat32Array = a.get("heights", PackedFloat32Array())
	parts.append(str(h.size()))
	for y in h:
		parts.append("%.3f" % y)
	var marks: Array = a.get("markings", [])
	parts.append(str(marks.size()))
	for m in marks:
		if m is Dictionary:
			parts.append(str(m.get("kind", 0)))
			parts.append("%.3f" % float(m.get("y", 0.0)))
			var quad: PackedVector2Array = m.get("quad", PackedVector2Array())
			parts.append(str(quad.size()))
			for qp in quad:
				parts.append("%.3f,%.3f" % [qp.x, qp.y])
	var faces: Array = a.get("arm_faces", [])
	parts.append(str(faces.size()))
	for f in faces:
		if f is Dictionary:
			parts.append("%.3f:%.3f:%.3f:%.3f" % [float(f.get("z", 0.0)), float(f.get("bank", 0.0)),
					float(f.get("crown", 0.0)), float(f.get("grade", 0.0))])
	var res: String = ":".join(parts)
	a["_cached_digest"] = {
		"digest": res,
		"lift": p_lift,
		"col": collision_enabled,
		"marks": markings_enabled,
		"col_lay": collision_layer,
		"col_mask": collision_mask,
	}
	return res


## Build one apron per junction. `p_aprons` is prepared by the network, each entry
## `{center, radius, plan, cum, alignment, crown, material}` — the host does no lookups of its own.
##
## Hosted here rather than on a road's own host because a junction belongs to no single road: it is where
## several stop being separate. Put on the network's host, it is rebuilt once per resolve instead of once
## per participant, and there is no question of which road owns it.
##
## Each apron carries one mesh repeated across the LOD slots. A footprint of a few dozen triangles has nothing
## worth decimating, and sharing the resource costs nothing — what it buys is that aprons go through the
## same distance culling and the same far-hide as everything else, with no second code path.
func rebuild_aprons(p_aprons: Array, p_lift: float = Pasture3DRoadMesher.DEPTH_LIFT) -> int:
	depth_lift = p_lift
	var active_jids := {}
	for a: Dictionary in p_aprons:
		var jid: String = str(a.get("id", "?"))
		active_jids[jid] = true

	# Drop aprons that are no longer present in p_aprons
	for jid in _apron_chunks.keys():
		if not active_jids.has(jid):
			var old_c: Dictionary = _apron_chunks[jid]
			var n: Node = old_c.get("node")
			if is_instance_valid(n):
				if n.get_parent() != null:
					n.get_parent().remove_child(n)
				n.queue_free()
			_apron_chunks.erase(jid)
			_apron_digests.erase(jid)

	for a: Dictionary in p_aprons:
		var jid: String = str(a.get("id", "?"))
		var d := _apron_digest(a, p_lift)
		if _apron_chunks.has(jid) and _apron_digests.get(jid) == d and is_instance_valid(_apron_chunks[jid].get("node")):
			continue # Unchanged: retain existing mesh, collision, and markings intact

		if _apron_chunks.has(jid):
			var old_c: Dictionary = _apron_chunks[jid]
			var n: Node = old_c.get("node")
			if is_instance_valid(n):
				if n.get_parent() != null:
					n.get_parent().remove_child(n)
				n.queue_free()
			_apron_chunks.erase(jid)
			_apron_digests.erase(jid)

		var arm_faces: Array = a.get("arm_faces", [])
		var boundary: PackedVector2Array = a["boundary"]
		if not arm_faces.is_empty():
			boundary = Pasture3DRoadMesher.densify_polygon(boundary, 1.0)
		var arrays := Pasture3DRoadMesher.build_footprint(a["center"], boundary, a["heights"],
				float(a["center_h"]), p_lift, arm_faces)
		if arrays.is_empty():
			continue
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat: Material = a.get("material")
		if mat != null:
			mesh.surface_set_material(0, mat)
		var mi := MeshInstance3D.new()
		mi.name = "Junction_%s" % jid
		mi.mesh = mesh
		mi.top_level = true
		add_child(mi)
		var markings := _add_junction_markings(mi, a, p_lift)
		if collision_enabled:
			# Rebuilt at lift ZERO, like the ribbon's (see `_add_collider`), and NOT reused from the mesh
			# above — that one carries the render lift. Without this the road has a hole in its collision
			# at every junction: a raycast asking "am I on tarmac" answers yes along the road and no in the
			# middle of the crossroads, which is exactly where a vehicle most needs the answer.
			var solid := Pasture3DRoadMesher.build_footprint(a["center"], boundary, a["heights"],
					float(a["center_h"]), 0.0, arm_faces)
			if not solid.is_empty():
				_collider_from(mi, solid, a.get("surface_info"))
		var meshes: Array = []
		for _lod in Pasture3DRoadMesher.LOD_LEVELS:
			meshes.append(mesh)
		var c: Vector2 = a["center"]
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		_apron_chunks[jid] = {
			"node": mi,
			"centre": Vector3(c.x, verts[0].y, c.y),
			"bounds": mesh.get_aabb(),
			"meshes": meshes,
			"lod": 0,
			"markings": markings,
		}
		_apron_digests[jid] = d

	_chunks = _apron_chunks.values()
	var col_count := 0
	for ch in _chunks:
		var n: Node = ch.get("node")
		if is_instance_valid(n) and n.has_node("Collision"):
			col_count += 1
	_colliders = col_count
	_dirty_lod = true
	_report = true
	return _chunks.size()


func _clear_walls() -> void:
	if _walls != null and is_instance_valid(_walls):
		if _walls.get_parent() != null:
			_walls.get_parent().remove_child(_walls)
		_walls.queue_free()
	_walls = null
	_walls_digest = 0
	wall_quads = 0


## Build the retaining walls where the grader capped a batter, as one mesh.
##
## ---- WHERE A WALL STANDS ----
##
## The grader (`Pasture3DRoadGrader.batter_height`) runs the batter out from the formation edge until it
## has climbed or fallen the wall height, and past that run leaves the ground ALONE. So the terrain holds
## a batter up to `wall_run` and raw hillside beyond, and the step between them is the wall. This reads
## both halves back rather than recomputing the grade: the batter line from the same definition the
## grader used, the hillside from the baked terrain just past the run. Where that hillside sits within
## WALL_MIN_FACE of the batter's end there is no step, and no wall is drawn.
##
## ---- WHICH SIDE OF THE STEP ----
##
## The heightfield cannot draw a vertical face: between the last graded vertex and the first untouched
## one it draws a steep triangle a vertex apart. The wall is put on the side of that triangle that HIDES
## it -- a fill wall out past it, on the low ground, facing away from the road; a cut wall in front of it,
## on the batter, facing the road -- and a cap spans the band between the face and the run at the wall's
## top, so the steep triangle is covered from both sides.
func _rebuild_walls(p_brush: Pasture3DRoadBrush, p_run: Dictionary, p_type: Pasture3DRoadType) -> void:
	var alignment: Pasture3DRoadAlignment = p_run["alignment"]
	var plan: PackedVector2Array = p_run["plan"]
	var cum: PackedFloat32Array = p_run["cum"]
	var terrain: Variant = p_brush.terrain
	if alignment == null or alignment.count() < 2 or plan.size() < 2 or terrain == null or terrain.data == null:
		_clear_walls()
		return
	var prof := p_brush.grading_profile(p_brush.road_modifier(), alignment.ds, alignment.count())
	var cut_wall := float(prof.get("cut_wall_height", 0.0))
	var fill_wall := float(prof.get("fill_wall_height", 0.0))
	if cut_wall <= 0.0 and fill_wall <= 0.0:
		_clear_walls()
		return
	var half: PackedFloat32Array = prof["half"]
	var shoulder: PackedFloat32Array = prof["shoulder"]
	var suppress: PackedByteArray = prof["suppress"]
	var skip: PackedByteArray = prof["skip"]
	var crown := float(prof.get("crown", 0.05))
	var cut_b := maxf(float(prof.get("cut_batter", 1.0)), 0.01)
	var fill_b := maxf(float(prof.get("fill_batter", 0.6)), 0.01)
	var hinge := maxf(float(prof.get("hinge_rounding", 0.0)), 0.0)
	var crown_mode: int = p_type.crown_mode
	var max_bank: float = p_type.max_superelevation
	var band := 1.5 * float(terrain.vertex_spacing)

	# Each side's walls as rows of [position along the road, the four heights/offsets], split wherever a
	# sample has no wall so a strip never bridges a gap.
	var strips: Array = []
	var digest := PackedFloat32Array()
	for side in [-1.0, 1.0]:
		for kind in [0, 1]: # 0 fill, 1 cut
			var height := fill_wall if kind == 0 else cut_wall
			if height <= 0.0:
				continue
			var cur: Array = []
			for i in alignment.count():
				var row := _wall_row(alignment, plan, cum, i, side, kind, height, half, shoulder, crown,
						crown_mode, max_bank, cut_b, fill_b, hinge, band, suppress, skip, terrain)
				if row.is_empty():
					if cur.size() >= 2:
						strips.append({"side": side, "kind": kind, "rows": cur})
					cur = []
					continue
				cur.append(row)
				for v in row:
					if v is Vector3:
						digest.append_array([v.x, v.y, v.z])
			if cur.size() >= 2:
				strips.append({"side": side, "kind": kind, "rows": cur})
	var h := hash(digest) ^ hash(p_type.wall_material.get_instance_id() if p_type.wall_material != null else 0)
	if h == _walls_digest and (_walls != null or strips.is_empty()):
		return
	_clear_walls()
	_walls_digest = h
	if strips.is_empty():
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quads := 0
	for strip in strips:
		var rows: Array = strip["rows"]
		for r in range(rows.size() - 1):
			var a: Array = rows[r]
			var b: Array = rows[r + 1]
			# a/b: [face_top, face_bottom, cap_back, outward_normal]
			var n_face: Vector3 = (a[3] + b[3]).normalized()
			_quad(st, a[0], b[0], b[1], a[1], n_face)
			_quad(st, a[2], b[2], b[0], a[0], Vector3.UP)
			quads += 2
	var mesh := st.commit()
	_walls = MeshInstance3D.new()
	_walls.name = "RetainingWalls"
	_walls.top_level = true
	_walls.mesh = mesh
	var mat: Material = p_type.wall_material
	if mat == null:
		var sm := StandardMaterial3D.new()
		sm.albedo_color = Color(0.55, 0.54, 0.5)
		sm.roughness = 0.95
		sm.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat = sm
	_walls.material_override = mat
	add_child(_walls)
	wall_quads = quads


## One wall cross-section at alignment sample `p_i`, or [] where no wall stands there:
## [face top, face bottom, cap back edge, face normal], world space. See `_rebuild_walls`.
func _wall_row(p_al: Pasture3DRoadAlignment, p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_i: int, p_side: float, p_kind: int, p_height: float, p_half: PackedFloat32Array,
		p_shoulder: PackedFloat32Array, p_crown: float, p_crown_mode: int, p_max_bank: float,
		p_cut_b: float, p_fill_b: float, p_hinge: float, p_band: float, p_suppress: PackedByteArray,
		p_skip: PackedByteArray, p_terrain: Variant) -> Array:
	# A bridge grades nothing and a junction's ground is the junction's: no batter, so no wall.
	if (p_i < p_suppress.size() and p_suppress[p_i] != 0) or (p_i < p_skip.size() and p_skip[p_i] != 0):
		return []
	var s := float(p_i) * p_al.ds
	var total: float = p_cum[p_cum.size() - 1]
	if s > total:
		return []
	var half: float = p_half[p_i] if p_i < p_half.size() else 3.5
	var shoulder: float = p_shoulder[p_i] if p_i < p_shoulder.size() else 0.5
	var edge_d := half + shoulder
	var z_ref := p_al.height_at(s)
	var bank: float = p_al.bank[p_i] if p_i < p_al.bank.size() else 0.0
	var z_edge := Pasture3DRoadGrader.surface_height(z_ref, bank, p_crown, edge_d * p_side, half, p_crown_mode,
			p_max_bank)
	var g1 := Pasture3DRoadGrader.edge_slope(z_ref, bank, p_crown, edge_d, p_side, half, p_crown_mode,
			p_max_bank) if p_hinge > 0.0 else 0.0
	var g2 := -p_fill_b if p_kind == 0 else p_cut_b
	var run := Pasture3DRoadGrader.wall_run(p_height, g1, g2, p_hinge)
	if not is_finite(run):
		return []
	var c := Pasture3DRoadGrader.plan_point_at(p_plan, p_cum, s)
	var tan2 := Pasture3DRoadGrader._segment_dir_at(p_plan, p_cum, s, false)
	var across := Vector2(-tan2.y, tan2.x) * p_side # the grader's positive side is this across
	var at := func(p_d: float) -> Vector2: return c + across * p_d
	# The hillside the grader left alone, just past the run.
	var out_xz: Vector2 = at.call(edge_d + run + p_band)
	var ground: float = p_terrain.data.get_height(Vector3(out_xz.x, 0.0, out_xz.y))
	if not is_finite(ground):
		return []
	var top_line := Pasture3DRoadGrader.batter_line(z_edge, g1, g2, run, p_hinge)
	var n3 := Vector3(across.x, 0.0, across.y)
	if p_kind == 0:
		# FILL: the batter stops `p_height` below the edge and the hillside is further down still.
		if ground > top_line - WALL_MIN_FACE:
			return []
		var face: Vector2 = at.call(edge_d + run + p_band)
		var back: Vector2 = at.call(edge_d + run)
		return [Vector3(face.x, top_line, face.y), Vector3(face.x, ground - WALL_EMBED, face.y),
				Vector3(back.x, top_line, back.y), n3]
	# CUT: the batter stops `p_height` above the edge and the hillside stands higher.
	if ground < top_line + WALL_MIN_FACE:
		return []
	var face_d := maxf(edge_d + run - p_band, edge_d)
	var face_c: Vector2 = at.call(face_d)
	var low := Pasture3DRoadGrader.batter_line(z_edge, g1, g2, face_d - edge_d, p_hinge)
	var back_c: Vector2 = at.call(edge_d + run)
	return [Vector3(face_c.x, ground, face_c.y), Vector3(face_c.x, low - WALL_EMBED, face_c.y),
			Vector3(back_c.x, ground, back_c.y), -n3]


## One quad a-b-c-d (in order around it) facing `p_n`. Godot's front face winds CLOCKWISE seen from the
## front, which is the opposite of the right-hand rule, so the order is chosen by testing the geometric
## normal against `p_n` rather than assumed.
static func _quad(p_st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, p_n: Vector3) -> void:
	var geo := (b - a).cross(c - a)
	var tris: Array = [[a, b, c], [a, c, d]] if geo.dot(p_n) < 0.0 else [[a, c, b], [a, d, c]]
	for tri in tris:
		for v in tri:
			p_st.set_normal(p_n)
			p_st.add_vertex(v)


## World metres across one terrain region — the unit chunk cuts snap to, so a chunk's lifetime matches
## the region it sits in.
func _region_metres(p_brush: Pasture3DRoadBrush) -> float:
	var terrain: Variant = p_brush.terrain
	if terrain == null:
		return 0.0
	return maxf(float(terrain.region_size) * terrain.vertex_spacing, 1.0)


## Structure flags across segments (bridges have unconditional collision and change meshing).
func _segments_bridge_signature(p_brush: Pasture3DRoadBrush) -> String:
	if p_brush == null or p_brush.segments.is_empty():
		return ""
	var s := ""
	for seg: Pasture3DRoadSegment in p_brush._live_segments():
		if seg.is_bridge:
			s += "B(%.1f,%.1f)" % [seg.start(), seg.end()]
	return s


## Kerb profile flags across segments and defaults.
func _segments_kerb_signature(p_brush: Pasture3DRoadBrush) -> String:
	if p_brush == null:
		return ""
	var s := ""
	if p_brush.road_defaults != null:
		s += "D(%d,%d)" % [p_brush.road_defaults.left_kerb, p_brush.road_defaults.right_kerb]
	for seg: Pasture3DRoadSegment in p_brush._live_segments():
		if seg.left_kerb != Pasture3DRoadType.KerbType.INHERIT or seg.right_kerb != Pasture3DRoadType.KerbType.INHERIT:
			s += "K(%.1f,%.1f,%d,%d)" % [seg.start(), seg.end(), seg.left_kerb, seg.right_kerb]
	return s


## Drop the previous build.
##
## `remove_child` FIRST and `queue_free` after, rather than `queue_free` alone. A queued node is still a
## child, still drawn and still colliding until the frame ends, so a rebuild that only queues leaves the
## old ribbon and the old shapes overlapping the new ones for a frame — visible as z-fighting on a
## road that just rebuilt, and as a doubled collider to anything raycasting in between. It also means a
## caller cannot look at the tree and see what it just built, which is how a criterion asserting that
## turning collision OFF removes the shapes ended up reading the shapes that were on their way out.
func _clear() -> void:
	for c in _chunks:
		var n: Node = c["node"]
		if is_instance_valid(n):
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.queue_free()
	_chunks.clear()
	_apron_chunks.clear()
	_apron_digests.clear()
	_colliders = 0


## Pick each chunk's tier from its distance to the camera, and hide it once tier FAR is enough.
##
## Distance is to the chunk's NEAREST POINT, not to its centre — see `_distance_to`, which is where the
## reasoning lives, because measuring to the centre broke tier NEAR and made whole chunks pop.
func _process(_delta: float) -> void:
	if _chunks.is_empty():
		return
	var cam := _camera()
	if cam == null:
		# No camera to measure from. Everything stays at whatever it was, which for a fresh rebuild is
		# LOD 0 and visible — the right default, because a chunk nobody can measure should be SEEN rather
		# than culled by a distance that was never computed.
		return
	var eye := cam.global_position
	for c in _chunks:
		var mi: MeshInstance3D = c["node"]
		if not is_instance_valid(mi):
			continue
		var d := _distance_to(c, eye)
		_nearest = minf(_nearest, d)
		if far_distance > 0.0:
			# Hysteresis both ways: hide only past far + band, show again only inside far - band. Without
			# the gap, a chunk sitting on the line toggles every frame.
			var shown: bool = mi.visible
			if shown and d > far_distance + lod_hysteresis:
				mi.visible = false
			elif not shown and d < far_distance - lod_hysteresis:
				mi.visible = true
			elif _dirty_lod:
				mi.visible = d <= far_distance
			if not mi.visible:
				# Nothing to fade into: the carriageway is already painted into the terrain, so stopping is
				# the whole transition (§10).
				_hidden += 1
				continue
		else:
			mi.visible = true
		var want := lod_for(d, int(c["lod"]))
		if want != int(c["lod"]) or _dirty_lod:
			c["lod"] = want
			mi.mesh = c["meshes"][want]
			# Markings follow the tier the ribbon is at, not a distance of their own: two thresholds over
			# one distance would disagree in the hysteresis band and leave a stripe hanging off a chunk
			# that had already coarsened under it.
			var marks = c.get("markings")
			if is_instance_valid(marks):
				marks.visible = want <= MARKINGS_MAX_LOD
	# Report ONCE per rebuild, on the first frame that had a camera. A ribbon that is built, parented and
	# hidden looks exactly like a ribbon that was never built, and the two were confused for a whole
	# debugging session — so the host says which it is, with the distance that decided it.
	if _report and Engine.is_editor_hint():
		_report = false
		var tiers := PackedInt32Array()
		tiers.resize(Pasture3DRoadMesher.LOD_LEVELS)
		for c in _chunks:
			tiers[int(c["lod"])] += 1
		print("[Pasture3D] %s: %d chunk(s) at LOD %s, %d hidden beyond %.0f m; nearest is %.0f m; %s"
				% [get_parent().name if get_parent() != null else name, _chunks.size(), str(Array(tiers)),
					_hidden, far_distance, _nearest,
					("%d collider(s)" % _colliders) if collision_enabled else "no collision"])
	_hidden = 0
	_nearest = INF
	_dirty_lod = false


## Distance from `p_eye` to the NEAREST POINT of a chunk, not to its centre.
##
## ---- WHY THE CENTRE IS THE WRONG POINT ----
##
## A chunk is cut to a terrain region, so at the default 256 m region it is up to 256 m LONG. Measuring
## to its centre means a chunk you are STANDING ON reports up to 128 m, and two things follow, both of
## which look like other bugs:
##
##   The chunk under your wheels is given a distant tier. With the default thresholds it never reaches
##   LOD 0 at all on a full-length chunk, so tier NEAR effectively does not exist and the road looks
##   permanently coarse — which reads as the LOD meshes being wrong rather than as the distance being
##   measured to the wrong place.
##
##   Whole chunks pop. As the camera moves, a centre crosses `far_distance` and 256 m of road appears or
##   vanishes in one frame, while the near end of that chunk was only 470 m away. That is the snapping.
##
## The mesh's own AABB is exact and already computed, so this costs a clamp.
func _distance_to(p_chunk: Dictionary, p_eye: Vector3) -> float:
	var box: Variant = p_chunk.get("bounds")
	if box == null:
		return p_eye.distance_to(p_chunk["centre"])
	var aabb: AABB = box
	var near := Vector3(
			clampf(p_eye.x, aabb.position.x, aabb.end.x),
			clampf(p_eye.y, aabb.position.y, aabb.end.y),
			clampf(p_eye.z, aabb.position.z, aabb.end.z))
	return p_eye.distance_to(near)


## The tier for a distance: the first band it falls inside, clamped to the coarsest mesh that exists.
##
## `p_current` is the tier the chunk is already showing. Passing it applies HYSTERESIS: the chunk keeps
## what it has until the distance clears the threshold by `lod_hysteresis`, so a camera hovering on a
## line does not swap the mesh every frame. Pass -1 for the raw answer.
##
## Public because it is the one part of the host that is arithmetic rather than scene-tree work, and an
## off-by-one band is invisible — the road still draws, at the wrong tier, and looks like the meshes
## being wrong rather than like the thresholds being read wrong.
func lod_for(p_distance: float, p_current: int = -1) -> int:
	var meshes_max := Pasture3DRoadMesher.LOD_LEVELS - 1
	var want := meshes_max
	for i in lod_distances.size():
		if p_distance < lod_distances[i]:
			want = mini(i, meshes_max)
			break
	if p_current < 0 or want == p_current or lod_hysteresis <= 0.0:
		return want
	# Moving to a COARSER tier needs the distance to be past that tier's own lower edge by the band;
	# moving FINER needs it to be inside the current tier's lower edge by the band. Asymmetric on purpose:
	# the band is measured against the line being crossed, not against where the chunk happens to be.
	var edge := p_current - 1 if want < p_current else p_current
	if edge < 0 or edge >= lod_distances.size():
		return want
	var line := lod_distances[edge]
	if want > p_current and p_distance < line + lod_hysteresis:
		return p_current
	if want < p_current and p_distance > line - lod_hysteresis:
		return p_current
	return want


## The camera to measure from: the editor's viewport camera when there is one, the game's otherwise.
## Both, because a road that only LODs at runtime cannot be judged in the editor, which is where the
## thresholds are actually chosen.
func _camera() -> Camera3D:
	# Reached through the singleton rather than by naming the class: EditorInterface does not exist in an
	# exported build, and a direct reference makes this script fail to load in the shipped game — which
	# would take the road meshes out of the very build they are for.
	if Engine.is_editor_hint() and Engine.has_singleton("EditorInterface"):
		var ed: Object = Engine.get_singleton("EditorInterface")
		var vp: Variant = ed.get_editor_viewport_3d(0)
		if vp != null:
			return vp.get_camera_3d()
	var world := get_viewport()
	return world.get_camera_3d() if world != null else null


## Say why a road built nothing. Every reason is otherwise silent and they all look identical: a road
## with no ribbon and a road whose ribbon was never asked for are the same picture.
func _why(p_brush: Pasture3DRoadBrush, p_reason: String) -> void:
	if Engine.is_editor_hint():
		print("[Pasture3D] %s: no ribbon — %s" % [p_brush.name, p_reason])


## The ribbon as TriangleMeshes in `p_node`'s local space, for the editor gizmo's collision triangles.
##
## The gizmo used to build these itself, inside `_redraw`: for every chunk it copied the vertex array,
## transformed it, built an ArrayMesh and called `generate_triangle_mesh()` — a BVH build per chunk. That
## ran on every redraw, which the editor issues on selection, on camera moves and on every transform
## change, so simply dragging a road paid a full pick-geometry rebuild per frame while the geometry
## itself had not changed.
##
## The cache key is the ribbon's own rebuild digest plus the node transform, because those are the only
## two things the result depends on: `_last_digest` changes exactly when the chunk meshes do, and the
## transform is what takes them from world space to local. Nothing else in a redraw can move a triangle.
func pick_meshes(p_node: Node3D) -> Array[TriangleMesh]:
	if p_node == null:
		return []
	var key := "%s|%s" % [_last_digest, str(p_node.global_transform)]
	if key == _pick_digest and not _pick_meshes.is_empty():
		return _pick_meshes

	var out: Array[TriangleMesh] = []
	for chunk in _chunks:
		var meshes: Array = chunk.get("meshes", [])
		if meshes.is_empty() or not (meshes[0] is ArrayMesh):
			continue
		var m: ArrayMesh = meshes[0]
		if m.get_surface_count() == 0:
			continue
		var arrays := m.surface_get_arrays(0)
		var wverts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var local_verts := PackedVector3Array()
		local_verts.resize(wverts.size())
		for vi in wverts.size():
			local_verts[vi] = p_node.to_local(wverts[vi])
		arrays[Mesh.ARRAY_VERTEX] = local_verts
		var am := ArrayMesh.new()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var tm := am.generate_triangle_mesh()
		if tm != null:
			out.append(tm)

	# Only a non-empty result is cached. An empty one means the ribbon is not built YET — a state that
	# ends without the digest changing — so caching it would leave the road unpickable until the next
	# rebuild.
	if not out.is_empty():
		_pick_meshes = out
		_pick_digest = key
	return out


## One junction's markings, as a child of its surface for the same reason a chunk's markings are a child
## of the chunk: they share its transform, its visibility and its culling, and nothing has to keep a
## second list in step with the first.
##
## THE HEIGHT COMES FROM THE SURFACE, not from the road's solved elevation. `Pasture3DRoadStopLine.point`
## carries the road's centreline height, which is a crown above the lane the bar is painted across; a bar
## built at that height floats at its middle and sinks at its ends, by several times MARKING_LIFT on any
## road with a camber. So the same sampler `build_footprint` used for the surface answers here too, and
## the paint sits on the geometry it was planned against by construction — now literally, since
## `footprint_height_at` interpolates over the very fan the surface is built from.
func _add_junction_markings(p_parent: Node3D, p_apron: Dictionary, p_lift: float) -> MeshInstance3D:
	var prims: Array = p_apron.get("markings", [])
	if prims.is_empty():
		return null
	var centre: Vector2 = p_apron["center"]
	var boundary: PackedVector2Array = p_apron["boundary"]
	var heights: PackedFloat32Array = p_apron["heights"]
	var centre_h := float(p_apron["center_h"])
	var arm_faces: Array = p_apron.get("arm_faces", [])
	var sampler := func(at: Vector2) -> float:
		return Pasture3DRoadMesher.footprint_height_at(at, centre, boundary, heights, centre_h, arm_faces)
	var arrays := Pasture3DRoadJunctionMarkings.build_junction(prims, sampler, p_lift)
	if arrays.is_empty():
		return null
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if markings_material != null:
		mesh.surface_set_material(0, markings_material)
	var mi := MeshInstance3D.new()
	mi.name = "Markings"
	mi.mesh = mesh
	p_parent.add_child(mi)
	return mi
