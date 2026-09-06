# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DSplinePreset — a Plow that arrives with its graph already built.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §9. Two subclasses: Pasture3DRidge and Pasture3DTrough. Both are
# the same node with different numbers in a Path Carve, which is the whole claim the rebuild makes —
# a Ridge is not a kind of brush, it is a Plow whose stack somebody already filled in.
#
# ---- WHY THIS CLASS EXISTS AT ALL, WHEN §9.2 SAYS `extends Pasture3DPlow` ----
#
# It does extend Pasture3DPlow; this sits between. The preset construction, the migration shim, the
# graph wiring and the Add Water override are identical on both subclasses and are all easy to get
# subtly wrong in ways nothing reports — a preset that rebuilds itself on load quietly discards the
# user's edits, a migration that runs twice doubles a height. Written twice, that is twice the chances.
# Recorded as a departure in §9.6.
#
# ---- THE PRESET IS SETUP, NOT SEMANTICS ----
#
# Everything below is reachable by hand: add a Plow, add a Pasture3DSpline child, add a Graph modifier,
# wire Input and Spline Source into a Path Carve. That property is what makes the preset safe to change
# later, and it is why nothing here is hidden or locked. Detach the child spline and the Ridge stops
# carving, which is correct rather than a bug to guard against.
@tool
class_name Pasture3DSplinePreset
extends Pasture3DPlow


## Old `@export`s read off disk by `_set`, applied once the preset exists. See `_apply_migration`.
##
## Held rather than applied immediately because `_set` runs during deserialisation, BEFORE `_ready` —
## there is no graph yet to write `crest_height` into. The dictionary is also the flag: non-empty means
## this node came from a scene saved by the old brush and has not been migrated yet.
var _legacy: Dictionary = {}


## Name of the child Pasture3DSpline the preset creates. "Crest" on a Ridge, "Bed" on a Trough.
func _preset_spline_name() -> String:
	return "Line"


## Fill in `p_carve` for this preset. The one thing a subclass really has to answer.
func _configure_carve(_p_carve: Pasture3DGraphNodePathCarve) -> void:
	pass


## Half-width the preset's child spline starts at, in metres.
func _preset_half_width() -> float:
	return 12.0


func _ready() -> void:
	super._ready()
	# Deferred: `_ready` runs before the scene's own children have all entered, and a preset built here
	# would add a second Pasture3DSpline beside the saved one. By the next idle frame the tree is whole
	# and `_has_preset()` can answer honestly.
	#
	# NOT gated on Engine.is_editor_hint(). A saved scene already has its preset, so at runtime this is a
	# tree walk that finds one and returns; gating it would instead mean a Trough built by code — the
	# simulation's generated rivers, and every bench gate — never gets a graph at all, and that is the one
	# case where the answer differs.
	call_deferred("_build_preset_if_new")


## Build the preset NOW rather than on the next idle frame.
##
## For a caller that builds a preset brush in code and then immediately drives it — `_make_trough` and
## the gates. `_build_preset_if_new` is idempotent, so the deferred call that follows finds the preset
## already there and does nothing.
##
## Unlike the deferred call it does not require being inside the tree: the tree test guards against
## running before a SAVED scene's children have arrived, and a caller that has just built the node in
## code knows there are none.
func install_preset_now() -> void:
	if not _has_preset():
		_install_preset()
	if not _legacy.is_empty():
		_apply_migration()


## Build the preset unless this node already has one.
##
## THE TEST IS THE TREE, NOT A FLAG. A saved boolean would have to survive a duplicate, a scene
## inheritance and a user deleting the child by hand, and it would be wrong in a different way each
## time. "Is there a spline child and a graph modifier" is the same question the preset answers, asked
## of the thing itself.
func _build_preset_if_new() -> void:
	if not is_inside_tree():
		return
	var had_preset := _has_preset()
	if not had_preset:
		_install_preset()
	if not _legacy.is_empty():
		_apply_migration()


func _has_preset() -> bool:
	if _preset_spline() != null:
		return true
	for m in modifiers:
		if m is Pasture3DNodeGraph:
			return true
	return false


## This preset's own child spline, or null. The FIRST Pasture3DSpline child, which is the same rule
## `Pasture3DGraphSources.resolve_splines` uses for the empty-key host fallback — asking a different
## question here would let the loop grow to fit one spline while the carve read another.
func _preset_spline() -> Pasture3DSpline:
	for c in get_children():
		if c is Pasture3DSpline:
			return c as Pasture3DSpline
	return null


## Add the child spline and the graph that reads it.
func _install_preset() -> void:
	var root: Node = get_tree().edited_scene_root if is_inside_tree() else null
	var sp := _preset_spline()
	if sp == null:
		sp = Pasture3DSpline.new()
		sp.name = _preset_spline_name()
		sp.carry_heights = true
		sp.snap_to_surface = false
		sp.half_width = _preset_half_width()
		add_child(sp)
		if root != null:
			sp.owner = root
		# The starter line is added through the spline's own machinery rather than built here, so a
		# preset's first curve is the same curve Add Spline would have given it.
		if sp._get_splines().is_empty():
			var line := sp._new_spline()
			if line != null and root != null:
				line.owner = root
	var has_graph := false
	for m in modifiers:
		if m is Pasture3DNodeGraph:
			has_graph = true
			break
	if has_graph:
		return
	var mod := Pasture3DNodeGraph.new()
	mod.graph = _build_preset_graph()
	# LIVE, not the Pasture3DNodeGraph default of FROZEN. A single carve over one loop is cheap, and a
	# preset that does nothing until you find a Bake button is not a preset. `modifier_warnings` is what
	# tells the user when it has stopped being cheap.
	mod.evaluation = Pasture3DNode.Evaluation.LIVE
	var list: Array[Pasture3DNode] = modifiers.duplicate()
	list.append(mod)
	modifiers = list


## `Input -> Path Carve.surface -> Output`, with `Spline Source -> Path Carve.path`.
##
## A fresh, scene-local Pasture3DTerrainGraph, deliberately not a shared `res://….tres`: two brushes
## sharing one graph resource would each write their own resolved path onto the same Spline Source
## before evaluating, thrashing its revision and defeating the per-node cache for both.
func _build_preset_graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	var inp := Pasture3DGraphNodeInput.new()
	var src := Pasture3DGraphNodeSplineSource.new()
	# Empty key ON PURPOSE: that is the host fallback (§5.1), and it is what makes the preset find its
	# own child without naming it. Name the child and the wiring breaks the moment somebody renames it.
	src.spline_key = ""
	var carve := Pasture3DGraphNodePathCarve.new()
	_configure_carve(carve)
	var outp := Pasture3DGraphNodeOutput.new()
	var list: Array = g.nodes
	list.assign([inp, src, carve, outp])
	g.nodes = list
	g.connections = [[0, 0, 2, 0], [1, 0, 2, 1], [2, 0, 3, 0]]
	g.output_node = 3
	return g


## The Path Carve node this preset drives, or null once the user has taken it out.
func preset_carve() -> Pasture3DGraphNodePathCarve:
	for m in modifiers:
		if not (m is Pasture3DNodeGraph):
			continue
		var g: Pasture3DTerrainGraph = (m as Pasture3DNodeGraph).graph
		if g == null:
			continue
		for n in g.nodes:
			if n is Pasture3DGraphNodePathCarve:
				return n as Pasture3DGraphNodePathCarve
	return null


# ---- migration (§9.5) ------------------------------------------------------------------------------
#
# The old brushes' @exports are on disk. `_set` catches each one as the scene deserialises and parks it;
# `_apply_migration` writes it into the preset once the preset exists.
#
# ---- THIS IS A BEHAVIOUR CHANGE AND IT IS SAID OUT LOUD ----
#
# A migrated Ridge is not bit-identical to the old one and cannot be. The old rasteriser had no loop and
# therefore no rim feather; the new one feathers into the terrain over the Plow's falloff_width, out at
# the loop, where the old one simply stopped at the flank foot. `noise` moves from a per-cell term inside
# the crest maths to a node before the carve, so the same field lands at a different place in the chain.
# What SHOULD match is the crest line and the flank reach, because the drape is the same drape, and that
# is what SplineBrushPresetGate [D] measures — with a stated tolerance, and no claim of parity.


## Legacy names that Pasture3DPlow ALSO declares, and the default to put back once migrated.
##
## `_set` never sees these. Godot calls it only for names the class does not declare, so a saved
## `blend_mode` lands straight on the Plow property of the same name and `_legacy` stays empty for it —
## which is not merely a missed migration, it is a value quietly changing meaning from "how the crest
## meets the ground" to "how this brush's whole layer composites". `_apply_migration` reads these off
## self, runs them through the map like any other, and then puts the property back.
##
## `smooth_passes` is deliberately NOT here. Pasture3DPlow's own `smooth_passes` is the same blur after
## the same rasterisation, so the shadowing IS the migration and there is nothing to move.
const SHADOWED := {"blend_mode": Pasture3DPlow.BlendMode.ADD}


## Old property name -> where it goes. Subclasses fill this in; see `_apply_migration` for the shapes
## the right-hand side may take.
func _migration_map() -> Dictionary:
	return {}


## Catch a legacy `@export` on load. Returning true tells Godot the property was handled, which is what
## stops it being reported as an unknown property on a class that no longer declares it.
func _set(p_name: StringName, p_value) -> bool:
	if _migration_map().has(String(p_name)):
		_legacy[String(p_name)] = p_value
		return true
	return false


## Write the parked legacy values into the preset, then synthesise the loop.
##
## ---- AND THE SPLINES MOVE ----
##
## The old brush's own Path3D children WERE the crest. After migration they belong to the child
## Pasture3DSpline, and the brush's own spline is a NEW loop, synthesised by running
## `fit_loop_to_splines` once. That reparenting is the step that can silently produce a wrong-looking
## brush, which is why it is the step the gate measures rather than the property mapping.
func _apply_migration() -> void:
	var legacy := _legacy
	_legacy = {}
	# The shadowed names, read off self rather than out of `_legacy` — see SHADOWED.
	for key in SHADOWED:
		if _migration_map().has(key) and not legacy.has(key):
			legacy[key] = get(key)
	var carve := preset_carve()
	var sp := _preset_spline()
	if carve == null or sp == null:
		push_warning("[Pasture3D] %s: could not migrate — the preset's graph or spline is missing." % name)
		return
	# The crest lines first: everything else is a number, and the numbers are meaningless on a spline
	# that is not there yet.
	_reparent_legacy_splines(sp)
	for key in legacy:
		var target = _migration_map()[key]
		var value = legacy[key]
		match typeof(target):
			TYPE_CALLABLE:
				(target as Callable).call(value, carve, sp)
			TYPE_ARRAY:
				# ["carve"|"spline", property]
				var obj = carve if target[0] == "carve" else sp
				obj.set(target[1], value)
			_:
				carve.set(String(target), value)
	# The pair that becomes a NODE rather than parameters, after the mapped loop because it is built from
	# both at once and the map has no order.
	_install_noise(legacy.get("noise"), float(legacy.get("noise_strength", 0.0)))
	# The legacy value has been consumed into the preset, so the Plow property it was sitting on goes
	# back to the class default. Left alone, an old Ridge saved with MIN would ALSO composite its whole
	# layer with MIN, applying the same intent twice on two different axes.
	for key in SHADOWED:
		if legacy.has(key):
			set(key, SHADOWED[key])
	# The loop the old brush never had. Once, at migration: after this the user owns it, and
	# `auto_fit_loop` only ever grows it.
	ensure_area_loop()
	_schedule_refresh()


## Move the old brush's Path3D children onto the preset's child spline. They were the crest; they still
## are, they just belong to the node that publishes it now.
func _reparent_legacy_splines(p_spline: Pasture3DSpline) -> void:
	var root: Node = get_tree().edited_scene_root if is_inside_tree() else null
	var incoming: Array = _get_splines()
	if incoming.is_empty():
		return
	# The starter stub goes first. `_install_preset` gives every new preset a two-point line so a
	# hand-placed Ridge has something to drag, and on a MIGRATING one that stub is not a spare: it sits
	# at the brush's origin, the Spline Source finds it alongside the real crest, and the carve follows
	# whichever comes first. The symptom is a ridge at the right height in the wrong place, which reads
	# as a transform bug rather than as an extra line nobody asked for.
	for stub in p_spline._get_splines():
		p_spline.remove_child(stub)
		stub.queue_free()
	for path in incoming:
		if path == null:
			continue
		remove_child(path)
		p_spline.add_child(path)
		if root != null:
			path.owner = root
		p_spline._connect_spline(path)


# ---- Add Water (§12.2) ------------------------------------------------------------------------------


## The spline Add Water should follow: the preset's CHILD, not the brush's loop.
##
## ---- WHY THIS OVERRIDE HAS TO EXIST ----
##
## `_build_pool_for` decides lake-versus-river from the curve: closed fills as a Pool, open becomes a
## Stream. That rule is right and it is the reason a Mound whose loop you open becomes a river. But
## after S6 a Trough's OWN spline is always a closed loop, so Add Water on one would build a moat —
## where `pasture3d_stream.gd`'s header says "Normally created by pressing Add Water on a
## Pasture3DTrough".
##
## Option (a) of §12.2: source the child. It preserves the documented relationship, and the child spline
## is precisely what Pasture3DStream already wants — it takes its level from the BANKS it measures
## either side of the line and treats the spline as the bed floor, which is what a Trough's spline has
## always been. Nothing about the closed/open rule changes: a preset whose child line is a ring still
## gets a Pool, and it should.
func _water_source_splines() -> Array:
	var sp := _preset_spline()
	if sp == null:
		return super._water_source_splines()
	var out := sp._get_splines()
	return out if not out.is_empty() else super._water_source_splines()


## The old `noise` + `noise_strength` as a Pasture3DNodeNoise BEFORE the carve.
##
## Before, not after, and that is the behaviour change §9.5 names. The old term was added INSIDE the
## crest maths, masked by the cross-section, so it jittered the crest and faded with the flank. A Noise
## node roughens the SURFACE the carve then drapes onto, so the same field lands at a different place in
## the chain and the result is a rougher hillside rather than a wobblier ridgeline. Both are things
## people want; only one of them is what the old property did, and pretending otherwise by burying a
## `noise` parameter back inside Path Carve would put a per-cell term inside a node that has a GPU
## kernel and a gate.
func _install_noise(p_noise, p_strength: float) -> void:
	if p_noise == null or absf(p_strength) <= 0.0:
		return
	var mod := Pasture3DNodeNoise.new()
	mod.noise = p_noise
	mod.strength = p_strength
	# At the FRONT: it is the surface the carve reads, so anything after the carve would roughen the
	# crest the carve just placed.
	var list: Array[Pasture3DNode] = modifiers.duplicate()
	list.insert(0, mod)
	modifiers = list


## Replace the preset's starter line with `p_path`, for a caller that has already computed the line the
## brush is meant to carve — the simulation's generated rivers, and the gates' fixtures.
##
## Replace rather than add: `_install_preset` gives every new preset a starter curve so a hand-placed
## Ridge has something to drag, and a caller supplying its own line wants ITS line carved, not its line
## plus a two-point stub sitting at the origin.
func adopt_preset_line(p_path: Path3D) -> void:
	var sp := _preset_spline()
	if sp == null or p_path == null:
		return
	for existing in sp._get_splines():
		if existing == p_path:
			continue
		sp.remove_child(existing)
		existing.queue_free()
	if p_path.get_parent() != sp:
		if p_path.get_parent() != null:
			p_path.get_parent().remove_child(p_path)
		sp.add_child(p_path)
	var root: Node = get_tree().edited_scene_root if is_inside_tree() else null
	if root != null:
		p_path.owner = root
	sp._connect_spline(p_path)


## Make sure the brush has an AREA loop, and fit it around the preset's line.
##
## `_install_preset` deliberately does not do this: a hand-placed Ridge gets its loop from the Place
## Brush tool, drawn where the user clicked. A preset built in code has no such gesture, so a caller that
## supplied its own line calls this to get the ring that bounds it.
func ensure_area_loop() -> void:
	if _get_splines().is_empty():
		_new_spline()
	fit_loop_to_splines()
