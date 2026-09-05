# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Junction markings — tier NEAR (P9a). A PURE KERNEL, like Pasture3DRoadMarkings, and split the same
# way and for the same reason:
#
#   plan_junction() — WHERE is the paint? Answers in WORLD space, as numbers a gate can assert.
#   build_junction() — what triangles? Extrudes the plan onto a surface and nothing more.
#
# ---- WHY THIS IS A SECOND KERNEL AND NOT A GENERALISED `Pasture3DRoadMarkings.plan` ----
#
# See the spec §2.3. `plan()` works because a road has ONE across-axis: every marking on it is a `u`, a
# signed distance from the centreline, and the builder turns `u` into a position by asking the road.
# A junction has three or more across-axes and no cross-section at all, so there is no `u` to answer in.
# Generalising `plan()` would mean giving it a road argument it currently does not need, on every call,
# to serve the one caller that has no single road — which is how a kernel that fits its job stops
# fitting it.
#
# So this one answers in world XZ and pays for it by having to be told the ground. That is the whole
# trade, and it is why the two kernels stay simple in different ways.
@tool
class_name Pasture3DRoadJunctionMarkings
extends RefCounted

## What a primitive is. STOP_BAR is the only kind built so far; the spec's ARM_CONTINUATION and
## CONNECTOR_GUIDE come next and share this plan/build split.
enum Kind { STOP_BAR }

## How far a stop bar reaches ALONG the road, metres. A stop bar is a bar, not a line: it is wider than
## a lane line so that it reads as an instruction rather than as part of the lane structure, which is
## the same reason it is painted that way on a real road.
const STOP_BAR_LENGTH: float = 0.5

## How far junction paint floats above the surface it is painted on. The road markings' own constant,
## reused rather than redeclared: a junction's paint and its approach's paint meet at the trim-back
## boundary, and two lifts that drifted apart would make the pair visibly step at exactly the join they
## are supposed to hide.
const MARKING_LIFT: float = Pasture3DRoadMarkings.MARKING_LIFT


## The junction's markings, world space.
##
## One `STOP_BAR` per incoming lane, taken from `p_junction.stop_lines` with no derivation at all —
## `endpoints()` already gives the two ends of the painted bar and `heading` gives which way is into the
## junction. That is the whole reason stop bars come first in the build order: the data was published
## in P4a, and anything this kernel computed for itself would be a second opinion about a number the
## lane solver already knows.
##
## A primitive is `{kind, quad, y, road_key, lane}`. `quad` is four world-XZ corners wound so the bar
## reads front-face-up (see `build_junction`), `y` is the road's own solved elevation there, and the
## road/lane are carried so a consumer can say WHICH bar it is looking at without matching positions.
##
## ---- A DISABLED JUNCTION PAINTS NOTHING ----
##
## Not "paints bars that mean nothing". `disabled` means the author has said this crossing is not a
## junction — an overpass, a road passing under another — and a stop bar there instructs a driver to
## halt on a road with nothing crossing it. The same rule the lane graph already follows.
static func plan_junction(p_junction: Pasture3DRoadJunction) -> Array:
	var out: Array = []
	if p_junction == null or not p_junction.detected or p_junction.disabled:
		return out
	for sl: Pasture3DRoadStopLine in p_junction.stop_lines:
		if sl == null or sl.width <= 0.0:
			continue
		var ends: Array = sl.endpoints()
		var a := Vector2(ends[0].x, ends[0].z)
		var b := Vector2(ends[1].x, ends[1].z)
		# The bar sits BEHIND the hold point, on the approach side, so a vehicle whose nose reaches
		# `point` has the whole bar in front of it. Painting it centred on the hold point would put half
		# the paint inside the junction, which is the half a driver cannot see once they are on it.
		var back := -sl.heading.normalized() * STOP_BAR_LENGTH
		out.append({
			"kind": Kind.STOP_BAR,
			"quad": PackedVector2Array([a, b, b + back, a + back]),
			"y": ends[0].y,
			"road_key": sl.road_key,
			"lane": sl.lane,
		})
	return out


## The primitives as triangles.
##
## `p_height` is an optional `Callable(Vector2) -> float` giving the surface height at a world XZ point.
## When it is null — or answers a non-finite height — a corner falls back to the primitive's own `y`,
## the road's solved elevation at the hold point.
##
## THE FALLBACK IS FLAT ACROSS THE BAR, and that is a real limitation rather than an oversight: a
## crowned road drops a couple of centimetres across one lane, so a bar built flat sinks into the crown
## at its middle. It is the honest answer when nothing has offered a surface, and it is why the host
## passes a sampler rather than relying on it.
##
## Winding follows Godot's front face — clockwise seen from the front — so an up-facing quad's
## `(b-a) x (c-a)` points DOWN. `plan_junction` emits its corners in that order already; this only
## fans them.
static func build_junction(p_prims: Array, p_height: Callable = Callable(),
		p_lift: float = 0.0) -> Array:
	var lift := p_lift + MARKING_LIFT
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for prim: Dictionary in p_prims:
		var quad: PackedVector2Array = prim.get("quad", PackedVector2Array())
		if quad.size() < 3:
			continue
		var base := verts.size()
		var y0 := float(prim.get("y", 0.0))
		for i in quad.size():
			var p := quad[i]
			var y := y0
			if p_height.is_valid():
				var h: float = p_height.call(p)
				if is_finite(h):
					y = h
			verts.append(Vector3(p.x, y + lift, p.y))
			normals.append(Vector3.UP)
			uvs.append(Vector2(float(i & 1), float((i >> 1) & 1)))
		for i in range(1, quad.size() - 1):
			indices.append_array(PackedInt32Array([base, base + i, base + i + 1]))
	if indices.is_empty():
		return []
	Pasture3DRoadMesher._recompute_normals(verts, indices, normals)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_INDEX] = indices
	return out
