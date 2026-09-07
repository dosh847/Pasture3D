# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeRuntimeSink — the shared shape of the B3 publish sinks (Path Publish, Water Surface
# Publish). PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §9.3.
#
# ---- WHAT V7a IS AND IS NOT ----
#
# It is NOT "export splines to a file". Two mature runtime consumers already ship — `Pasture3DRoadRuntime`
# answers `locate()` with no editor and no terrain, and `Pasture3DWaterBody` answers `get_water_height()`
# twice a physics tick per buoy. **What is missing is the arrow back.**
# `PASTURE3D_SPLINE_GRAPH_SPEC.md` §12.3 names it: the solve can spawn a Pond, the Pond cannot read the
# solve, and editing terrain under one desynchronises them with no signal.
#
# So a publish sink is a PUBLISH + STALENESS contract, not a format.
#
# ---- TERMINAL, LIKE EVERY OTHER SINK ----
#
# `has_output()` is false (§9.2's mechanism). Nothing can wire from it, so no compiler pass visits it, so
# there is no op, no `graph_op_ids()` entry and no native risk. It fires at bake, from
# `Pasture3DGraphRuntimeSinks`, which no evaluator references.
#
# ---- THE CONSUMER IS NAMED, NOT REFERENCED ----
#
# A graph is a Resource: no position in the scene, no parent, no way to reach a node. Every graph node
# that names something in the scene does it with a KEY resolved host-side — `Pasture3DGraphSources`'s
# header explains at length why that is one function and not six. A publish sink is the same mechanism
# pointed the other way: it names its consumer, the host resolves it at bake, and a key naming nothing is
# a normal state that warns rather than crashing.
#
# ---- THE DIGEST LIVES ON THE CONSUMER ----
#
# The producer stamps the content digest it published; the CONSUMER stores it. Staleness is
# `consumer.published_digest != producer.current_digest`, re-derived by resolving the path again — which
# is what makes an edit to the terrain UNDER a published river detectable at all: the drape re-runs, the
# heights move, the digest moves. `check-derived-values-outside-the-chain` is why the gate asserts the
# consumer's STORED digest: comparing a producer's digest to itself proves only that hashing is a
# function.
#
# ---- A STALE CONSUMER STILL ANSWERS ----
#
# `locate()` and `get_water_height()` keep working on the last good data and report `stale`. A runtime
# consumer that starts returning nulls because somebody moved a spline in the editor is a crash in a
# shipped game, arriving weeks after the edit that caused it.
@tool
class_name Pasture3DGraphNodeRuntimeSink
extends Pasture3DGraphNode

## The consumer's node name in the host's scene. Empty means "not chosen yet", which is a normal state
## for a graph mid-edit and warns rather than publishing somewhere arbitrary.
@export var consumer_key: String = "":
	set(v):
		consumer_key = v
		emit_changed()

## Filled host-side by `Pasture3DGraphSources.resolve_publish_targets` so the inspector can offer a
## dropdown. EDITOR-ONLY and deliberately not stored — it is a view of the scene, not of this node, and
## a serialised copy would be a second source that goes stale the moment a node is renamed.
## Setting it must NOTIFY (`property-hints-need-notifying`): `_validate_property` runs once while Godot
## builds the property list, so a list stamped after that build leaves the field a plain String box with
## the hint written correctly and nothing to show for it.
var editor_consumer_keys: PackedStringArray = PackedStringArray():
	set(v):
		if editor_consumer_keys == v:
			return
		editor_consumer_keys = v
		notify_property_list_changed()


## Offer the scene's consumers as suggestions, and keep the field typeable. ENUM_SUGGESTION rather than
## ENUM for the reason `Pasture3DGraphNodeRoadSource` gives at length: a hard enum can only hold what
## exists right now, so a graph opened without its scene would show its key as invalid and the first
## click would silently rewrite it to a different consumer.
func _validate_property(property: Dictionary) -> void:
	if property["name"] != &"consumer_key" or editor_consumer_keys.is_empty():
		return
	property["hint"] = PROPERTY_HINT_ENUM_SUGGESTION
	property["hint_string"] = ",".join(editor_consumer_keys)


## Terminal. See the header.
func has_output() -> bool:
	return false


func role() -> Role:
	return Role.FILTER


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["path"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.PATH])


func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1])


## The class name a consumer must be for this sink to publish into it. Used by the host-side resolver to
## build the dropdown and by the writer to refuse a key that names the wrong kind of node.
func consumer_class() -> StringName:
	return &"Node"


## Hand `p_path` to `p_consumer`. Returns {} on success, or {"error": String}. Implementations must not
## stamp the digest — `Pasture3DGraphRuntimeSinks` does that at one place for both sinks, so the two
## cannot disagree about what was published.
func publish(_p_path: Pasture3DGraphPath, _p_consumer) -> Dictionary:
	return {"error": "this sink does not implement publish()"}


## WHERE the digest is stamped, which is not always the consumer itself.
##
## The stamp has to live on the object that ANSWERS. A `Pasture3DWaterBody` answers `get_water_height()`
## itself, so it carries its own. A `Pasture3DRoadNetwork` does not answer anything — `locate()` is on the
## `Pasture3DRoadRuntime` it holds — so stamping the network would leave the flag on a node nobody queries
## and `locate()` reporting fresh forever. Returning null means "nothing to stamp", which is a skip and
## not an error.
func digest_target(p_consumer):
	return p_consumer


## Reasons this sink cannot publish, named. Empty means it will.
func sink_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if consumer_key.strip_edges().is_empty():
		out.append("no consumer is named, so there is nothing to publish to")
	return out
