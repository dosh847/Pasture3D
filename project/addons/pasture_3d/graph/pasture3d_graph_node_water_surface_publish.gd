# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeWaterSurfacePublish — hands a resolved PATH to a `Pasture3DWaterBody`. §9.3.
#
# Read Pasture3DGraphNodeRuntimeSink's header first.
#
# ---- ONE NODE, TWO CONSUMERS, AND THE DISCRIMINANT IS NOT A MODE SWITCH ----
#
# A CLOSED path is a lake; an OPEN one is a river. That is not a setting anyone chooses here — `closed` is
# already a property of `Pasture3DGraphPath`, the two water bodies already split on exactly it
# (`Pasture3DPool._local_polygon` refuses an open curve outright and points at `Pasture3DStream`), and a
# mode flag on this node would be a second place to get the same answer wrong. So this node reads what the
# path IS and hands it to whichever body is named:
#
#   * **Closed → `Pasture3DPool`.** The pool receives an EXTENT, not a level, and stays flat (§14.1 Q4).
#     No runtime query path changes, which is why this half is V7a.
#   * **Open → `Pasture3DStream`.** The sloped case: the heights become the still surface and the
#     per-vertex half-widths become the waterline. That is V7b (§9.4); V7a routes it and stores it.
#
# A mismatch — a closed path at a Stream, an open one at a Pool — is REFUSED by name rather than coerced.
# Closing an open path means inventing a wedge between its two endpoints that the author never drew, and
# the Pool's own configuration warning has said so for as long as it has existed.
#
# ---- WHY THE POOL GETS A Curve3D AND NOT A LEVEL ----
#
# `Pasture3DPool` builds its surface from `source_spline` / `curve`, decimates it, offsets it and scanline-
# fills it. Writing the outline into `curve` puts the graph's loop through that whole existing path, so
# `edge_offset`, the mask modes and the clipmap keep working unchanged. Writing a LEVEL instead would be a
# second way for a pool to have a height, and §14.1 Q4 settled that it must not: a pool is flat, and the
# level it is flat AT is the node's own Y.
@tool
class_name Pasture3DGraphNodeWaterSurfacePublish
extends Pasture3DGraphNodeRuntimeSink


func op() -> StringName:
	return &"water_surface_publish"


func consumer_class() -> StringName:
	return &"Pasture3DWaterBody"


func publish(p_path: Pasture3DGraphPath, p_consumer) -> Dictionary:
	if p_path == null or p_path.points.size() < 3:
		return {"error": "the resolved path has fewer than three points, so it is not a water surface"}
	if p_consumer == null:
		return {"error": "the named consumer is not a Pasture3DWaterBody"}
	var is_pool: bool = p_consumer is Pasture3DPool
	var is_stream: bool = p_consumer is Pasture3DStream
	if not is_pool and not is_stream:
		return {"error": "'%s' is a water body but neither a Pool nor a Stream" % p_consumer.name}

	# THE DISCRIMINANT. Refused rather than coerced — see the header.
	if is_pool and not p_path.closed:
		return {"error": ("the path is OPEN and '%s' is a Pool, which fills a closed outline. Publish it "
				+ "to a Stream, or close the path.") % p_consumer.name}
	if is_stream and p_path.closed:
		return {"error": ("the path is CLOSED and '%s' is a Stream, which follows an open course. Publish "
				+ "it to a Pool, or open the path.") % p_consumer.name}

	if is_pool:
		return _publish_pool(p_path, p_consumer)
	return _publish_stream(p_path, p_consumer)


## The closed half (V7a). The outline goes into the pool's own `curve`, in the pool's local space,
## through the same door a hand-authored Curve3D uses.
func _publish_pool(p_path: Pasture3DGraphPath, p_pool) -> Dictionary:
	var to_local: Transform3D = p_pool.global_transform.affine_inverse()
	var c := Curve3D.new()
	for i in range(p_path.points.size()):
		var xz: Vector2 = p_path.points[i]
		var y: float = p_path.heights[i] if i < p_path.heights.size() else 0.0
		c.add_point(to_local * Vector3(xz.x, y, xz.y))
	c.closed = true
	# `curve` overrides `source_spline`, and the pool's setter rewires the `changed` signal and requests a
	# rebuild. Assigning through the property rather than poking the field is what makes the pool notice.
	p_pool.curve = c
	return {}


## The open half. V7a stores the path on the stream and V7b is what makes the stream READ it — see
## `Pasture3DStream.published_path`. Storing it here rather than in V7b is deliberate: it means the
# routing decision above is testable now, by the phase whose gate covers routing, and V7b changes what a
## stream does with a path rather than how a path reaches one.
func _publish_stream(p_path: Pasture3DGraphPath, p_stream) -> Dictionary:
	if not ("published_path" in p_stream):
		return {"error": ("'%s' is a Stream from a build without the published-surface property; "
				+ "V7b adds it.") % p_stream.name}
	p_stream.published_path = p_path
	return {}
