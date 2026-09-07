# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathPublish — hands a resolved PATH to `Pasture3DRoadRuntime` as a run. §9.3.
#
# Read Pasture3DGraphNodeRuntimeSink's header first.
#
# ---- WHY THE CONSUMER IS THE NETWORK AND THE ARTEFACT IS A RUN ----
#
# `Pasture3DRoadRuntime` is a Resource with no node references, held by a `Pasture3DRoadNetwork`. Its
# header states the line this publish must not cross: *"Pasture3D publishes road and lane DATA, and a
# project's traffic, AI and race logic are that project's to write."* So this fills a `Pasture3DRoadRun`
# — plan, cumulative arc length, width — and nothing else. It does not drive anything, does not tick, and
# does not make the runtime know a graph exists.
#
# ---- WHY THE RUN ID IS KEYED ON THIS NODE ----
#
# `build_runtime()` keys run ids on a road brush's `source_key` through the network's `run_ids` dictionary,
# so an id survives a rebake. A graph-published run needs the same property for the same reason — a route
# stored against run 3 must still mean this river-crossing after the next bake — and it gets it by keying
# on the publish node's own identity. Re-publishing REPLACES the run with that key rather than appending,
# which is the §8.1 clear-first rule wearing runtime clothes: without it every bake would add another copy
# of the same road and `locate()` would return whichever one it reached first.
@tool
class_name Pasture3DGraphNodePathPublish
extends Pasture3DGraphNodeRuntimeSink

## Half-width used where the path carries none. A path that DOES carry per-vertex half-widths uses them;
## this is the declared default, not an override.
@export_range(0.5, 40.0, 0.1, "or_greater") var half_width: float = 4.0:
	set(v):
		half_width = maxf(0.1, v)
		emit_changed()

## How far off the carriageway still counts as "on the corridor" for `locate()`. Mirrors the road
## brush's `corridor_half_width()` and is read by `Pasture3DRoadRun.locate` exactly as that one is.
@export_range(1.0, 100.0, 0.5, "or_greater") var corridor_half_width: float = 8.0:
	set(v):
		corridor_half_width = maxf(0.1, v)
		emit_changed()

## What the published run calls itself. Empty means the node's own label.
@export var run_label: String = "":
	set(v):
		run_label = v
		emit_changed()


func op() -> StringName:
	return &"path_publish"


func consumer_class() -> StringName:
	return &"Pasture3DRoadNetwork"


## The stable key this node's run is filed under. Derived from the node's label so that renaming a node
## re-files its run — which is visible and undoable — rather than from its index in `nodes`, which moves
## whenever anything above it is deleted and would silently orphan every route.
## The RUNTIME, not the network. See the base class — `locate()` is what reads the flag, and it lives
## here. Null before the first publish, which is exactly when there is nothing to stamp yet.
func digest_target(p_consumer):
	return p_consumer.runtime if p_consumer != null else null


func run_key() -> String:
	var nm: String = resource_name
	return "graph:%s" % (nm if nm != "" else "path_publish")


func publish(p_path: Pasture3DGraphPath, p_consumer) -> Dictionary:
	if p_path == null or p_path.points.size() < 2:
		return {"error": "the resolved path has fewer than two points, so it is not a run"}
	if p_consumer == null:
		return {"error": "the named consumer is not a Pasture3DRoadNetwork"}
	var rt = p_consumer.runtime
	if rt == null:
		# Created rather than refused: a network that has never baked a road has no runtime, and a graph
		# that publishes one is a legitimate way for the first one to exist.
		rt = Pasture3DRoadRuntime.new()
		rt.built_at = Time.get_datetime_string_from_system()
		p_consumer.runtime = rt

	var key := run_key()
	if not p_consumer.run_ids.has(key):
		p_consumer.run_ids[key] = p_consumer.next_run_id
		p_consumer.next_run_id += 1
	var id: int = int(p_consumer.run_ids[key])

	var run := Pasture3DRoadRun.new()
	run.id = id
	run.source_key = key
	run.label = run_label if run_label != "" else (resource_name if resource_name != "" else "Graph Path")
	run.plan = p_path.points
	run.cum = _cumulative(p_path.points, p_path.closed)
	run.half_width = _widest(p_path)
	run.corridor_half_width = corridor_half_width

	# REPLACE, never append. See the header — appending would leave `locate()` choosing between copies.
	var runs: Array[Pasture3DRoadRun] = rt.runs
	var replaced := false
	for i in range(runs.size()):
		if runs[i] != null and runs[i].source_key == key:
			runs[i] = run
			replaced = true
			break
	if not replaced:
		runs.append(run)
	rt.runs = runs
	rt.built_at = Time.get_datetime_string_from_system()
	return {}


## Arc length at each point. `Pasture3DRoadRun.locate` walks `plan` against `cum`, so the two must be the
## same length or the projection reads past the end of one of them.
## A closed path's final segment back to the start is deliberately NOT recorded: `cum` is indexed BY
## POINT and there is no point to hold it, so a published loop is walked as an open polyline — which is
## what a route does with one anyway.
static func _cumulative(p_points: PackedVector2Array, _p_closed: bool) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_points.size())
	if p_points.is_empty():
		return out
	out[0] = 0.0
	for i in range(1, p_points.size()):
		out[i] = out[i - 1] + p_points[i - 1].distance_to(p_points[i])
	return out


## The run's single half-width. A `Pasture3DRoadRun` carries one, so a tapered path has to collapse to a
## number — and it collapses to the WIDEST rather than the mean, because this width feeds `on_road` and a
## mean would report a vehicle off a road it is demonstrably standing on at the wide end.
func _widest(p_path: Pasture3DGraphPath) -> float:
	var w := 0.0
	for h in p_path.half_widths:
		w = maxf(w, h)
	return w if w > 0.0 else half_width
