# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DNodeGraph — a brush node-stack step that runs a whole Pasture3DTerrainGraph over the brush's
# footprint and adds its output, feathered by the brush's interior profile. This is the MOUNT that makes
# the terrain graph (PASTURE3D_TERRAIN_GRAPH_SPEC.md) usable: the same reusable graph resource that can
# drive a whole landscape becomes a masked, local operation on a brush.
#
# It is a GRID node — the graph reads across the whole footprint, so it cannot fold into the cell loop —
# and the host evaluates it in `Pasture3DTerrainBrush._apply_graph_step`. Because the native C++
# rasteriser does not know the `&"graph"` op, a brush carrying an active one is routed onto the GDScript
# rasteriser (`Pasture3DTerrainBrush._native_raster` -> `_stack_forces_gdscript`); the graph itself is
# pure GDScript today.
#
# ---- FROZEN by default (mirrors Pasture3DNodeErosion) ----
#
# A graph over a terrain-spanning footprint is expensive, and auto_refresh re-bakes on every spline drag,
# so this defaults to FROZEN: its raw output is cached per grid EXTENT and re-evaluated only on a cache
# miss (a new extent, or reopening a scene) or an explicit Bake. While frozen, ANY change — a node param,
# the wiring, the graph swapped — leaves the cached output in place and raises a stale warning until you
# press Bake Graph. Set Evaluation to Live on a small graph to watch it update per drag.
#
# The cache stores the RAW graph output (before strength and the interior profile), which is why it stays
# valid as the spline drags WITHIN an extent: the graph is world-fixed, and only strength and the profile
# — applied per bake in _apply_graph_step — move with the footprint. So editing Strength never invalidates.
@tool
class_name Pasture3DNodeGraph
extends Pasture3DNode

## The graph to run. Its `.tres` is the reusable "one graph per landscape" unit — the same resource can
## drive a whole terrain elsewhere. Unassigned = the node is inactive (it contributes nothing and does
## not force the GDScript path).
@export var graph: Pasture3DTerrainGraph:
	set(v):
		if graph != null and graph.changed.is_connected(_on_graph_changed):
			graph.changed.disconnect(_on_graph_changed)
		if graph != null and graph.parameters_changed.is_connected(_on_graph_params_changed):
			graph.parameters_changed.disconnect(_on_graph_params_changed)
		if graph != null and graph.sinks_changed.is_connected(_on_graph_sinks_changed):
			graph.sinks_changed.disconnect(_on_graph_sinks_changed)
		graph = v
		if graph != null and not graph.sinks_changed.is_connected(_on_graph_sinks_changed):
			graph.sinks_changed.connect(_on_graph_sinks_changed)
		if graph != null and not graph.changed.is_connected(_on_graph_changed):
			graph.changed.connect(_on_graph_changed)
		if graph != null and not graph.parameters_changed.is_connected(_on_graph_params_changed):
			graph.parameters_changed.connect(_on_graph_params_changed)
		notify_property_list_changed()
		_touch()

## Only the sinks' colours moved (Pasture3DTerrainGraph.sinks_changed). Not a `changed`: the height this
## modifier contributes is the same, so the host re-runs the sink pass alone, Frozen or Live alike -- it
## solves nothing, so there is no expensive work for Frozen to hold back.
signal sinks_edited(mod: Pasture3DNodeGraph)


func _on_graph_sinks_changed(_p_index: int) -> void:
	sinks_edited.emit(self)


func _on_graph_changed() -> void:
	if evaluation == Evaluation.FROZEN:
		_stale = true
		if Engine.is_editor_hint():
			emit_changed.call_deferred()
		return
	_touch()

# ---- Graph parameters (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §10.2) ---------------------------
#
# The graph DECLARES its parameters; this modifier SUPPLIES their values, so two brushes sharing one graph
# can bake different terrain from it. Each declared parameter is an inspector property `parameters/<id>`
# (`_get_property_list`), and what is stored is only the values set here, in `param_overrides`. An id with
# no entry reads the graph's declared default.
#
# The values reach the graph by STAMPING (`stamp_params`), the way the footprint does: the brush stamps
# before every compile and evaluate of this graph, and keys every cache on `graph_key()`, which hashes the
# graph's revision together with what its Parameter nodes now read.

## A parameter value was set or cleared on this host. The graph editor listens to refresh its previews,
## which read this host's values but hear nothing from the graph when only a value moved.
signal params_edited()

const PARAM_PREFIX := "parameters/"

## `{id: value}`, set through the `parameters/<id>` properties or `set_param`. Saved, not shown: the
## inspector shows the per-parameter properties instead. An entry whose id the graph no longer declares is
## kept (renaming a parameter back restores it) but ignored, and reported by `modifier_warnings`.
@export_storage var param_overrides: Dictionary = {}:
	set(v):
		param_overrides = v.duplicate() if v != null else {}
		_touch()


## The `parameters/<id>` list this host last showed, as `_params_list_sig` hashes it.
var _shown_params_sig: int = 0
## A rebuild is waiting for the author to finish typing (`_flush_params_list`).
var _params_list_pending: bool = false
## Engine ticks of the last declaration edit, so the flush waits for a quiet moment.
var _params_edit_msec: int = 0


## What the host inspector shows for the declared parameters: names, types and hints. Not labels or
## defaults, which no host property displays.
func _params_list_sig() -> int:
	var sig: Array = []
	if graph != null:
		for id in graph.param_ids():
			var info := graph.find_param(id).property_info(String(id))
			sig.append([info["name"], info["type"], info.get("hint", 0), info.get("hint_string", "")])
	return hash(sig)


## A declaration changed. Rebuilding this modifier's inspector is what folds the stack it sits in, and the
## declaration is usually being edited INSIDE that stack, so a rebuild per keystroke made the ID field
## untypeable: each character collapsed the entry being typed into. So:
##  * nothing is rebuilt unless what the host shows actually changed (a Label or Default edit never does);
##  * in the editor, the rebuild waits until no text field has focus and the edits have stopped, i.e. until
##    the author pressed Enter or clicked away.
func _on_graph_params_changed() -> void:
	if _params_list_sig() == _shown_params_sig:
		return
	_params_edit_msec = Time.get_ticks_msec()
	if not Engine.is_editor_hint():
		_shown_params_sig = _params_list_sig()
		notify_property_list_changed()
		return
	if not _params_list_pending:
		_params_list_pending = true
		_flush_params_list.call_deferred()


func _flush_params_list() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		_params_list_pending = false
		notify_property_list_changed()
		return
	while true:
		await tree.create_timer(0.3).timeout
		var focus: Control = tree.root.gui_get_focus_owner()
		var typing := focus is LineEdit or focus is TextEdit
		if not typing and Time.get_ticks_msec() - _params_edit_msec >= 300:
			break
	_params_list_pending = false
	var sig := _params_list_sig()
	if sig != _shown_params_sig:
		_shown_params_sig = sig
		notify_property_list_changed()


func _get_property_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if graph == null:
		return out
	# What the inspector is about to show, so `_on_graph_params_changed` can tell an edit that changes it.
	_shown_params_sig = _params_list_sig()
	if graph.param_ids().is_empty():
		return out
	# Its own group. The parameters are appended after every exported property, so without one they land
	# inside whatever group was declared last (Feathering) and read as feathering settings.
	out.append({"name": "Parameters", "type": TYPE_NIL, "usage": PROPERTY_USAGE_GROUP, "hint_string": PARAM_PREFIX})
	var keys := PackedStringArray()
	var keyed := false
	for id in graph.param_ids():
		var decl := graph.find_param(id)
		if decl.is_path() and not keyed:
			keyed = true
			keys = Pasture3DGraphSources.spline_keys(_inspected_host())
		out.append(decl.property_info(PARAM_PREFIX + String(id), keys if decl.is_path() else PackedStringArray()))
		if decl.is_path():
			# Read-only: the spline this brush actually reads. The key field is EMPTY by default (the brush's
			# own spline child), and an empty field says nothing about which line that is.
			out.append({"name": PARAM_PREFIX + String(id) + READS_SUFFIX, "type": TYPE_STRING,
					"usage": PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY})
	return out


## Suffix of the read-only "which spline does this resolve to" property shown under each PATH parameter.
const READS_SUFFIX := "__reads"


## The brush whose inspector is showing this modifier, or the brush stamped last. A shared modifier sits
## under several brushes, and the readout and the key list must describe the one being looked at.
func _inspected_host() -> Node:
	if Engine.is_editor_hint():
		var o: Object = EditorInterface.get_inspector().get_edited_object()
		if o is Pasture3DTerrainBrush and (o as Pasture3DTerrainBrush).modifiers.has(self):
			return o as Node
	return stamp_host()


## What the readout shows for PATH parameter `p_id` on `p_host`: the resolved spline's key, and whether it
## was the brush's own child or picked by key.
func param_reads(p_id: StringName, p_host: Node) -> String:
	var key := param_key(p_id)
	var sp := Pasture3DGraphSources.param_spline(p_host, key)
	if sp == null:
		return "(no spline: add a Pasture3DSpline under this brush)" if key.is_empty() else "(not found: %s)" % key
	return ("%s  (this brush's own spline)" % sp.spline_key()) if key.is_empty() else sp.spline_key()


func _param_of(p_name: StringName) -> Pasture3DGraphParam:
	var s := String(p_name)
	if graph == null or not s.begins_with(PARAM_PREFIX):
		return null
	return graph.find_param(StringName(s.substr(PARAM_PREFIX.length())))


func _get(p_name: StringName) -> Variant:
	var decl := _param_of(p_name)
	if decl == null:
		var s := String(p_name)
		if s.ends_with(READS_SUFFIX):
			var rd := _param_of(StringName(s.trim_suffix(READS_SUFFIX)))
			if rd != null and rd.is_path():
				return param_reads(rd.id, _inspected_host())
		return null
	if decl.is_path():
		return param_key(decl.id)
	return decl.typed(param_number(decl.id))


func _set(p_name: StringName, p_value: Variant) -> bool:
	var decl := _param_of(p_name)
	if decl == null:
		return false
	set_param(decl.id, p_value)
	return true


func _property_can_revert(p_name: StringName) -> bool:
	return _param_of(p_name) != null


func _property_get_revert(p_name: StringName) -> Variant:
	var decl := _param_of(p_name)
	return decl.typed(decl.default_number()) if decl != null else null


## The spline key PATH parameter `p_id` reads on this host: its override, or the empty key (the host's own
## first Pasture3DSpline child). See Pasture3DGraphParam's header.
func param_key(p_id: StringName) -> String:
	var v: Variant = param_overrides.get(p_id, "")
	return v if v is String else ""


## The number parameter `p_id` evaluates to on this host: its override, coerced to the declared type, or
## the declared default. 0 for an id the graph does not declare.
func param_number(p_id: StringName) -> float:
	var decl := graph.find_param(p_id) if graph != null else null
	if decl == null:
		return 0.0
	return decl.coerce(param_overrides[p_id]) if param_overrides.has(p_id) else decl.default_number()


## Set parameter `p_id` on this host. Stored as typed, so the saved file reads as what the inspector shows.
## An id the graph does not declare is stored all the same (a graph may be swapped in that declares it) and
## reported.
func set_param(p_id: StringName, p_value: Variant) -> void:
	var decl := graph.find_param(p_id) if graph != null else null
	if decl != null and decl.is_path():
		# The empty key IS the default, so it is stored as no override: a saved host reads as untouched.
		var key := String(p_value) if p_value != null else ""
		# Picking the host's OWN spline stores the empty key, which reads "my own spline" rather than this
		# spline by name: a duplicate of this brush then reads ITS own, not the original's.
		var own := Pasture3DGraphSources.own_spline(_inspected_host())
		if own != null and own.spline_key() == key:
			key = ""
		if key.is_empty():
			clear_param(p_id)
			return
		if param_overrides.get(p_id) == key:
			return
		param_overrides[p_id] = key
		_on_override_changed(p_id)
		return
	var v: Variant = decl.typed(decl.coerce(p_value)) if decl != null else p_value
	if param_overrides.has(p_id) and param_overrides[p_id] == v:
		return
	param_overrides[p_id] = v
	_on_override_changed(p_id)


## Drop parameter `p_id`'s value on this host, so it reads the declared default.
func clear_param(p_id: StringName) -> void:
	if not param_overrides.has(p_id):
		return
	param_overrides.erase(p_id)
	_on_override_changed(p_id)


## An override is a HOST edit, like Strength, not a graph edit: it re-bakes this host and no other, so it
## emits this modifier's `changed` and never the graph's.
##
## Two caches are keyed on the value and would only report the change as stale, which is the right answer
## for an edit the author has not asked to see and the wrong one here, where the value IS the edit:
##  * this modifier's own frozen cache, keyed on `graph_key()`;
##  * a FROZEN solver node downstream of a Parameter node reading `p_id`, whose freeze key hashes the value.
## Both are dropped, so the bake re-solves. A solver NOT downstream of that Parameter keeps its solve.
func _on_override_changed(p_id: StringName) -> void:
	if graph != null:
		var hit := {}
		for ni in range(graph.nodes.size()):
			var pn: Pasture3DGraphNode = graph.nodes[ni]
			if pn == null or pn.op() != &"param" or StringName(pn.get("param_id")) != p_id:
				continue
			for di in graph.get_downstream_nodes(ni):
				var dn: Pasture3DGraphNode = graph.nodes[di]
				if dn is Pasture3DGraphSolverNode and not hit.has(di):
					hit[di] = true
					# Only this modifier's hosts: another brush sharing the graph keeps its own solve.
					var hosts: Array = _stamped_hosts.keys()
					if hosts.is_empty():
						hosts = [(dn as Pasture3DGraphSolverNode).host_slot()]
					for h in hosts:
						(dn as Pasture3DGraphSolverNode).forget_solve_for(int(h))
	drop_cache_for_bake()
	params_edited.emit()
	_touch()


## The brush this modifier was last stamped for. A PATH parameter's value depends on the HOST, not only on
## `param_overrides` (the empty key is the host's own spline child), and one modifier is often shared by
## duplicated brushes, so the host has to be named at the stamp. Callers that cannot name it (`content_key`,
## the frozen cache) run straight after one that did, on the same host, and read this. Weak, so a deleted
## brush is not kept alive by a modifier it shared.
var _stamp_host: WeakRef = null

## `{host instance id: {param id: Pasture3DGraphPath}}`: the path each host was last stamped with, kept so an
## unchanged spline stamps the SAME instance. Downstream path filters and the geometry table key on the
## instance id, so a fresh-but-equal path every stamp would re-run every filter on every compile.
var _path_memo: Dictionary = {}

## Every host id this modifier has stamped (0 for none): whose solver slots an override edit drops.
var _stamped_hosts: Dictionary = {}


func stamp_host() -> Node:
	if _stamp_host == null:
		return null
	var o: Object = _stamp_host.get_ref()
	return o as Node if is_instance_valid(o) else null


## Push this host's values onto the graph. Called before every compile and evaluate on this host's behalf.
## `p_host` is the brush whose graph this is; null means the host stamped last (see `_stamp_host`).
func stamp_params(p_host: Node = null) -> void:
	if graph == null:
		return
	if p_host != null:
		_stamp_host = weakref(p_host)
	else:
		p_host = stamp_host()
	var hid := p_host.get_instance_id() if p_host != null else 0
	_stamped_hosts[hid] = true
	graph.set_host_params(param_overrides, _host_paths(p_host), hid)


## Resolve every PATH parameter for `p_host`, reusing last stamp's instance where the content is unchanged.
func _host_paths(p_host: Node) -> Dictionary:
	var out := {}
	var hid := p_host.get_instance_id() if p_host != null else 0
	var memo: Dictionary = _path_memo.get(hid, {})
	var kept := {}
	for id in graph.param_ids():
		var decl := graph.find_param(id)
		if not decl.is_path():
			continue
		var made := Pasture3DGraphSources.param_path(decl, p_host, param_key(id))
		var old: Pasture3DGraphPath = memo.get(id)
		if made != null and old != null and old.content_digest() == made.content_digest():
			made = old
		out[id] = made
		if made != null:
			kept[id] = made
	if kept.is_empty():
		_path_memo.erase(hid)
	else:
		_path_memo[hid] = kept
	return out


## PATH parameters that resolve to no spline on `p_host`: what `modifier_warnings` reports.
func unresolved_path_params(p_host: Node) -> Array[StringName]:
	var out: Array[StringName] = []
	if graph == null:
		return out
	for id in graph.param_ids():
		var decl := graph.find_param(id)
		if decl.is_path() and Pasture3DGraphSources.param_spline(p_host, param_key(id)) == null:
			out.append(id)
	return out


## The graph's key FOR THIS HOST: its revision, plus what its Parameter nodes read with this host's values
## stamped. Stamps as a side effect, so a caller can compile straight after. Equal to `graph.content_key()`
## for a graph with no Parameter node, so such a graph keys exactly as it did before parameters existed.
func graph_key(p_host: Node = null) -> int:
	if graph == null:
		return 0
	stamp_params(p_host)
	var ps := graph.params_sig()
	return graph.content_key() if ps == 0 else hash([graph.content_key(), ps])


## Overrides naming a parameter the graph does not declare.
func unknown_overrides() -> Array[StringName]:
	var out: Array[StringName] = []
	if graph == null:
		return out
	var ids := graph.param_ids()
	for k in param_overrides:
		if not ids.has(StringName(k)):
			out.append(StringName(k))
	return out


## How strongly the graph's output replaces the incoming surface, 0..1, feathered further by the brush's
## interior profile so the rim stays clean. 0 = the graph does nothing; 1 = its output fully applies at the
## profile's centre. It is an AMOUNT, not metres: the graph is a filter (input → output), and a generator
## node inside it already carries its own amplitude.
@export_range(0.0, 1.0, 0.01) var strength: float = 1.0:
	set(v):
		strength = clampf(v, 0.0, 1.0)
		_touch()

enum FeatherMode {
	USE_BRUSH_MASK = 0,
	CUSTOM = 1,
	OFF = 2,
}

@export_group("Feathering")
## How the graph's output blends into the incoming terrain at the loop boundary.
## USE_BRUSH_MASK: Inherit Falloff Width & Curve from the host brush's Mask settings.
## CUSTOM: Use this modifier's own Custom Falloff Width and Curve.
## OFF: Apply 100% across the whole loop interior (tapers only across Modifier Margin if set).
@export var feather_mode: FeatherMode = FeatherMode.USE_BRUSH_MASK:
	set(v):
		feather_mode = v
		notify_property_list_changed()
		_touch()

## Custom inward feathering distance from the loop rim in metres (used when feather_mode == CUSTOM).
@export var custom_falloff_width: float = 15.0:
	set(v):
		custom_falloff_width = maxf(v, 0.001)
		_touch()

## Optional custom 0→1 fade curve for feathering (used when feather_mode == CUSTOM). Default null -> smoothstep.
@export var custom_falloff_curve: Curve:
	set(v):
		if custom_falloff_curve != null and custom_falloff_curve.changed.is_connected(_touch):
			custom_falloff_curve.changed.disconnect(_touch)
		custom_falloff_curve = v
		if custom_falloff_curve != null and not custom_falloff_curve.changed.is_connected(_touch):
			custom_falloff_curve.changed.connect(_touch)
		_touch()


# ---- The frozen cache (mirrors Pasture3DNodeErosion §6.3) --------------------------------------------
#
# IN MEMORY ONLY and keyed by grid EXTENT: the baked heights already persist in the layer, so the cache
# only saves re-evaluating after a reload, and several loops bake several grids that must not thrash one
# slot. Each entry is `{key, grid}` — `key` is the graph's content revision at bake time, the staleness
# signal. The host (Pasture3DTerrainBrush._compile_modifiers / _commit_modifier_caches) drives all of it;
# these methods are the storage it calls, the same contract the erosion modifier uses. `_cache` itself is
# declared on Pasture3DNode, which can spill it to disk (M6).
## Monotonic counter stamped onto an entry each time it is stored or served — the LRU order.
var _access_tick: int = 0
var _stale: bool = false

## Working input surface captured during brush rasterisation, used to render live 2D previews in Graph Editor
var last_input_surface: PackedFloat32Array = PackedFloat32Array()
var last_rect: Rect2 = Rect2(-50.0, -50.0, 100.0, 100.0)
var last_gw: int = 0
var last_gh: int = 0
## The channel-sink fields the worker's height solve tapped in the same pass, keyed by
## Pasture3DGraphChannelSinks._field_key, plus the surface and graph revision they answer for. The sink
## pass uses them instead of evaluating the graph again (which re-ran every solver on the main thread).
var sink_taps: Dictionary = {}

@export_tool_button("Bake Graph") var _bake_btn = bake_graph


## Graph steps default to FROZEN — a solve per drag is unusable over a big footprint. See the header.
func _init() -> void:
	evaluation = Evaluation.FROZEN


func _supports_freezing() -> bool:
	return true


## Trigger a full evaluation of the graph on the host brush and store the result in the cache.
func bake_graph(p_host: Pasture3DTerrainBrush = null) -> void:
	drop_cache_for_bake()
	var brush: Pasture3DTerrainBrush = p_host
	if brush == null and Engine.is_editor_hint():
		var tree: SceneTree = Engine.get_main_loop() as SceneTree
		if tree != null:
			var sel := EditorInterface.get_selection().get_selected_nodes()
			for nd in sel:
				if nd is Pasture3DTerrainBrush and (nd as Pasture3DTerrainBrush).modifiers.has(self):
					brush = nd as Pasture3DTerrainBrush
					break
			if brush == null:
				for b in tree.get_nodes_in_group(Pasture3DTerrainBrush.BRUSH_GROUP):
					if b is Pasture3DTerrainBrush and (b as Pasture3DTerrainBrush).modifiers.has(self):
						brush = b as Pasture3DTerrainBrush
						break
	if brush != null:
		# Only this host. The modifier is often shared (a duplicated brush shares its stack), and dropping
		# every entry made the full layer bake re-solve every host on it: Bake to Brush baked them all.
		drop_cache_for_host(brush)
		brush.force_bake_modifiers(true)
	else:
		_touch()


## Every brush in `p_tree` whose stack carries a Graph modifier editing `p_graph`, in tree order.
static func hosts_of_graph(p_graph: Pasture3DTerrainGraph, p_tree: SceneTree) -> Array:
	var out: Array = []
	if p_graph == null or p_tree == null:
		return out
	for b in p_tree.get_nodes_in_group(Pasture3DTerrainBrush.BRUSH_GROUP):
		if b is Pasture3DTerrainBrush and is_instance_valid(b):
			for m in (b as Pasture3DTerrainBrush).modifiers:
				if m is Pasture3DNodeGraph and (m as Pasture3DNodeGraph).graph == p_graph:
					out.append(b)
					break
	return out


## The hosts a Bake to All bakes: one per layer owner. A full bake of one tool repaints every tool on its layer,
## so a second host on the same layer would bake the layer again for nothing.
static func bake_all_leads(p_hosts: Array) -> Array:
	var seen := {}
	var out: Array = []
	for b: Pasture3DTerrainBrush in p_hosts:
		if not seen.has(b._layer_owner):
			seen[b._layer_owner] = true
			out.append(b)
	return out


## Bake to All: drop every cache of every Graph modifier editing `p_graph`, then bake each layer one of their
## hosts sits on. Returns how many brushes host the graph.
static func bake_all_hosts(p_graph: Pasture3DTerrainGraph, p_tree: SceneTree) -> int:
	var hosts := hosts_of_graph(p_graph, p_tree)
	for b: Pasture3DTerrainBrush in hosts:
		for m in b.modifiers:
			if m is Pasture3DNodeGraph and (m as Pasture3DNodeGraph).graph == p_graph:
				(m as Pasture3DNodeGraph).drop_cache_for_bake()
	for b: Pasture3DTerrainBrush in bake_all_leads(hosts):
		b.force_bake_modifiers()
	return hosts.size()


## A copy of this modifier for `p_host` alone: same graph (shared, not copied) and settings, carrying the cache
## entries `p_host` solved, which leave this one. For a per-brush setting on a modifier a duplicated brush
## shares, such as Live/Frozen.
func split_for_host(p_host: Object) -> Pasture3DNodeGraph:
	_unspill()
	var copy: Pasture3DNodeGraph = duplicate(false)
	var id := p_host.get_instance_id()
	copy._stamped_hosts = {id: true}
	_stamped_hosts.erase(id)
	# A PATH key naming the spline of another brush hosting the same GRAPH is that brush's "own spline",
	# written by name before `set_param` stored the empty key for it, and carried over by a duplicate. The
	# copy reads its host's own spline instead, which is what duplicating a brush means. (The co-host may
	# already have split off its own copy, so it is matched by graph, not by this modifier.)
	if graph != null and p_host is Node and Pasture3DGraphSources.own_spline(p_host as Node) != null:
		for pid in graph.param_ids():
			var decl := graph.find_param(pid)
			var key := copy.param_key(pid)
			if not decl.is_path() or key.is_empty():
				continue
			var sp := Pasture3DGraphSources.param_spline(p_host as Node, key)
			var owner_brush := sp.get_parent() if sp != null else null
			if owner_brush is Pasture3DTerrainBrush and owner_brush != p_host and _hosts_graph(owner_brush, graph):
				copy.param_overrides.erase(pid)
	var moved: Array = []
	for k in _cache:
		if int((_cache[k] as Dictionary).get("host", 0)) == id:
			moved.append(k)
	for k in moved:
		copy._cache[k] = _cache[k]
		_cache.erase(k)
	return copy


static func _hosts_graph(p_brush: Pasture3DTerrainBrush, p_graph: Pasture3DTerrainGraph) -> bool:
	for m in p_brush.modifiers:
		if m is Pasture3DNodeGraph and (m as Pasture3DNodeGraph).graph == p_graph:
			return true
	return false


## Drop the entries `p_host` filed, and no other host's. Each entry carries the id of the brush that solved
## it (`store_cache`'s caller tags it); an untagged entry is left alone. Returns how many were dropped.
func drop_cache_for_host(p_host: Object) -> int:
	_unspill()
	var id := p_host.get_instance_id()
	var gone: Array = []
	for k in _cache:
		if int((_cache[k] as Dictionary).get("host", 0)) == id:
			gone.append(k)
	for k in gone:
		_cache.erase(k)
	return gone.size()


## Drop the cache WITHOUT notifying, for a caller that is about to bake the host itself. `clear_cache`
## touches the resource, which arms the brush's debounced re-bake -- fine on its own, but a caller baking
## several graph modifiers on one brush would arm one refresh per modifier and then bake again on top.
func drop_cache_for_bake() -> void:
	_drop_spill()
	_cache.clear()
	_stale = false


## Drop every cached evaluation, so the next refresh recomputes.
func clear_cache() -> void:
	_drop_spill()
	_cache.clear()
	_stale = false
	_touch()


func cache_bytes() -> int:
	var n := 0
	for k in _cache:
		n += (_cache[k].get("grid", PackedFloat32Array()) as PackedFloat32Array).size() * 4
	return n


func has_cache() -> bool:
	return not _cache.is_empty() or is_spilled()


## How far a frozen solve may be re-projected, in cells. Two cells is the bounding-box rounding the
## footprint picks up while a spline is dragged; it is NOT a licence to serve another loop's grid.
const ORIGIN_TOLERANCE_CELLS := 2


## The frozen solve for this bake grid, or `{}` for a miss.
##
## THE ORIGIN IS PART OF THE KEY. `_extent_key` is "ox,oz,gw,gh" with the first two fields the loop's
## world origin in cells, and the fallback this replaces parsed only fields 2 and 3 — so any cached entry
## of the right SIZE was served for any PLACE. Two same-sized loops under one Mound with a frozen Graph
## modifier: loop A caches at "0,0,200,200", loop B misses at "640,640,200,200" and was handed A's grid.
## Nothing warned, because for a pure generator graph the key is `g.content_key()`, which does not change
## when the loop moves. The second branch was worse still: it stretched the nearest-sized grid to fit,
## which is a resize, not a translation.
##
## What survives is the case that fallback was actually written for — the ±1..2 cell jitter in a
## footprint's bounding box while a spline is being dragged. That is a TRANSLATION of the same grid, so
## it is served by shifting whole cells (both grids share `vertex_spacing`, so the lattices align and no
## interpolation is needed), clamping the one- or two-cell band that falls off the source edge. Anything
## further away, or any change of dimensions, is a miss.
func cache_for(p_extent: String) -> Dictionary:
	_unspill()
	if _cache.has(p_extent):
		# Serving IS an access. Without this the tick would only record when an entry was solved, so an
		# extent that keeps being served would age out under an extent that keeps being re-solved.
		_cache[p_extent]["tick"] = _access_tick
		_access_tick += 1
		return _cache[p_extent]
	if evaluation != Evaluation.FROZEN or _cache.is_empty():
		return {}
	var want := _parse_extent(p_extent)
	if want.is_empty():
		return {}
	var best: Dictionary = {}
	var best_shift := ORIGIN_TOLERANCE_CELLS + 1
	for k: String in _cache:
		var have := _parse_extent(k)
		if have.is_empty() or have["gw"] != want["gw"] or have["gh"] != want["gh"]:
			continue
		var entry: Dictionary = _cache[k]
		var g: PackedFloat32Array = entry.get("grid", PackedFloat32Array())
		if g.size() != want["gw"] * want["gh"]:
			continue
		var shift: int = maxi(absi(have["ox"] - want["ox"]), absi(have["oz"] - want["oz"]))
		if shift < best_shift:
			best_shift = shift
			best = {"entry": entry, "dx": want["ox"] - have["ox"], "dz": want["oz"] - have["oz"]}
	if best.is_empty():
		return {}
	var src: Dictionary = best["entry"]
	if best["dx"] == 0 and best["dz"] == 0:
		# Same place, different key text (a floating-point origin that rounds to the same cell). Nothing
		# to re-project, so this one may be memoised under the new key.
		_cache[p_extent] = src
		return src
	# Deliberately NOT written back under `p_extent`. Memoising a re-projection makes it the source for
	# the next one, so a spline dragged two cells at a time would walk the borrowed grid arbitrarily far
	# from where it was solved, one tolerated step after another. Each shift is measured from the entry
	# that was actually solved.
	var src_z: PackedFloat32Array = src.get("z", PackedFloat32Array())
	return {
		"key": src.get("key", 0),
		"grid": _shift_grid(src["grid"], want["gw"], want["gh"], best["dx"], best["dz"]),
		"z": _shift_grid(src_z, want["gw"], want["gh"], best["dx"], best["dz"]) if src_z.size() == src["grid"].size() else PackedFloat32Array(),
		"gw": want["gw"],
		"gh": want["gh"],
	}


## "ox,oz,gw,gh" -> {ox, oz, gw, gh}, or {} if the string is not one. Written once because `cache_for`
## has to parse BOTH sides of the comparison, and parsing them by different rules is how the origin got
## dropped from one of them.
static func _parse_extent(p_extent: String) -> Dictionary:
	var parts := p_extent.split(",")
	if parts.size() < 4:
		return {}
	return {
		"ox": parts[0].to_int(), "oz": parts[1].to_int(),
		"gw": parts[2].to_int(), "gh": parts[3].to_int(),
	}


## Translate a grid by whole cells. `p_dx`/`p_dz` are how far the DESTINATION origin is past the
## source's, so destination cell (ix, iz) reads source cell (ix + dx, iz + dz); the band that falls off
## the edge clamps to the nearest source cell rather than inventing a value.
static func _shift_grid(p_src: PackedFloat32Array, p_gw: int, p_gh: int, p_dx: int, p_dz: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_gw * p_gh)
	for iz in range(p_gh):
		var sz: int = clampi(iz + p_dz, 0, p_gh - 1)
		var srow: int = sz * p_gw
		var drow: int = iz * p_gw
		for ix in range(p_gw):
			out[drow + ix] = p_src[srow + clampi(ix + p_dx, 0, p_gw - 1)]
	return out


## The cache's byte budget. A drag mints a NEW extent key on every tick — the footprint's world origin
## moves — and nothing ever removed one, so a minute of dragging a 512^2 loop retained a fresh ~1 MB grid
## per tick for the lifetime of the resource. Mirrors Pasture3DTerrainGraph.max_cache_bytes in intent;
## the number is per-modifier rather than per-graph because a brush holds one of these per Graph step.
const MAX_CACHE_BYTES := 64 * 1024 * 1024


func store_cache(p_extent: String, p_entry: Dictionary) -> void:
	_unspill()
	var parts := p_extent.split(",")
	if parts.size() >= 4:
		p_entry["gw"] = parts[2].to_int()
		p_entry["gh"] = parts[3].to_int()
	p_entry["tick"] = _access_tick
	_access_tick += 1
	_cache[p_extent] = p_entry
	_evict_if_needed()


## Drop least-recently-served entries until the cache is inside its budget. THE ENTRY JUST STORED IS
## NEVER DROPPED: it is the one the caller is about to read back, and a budget smaller than a single grid
## would otherwise evict it and turn every bake into a miss. That leaves the budget advisory for one
## oversized grid, which is the right trade — a cache that cannot hold the current solve is worse than
## one that is briefly over.
func _evict_if_needed() -> void:
	if cache_bytes() <= MAX_CACHE_BYTES:
		return
	var keys: Array = _cache.keys()
	keys.sort_custom(func(a, b): return int(_cache[a].get("tick", 0)) < int(_cache[b].get("tick", 0)))
	for k in keys:
		if _cache.size() <= 1 or cache_bytes() <= MAX_CACHE_BYTES:
			return
		_cache.erase(k)


## Record whether the last bake served a cache the graph has since changed under. Set DURING a bake, so it
## deliberately does not `_touch()` (that would re-bake from inside a bake); it only refreshes warnings.
func set_stale(p_stale: bool) -> void:
	if _stale == p_stale:
		return
	_stale = p_stale


func op() -> StringName:
	return &"graph"


## A graph reads the whole grid (its own grid nodes route across it), so it is a grid node and cannot be
## folded into the cell loop.
func needs_grid() -> bool:
	return true


## Inactive with no graph, a zero strength, or a graph with no output — exactly the cases where running
## it would cost the O(cells) evaluation and the forced GDScript path for nothing.
## Gate control: keep an identity graph (Input -> Output) in the stack.
var identity_is_active := false


## An identity graph is inactive: it paints the surface it was given, so it costs nothing and reaches nothing.
## A graph with no Output is active when it has bake-time sinks (`is_sinks_only`): the Output and the sinks
## are both terminals of a bake, and requiring the Output alone dropped a paint-only graph from the stack, so
## its sinks never ran.
func is_active() -> bool:
	if not enabled or graph == null:
		return false
	if graph.output_index() < 0:
		return is_sinks_only()
	return not is_zero_approx(strength) and (identity_is_active or not graph.is_identity())


## A graph with no Output and at least one bake-time sink (a channel or a runtime publish sink; export sinks
## run on demand, not per bake). It paints and publishes, and contributes no height: `_apply_graph_step`
## records the surface its sinks read and hands the grid back unchanged. Strength is a height amount, so it
## does not apply.
func is_sinks_only() -> bool:
	if graph == null or not graph.is_compatible() or graph.output_index() >= 0:
		return false
	return (not Pasture3DGraphChannelSinks.sinks_of(graph).is_empty()
			or not Pasture3DGraphRuntimeSinks.sinks_of(graph).is_empty())


func _validate_property(property: Dictionary) -> void:
	if (property.name == "custom_falloff_width" or property.name == "custom_falloff_curve") and feather_mode != FeatherMode.CUSTOM:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func content_key() -> int:
	var ck := graph_key()
	var curve_pts := Pasture3DTerrainBrush._curve_signature(custom_falloff_curve)
	return hash([ck, strength, enabled, int(feather_mode), custom_falloff_width, curve_pts])


func modifier_warnings(p_host) -> PackedStringArray:
	var w := PackedStringArray()
	if not enabled:
		return w
	if graph == null:
		w.append("%s: no Terrain Graph assigned, so it contributes nothing." % display_name())
		return w
	if is_zero_approx(strength):
		w.append("%s: Strength is 0 m, so the graph contributes nothing." % display_name())
	for id in unknown_overrides():
		w.append("%s: a value is set for parameter '%s', which the graph does not declare, so it is ignored."
				% [display_name(), id])
	if p_host is Node:
		for id in unresolved_path_params(p_host):
			var key := param_key(id)
			if key.is_empty():
				w.append(("%s: spline parameter '%s' reads this brush's own spline, and it has none. Add a "
						+ "Pasture3DSpline under the brush, or pick one by key.") % [display_name(), id])
			else:
				w.append("%s: spline parameter '%s' names \"%s\", which is not in this scene." % [display_name(), id, key])
	if _stale:
		w.append(("%s is FROZEN and the graph has changed since it was baked, so the terrain is showing "
			+ "the OLD graph. Press Bake Graph to re-evaluate, or set Evaluation to Live.") % display_name())
	if evaluation == Evaluation.FROZEN and not _cache.is_empty():
		w.append("%s holds %.1f MB of cached graph output. Press Bake Graph to re-evaluate it."
			% [display_name(), cache_bytes() / 1048576.0])
	w.append_array(graph.graph_warnings(true))
	return w


## Pasture3DNode.apply_field(). See Pasture3DNodeErosion.apply_field for why the body stays on the host.
func apply_field(p_step: Dictionary, p_vals: PackedFloat32Array, p_ctx: Dictionary) -> PackedFloat32Array:
	return p_ctx["host"]._apply_graph_step(p_step, p_vals, p_ctx)


## Pasture3DNode.forces_gdscript(). The native evaluator runs a graph only when it implements every node
## in it; an unsupported op would otherwise be dropped in silence.
func forces_gdscript(_p_host) -> bool:
	return graph == null or not (graph.native_supported() or graph._native_supported_if_staged(graph.output_index()))


## Pasture3DNode.make_pending().
##
## The program is COMPILED HERE, on the main thread, and the worker gets the program rather than the
## resource. The native path only defers a graph it could compile, so this is never empty in practice;
## the guard is what makes that a fact instead of an assumption.
func make_pending(p_out: Dictionary, p_extent: String) -> Dictionary:
	if not p_out.has("pending") or graph == null:
		return {}
	stamp_params()
	var entry := {
		"mod": self,
		"prog": graph.compile_graph_program(),
		"gw": int(p_out["pending_gw"]),
		"gh": int(p_out["pending_gh"]),
		"rect": p_out.get("pending_rect", last_rect),
		"z": p_out["pending"],
		"key": int(p_out["pending_key"]),
		"extent": p_extent,
		"done": 0,
	}
	_add_sink_taps(entry)
	return entry


## When the graph has channel sinks, compile ONE program over the output and every field they read, so the
## worker's solve answers both. Without it the sink pass evaluated the graph a second time, synchronously
## on the main thread -- a Salève in the graph was solved twice per bake, once where nobody could see it.
func _add_sink_taps(r_entry: Dictionary) -> void:
	var reqs: Array = Pasture3DGraphChannelSinks.tap_requests(graph)
	var out_idx: int = graph.output_index()
	if reqs.is_empty() or out_idx < 0:
		return
	var roots: Array = [out_idx]
	for r in reqs:
		if not roots.has(int(r["node"])):
			roots.append(int(r["node"]))
	var compiled: Dictionary = graph.compile_graph_program_multi(roots)
	if compiled.is_empty():
		return
	var slot_of: Dictionary = compiled["slot_of"]
	if not slot_of.has(out_idx):
		return
	var slots := PackedInt32Array([int(slot_of[out_idx])])
	var chans := PackedInt32Array([0])
	var keys: Array = []
	for r in reqs:
		if not slot_of.has(int(r["node"])):
			continue
		keys.append(Pasture3DGraphChannelSinks._field_key(int(r["node"]), int(r["port"])))
		slots.append(Pasture3DTerrainGraph.tap_slot(compiled, int(r["node"]), int(r["port"])))
		chans.append(Pasture3DTerrainGraph.tap_channel(compiled, int(r["node"]), int(r["port"])))
	r_entry["taps_prog"] = compiled["program"]
	r_entry["tap_slots"] = slots
	r_entry["tap_chans"] = chans
	r_entry["tap_keys"] = keys
	r_entry["tap_content"] = hash([graph_key(), graph._footprint_sig()])


## The worker's sink fields, filed on the main thread with the surface they were solved over.
func adopt_sink_taps(p_state: Dictionary) -> void:
	if not p_state.has("sink_fields"):
		return
	sink_taps = {"fields": p_state["sink_fields"], "z_hash": hash(p_state["z"]),
			"gw": int(p_state["gw"]), "gh": int(p_state["gh"]), "content": int(p_state["tap_content"])}


## The pre-tapped fields for a sink pass over `p_z`, or {} when they answer a different surface or graph.
func sink_taps_for(p_z: PackedFloat32Array, p_gw: int, p_gh: int) -> Dictionary:
	if sink_taps.is_empty() or graph == null:
		return {}
	if int(sink_taps["gw"]) != p_gw or int(sink_taps["gh"]) != p_gh:
		return {}
	if int(sink_taps["content"]) != hash([graph_key(), graph._footprint_sig()]) or int(sink_taps["z_hash"]) != hash(p_z):
		return {}
	return sink_taps["fields"]


func pending_queue() -> StringName:
	return &"graph"
