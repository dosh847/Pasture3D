# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphRuntimeSinks — the bake-time half of the B3 publish sinks.
# PASTURE3D_GRAPH_VISUALIZATION_SPEC.md §9.3. The node classes declare what a sink IS; this runs them.
#
# ---- THE PUBLISH IS A PATH RE-RESOLVE, NOT A READ OF WHATEVER THE NODE HELD ----
#
# It calls `Pasture3DTerrainGraph.resolved_path_of()`, the pre-pass's public door, which walks the whole
# upstream filter chain. Reading the source node's `path_output()` instead would publish the INPUT to a
# Path Drape and call it the output — `PathDeriveGate`'s trap, in a new place — and, worse, it would make
# the staleness check below inert, because the thing that moves when terrain is edited is precisely the
# drape.
#
# ---- WHY STALENESS IS RE-DERIVED AND NOT SIGNALLED ----
#
# `PASTURE3D_SPLINE_GRAPH_SPEC.md` §12.3 is about an edit with NO signal: the terrain moves under a
# published river and nothing tells the river. So the check cannot wait to be told. `check_staleness`
# re-resolves each publish node's path and compares the digest to what the CONSUMER stored. An edit under
# the path re-drapes it and the digest moves; an edit somewhere else does not touch the path and the
# digest does not move. That difference is the whole mechanism, and V7a's gate [B] is exactly those two
# cases.
#
# The digest is stamped HERE for both sinks rather than inside each `publish()`, so the producer and the
# consumer cannot end up disagreeing about what was published — a `publish()` that forgot to stamp would
# leave a consumer permanently stale, and one that stamped the wrong path would leave it permanently
# fresh, which is worse.
#
# ---- A STALE CONSUMER STILL ANSWERS ----
#
# Nothing here clears a consumer's data. `stale` is a flag beside it. `Pasture3DRoadRuntime.locate()`
# keeps returning the last good run and adds `stale` to what it reports; `get_water_height()` is untouched
# on the physics path and the flag is read out of band. A runtime consumer that started returning nulls
# because somebody moved a spline in the editor is a crash in a shipped game.
@tool
class_name Pasture3DGraphRuntimeSinks
extends RefCounted

## Successful publishes since the counter was last reset. Counted AT the publish, so a gate can tell
## "it ran and published nothing" from "it never ran" (`gate-pass-can-mean-nothing-ran`).
static var publish_count: int = 0
## Staleness checks that found a consumer out of date. Counted for the same reason.
static var stale_count: int = 0


## Node indices of every runtime sink in `p_graph`, in graph order.
static func sinks_of(p_graph) -> PackedInt32Array:
	var out := PackedInt32Array()
	if p_graph == null:
		return out
	for i in range(p_graph.nodes.size()):
		var n = p_graph.nodes[i]
		if n != null and n is Pasture3DGraphNodeRuntimeSink:
			out.append(i)
	return out


## Which node/port drives `p_to`:`p_port`, as {"node": int, "port": int}, or {} when unwired.
static func source_of(p_graph, p_to: int, p_port: int) -> Dictionary:
	if p_graph == null:
		return {}
	for c in p_graph.connections:
		if int(c[2]) == p_to and int(c[3]) == p_port:
			return {"node": int(c[0]), "port": int(c[1])}
	return {}


## Publish every runtime sink in `p_graph`. `p_host` is any node in the consumer's scene — the host
## brush at bake, which is how every other scene-naming graph node is resolved (§9.3, and
## `graph-source-resolution-is-host-side`).
##
## Returns {"published": int, "sinks": int, "skipped": Array[String], "consumers": PackedStringArray}.
## `p_ctx`, when given, is the bake's tap domain — {"gw", "gh", "rect", "input"} — and makes each path
## resolve against THAT surface rather than against whatever the last evaluation captured. See
## `Pasture3DTerrainGraph.stage_paths_for` for why a Path Drape needs it. Omitting it is legal and is
## what an out-of-band caller (an editor button, a gate asking a question about the last bake) does.
static func run(p_graph, p_host: Node, p_ctx: Dictionary = {}) -> Dictionary:
	var report := {"published": 0, "sinks": 0, "skipped": [],
			"consumers": PackedStringArray()}
	var idx := sinks_of(p_graph)
	if idx.is_empty():
		return report
	for ni in idx:
		var sink: Pasture3DGraphNodeRuntimeSink = p_graph.nodes[ni]
		var label := _label_of(sink, ni)
		var warn := sink.sink_warnings()
		if not warn.is_empty():
			for w in warn:
				report["skipped"].append("%s: %s" % [label, w])
			continue
		var path := resolve_path(p_graph, ni, p_ctx)
		if path == null:
			report["skipped"].append("%s: the `path` port resolved to nothing" % label)
			continue
		var consumer := find_consumer(p_host, sink)
		if consumer == null:
			# A key naming nothing is a NORMAL state — a graph opened without its scene, a node renamed
			# mid-edit — so it is named and skipped rather than treated as an error. The same call
			# `Pasture3DGraphSources` makes about an unresolved Road Source, for the same reason.
			report["skipped"].append("%s: no %s named '%s' in this scene"
					% [label, sink.consumer_class(), sink.consumer_key])
			continue
		var res: Dictionary = sink.publish(path, consumer)
		if res.has("error"):
			report["skipped"].append("%s: %s" % [label, res["error"]])
			continue
		# AFTER `publish()`, and on the sink's own target: a Path Publish stamps the RUNTIME, which the
		# publish above may have just created. Stamping the network instead would leave the flag on a node
		# nobody queries and `locate()` reporting fresh forever.
		_stamp(sink.digest_target(consumer), path.content_digest(), label)
		publish_count += 1
		report["published"] = int(report["published"]) + 1
		report["sinks"] = int(report["sinks"]) + 1
		var names: PackedStringArray = report["consumers"]
		names.append(sink.consumer_key)
		report["consumers"] = names
	return report


## Re-resolve every publish sink's path and mark its consumer stale where the content has moved since it
## was published. Returns the warnings, and sets each consumer's `published_stale`.
##
## Called at bake AFTER `run()` — where it always finds everything fresh, which is the point — and
## callable on its own, which is how an editor or a gate asks "is this still true?" without republishing.
static func check_staleness(p_graph, p_host: Node, p_ctx: Dictionary = {}) -> PackedStringArray:
	var out := PackedStringArray()
	for ni in sinks_of(p_graph):
		var sink: Pasture3DGraphNodeRuntimeSink = p_graph.nodes[ni]
		var consumer := find_consumer(p_host, sink)
		if consumer == null:
			continue
		var path := resolve_path(p_graph, ni, p_ctx)
		if path == null:
			continue
		var target = sink.digest_target(consumer)
		if target == null:
			continue
		var now: int = path.content_digest()
		var held = target.get("published_digest")
		var stored: int = int(held) if held != null else 0
		var stale: bool = stored != now
		target.set("published_stale", stale)
		if stale:
			stale_count += 1
			out.append(("'%s' was published from %s and the graph has moved since — it is answering "
					+ "from the last good data and reporting stale.")
					% [sink.consumer_key, _label_of(sink, ni)])
	return out


## The PATH a sink's wired source actually produces, through the whole upstream filter chain.
static func resolve_path(p_graph, p_ni: int, p_ctx: Dictionary = {}) -> Pasture3DGraphPath:
	var src := source_of(p_graph, p_ni, 0)
	if src.is_empty():
		return null
	# Stage the derive family against the caller's surface FIRST, when there is one. Without this a Path
	# Drape answers from the grid it captured at the previous evaluation — see the header, and
	# `Pasture3DTerrainGraph.stage_paths_for`.
	if not p_ctx.is_empty() and p_graph.has_method("stage_paths_for"):
		p_graph.stage_paths_for(p_ni, int(p_ctx.get("gw", 0)), int(p_ctx.get("gh", 0)),
				p_ctx.get("rect", Rect2()), p_ctx.get("input", PackedFloat32Array()))
	return p_graph.resolved_path_of(int(src["node"]))


## The consumer a sink names, found in `p_host`'s scene. Null when the key names nothing of that class.
static func find_consumer(p_host: Node, p_sink: Pasture3DGraphNodeRuntimeSink) -> Node:
	if p_host == null or p_sink.consumer_key.strip_edges().is_empty():
		return null
	var root: Node = p_host.get_tree().get_edited_scene_root() if (p_host.is_inside_tree()
			and Engine.is_editor_hint() and p_host.get_tree() != null) else null
	if root == null:
		root = p_host.get_tree().current_scene if (p_host.is_inside_tree()
				and p_host.get_tree() != null) else null
	if root == null:
		root = p_host
	for n in candidates(root, p_sink.consumer_class()):
		if String(n.name) == p_sink.consumer_key:
			return n
	return null


## Every node under `p_root` that could be a consumer of the given class. Also what fills the inspector's
## dropdown, so the list you can choose from and the list that resolves are the same list.
static func candidates(p_root: Node, p_class: StringName) -> Array:
	var out: Array = []
	if p_root == null:
		return out
	var stack: Array = [p_root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.is_class(String(p_class)) or _script_is(n, p_class):
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


## `is_class` only knows engine classes, and every consumer here is a GDScript `class_name`. Walking the
## script inheritance chain is what makes "a Pool is a Pasture3DWaterBody" true for the dropdown as well
## as for the publish.
static func _script_is(p_node: Node, p_class: StringName) -> bool:
	var s: Script = p_node.get_script()
	while s != null:
		if s.get_global_name() == p_class:
			return true
		s = s.get_base_script()
	return false


## Stamp what was published, on the CONSUMER. See the header for why this is here and not in `publish()`.
static func _stamp(p_target, p_digest: int, p_by: String) -> void:
	if p_target == null:
		return
	p_target.set("published_digest", p_digest)
	p_target.set("published_by", p_by)
	p_target.set("published_stale", false)


static func _label_of(p_sink, p_index: int) -> String:
	var nm: String = p_sink.resource_name
	return nm if nm != "" else "%s #%d" % [p_sink.op(), p_index]
