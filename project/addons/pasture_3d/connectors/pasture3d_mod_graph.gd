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
		graph = v
		if graph != null and not graph.changed.is_connected(_on_graph_changed):
			graph.changed.connect(_on_graph_changed)
		_touch()

func _on_graph_changed() -> void:
	if evaluation == Evaluation.FROZEN:
		_stale = true
		if Engine.is_editor_hint():
			emit_changed.call_deferred()
		return
	_touch()

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
# these methods are the storage it calls, the same contract the erosion modifier uses.
var _cache: Dictionary = {}
var _stale: bool = false

## Working input surface captured during brush rasterisation, used to render live 2D previews in Graph Editor
var last_input_surface: PackedFloat32Array = PackedFloat32Array()
var last_rect: Rect2 = Rect2(-50.0, -50.0, 100.0, 100.0)
var last_gw: int = 0
var last_gh: int = 0

@export_tool_button("Bake Graph") var _bake_btn = bake_graph


## Graph steps default to FROZEN — a solve per drag is unusable over a big footprint. See the header.
func _init() -> void:
	evaluation = Evaluation.FROZEN


func _supports_freezing() -> bool:
	return true


## Trigger a full evaluation of the graph on the host brush and store the result in the cache.
func bake_graph(p_host: Pasture3DTerrainBrush = null) -> void:
	_cache.clear()
	_stale = false
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
		brush.force_bake_modifiers()
	else:
		_touch()


## Drop every cached evaluation, so the next refresh recomputes.
func clear_cache() -> void:
	_cache.clear()
	_stale = false
	_touch()


func cache_bytes() -> int:
	var n := 0
	for k in _cache:
		n += (_cache[k].get("grid", PackedFloat32Array()) as PackedFloat32Array).size() * 4
	return n


func has_cache() -> bool:
	return not _cache.is_empty()


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
	if _cache.has(p_extent):
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
	return {
		"key": src.get("key", 0),
		"grid": _shift_grid(src["grid"], want["gw"], want["gh"], best["dx"], best["dz"]),
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


func store_cache(p_extent: String, p_entry: Dictionary) -> void:
	var parts := p_extent.split(",")
	if parts.size() >= 4:
		p_entry["gw"] = parts[2].to_int()
		p_entry["gh"] = parts[3].to_int()
	_cache[p_extent] = p_entry


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
func is_active() -> bool:
	return enabled and graph != null and not is_zero_approx(strength) and graph.output_index() >= 0


func _validate_property(property: Dictionary) -> void:
	if (property.name == "custom_falloff_width" or property.name == "custom_falloff_curve") and feather_mode != FeatherMode.CUSTOM:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func content_key() -> int:
	var ck := graph.content_key() if graph != null else 0
	var curve_pts := Pasture3DTerrainBrush._curve_signature(custom_falloff_curve)
	return hash([ck, strength, enabled, int(feather_mode), custom_falloff_width, curve_pts])


func modifier_warnings(_p_host) -> PackedStringArray:
	var w := PackedStringArray()
	if not enabled:
		return w
	if graph == null:
		w.append("%s: no Terrain Graph assigned, so it contributes nothing." % display_name())
		return w
	if is_zero_approx(strength):
		w.append("%s: Strength is 0 m, so the graph contributes nothing." % display_name())
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
	return graph == null or not graph.native_supported()


## Pasture3DNode.make_pending().
##
## The program is COMPILED HERE, on the main thread, and the worker gets the program rather than the
## resource. The native path only defers a graph it could compile, so this is never empty in practice;
## the guard is what makes that a fact instead of an assumption.
func make_pending(p_out: Dictionary, p_extent: String) -> Dictionary:
	if not p_out.has("pending") or graph == null:
		return {}
	return {
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


func pending_queue() -> StringName:
	return &"graph"
