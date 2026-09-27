@tool
extends RefCounted
## No class_name on purpose: preload this file (a new global class needs an editor rescan to register).
## Bake scope and the neighbour rule (PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md §F).
##
## A bake is the only operation that may load a region, and it leaves the loaded set exactly as it found
## it. The scope picks TARGET regions; every brush whose footprint touches one is baked over its WHOLE
## footprint, loading the neighbours it reaches, because a solver (erosion, grown relief, a graph) sees its
## whole domain and a clipped domain bakes a different result that seams at the cut.
##
## ---- THE UNIT OF WORK IS A LAYER OWNER, NOT A BRUSH (deviation from §F's wording) ----
##
## `_refresh_owner` clears and repaints EVERY tool bound to a layer, so there is no way to bake one brush
## of a shared layer without re-stamping its layer-mates. "Atomic over its footprint" therefore has to hold
## for the owner: its working set is the union of all its tools' footprints. Baking a subset would leave a
## layer-mate repainted over a clipped domain, which is exactly the seam the rule exists to prevent.
##
## ---- WHAT "READS BELOW" MEANS FOR THE INPUT CLOSURE ----
##
## Every painting brush samples the composite below it (snap, blend, the rasteriser's base grid), but a
## pointwise sample over its own footprint is served by the lower layers' tiles as they were last baked,
## which the load brings in. Only a brush whose result depends on its whole DOMAIN (an erosion solve, a
## grown relief field, a graph) needs the brushes feeding that domain baked first; that is the closure.
## Anything wider would pull a road network's whole world in, which §F rules out.
##
## A graph has a second kind of input: a Road, Shape or Spline Source names a brush elsewhere in the scene
## and reads its geometry (a road's solved alignment included). That brush's owner is an input by
## REFERENCE, not by overlap, and joins the closure the same way. Sources are NOT skipped when the brush
## they name sits in an unloaded region: they read scene geometry, not region data, and skipping them
## would make a bake's result depend on which regions happened to be loaded.
##
## ---- ROADS: THE JUNCTION FIXED POINT RUNS INSIDE THE BAKE ----
##
## A junction couples the roads that meet at it, and settles by bake -> resolve -> bake. In the editor the
## second bake is a scheduled live refresh, and the live rule refuses those for a road reaching an unloaded
## region, so after a scoped bake released its neighbours the junction would never settle. So the bake runs
## the fixed point itself (`settle_roads`) while every region a road owner touches is still held.
##
## ---- DRIVING IT ----
##
## `bake()` does everything synchronously. A caller with its own per-owner work (the brush registry's
## snapshots, cache clears and deferred solves) drives the steps instead:
##     var ctx := sb.begin(scope, targets)
##     for i in ctx["owners"].size(): sb.load_for(ctx, i); <bake owner i>; sb.release_after(ctx, i)
##     sb.settle_roads(ctx, <bake callable>)
##     var report := sb.finish(ctx)

const ScopeNames := ["selected", "all_loaded", "all_regions"]
enum Scope { SELECTED, ALL_LOADED, ALL_REGIONS }

## Turns of the junction fixed point before a bake gives up and reports the network unsettled. The gates
## settle crossings in two; four leaves room without letting an oscillation run forever.
const ROAD_SETTLE_TURNS := 4

var terrain
## A layer owner whose working set is larger than this many regions is skipped and reported, never baked
## in pieces. <= 0 disables the budget.
var budget_regions: int = 64
## When non-empty, only these owners can be TARGET owners (the brush registry bakes what is registered);
## the closure may still add others, because a registered brush's inputs are its inputs either way.
var root_owners: Array = []
## GATE CONTROL ONLY. Release every region the moment the owner that loaded it has baked, ignoring the
## other pending owners that share it; the release criterion must fail on it.
var debug_release_early: bool = false
## GATE CONTROL ONLY. Bake the targets without loading any neighbour: the clipped bake §F forbids.
var debug_no_neighbours: bool = false
## GATE CONTROL ONLY. Skip the junction fixed point, leaving it to the deferred resolve.
var debug_no_road_settle: bool = false
## GATE CONTROL ONLY. Write the region index at every release, as before M3 (PASTURE3D_BAKE_MEMORY_SPEC.md).
var debug_index_per_unload: bool = false
## GATE ONLY. Never write the index at `finish`: what a crash after the last release leaves on disk.
var debug_skip_index_write: bool = false


func _init(p_terrain = null) -> void:
	terrain = p_terrain


## What a bake would do, without loading or writing anything: `{owners: [{owner, regions, order,
## reads_domain, via, brushes}], skipped_locked, skipped_budget, working_set, targets}`. `via` is "target"
## or "closure". Split out so the plan is measurable on its own (the closure has no height signature).
func plan(p_scope: int, p_targets: Array = []) -> Dictionary:
	var existing := _existing_regions()
	var targets := _targets(p_scope, p_targets, existing)
	var owners := _collect_owners(existing)
	var chosen := {}
	for o: String in owners:
		if not root_owners.is_empty() and not root_owners.has(o):
			continue
		if _intersects(owners[o]["regions"], targets):
			chosen[o] = "target"
	# Input closure: a domain reader's lower-layer owners whose footprints overlap its own, and every owner
	# a graph source names; recursively.
	var queue: Array = chosen.keys()
	while not queue.is_empty():
		var o: String = queue.pop_back()
		var od: Dictionary = owners[o]
		for p: String in od["sources"]:
			if owners.has(p) and not chosen.has(p):
				chosen[p] = "closure"
				queue.append(p)
		if not bool(od["reads_domain"]):
			continue
		for p: String in owners:
			if chosen.has(p):
				continue
			var pd: Dictionary = owners[p]
			if int(pd["order"]) < int(od["order"]) and _boxes_overlap(pd["boxes"], od["boxes"]):
				chosen[p] = "closure"
				queue.append(p)
	var out_owners: Array = []
	var skipped_locked: Array = []
	var skipped_budget: Array = []
	for o: String in chosen:
		var od: Dictionary = owners[o]
		var regions: Array = od["regions"]
		var locked := false
		for r: Vector2i in regions:
			if _is_locked(r):
				locked = true
				break
		if locked:
			skipped_locked.append(o)
			continue
		if budget_regions > 0 and regions.size() > budget_regions:
			skipped_budget.append(o)
			continue
		out_owners.append({"owner": o, "regions": regions, "order": od["order"],
				"reads_domain": od["reads_domain"], "via": chosen[o], "brushes": od["brushes"]})
	# Layer order (the closure's inputs first); within a layer, by the owner's first region so owners
	# sharing regions sit together and a loaded neighbour is reused before it is released.
	out_owners.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["order"]) != int(b["order"]):
			return int(a["order"]) < int(b["order"])
		return _region_less(_first_region(a["regions"]), _first_region(b["regions"])))
	var working := {}
	for od: Dictionary in out_owners:
		for r: Vector2i in od["regions"]:
			working[r] = true
	return {"owners": out_owners, "skipped_locked": skipped_locked, "skipped_budget": skipped_budget,
			"working_set": working.keys(), "targets": targets.keys()}


## Bake everything the plan names, synchronously. Returns the report `finish` describes.
func bake(p_scope: int, p_targets: Array = []) -> Dictionary:
	var ctx := begin(p_scope, p_targets)
	if not bool(ctx["ok"]):
		return ctx["report"]
	for i in (ctx["owners"] as Array).size():
		load_for(ctx, i)
		bake_owner(ctx["owners"][i])
		mark_baked(ctx, i)
		release_after(ctx, i)
	settle_roads(ctx, bake_owner)
	return finish(ctx)


## Plan and count references. `ok` false means nothing was done and `report.reason` says why.
func begin(p_scope: int, p_targets: Array = []) -> Dictionary:
	var report := {"ok": false, "reason": "", "scope": ScopeNames[clampi(p_scope, 0, 2)], "targets": [],
			"owners": [], "regions_written": [], "loaded_for_bake": [], "released": [],
			"skipped_locked": [], "skipped_budget": [], "events": [], "road_turns": 0,
			"roads_unsettled": [], "release_usec": 0}
	var ctx := {"ok": false, "report": report, "owners": []}
	if terrain == null or terrain.data == null:
		report["reason"] = "no terrain"
		return ctx
	var p := plan(p_scope, p_targets)
	report["targets"] = p["targets"]
	report["skipped_locked"] = p["skipped_locked"]
	report["skipped_budget"] = p["skipped_budget"]
	var target_set := {}
	for t: Vector2i in p["targets"]:
		target_set[t] = true
	var data = terrain.data
	var owners: Array = p["owners"]
	# One reference per pending owner touching a region the bake itself has to load, plus one per road
	# network over every region its owners touch: those are held until `settle_roads` has run. A region
	# loaded before the bake is never counted and never released.
	var refs := {}
	var road_hold := {}
	for od: Dictionary in owners:
		var regions := _regions_for(od, target_set)
		od["load"] = regions
		var has_road := _has_roads(od)
		for r: Vector2i in regions:
			if not data.is_region_loaded(r):
				refs[r] = int(refs.get(r, 0)) + 1
				if has_road and not road_hold.has(r):
					road_hold[r] = true
					refs[r] = int(refs[r]) + 1
	# A terrain with no data directory can still bake what is loaded; it just cannot load anything.
	if not refs.is_empty() and String(terrain.data_directory).is_empty():
		report["reason"] = "the bake needs unloaded regions %s but the terrain has no data_directory" % [refs.keys()]
		return ctx
	ctx.merge({"ok": true, "owners": owners, "refs": refs, "road_hold": road_hold, "ours": {},
			"written": {}, "baked": {}}, true) # overwrite: ctx already holds ok=false and owners=[]
	return ctx


## Load every region owner `p_index` reaches that is not loaded yet.
func load_for(p_ctx: Dictionary, p_index: int) -> void:
	var data = terrain.data
	var od: Dictionary = p_ctx["owners"][p_index]
	var report: Dictionary = p_ctx["report"]
	for r: Vector2i in od["load"]:
		if data.is_region_loaded(r):
			continue
		var err: int = data.load_region(r, terrain.data_directory)
		if err != OK:
			push_warning("Pasture3DScopedBake: could not load region %s (error %d)" % [r, err])
			continue
		p_ctx["ours"][r] = true
		(report["loaded_for_bake"] as Array).append(r)
		(report["events"] as Array).append(["load", r])


## Record that owner `p_index` has baked (the caller baked it between `load_for` and `release_after`).
func mark_baked(p_ctx: Dictionary, p_index: int) -> void:
	var od: Dictionary = p_ctx["owners"][p_index]
	p_ctx["baked"][od["owner"]] = od
	(p_ctx["report"]["owners"] as Array).append(od["owner"])
	(p_ctx["report"]["events"] as Array).append(["bake", od["owner"]])
	for r: Vector2i in od["load"]:
		if terrain.data.is_region_loaded(r):
			p_ctx["written"][r] = true


## Drop owner `p_index`'s references, releasing each region no pending owner still needs.
func release_after(p_ctx: Dictionary, p_index: int) -> void:
	var od: Dictionary = p_ctx["owners"][p_index]
	for r: Vector2i in od["load"]:
		if not p_ctx["ours"].has(r):
			continue
		p_ctx["refs"][r] = int(p_ctx["refs"][r]) - 1
		if int(p_ctx["refs"][r]) <= 0 or debug_release_early:
			_release(p_ctx, r)


## The junction fixed point over every road network with a road in a baked owner: resolve, re-bake the
## owners whose roads' junction pins moved, repeat until nothing moves. `p_bake` takes an owner entry and
## bakes it (the same callable the caller used for the first pass). Then the road hold is released.
##
## A road OUTSIDE the baked owners whose pins moved cannot be re-baked here without loading its regions;
## it is reported in `roads_unsettled` rather than silently left, as is anything still moving after
## ROAD_SETTLE_TURNS.
func settle_roads(p_ctx: Dictionary, p_bake: Callable) -> void:
	var report: Dictionary = p_ctx["report"]
	var nets := {}
	var road_owner := {} # road brush -> owner entry
	for o: String in p_ctx["baked"]:
		var od: Dictionary = p_ctx["baked"][o]
		for b in od["brushes"]:
			if b is Pasture3DRoadBrush:
				road_owner[b] = od
				var net = b.road_network()
				if net != null:
					nets[net] = true
	if not debug_no_road_settle:
		for net in nets:
			var roads: Array = net.road_brushes()
			var turn := 0
			while turn < ROAD_SETTLE_TURNS:
				turn += 1
				var moved := _resolve_quietly(net, roads)
				var rebake := {}
				var outside: Array = []
				for b in moved:
					if road_owner.has(b):
						rebake[road_owner[b]["owner"]] = road_owner[b]
					else:
						outside.append(String(b.name))
				for n in outside:
					if not (report["roads_unsettled"] as Array).has(n):
						(report["roads_unsettled"] as Array).append(n)
				report["road_turns"] = int(report["road_turns"]) + 1
				(report["events"] as Array).append(["resolve", turn])
				if rebake.is_empty():
					break
				if turn == ROAD_SETTLE_TURNS:
					for o: String in rebake:
						for b in rebake[o]["brushes"]:
							if b is Pasture3DRoadBrush and not (report["roads_unsettled"] as Array).has(String(b.name)):
								(report["roads_unsettled"] as Array).append(String(b.name))
					break
				for o: String in rebake:
					p_bake.call(rebake[o])
					(report["events"] as Array).append(["bake", o])
	for r: Vector2i in (p_ctx["road_hold"] as Dictionary).keys():
		if not p_ctx["ours"].has(r):
			continue
		p_ctx["refs"][r] = int(p_ctx["refs"][r]) - 1
		if int(p_ctx["refs"][r]) <= 0:
			_release(p_ctx, r)
	p_ctx["road_hold"] = {}


## Release anything still held and fill in the report: `{ok, reason, scope, targets, owners,
## regions_written, loaded_for_bake, released, skipped_locked, skipped_budget, events, road_turns,
## roads_unsettled}`. `events` is the ordered log of ["load", loc], ["bake", owner], ["release", loc] and
## ["resolve", turn], which the release criterion reads.
func finish(p_ctx: Dictionary) -> Dictionary:
	var report: Dictionary = p_ctx["report"]
	if not bool(p_ctx.get("ok", false)):
		return report
	# Anything still held (a cancelled run, a failed load) goes back to how it was found.
	for r: Vector2i in (p_ctx["ours"] as Dictionary).keys():
		_release(p_ctx, r)
	# Each release updated the index in memory only; it is written once, here (PASTURE3D_BAKE_MEMORY_SPEC.md M3).
	if not (report["released"] as Array).is_empty() and not debug_index_per_unload and not debug_skip_index_write:
		terrain.data.write_region_index()
	report["regions_written"] = (p_ctx["written"] as Dictionary).keys()
	report["ok"] = true
	return report


## The same dispatch Bake All uses (Pasture3DSimManager._bake_all_step), without the deferred path: full
## resolution, stamp caches dropped, the layer repainted through its own owner bake.
func bake_owner(p_owner: Dictionary) -> void:
	var owner: String = p_owner["owner"]
	var brushes: Array = p_owner["brushes"]
	if brushes.is_empty():
		return
	for b in brushes:
		b._preview_full_res = true
		b._stamp_cache.clear()
	if owner.begins_with(Pasture3DTerrainBrush.LAYER_BRUSH_OWNER_PREFIX):
		var host = (brushes[0] as Pasture3DTerrainBrush)._layer_brush_for_owner(owner)
		if host != null:
			host._base_key = ""
			host.bake_layer(false)
			return
	(brushes[0] as Pasture3DTerrainBrush)._refresh_owner(owner, false, [])


# ---- internals -----------------------------------------------------------------------------------


## Run one junction resolve without letting it arm live refreshes, and return the roads whose pins moved
## beyond tolerance: the same test `schedule_junction_rebake` makes, taken against each road's baseline
## from before the resolve.
func _resolve_quietly(p_net, p_roads: Array) -> Array:
	var base := {}
	for b in p_roads:
		if b == null:
			continue
		base[b] = [b._last_junction_values.duplicate(), b.last_junction_digest, b._suspend_auto]
		b._suspend_auto = true
	p_net.resolve_junctions()
	var moved: Array = []
	for b in base:
		var pre_vals: Dictionary = base[b][0]
		var vals: Dictionary = b.junction_values()
		b._suspend_auto = base[b][2]
		# `junction_rebake_needed`'s first-bake case: no baseline yet and an unchanged digest is settled.
		if pre_vals.is_empty() and not vals.is_empty() and b.junction_digest() == base[b][1]:
			continue
		if Pasture3DRoadBrush.junction_values_differ(vals, pre_vals):
			moved.append(b)
	return moved


func _release(p_ctx: Dictionary, p_loc: Vector2i) -> void:
	if not p_ctx["ours"].has(p_loc):
		return
	p_ctx["ours"].erase(p_loc)
	# unload_region saves a modified region (and its layer tiles) before dropping it. The index is written
	# once by `finish`, not per region: it describes the whole world, so per region it was O(n²) bytes.
	var t0 := Time.get_ticks_usec()
	var err: int = terrain.data.unload_region(p_loc, true, debug_index_per_unload)
	p_ctx["report"]["release_usec"] = int(p_ctx["report"]["release_usec"]) + Time.get_ticks_usec() - t0
	if err != OK:
		push_warning("Pasture3DScopedBake: could not unload region %s (error %d)" % [p_loc, err])
	(p_ctx["report"]["released"] as Array).append(p_loc)
	(p_ctx["report"]["events"] as Array).append(["release", p_loc])


static func _has_roads(p_owner: Dictionary) -> bool:
	for b in p_owner["brushes"]:
		if b is Pasture3DRoadBrush:
			return true
	return false


## The regions an owner's bake loads: its whole footprint, or (control only) just its targets.
func _regions_for(p_owner: Dictionary, p_targets: Dictionary) -> Array:
	if not debug_no_neighbours:
		return p_owner["regions"]
	var out: Array = []
	for r: Vector2i in p_owner["regions"]:
		if p_targets.has(r) or terrain.data.is_region_loaded(r):
			out.append(r)
	return out


## owner -> {brushes, boxes, regions (existing only), order, reads_domain, sources (owners named by graph
## sources)}
func _collect_owners(p_existing: Dictionary) -> Dictionary:
	var owners := {}
	var size := float(terrain.get_region_size()) * float(terrain.get_vertex_spacing())
	var stack_count: int = terrain.data.get_layer_stack_size()
	var owner_of := {} # brush -> owner, for resolving graph source references
	var nodes: Array = terrain.get_tree().get_nodes_in_group(Pasture3DTerrainBrush.BRUSH_GROUP) \
			if terrain.is_inside_tree() else []
	for n in nodes:
		if not (n is Pasture3DTerrainBrush) or not is_instance_valid(n) or n.terrain != terrain or not n._paints():
			continue
		var owner: String = n.layer_owner_id() if n is Pasture3DLayerBrush else n._layer_owner
		if owner.is_empty():
			continue
		owner_of[n] = owner
		if not owners.has(owner):
			var order: int = terrain.data.find_layer_by_owner(owner)
			# A layer not created yet is appended at the top on its first bake.
			owners[owner] = {"brushes": [], "boxes": [], "regions": {}, "reads_domain": false,
					"sources": [], "order": order if order >= 0 else stack_count + owners.size()}
		var od: Dictionary = owners[owner]
		(od["brushes"] as Array).append(n)
		for box: AABB in n._own_footprints():
			if box.size == Vector3.ZERO:
				continue
			(od["boxes"] as Array).append(box)
			for r: Vector2i in Pasture3DTerrainBrush.footprint_regions(box, size):
				if p_existing.has(r):
					od["regions"][r] = true
		if _reads_domain(n):
			od["reads_domain"] = true
	for o: String in owners:
		var od: Dictionary = owners[o]
		for b in od["brushes"]:
			for src in _graph_source_brushes(b):
				var so: String = owner_of.get(src, "")
				if not so.is_empty() and so != o and not (od["sources"] as Array).has(so):
					(od["sources"] as Array).append(so)
		var keys: Array = od["regions"].keys()
		keys.sort_custom(_region_less)
		od["regions"] = keys
	return owners


## The brushes a brush's graph modifiers name through Road, Shape and Spline Source nodes: the same keys
## `Pasture3DGraphSources` resolves, looked up the same way.
func _graph_source_brushes(p_brush) -> Array:
	var out: Array = []
	if not p_brush._supports_modifiers():
		return out
	for m in p_brush.modifiers:
		if not (m is Pasture3DNodeGraph) or not m.is_active() or m.graph == null:
			continue
		# Searched from the host's own terrain ancestor, as `Pasture3DGraphSources` does: a brush the real
		# resolver cannot reach is not an input.
		var scene_terrain: Node = Pasture3DGraphSources._terrain_of(p_brush)
		for node in m.graph.nodes:
			if node == null:
				continue
			match node.op():
				&"road_source":
					var net := Pasture3DRoadNetwork.find_for(p_brush)
					if net != null and not String(node.road_key).is_empty():
						for rb in net.road_brushes():
							if rb.road_key() == node.road_key:
								out.append(rb)
				&"shape_source":
					if not String(node.shape_key).is_empty():
						for sb in Pasture3DGraphSources.shape_brushes(scene_terrain):
							if sb.shape_key() == node.shape_key:
								out.append(sb)
				&"spline_source":
					if not String(node.spline_key).is_empty():
						for sp in Pasture3DGraphSources.spline_brushes(scene_terrain):
							if sp.spline_key() == node.spline_key:
								out.append(sp)
	return out


func _existing_regions() -> Dictionary:
	var out := {}
	for r: Vector2i in terrain.data.get_region_locations():
		out[r] = true
	var index = terrain.data.get_region_index()
	if index != null:
		for r: Vector2i in index.get_locations():
			out[r] = true
	return out


func _targets(p_scope: int, p_targets: Array, p_existing: Dictionary) -> Dictionary:
	var out := {}
	match p_scope:
		Scope.SELECTED:
			for r in p_targets:
				if p_existing.has(Vector2i(r)):
					out[Vector2i(r)] = true
		Scope.ALL_LOADED:
			for r: Vector2i in terrain.data.get_region_locations():
				out[r] = true
		Scope.ALL_REGIONS:
			out = p_existing.duplicate()
	return out


func _is_locked(p_loc: Vector2i) -> bool:
	var data = terrain.data
	if data.is_region_loaded(p_loc):
		return data.is_region_locked(p_loc)
	var index = data.get_region_index()
	return index != null and index.has_entry(p_loc) and bool(index.get_entry(p_loc).get("locked", false))


## Whether a brush's result depends on its whole domain rather than pointwise on the ground below: an
## erosion solve, a grown relief field or a graph. Frozen ones count too; the closure is about what the
## result was computed FROM, and a re-solve (Bake All clears the freezes) reads the domain again.
static func _reads_domain(p_brush) -> bool:
	if not p_brush.erosion_modifiers().is_empty() or p_brush._has_growing_relief():
		return true
	if p_brush._supports_modifiers():
		for m in p_brush.modifiers:
			if m is Pasture3DNodeGraph and m.is_active():
				return true
	return false


static func _intersects(p_regions: Array, p_set: Dictionary) -> bool:
	for r in p_regions:
		if p_set.has(r):
			return true
	return false


static func _boxes_overlap(p_a: Array, p_b: Array) -> bool:
	for a: AABB in p_a:
		for b: AABB in p_b:
			if a.position.x < b.end.x and b.position.x < a.end.x and a.position.z < b.end.z and b.position.z < a.end.z:
				return true
	return false


static func _region_less(a: Vector2i, b: Vector2i) -> bool:
	return a.y < b.y or (a.y == b.y and a.x < b.x)


static func _first_region(p_regions: Array) -> Vector2i:
	return p_regions[0] if not p_regions.is_empty() else Vector2i(0x7fffffff, 0x7fffffff)
